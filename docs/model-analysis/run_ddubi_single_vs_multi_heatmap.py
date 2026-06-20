from __future__ import annotations

import argparse
import csv
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont


REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_EMBED_ROOT = REPO_ROOT / "python-embed"
if str(PYTHON_EMBED_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_EMBED_ROOT))

from app.embedding.base import EmbedInput
from app.embedding.dog_nose_identification2_embedder import DogNoseIdentification2Embedder


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


@dataclass(frozen=True)
class ImageRecord:
    number: int
    path: Path


def parse_number_spec(value: str) -> list[int]:
    numbers: list[int] = []
    for part in value.split(","):
        item = part.strip()
        if not item:
            continue
        if "-" in item:
            start_text, end_text = item.split("-", 1)
            start = int(start_text)
            end = int(end_text)
            if end < start:
                raise ValueError(f"Invalid descending range: {item}")
            numbers.extend(range(start, end + 1))
        else:
            numbers.append(int(item))
    deduped = sorted(set(numbers))
    if len(deduped) != len(numbers):
        raise ValueError(f"Duplicate image numbers in spec: {value}")
    if not deduped:
        raise ValueError("At least one image number is required")
    return deduped


def content_type(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if suffix == ".png":
        return "image/png"
    if suffix == ".webp":
        return "image/webp"
    return "application/octet-stream"


def find_numbered_images(image_dir: Path, required_numbers: Iterable[int]) -> dict[int, ImageRecord]:
    if not image_dir.exists():
        raise FileNotFoundError("Image directory does not exist")
    hits: dict[int, ImageRecord] = {}
    duplicates: dict[int, list[str]] = {}
    for path in sorted(image_dir.iterdir(), key=lambda item: numeric_sort_key(item.name)):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        try:
            number = int(path.stem)
        except ValueError:
            continue
        if number in hits:
            duplicates.setdefault(number, [hits[number].path.name]).append(path.name)
            continue
        hits[number] = ImageRecord(number=number, path=path)
    if duplicates:
        detail = ", ".join(f"{number}: {names}" for number, names in sorted(duplicates.items()))
        raise RuntimeError(f"Duplicate numeric image filenames found: {detail}")
    missing = [number for number in sorted(required_numbers) if number not in hits]
    if missing:
        raise RuntimeError(f"Missing required image numbers: {missing}")
    return {number: hits[number] for number in sorted(required_numbers)}


def numeric_sort_key(name: str) -> tuple[int, int | str]:
    stem = Path(name).stem
    try:
        return (0, int(stem))
    except ValueError:
        return (1, name.lower())


def load_embedder(model_dir: Path, model_path: Path | None, device: str) -> DogNoseIdentification2Embedder:
    embedder = DogNoseIdentification2Embedder(
        model_dir=str(model_dir),
        model_path=str(model_path) if model_path else None,
        embed_device=device,
    )
    if not embedder.load():
        raise RuntimeError(f"Failed to load embedder: {embedder.load_error}")
    return embedder


def embed_records(
    embedder: DogNoseIdentification2Embedder,
    records: list[ImageRecord],
) -> dict[int, list[float]]:
    inputs = [
        EmbedInput(image_bytes=record.path.read_bytes(), content_type=content_type(record.path))
        for record in records
    ]
    results = embedder.embed_batch(inputs)
    return {record.number: result.vector for record, result in zip(records, results)}


def dot(a: list[float], b: list[float]) -> float:
    return float(sum(x * y for x, y in zip(a, b)))


def stats(values: Iterable[float]) -> dict[str, float]:
    data = list(values)
    if not data:
        return {"count": 0.0, "mean": 0.0, "min": 0.0, "max": 0.0, "std": 0.0}
    mean = sum(data) / len(data)
    variance = sum((value - mean) ** 2 for value in data) / len(data)
    return {
        "count": float(len(data)),
        "mean": mean,
        "min": min(data),
        "max": max(data),
        "std": math.sqrt(variance),
    }


def fmt(value: float) -> str:
    return f"{value:.4f}"


def csv_float(value: float) -> str:
    return f"{value:.10f}"


def blend(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    return tuple(round(c1[index] + (c2[index] - c1[index]) * t) for index in range(3))


def color_for(value: float, vmin: float, vmax: float) -> tuple[int, int, int]:
    if vmax <= vmin:
        t = 1.0
    else:
        t = (value - vmin) / (vmax - vmin)
    t = max(0.0, min(1.0, t))
    low = (247, 251, 255)
    mid = (107, 174, 214)
    high = (8, 81, 156)
    if t < 0.55:
        return blend(low, mid, t / 0.55)
    return blend(mid, high, (t - 0.55) / 0.45)


def text_color_for(rgb: tuple[int, int, int]) -> tuple[int, int, int]:
    luminance = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]
    return (255, 255, 255) if luminance < 122 else (21, 35, 52)


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    try:
        return ImageFont.truetype("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf", size)
    except OSError:
        return ImageFont.load_default()


def text_size(draw: ImageDraw.ImageDraw, text: str, fnt: ImageFont.ImageFont) -> tuple[int, int]:
    box = draw.multiline_textbbox((0, 0), text, font=fnt, spacing=4)
    return box[2] - box[0], box[3] - box[1]


def draw_centered_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int, int, int],
    text: str,
    fnt: ImageFont.ImageFont,
    fill: tuple[int, int, int],
    spacing: int = 4,
) -> None:
    left, top, right, bottom = xy
    width, height = text_size(draw, text, fnt)
    x = left + (right - left - width) / 2
    y = top + (bottom - top - height) / 2
    draw.multiline_text((x, y), text, font=fnt, fill=fill, align="center", spacing=spacing)


