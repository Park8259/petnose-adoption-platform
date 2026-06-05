from __future__ import annotations

import argparse
import csv
import itertools
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_EMBED_ROOT = REPO_ROOT / "python-embed"
if str(PYTHON_EMBED_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_EMBED_ROOT))

from app.embedding.dog_nose_identification2_embedder import DogNoseIdentification2Embedder
from app.embedding.image_preprocess import decode_rgb_image


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png"}


@dataclass(frozen=True)
class ImageRecord:
    dog_id: str
    path: Path


def numeric_sort_key(path: Path) -> tuple[int, str]:
    try:
        return int(path.name), path.name
    except ValueError:
        return 10**9, path.name


def image_sort_key(path: Path) -> str:
    return path.name.lower()


def select_records(dataset_dir: Path, dog_limit: int, images_per_dog: int) -> dict[str, list[ImageRecord]]:
    dog_dirs = sorted([p for p in dataset_dir.iterdir() if p.is_dir()], key=numeric_sort_key)
    selected: dict[str, list[ImageRecord]] = {}

    for dog_dir in dog_dirs:
        images = sorted(
            [p for p in dog_dir.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS],
            key=image_sort_key,
        )
        if len(images) < 4:
            continue
        # Prefer dogs that can supply 3 registration references and 2 validation images.
        if len(images) < images_per_dog:
            continue
        selected[dog_dir.name] = [ImageRecord(dog_dir.name, p) for p in images[:images_per_dog]]
        if len(selected) >= dog_limit:
            break

    if len(selected) < dog_limit:
        for dog_dir in dog_dirs:
            if dog_dir.name in selected:
                continue
            images = sorted(
                [p for p in dog_dir.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS],
                key=image_sort_key,
            )
            if len(images) < 4:
                continue
            selected[dog_dir.name] = [ImageRecord(dog_dir.name, p) for p in images[: min(images_per_dog, len(images))]]
            if len(selected) >= dog_limit:
                break

    return selected


def load_embedder(model_dir: Path, device: str) -> DogNoseIdentification2Embedder:
    embedder = DogNoseIdentification2Embedder(
        model_dir=str(model_dir),
        model_path=None,
        embed_device=device,
    )
    if not embedder.load():
        raise RuntimeError(f"Failed to load embedder: {embedder.load_error}")
    return embedder


def batch_embeddings(
    embedder: DogNoseIdentification2Embedder,
    records: Iterable[ImageRecord],
    batch_size: int,
) -> dict[str, list[float]]:
    torch = embedder._torch
    records = list(records)
    vectors: dict[str, list[float]] = {}

    for start in range(0, len(records), batch_size):
        batch_records = records[start : start + batch_size]
        tensors = []
        for record in batch_records:
            image = decode_rgb_image(record.path.read_bytes())
            tensors.append(embedder._preprocess(image))
        batch = torch.stack(tensors).to(embedder._runtime_device)
        with torch.inference_mode():
            features = embedder._model(batch, return_logits=False)
            features = torch.nn.functional.normalize(features, p=2, dim=1)
        for record, vector in zip(batch_records, features.detach().cpu().float().tolist()):
            vectors[str(record.path)] = vector
    return vectors


def dot(a: list[float], b: list[float]) -> float:
    return float(sum(x * y for x, y in zip(a, b)))


def normalized_centroid(vectors: list[list[float]]) -> list[float]:
    dim = len(vectors[0])
    centroid = [0.0] * dim
    for vector in vectors:
        for i, value in enumerate(vector):
            centroid[i] += value
    inv_n = 1.0 / len(vectors)
    centroid = [value * inv_n for value in centroid]
    norm = math.sqrt(sum(value * value for value in centroid)) or 1.0
    return [value / norm for value in centroid]


def stats(values: list[float]) -> dict[str, float]:
    if not values:
        return {"count": 0, "mean": 0.0, "min": 0.0, "max": 0.0, "std": 0.0}
    mean = sum(values) / len(values)
    variance = sum((value - mean) ** 2 for value in values) / len(values)
    return {
        "count": len(values),
        "mean": mean,
        "min": min(values),
        "max": max(values),
        "std": math.sqrt(variance),
    }


def quantiles(values: list[float]) -> dict[str, float]:
    if not values:
        return {}
    ordered = sorted(values)

    def q(p: float) -> float:
        if len(ordered) == 1:
            return ordered[0]
        pos = (len(ordered) - 1) * p
        lo = math.floor(pos)
        hi = math.ceil(pos)
        if lo == hi:
            return ordered[lo]
        return ordered[lo] * (hi - pos) + ordered[hi] * (pos - lo)

    return {
        "p01": q(0.01),
        "p05": q(0.05),
        "p10": q(0.10),
        "p25": q(0.25),
        "p50": q(0.50),
        "p75": q(0.75),
        "p90": q(0.90),
        "p95": q(0.95),
        "p99": q(0.99),
    }


