from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path
import statistics
import sys
import time
from typing import Any


PYTHON_EMBED_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_EMBED_ROOT))

from app.embedding.base import EmbedInput  # noqa: E402
from app.embedding.dog_nose_identification2_embedder import DogNoseIdentification2Embedder  # noqa: E402
from app.embedding.dog_nose_identification2_onnx_embedder import DogNoseIdentification2OnnxEmbedder  # noqa: E402


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}


@dataclass(frozen=True, slots=True)
class FixtureImage:
    label: str
    content_type: str
    image_bytes: bytes


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export and compare dog-nose-identification2 ONNX Runtime CPU inference.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export", help="Export torch+timm embedder to ONNX.")
    add_model_args(export_parser)
    export_parser.add_argument("--output", required=True, help="Output .onnx path.")
    export_parser.add_argument("--opset", type=int, default=17)
    export_parser.add_argument("--no-dynamic-batch", action="store_true")
    export_parser.add_argument("--summary-json", default="")
    export_parser.set_defaults(func=export_onnx)

    compare_parser = subparsers.add_parser("compare", help="Compare PyTorch and ONNX vectors.")
    add_model_args(compare_parser)
    add_onnx_args(compare_parser)
    add_fixture_args(compare_parser)
    compare_parser.add_argument("--output-dir", default="")
    compare_parser.set_defaults(func=compare_vectors)

    benchmark_parser = subparsers.add_parser("benchmark", help="Benchmark PyTorch and ONNX direct inference.")
    add_model_args(benchmark_parser)
    add_onnx_args(benchmark_parser)
    add_fixture_args(benchmark_parser)
    benchmark_parser.add_argument("--batch-sizes", default="1,5")
    benchmark_parser.add_argument("--warmup", type=int, default=3)
    benchmark_parser.add_argument("--runs", type=int, default=20)
    benchmark_parser.add_argument("--output-dir", default="")
    benchmark_parser.set_defaults(func=benchmark_runtimes)

    args = parser.parse_args()
    result = args.func(args)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def add_model_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--model-dir", default="/models/dog_nose_identification2")
    parser.add_argument("--model-path", default="")


def add_onnx_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--onnx", required=True, help="Exported ONNX model path.")
    parser.add_argument("--model-tag", default="s101_224")
    parser.add_argument("--image-size", type=int, default=224)


def add_fixture_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--fixtures", nargs="+", required=True, help="Image files or directories.")
    parser.add_argument("--limit", type=int, default=0, help="Optional maximum number of images.")


def export_onnx(args: argparse.Namespace) -> dict[str, Any]:
    embedder = load_torch_embedder(args.model_dir, args.model_path)
    torch = embedder._torch

    class NormalizedEmbedding(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, images):
            embedding = self.model(images, return_logits=False)
            return torch.nn.functional.normalize(embedding, p=2, dim=1)

    model = NormalizedEmbedding(embedder._model).eval().cpu()
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    dummy = torch.randn(1, 3, embedder._image_size, embedder._image_size, dtype=torch.float32)
    dynamic_axes = None
    if not args.no_dynamic_batch:
        dynamic_axes = {"images": {0: "batch"}, "embeddings": {0: "batch"}}

    with torch.inference_mode():
        torch.onnx.export(
            model,
            dummy,
            str(output_path),
            export_params=True,
            opset_version=args.opset,
            do_constant_folding=True,
            input_names=["images"],
            output_names=["embeddings"],
            dynamic_axes=dynamic_axes,
        )

    checker_status = "not_checked"
    try:
        import onnx  # type: ignore

        onnx_model = onnx.load(str(output_path))
        onnx.checker.check_model(onnx_model)
        checker_status = "ok"
    except Exception as exc:  # pragma: no cover - optional dependency
        checker_status = f"failed: {type(exc).__name__}"

    result = {
        "status": "ok",
        "onnx_path": str(output_path),
        "onnx_size_bytes": output_path.stat().st_size,
        "model": embedder.model_name,
        "source_backend": embedder.backend,
        "target_backend": "onnxruntime-cpu",
        "image_size": embedder._image_size,
        "vector_dim": embedder.vector_dim,
        "opset": args.opset,
        "dynamic_batch": not args.no_dynamic_batch,
        "onnx_checker": checker_status,
    }
    if args.summary_json:
        write_json(Path(args.summary_json), result)
    return result


def compare_vectors(args: argparse.Namespace) -> dict[str, Any]:
    fixtures = collect_fixtures(args.fixtures, args.limit)
    torch_embedder = load_torch_embedder(args.model_dir, args.model_path)
    onnx_embedder = load_onnx_embedder(args)
    np = onnx_embedder._np

    rows = []
    for fixture in fixtures:
        torch_result = torch_embedder.embed(fixture.image_bytes, fixture.content_type)
        onnx_result = onnx_embedder.embed(fixture.image_bytes, fixture.content_type)
        torch_vector = np.asarray(torch_result.vector, dtype=np.float32)
        onnx_vector = np.asarray(onnx_result.vector, dtype=np.float32)
        diff = np.abs(torch_vector - onnx_vector)
        torch_norm = float(np.linalg.norm(torch_vector))
        onnx_norm = float(np.linalg.norm(onnx_vector))
        cosine = float(np.dot(torch_vector, onnx_vector) / max(torch_norm * onnx_norm, 1e-12))
        rows.append(
            {
                "label": fixture.label,
                "dimension": int(torch_vector.shape[0]),
                "max_abs_diff": float(diff.max()),
                "mean_abs_diff": float(diff.mean()),
                "cosine": cosine,
                "torch_norm": torch_norm,
                "onnx_norm": onnx_norm,
            }
        )

    summary = {
        "status": "ok",
        "fixtures": len(fixtures),
        "torch_model": torch_embedder.model_name,
        "torch_backend": torch_embedder.backend,
        "onnx_model": onnx_embedder.model_name,
        "onnx_backend": onnx_embedder.backend,
        "max_abs_diff": max(row["max_abs_diff"] for row in rows),
        "mean_abs_diff": statistics.fmean(row["mean_abs_diff"] for row in rows),
        "min_cosine": min(row["cosine"] for row in rows),
        "mean_cosine": statistics.fmean(row["cosine"] for row in rows),
        "rows": rows,
    }
    write_outputs(args.output_dir, "comparison", summary, rows)
    return summary