def draw_colorbar(
    draw: ImageDraw.ImageDraw,
    x: int,
    y: int,
    width: int,
    height: int,
    vmin: float,
    vmax: float,
    label_font: ImageFont.ImageFont,
) -> None:
    for index in range(width):
        value = vmin + (vmax - vmin) * (index / max(width - 1, 1))
        draw.line((x + index, y, x + index, y + height), fill=color_for(value, vmin, vmax))
    draw.rectangle((x, y, x + width, y + height), outline=(135, 148, 166), width=1)
    draw.text((x, y + height + 6), fmt(vmin), font=label_font, fill=(51, 65, 85))
    max_label = fmt(vmax)
    max_w, _ = text_size(draw, max_label, label_font)
    draw.text((x + width - max_w, y + height + 6), max_label, font=label_font, fill=(51, 65, 85))


def draw_heatmap(
    path: Path,
    title: str,
    subtitle: str,
    row_labels: list[str],
    col_labels: list[str],
    values: list[list[float]],
    cell_labels: list[list[str]],
    caption_lines: list[str],
    vmin: float,
    vmax: float,
    cell_w: int,
    cell_h: int,
    left_margin: int,
) -> None:
    title_font = font(30, bold=True)
    subtitle_font = font(16)
    axis_font = font(15, bold=True)
    cell_font = font(14, bold=True)
    caption_font = font(15)
    small_font = font(13)
    top_margin = 136
    header_h = 44
    bottom_margin = 130
    right_margin = 56
    width = left_margin + len(col_labels) * cell_w + right_margin
    height = top_margin + header_h + len(row_labels) * cell_h + bottom_margin

    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    draw.text((34, 24), title, font=title_font, fill=(15, 23, 42))
    draw.text((36, 64), subtitle, font=subtitle_font, fill=(71, 85, 105))
    scale_w = min(460, max(260, len(col_labels) * cell_w // 3))
    draw_colorbar(draw, width - scale_w - 34, 30, scale_w, 18, vmin, vmax, small_font)

    grid_x = left_margin
    grid_y = top_margin + header_h
    for col_idx, label in enumerate(col_labels):
        x0 = grid_x + col_idx * cell_w
        draw_centered_text(draw, (x0, top_margin, x0 + cell_w, top_margin + header_h), label, axis_font, (51, 65, 85))
    for row_idx, label in enumerate(row_labels):
        y0 = grid_y + row_idx * cell_h
        draw_centered_text(draw, (26, y0, left_margin - 12, y0 + cell_h), label, axis_font, (51, 65, 85))
        for col_idx, value in enumerate(values[row_idx]):
            x0 = grid_x + col_idx * cell_w
            fill = color_for(value, vmin, vmax)
            draw.rectangle((x0, y0, x0 + cell_w, y0 + cell_h), fill=fill, outline=(226, 232, 240), width=2)
            draw_centered_text(
                draw,
                (x0 + 4, y0 + 4, x0 + cell_w - 4, y0 + cell_h - 4),
                cell_labels[row_idx][col_idx],
                cell_font,
                text_color_for(fill),
                spacing=2,
            )
    cap_y = grid_y + len(row_labels) * cell_h + 24
    for line in caption_lines:
        draw.text((34, cap_y), line, font=caption_font, fill=(51, 65, 85))
        cap_y += 25
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)


def draw_summary(path: Path, rows: list[dict[str, str]]) -> None:
    title_font = font(28, bold=True)
    header_font = font(15, bold=True)
    body_font = font(14)
    columns = [
        ("Target", 82),
        ("Single ref1", 120),
        ("Multi max", 120),
        ("Delta max", 110),
        ("Best ref", 92),
        ("Multi mean", 120),
        ("Delta mean", 116),
    ]
    width = 46 + sum(width for _, width in columns) + 46
    row_h = 42
    height = 112 + row_h * (len(rows) + 1) + 58
    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    draw.text((34, 28), "Single vs multi-reference summary (Targets 6-13)", font=title_font, fill=(15, 23, 42))
    draw.text((36, 66), "Delta = multi aggregated score - single reference score", font=body_font, fill=(71, 85, 105))

    x = 46
    y = 112
    for label, width_value in columns:
        draw.rectangle((x, y, x + width_value, y + row_h), fill=(241, 245, 249), outline=(203, 213, 225), width=1)
        draw_centered_text(draw, (x, y, x + width_value, y + row_h), label, header_font, (30, 41, 59))
        x += width_value

    for row_index, row in enumerate(rows):
        x = 46
        y0 = y + row_h * (row_index + 1)
        fill = (255, 255, 255) if row_index % 2 == 0 else (248, 250, 252)
        values = [
            row["target"],
            row["single"],
            row["multi_max"],
            row["delta_max"],
            row["best_ref"],
            row["multi_mean"],
            row["delta_mean"],
        ]
        for (_, width_value), value in zip(columns, values):
            draw.rectangle((x, y0, x + width_value, y0 + row_h), fill=fill, outline=(226, 232, 240), width=1)
            color = (22, 101, 52) if value.startswith("+") else (51, 65, 85)
            draw_centered_text(draw, (x, y0, x + width_value, y0 + row_h), value, body_font, color)
            x += width_value
    img.save(path)


def write_csv(path: Path, rows: list[dict[str, object]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def stat_row(scenario: str, score_type: str, target_images: str, values: list[float], notes: str = "") -> dict[str, object]:
    summary = stats(values)
    return {
        "row_type": "stats",
        "scenario": scenario,
        "score_type": score_type,
        "target_image_number": "",
        "reference_image_number": "",
        "count": int(summary["count"]),
        "mean": csv_float(summary["mean"]),
        "min": csv_float(summary["min"]),
        "max": csv_float(summary["max"]),
        "std": csv_float(summary["std"]),
        "single_score": "",
        "multi_max_score": "",
        "multi_mean_score": "",
        "delta_max_vs_single": "",
        "delta_mean_vs_single": "",
        "best_reference_image_number": "",
        "target_images": target_images,
        "reference_images": "",
        "notes": notes,
    }


def write_markdown_summary(
    output_path: Path,
    image_numbers: list[int],
    reference_images: list[int],
    target_images: list[int],
    embedder: DogNoseIdentification2Embedder,
    single_stats_all: dict[str, float],
    single_stats_comparable: dict[str, float],
    multi_max_stats: dict[str, float],
    multi_mean_stats: dict[str, float],
    full_matrix_stats: dict[str, float],
    deltas: list[dict[str, object]],
    vmin: float,
    vmax: float,
) -> None:
    best = max(deltas, key=lambda row: float(row["delta_max_vs_single"]))
    weakest = min(deltas, key=lambda row: float(row["single_score"]))
    lowest_case_improvement = multi_max_stats["min"] - single_stats_comparable["min"]
    checkpoint_path = getattr(embedder, "_resolved_model_path", None)
    checkpoint_basename = checkpoint_path.name if checkpoint_path else "unknown"
    lines = [
        "# Ddubi single-reference vs multi-reference heatmap",
        "",
        "## Inputs",
        "",
        "- Source directory: `<fixture-dir>`",
        "- Images: " + ", ".join(f"`{number}.<ext>`" for number in image_numbers),
        "- Numeric filename sorting was used.",
        "",
        "## Method",
        "",
        "- Embedder: project `DogNoseIdentification2Embedder` from `python-embed/app/embedding/dog_nose_identification2_embedder.py`.",
        f"- Model: `{embedder.model_name}`.",
        f"- Vector dimension: `{embedder.vector_dim}`.",
        f"- Runtime device: `{embedder.device}`.",
        f"- Checkpoint basename: `{checkpoint_basename}`.",
        f"- Checkpoint exists: `{checkpoint_path is not None}`.",
        f"- Reference images: `{','.join(str(number) for number in reference_images)}`.",
        f"- Target images: `{','.join(str(number) for number in target_images)}`.",
        "- Embeddings are L2-normalized by the project embedder; scores below are cosine similarities.",
        f"- Heatmaps use a common color scale: `{vmin:.2f}` to `{vmax:.2f}`.",
        "",
        "## Summary metrics",
        "",
        "| Scenario | Targets | Mean | Min | Max | Std |",
        "|---|---:|---:|---:|---:|---:|",
        f"| Single reference, ref {reference_images[0]} | {target_images[0]}-{target_images[-1]} | {single_stats_comparable['mean']:.4f} | {single_stats_comparable['min']:.4f} | {single_stats_comparable['max']:.4f} | {single_stats_comparable['std']:.4f} |",
        f"| Multi reference max, refs {reference_images[0]}-{reference_images[-1]} | {target_images[0]}-{target_images[-1]} | {multi_max_stats['mean']:.4f} | {multi_max_stats['min']:.4f} | {multi_max_stats['max']:.4f} | {multi_max_stats['std']:.4f} |",
        f"| Multi reference mean, refs {reference_images[0]}-{reference_images[-1]} | {target_images[0]}-{target_images[-1]} | {multi_mean_stats['mean']:.4f} | {multi_mean_stats['min']:.4f} | {multi_mean_stats['max']:.4f} | {multi_mean_stats['std']:.4f} |",
        f"| Multi full matrix cells | {target_images[0]}-{target_images[-1]} | {full_matrix_stats['mean']:.4f} | {full_matrix_stats['min']:.4f} | {full_matrix_stats['max']:.4f} | {full_matrix_stats['std']:.4f} |",
        "",
        "## Presentation summary",
        "",
        f"- Comparable single-reference mean: `{single_stats_comparable['mean']:.4f}`.",
        f"- Multi-reference max mean: `{multi_max_stats['mean']:.4f}`.",
        f"- Lowest-case improvement by max aggregation: `{lowest_case_improvement:+.4f}`.",
        f"- Largest target-level max improvement: image `{best['target_image_number']}` from `{float(best['single_score']):.4f}` to `{float(best['multi_max_score']):.4f}`.",
        f"- Weakest single-reference target: image `{weakest['target_image_number']}` from `{float(weakest['single_score']):.4f}` to `{float(weakest['multi_max_score']):.4f}`.",
        "",
        "This is matching-stability evidence, not classification-accuracy evidence.",
    ]
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--reference-images", required=True, help="Comma-separated numbers or ranges, for example 1-5")
    parser.add_argument("--target-images", required=True, help="Comma-separated numbers or ranges, for example 6-13")
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--model-path", type=Path)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--vmin", type=float, default=0.65)
    parser.add_argument("--vmax", type=float, default=1.00)
    args = parser.parse_args()

    reference_images = parse_number_spec(args.reference_images)
    target_images = parse_number_spec(args.target_images)
    required_numbers = sorted(set(reference_images + target_images))
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    image_map = find_numbered_images(args.image_dir, required_numbers)
    records = [image_map[number] for number in required_numbers]
    embedder = load_embedder(args.model_dir, args.model_path, args.device)
    vectors = embed_records(embedder, records)

    single_ref = reference_images[0]
    single_targets = [target for target in target_images if target != single_ref]
    single_scores = {target: dot(vectors[single_ref], vectors[target]) for target in single_targets}
    full_matrix = {
        ref: {target: dot(vectors[ref], vectors[target]) for target in target_images}
        for ref in reference_images
    }
    multi_max = {target: max(full_matrix[ref][target] for ref in reference_images) for target in target_images}
    multi_mean = {
        target: sum(full_matrix[ref][target] for ref in reference_images) / len(reference_images)
        for target in target_images
    }
    best_ref = {target: max(reference_images, key=lambda ref: full_matrix[ref][target]) for target in target_images}

    single_stats_all = stats(single_scores.values())
    single_stats_comparable = stats(single_scores[target] for target in target_images)
    multi_max_stats = stats(multi_max.values())
    multi_mean_stats = stats(multi_mean.values())
    full_matrix_stats = stats(full_matrix[ref][target] for ref in reference_images for target in target_images)

    single_values = [[single_scores[target] for target in target_images]]
    single_labels = [[f"Img {target}\n{fmt(single_scores[target])}" for target in target_images]]
    draw_heatmap(
        output_dir / "ddubi_single_reference_heatmap.png",
        f"Single-reference registration (Ref: {single_ref})",
        f"Model {embedder.model_name} | cosine similarity",
        [f"Ref {single_ref}"],
        [f"Target {target}" for target in target_images],
        single_values,
        single_labels,
        [
            f"Targets {target_images[0]}-{target_images[-1]}: mean {single_stats_comparable['mean']:.4f}, min {single_stats_comparable['min']:.4f}, std {single_stats_comparable['std']:.4f}",
            "This chart contains scores only; raw images and vectors are not written.",
        ],
        args.vmin,
        args.vmax,
        cell_w=128,
        cell_h=84,
        left_margin=112,
    )

    multi_rows = [f"Ref {ref}" for ref in reference_images] + ["Target max", "Target mean"]
    multi_values = [[full_matrix[ref][target] for target in target_images] for ref in reference_images]
    multi_values.append([multi_max[target] for target in target_images])
    multi_values.append([multi_mean[target] for target in target_images])
    multi_labels = [
        [f"R{ref}-T{target}\n{fmt(full_matrix[ref][target])}" for target in target_images]
        for ref in reference_images
    ]
    multi_labels.append([f"T{target} max\n{fmt(multi_max[target])}" for target in target_images])
    multi_labels.append([f"T{target} mean\n{fmt(multi_mean[target])}" for target in target_images])
    draw_heatmap(
        output_dir / "ddubi_multi_reference_heatmap.png",
        f"Multi-reference registration (Refs: {reference_images[0]}-{reference_images[-1]})",
        "Full reference-target matrix with target-level max and mean aggregation",
        multi_rows,
        [f"Target {target}" for target in target_images],
        multi_values,
        multi_labels,
        [
            f"Max aggregation: mean {multi_max_stats['mean']:.4f}, min {multi_max_stats['min']:.4f}, std {multi_max_stats['std']:.4f}",
            f"Mean aggregation: mean {multi_mean_stats['mean']:.4f}, min {multi_mean_stats['min']:.4f}, std {multi_mean_stats['std']:.4f}",
        ],
        args.vmin,
        args.vmax,
        cell_w=128,
        cell_h=74,
        left_margin=148,
    )

    delta_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, str]] = []
    for target in target_images:
        delta_max = multi_max[target] - single_scores[target]
        delta_mean = multi_mean[target] - single_scores[target]
        delta_rows.append(
            {
                "target_image_number": target,
                "single_score": single_scores[target],
                "multi_max_score": multi_max[target],
                "multi_mean_score": multi_mean[target],
                "delta_max_vs_single": delta_max,
                "delta_mean_vs_single": delta_mean,
                "best_reference_image_number": best_ref[target],
            }
        )
        summary_rows.append(
            {
                "target": f"Img {target}",
                "single": fmt(single_scores[target]),
                "multi_max": fmt(multi_max[target]),
                "delta_max": f"{delta_max:+.4f}",
                "best_ref": f"Ref {best_ref[target]}",
                "multi_mean": fmt(multi_mean[target]),
                "delta_mean": f"{delta_mean:+.4f}",
            }
        )
    draw_summary(output_dir / "ddubi_single_vs_multi_summary.png", summary_rows)

    write_csv(
        output_dir / "ddubi_similarity_single.csv",
        [
            {
                "reference_image_number": single_ref,
                "reference_filename": image_map[single_ref].path.name,
                "target_image_number": target,
                "target_filename": image_map[target].path.name,
                "cosine_similarity": csv_float(single_scores[target]),
                "model": embedder.model_name,
                "dimension": embedder.vector_dim,
            }
            for target in single_targets
        ],
        [
            "reference_image_number",
            "reference_filename",
            "target_image_number",
            "target_filename",
            "cosine_similarity",
            "model",
            "dimension",
        ],
    )

    multi_csv_rows: list[dict[str, object]] = []
    for target in target_images:
        for ref in reference_images:
            multi_csv_rows.append(
                {
                    "reference_image_number": ref,
                    "reference_filename": image_map[ref].path.name,
                    "target_image_number": target,
                    "target_filename": image_map[target].path.name,
                    "cosine_similarity": csv_float(full_matrix[ref][target]),
                    "target_max_similarity": csv_float(multi_max[target]),
                    "target_mean_similarity": csv_float(multi_mean[target]),
                    "best_reference_image_number": best_ref[target],
                    "is_best_reference": str(ref == best_ref[target]).lower(),
                    "model": embedder.model_name,
                    "dimension": embedder.vector_dim,
                }
            )
    write_csv(
        output_dir / "ddubi_similarity_multi.csv",
        multi_csv_rows,
        [
            "reference_image_number",
            "reference_filename",
            "target_image_number",
            "target_filename",
            "cosine_similarity",
            "target_max_similarity",
            "target_mean_similarity",
            "best_reference_image_number",
            "is_best_reference",
            "model",
            "dimension",
        ],
    )

    summary_csv_rows = [
        stat_row("single_reference_ref1_comparable", "cosine", f"{target_images[0]}-{target_images[-1]}", [single_scores[target] for target in target_images]),
        stat_row("multi_reference_refs", "target_max_similarity", f"{target_images[0]}-{target_images[-1]}", list(multi_max.values())),
        stat_row("multi_reference_refs", "target_mean_similarity", f"{target_images[0]}-{target_images[-1]}", list(multi_mean.values())),
        stat_row("multi_reference_refs_full_matrix", "reference_target_cosine", f"{target_images[0]}-{target_images[-1]}", [full_matrix[ref][target] for ref in reference_images for target in target_images]),
    ]
    for row in delta_rows:
        summary_csv_rows.append(
            {
                "row_type": "target_delta",
                "scenario": "single_vs_multi_comparable",
                "score_type": "target_delta",
                "target_image_number": row["target_image_number"],
                "reference_image_number": f"{single_ref} vs {reference_images[0]}-{reference_images[-1]}",
                "count": "",
                "mean": "",
                "min": "",
                "max": "",
                "std": "",
                "single_score": csv_float(float(row["single_score"])),
                "multi_max_score": csv_float(float(row["multi_max_score"])),
                "multi_mean_score": csv_float(float(row["multi_mean_score"])),
                "delta_max_vs_single": csv_float(float(row["delta_max_vs_single"])),
                "delta_mean_vs_single": csv_float(float(row["delta_mean_vs_single"])),
                "best_reference_image_number": row["best_reference_image_number"],
                "target_images": row["target_image_number"],
                "reference_images": f"{single_ref};{reference_images[0]}-{reference_images[-1]}",
                "notes": "",
            }
        )
    summary_fields = [
        "row_type",
        "scenario",
        "score_type",
        "target_image_number",
        "reference_image_number",
        "count",
        "mean",
        "min",
        "max",
        "std",
        "single_score",
        "multi_max_score",
        "multi_mean_score",
        "delta_max_vs_single",
        "delta_mean_vs_single",
        "best_reference_image_number",
        "target_images",
        "reference_images",
        "notes",
    ]
    write_csv(output_dir / "ddubi_similarity_summary.csv", summary_csv_rows, summary_fields)
    write_markdown_summary(
        output_dir / "ddubi-single-vs-multi-heatmap.md",
        required_numbers,
        reference_images,
        target_images,
        embedder,
        single_stats_all,
        single_stats_comparable,
        multi_max_stats,
        multi_mean_stats,
        full_matrix_stats,
        delta_rows,
        args.vmin,
        args.vmax,
    )

    checkpoint_path = getattr(embedder, "_resolved_model_path", None)
    print(f"model={embedder.model_name}")
    print(f"dimension={embedder.vector_dim}")
    print(f"checkpoint_basename={checkpoint_path.name if checkpoint_path else 'unknown'}")
    print(f"checkpoint_exists={checkpoint_path is not None}")
    print("output_dir=<output-dir>")


if __name__ == "__main__":
    main()