def write_pairwise(
    output_path: Path,
    selected: dict[str, list[ImageRecord]],
    vectors: dict[str, list[float]],
) -> dict[str, dict[str, float]]:
    rows = []

    for dog_id, records in selected.items():
        record = records[0]
        score = dot(vectors[str(record.path)], vectors[str(record.path)])
        rows.append(
            {
                "experiment": "A_same_file",
                "dog_id_a": dog_id,
                "image_a": str(record.path),
                "dog_id_b": dog_id,
                "image_b": str(record.path),
                "cosine_score": f"{score:.10f}",
            }
        )

    for dog_id, records in selected.items():
        for left, right in itertools.combinations(records, 2):
            score = dot(vectors[str(left.path)], vectors[str(right.path)])
            rows.append(
                {
                    "experiment": "B_same_dog_different_images",
                    "dog_id_a": dog_id,
                    "image_a": str(left.path),
                    "dog_id_b": dog_id,
                    "image_b": str(right.path),
                    "cosine_score": f"{score:.10f}",
                }
            )

    dog_items = list(selected.items())
    for (dog_a, records_a), (dog_b, records_b) in itertools.combinations(dog_items, 2):
        for left in records_a:
            for right in records_b:
                score = dot(vectors[str(left.path)], vectors[str(right.path)])
                rows.append(
                    {
                        "experiment": "C_different_dogs",
                        "dog_id_a": dog_a,
                        "image_a": str(left.path),
                        "dog_id_b": dog_b,
                        "image_b": str(right.path),
                        "cosine_score": f"{score:.10f}",
                    }
                )

    with output_path.open("w", newline="", encoding="utf-8") as fp:
        writer = csv.DictWriter(
            fp,
            fieldnames=["experiment", "dog_id_a", "image_a", "dog_id_b", "image_b", "cosine_score"],
        )
        writer.writeheader()
        writer.writerows(rows)

    grouped: dict[str, list[float]] = {}
    for row in rows:
        grouped.setdefault(row["experiment"], []).append(float(row["cosine_score"]))
    return {key: stats(values) | quantiles(values) for key, values in grouped.items()}


def multi_scores(query: list[float], refs: list[list[float]]) -> dict[str, float]:
    ref_scores = sorted([dot(query, ref) for ref in refs], reverse=True)
    centroid_score = dot(query, normalized_centroid(refs))
    max_reference_score = ref_scores[0]
    top2_average_score = sum(ref_scores[:2]) / min(2, len(ref_scores))
    return {
        "single_reference_score": ref_scores[-1] if len(ref_scores) == 1 else dot(query, refs[0]),
        "centroid_score": centroid_score,
        "max_reference_score": max_reference_score,
        "top2_average_score": top2_average_score,
        "centroid_plus_max_score": 0.5 * (centroid_score + max_reference_score),
    }


def write_multi_reference(
    output_path: Path,
    selected: dict[str, list[ImageRecord]],
    vectors: dict[str, list[float]],
) -> dict[str, dict[str, dict[str, float]]]:
    registration: dict[str, list[ImageRecord]] = {}
    validation: dict[str, list[ImageRecord]] = {}

    for dog_id, records in selected.items():
        registration[dog_id] = records[:3]
        validation[dog_id] = records[3:]

    rows = []
    for query_dog_id, query_records in validation.items():
        for query_record in query_records:
            query_vector = vectors[str(query_record.path)]
            for target_dog_id, ref_records in registration.items():
                refs = [vectors[str(record.path)] for record in ref_records]
                scores = multi_scores(query_vector, refs)
                rows.append(
                    {
                        "query_dog_id": query_dog_id,
                        "target_dog_id": target_dog_id,
                        "is_same_dog": str(query_dog_id == target_dog_id).lower(),
                        "query_image": str(query_record.path),
                        "reference_images": "|".join(str(record.path) for record in ref_records),
                        "reference_count": len(ref_records),
                        **{key: f"{value:.10f}" for key, value in scores.items()},
                    }
                )

    fieldnames = [
        "query_dog_id",
        "target_dog_id",
        "is_same_dog",
        "query_image",
        "reference_images",
        "reference_count",
        "single_reference_score",
        "centroid_score",
        "max_reference_score",
        "top2_average_score",
        "centroid_plus_max_score",
    ]
    with output_path.open("w", newline="", encoding="utf-8") as fp:
        writer = csv.DictWriter(fp, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    by_label: dict[str, dict[str, list[float]]] = {}
    for row in rows:
        label = "positive_same_dog" if row["is_same_dog"] == "true" else "negative_different_dogs"
        by_label.setdefault(label, {})
        for method in fieldnames[6:]:
            by_label[label].setdefault(method, []).append(float(row[method]))

    return {
        label: {method: stats(values) | quantiles(values) for method, values in methods.items()}
        for label, methods in by_label.items()
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--dataset-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--dog-limit", default=50, type=int)
    parser.add_argument("--images-per-dog", default=5, type=int)
    parser.add_argument("--batch-size", default=8, type=int)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    selected = select_records(args.dataset_dir, args.dog_limit, args.images_per_dog)
    if not selected:
        raise RuntimeError(f"No dog folders selected from {args.dataset_dir}")

    all_records = [record for records in selected.values() for record in records]
    embedder = load_embedder(args.model_dir, args.device)
    vectors = batch_embeddings(embedder, all_records, args.batch_size)

    pairwise_summary = write_pairwise(args.output_dir / "pairwise_scores.csv", selected, vectors)
    multi_summary = write_multi_reference(args.output_dir / "multi_reference_scores.csv", selected, vectors)

    payload = {
        "model_name": embedder.model_name,
        "vector_dim": embedder.vector_dim,
        "device": embedder.device,
        "model_path": str(embedder._resolved_model_path),
        "image_size": embedder._image_size,
        "dataset_dir": str(args.dataset_dir),
        "dog_count": len(selected),
        "image_count": len(all_records),
        "images_per_dog_requested": args.images_per_dog,
        "selected_dog_ids": list(selected.keys()),
        "pairwise_summary": pairwise_summary,
        "multi_reference_summary": multi_summary,
    }
    (args.output_dir / "experiment_summary.json").write_text(
        json.dumps(payload, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    print(json.dumps(payload, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