def benchmark_runtimes(args: argparse.Namespace) -> dict[str, Any]:
    fixtures = collect_fixtures(args.fixtures, args.limit)
    batch_sizes = parse_batch_sizes(args.batch_sizes)
    torch_embedder = load_torch_embedder(args.model_dir, args.model_path)
    onnx_embedder = load_onnx_embedder(args)

    rows = []
    for runtime_name, embedder in (("torch", torch_embedder), ("onnxruntime", onnx_embedder)):
        for batch_size in batch_sizes:
            batches = make_batches(fixtures, batch_size, args.warmup + args.runs)
            for batch in batches[: args.warmup]:
                embedder.embed_batch([EmbedInput(item.image_bytes, item.content_type) for item in batch])

            total_ms = []
            for batch in batches[args.warmup :]:
                inputs = [EmbedInput(item.image_bytes, item.content_type) for item in batch]
                started = time.perf_counter()
                results = embedder.embed_batch(inputs)
                elapsed_ms = (time.perf_counter() - started) * 1000.0
                if len(results) != batch_size:
                    raise RuntimeError(f"Unexpected result count: expected={batch_size}, actual={len(results)}")
                total_ms.append(elapsed_ms)

            rows.append(summarize_latency(runtime_name, embedder.backend, batch_size, total_ms))

    summary = {
        "status": "ok",
        "fixtures": len(fixtures),
        "warmup": args.warmup,
        "runs": args.runs,
        "batch_sizes": batch_sizes,
        "torch_model": torch_embedder.model_name,
        "onnx_model": onnx_embedder.model_name,
        "rows": rows,
    }
    write_outputs(args.output_dir, "benchmark", summary, rows)
    return summary


def load_torch_embedder(model_dir: str, model_path: str) -> DogNoseIdentification2Embedder:
    embedder = DogNoseIdentification2Embedder(
        model_dir=model_dir,
        model_path=model_path.strip() or None,
        embed_device="cpu",
    )
    if not embedder.load():
        raise RuntimeError(f"PyTorch embedder load failed: {embedder.load_error}")
    return embedder


def load_onnx_embedder(args: argparse.Namespace) -> DogNoseIdentification2OnnxEmbedder:
    embedder = DogNoseIdentification2OnnxEmbedder(
        model_dir=args.model_dir,
        onnx_path=args.onnx,
        model_tag=args.model_tag,
        default_image_size=args.image_size,
    )
    if not embedder.load():
        raise RuntimeError(f"ONNX Runtime embedder load failed: {embedder.load_error}")
    return embedder


def collect_fixtures(paths: list[str], limit: int) -> list[FixtureImage]:
    hits: list[Path] = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            hits.extend(sorted(p for p in path.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES))
        elif path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES:
            hits.append(path)
        else:
            raise FileNotFoundError(f"Fixture image path not found or unsupported: {raw}")

    unique = list(dict.fromkeys(path.resolve() for path in hits))
    if limit > 0:
        unique = unique[:limit]
    if not unique:
        raise RuntimeError("No fixture images found.")

    fixtures = []
    for path in unique:
        fixtures.append(
            FixtureImage(
                label=f"{path.parent.name}/{path.name}",
                content_type=content_type_for(path),
                image_bytes=path.read_bytes(),
            )
        )
    return fixtures


def content_type_for(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if suffix == ".png":
        return "image/png"
    raise ValueError(f"Unsupported image extension: {path}")


def parse_batch_sizes(raw: str) -> list[int]:
    values = [int(part.strip()) for part in raw.split(",") if part.strip()]
    if not values or any(value <= 0 for value in values):
        raise ValueError("--batch-sizes must contain positive integers.")
    return values


def make_batches(fixtures: list[FixtureImage], batch_size: int, count: int) -> list[list[FixtureImage]]:
    batches = []
    for batch_index in range(count):
        start = batch_index * batch_size
        batches.append([fixtures[(start + offset) % len(fixtures)] for offset in range(batch_size)])
    return batches


def summarize_latency(runtime_name: str, backend: str, batch_size: int, total_ms: list[float]) -> dict[str, Any]:
    per_image_ms = [value / batch_size for value in total_ms]
    return {
        "runtime": runtime_name,
        "backend": backend,
        "batch_size": batch_size,
        "runs": len(total_ms),
        "total_mean_ms": statistics.fmean(total_ms),
        "total_p50_ms": percentile(total_ms, 50),
        "total_p95_ms": percentile(total_ms, 95),
        "total_min_ms": min(total_ms),
        "total_max_ms": max(total_ms),
        "per_image_mean_ms": statistics.fmean(per_image_ms),
        "per_image_p50_ms": percentile(per_image_ms, 50),
        "per_image_p95_ms": percentile(per_image_ms, 95),
    }


def percentile(values: list[float], percent: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * (percent / 100.0)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def write_outputs(output_dir: str, stem: str, summary: dict[str, Any], rows: list[dict[str, Any]]) -> None:
    if not output_dir:
        return
    root = Path(output_dir)
    root.mkdir(parents=True, exist_ok=True)
    write_json(root / f"{stem}_summary.json", summary)
    if rows:
        with (root / f"{stem}.csv").open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
