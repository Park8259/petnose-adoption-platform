from __future__ import annotations

import argparse
import csv
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
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
SCHEMA_VERSION = 1
SCOPE_LOCAL_MODEL_ONLY = "local-model-only"
SCOPE_LOCAL_DIRECT_EMBEDDER = "local-direct-embedder"
STATISTICS_SCHEMA = {
    "mean": "arithmetic_mean",
    "p50": "linear_interpolated_50th_percentile",
    "p95": "linear_interpolated_95th_percentile",
    "warmup": "excluded_from_statistics",
}
STATISTICS_HELP = """Statistical definitions:
  Mean: arithmetic average of measured latencies.
  P50: median measured latency.
  P95: 95th percentile measured latency.
  Warm-up runs are excluded from all reported statistics.
  Percentiles use linear interpolation between sorted samples.
"""


@dataclass(frozen=True, slots=True)
class FixtureImage:
    label: str
    content_type: str
    image_bytes: bytes


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export and compare dog-nose-identification2 ONNX Runtime CPU inference.",
        epilog=STATISTICS_HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser(
        "export",
        help="Export torch+timm embedder to ONNX.",
        epilog=STATISTICS_HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_model_args(export_parser)
    export_parser.add_argument("--output", required=True, help="Output .onnx path.")
    export_parser.add_argument("--opset", type=positive_int, default=17)
    export_parser.add_argument("--no-dynamic-batch", action="store_true")
    export_parser.add_argument("--summary-json", default="")
    export_parser.set_defaults(func=export_onnx)

    compare_parser = subparsers.add_parser(
        "compare",
        help="Compare PyTorch and ONNX vectors.",
        epilog=STATISTICS_HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_model_args(compare_parser)
    add_onnx_args(compare_parser)
    add_fixture_args(compare_parser)
    compare_parser.add_argument("--output-dir", default="")
    compare_parser.set_defaults(func=compare_vectors)

    benchmark_parser = subparsers.add_parser(
        "benchmark",
        help="Benchmark PyTorch and ONNX direct inference.",
        epilog=STATISTICS_HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_model_args(benchmark_parser)
    add_onnx_args(benchmark_parser)
    add_fixture_args(benchmark_parser)
    benchmark_parser.add_argument("--batch-sizes", default="1,5")
    benchmark_parser.add_argument("--warmup", type=non_negative_int, default=3)
    benchmark_parser.add_argument("--runs", type=positive_int, default=20)
    benchmark_parser.add_argument("--output-dir", default="")
    benchmark_parser.set_defaults(func=benchmark_runtimes)

    batch_compare_parser = subparsers.add_parser(
        "batch-compare",
        help="Compare five sequential PyTorch embed calls with one PyTorch embed_batch call.",
        epilog=STATISTICS_HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    add_model_args(batch_compare_parser)
    add_fixture_args(batch_compare_parser)
    batch_compare_parser.add_argument("--batch-size", type=positive_int, default=5)
    batch_compare_parser.add_argument("--warmup", type=non_negative_int, default=2)
    batch_compare_parser.add_argument("--runs", type=positive_int, default=10)
    batch_compare_parser.add_argument("--output-dir", default="")
    batch_compare_parser.set_defaults(func=batch_compare)

    args = parser.parse_args()
    result = args.func(args)
    assert_sanitized_payload(result)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def add_model_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--model-dir", default="/models/dog_nose_identification2")
    parser.add_argument("--model-path", default="")
    parser.add_argument("--embed-device", default="cpu", help="PyTorch embedder device, e.g. cpu or cuda:0.")
    parser.add_argument(
        "--embed-device-required",
        action="store_true",
        help="Fail if the requested PyTorch embedder device cannot be used.",
    )
    parser.add_argument(
        "--disable-tf32",
        action="store_true",
        help="Deprecated no-op; PyTorch TF32 math is disabled by default for strict CUDA/ONNX parity.",
    )
    parser.add_argument(
        "--allow-tf32",
        action="store_true",
        help="Allow PyTorch TF32 math for exploratory CUDA performance checks.",
    )


def add_onnx_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--onnx", required=True, help="Exported ONNX model path.")
    parser.add_argument("--model-tag", default="s101_224")
    parser.add_argument("--image-size", type=positive_int, default=224)


def add_fixture_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--fixtures", nargs="+", required=True, help="Image files or directories.")
    parser.add_argument("--limit", type=non_negative_int, default=0, help="Optional maximum number of images.")
    parser.add_argument(
        "--label-mode",
        choices=("basename", "index"),
        default="index",
        help="Fixture label written to summaries. Use index to avoid local filename disclosure.",
    )


def export_onnx(args: argparse.Namespace) -> dict[str, Any]:
    embedder = load_torch_embedder(
        args.model_dir,
        args.model_path,
        torch_device_arg(args),
        torch_device_required_arg(args),
        torch_disable_tf32_arg(args),
    )
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

    result = with_schema(
        SCOPE_LOCAL_MODEL_ONLY,
        {
            "status": "ok",
            "onnx_path": safe_path_name(output_path),
            "onnx_artifact": safe_path_name(output_path),
            "onnx_size_bytes": output_path.stat().st_size,
            "model": embedder.model_name,
            "checkpoint": safe_path_name(getattr(embedder, "_resolved_model_path", None)),
            "source_backend": embedder.backend,
            "target_backend": "onnxruntime-cpu",
            "image_size": embedder._image_size,
            "vector_dim": embedder.vector_dim,
            "opset": args.opset,
            "dynamic_batch": not args.no_dynamic_batch,
            "onnx_checker": checker_status,
        },
    )
    if args.summary_json:
        write_json(Path(args.summary_json), result)
    return result


def compare_vectors(args: argparse.Namespace) -> dict[str, Any]:
    fixtures = collect_fixtures(args.fixtures, args.limit, args.label_mode)
    torch_embedder = load_torch_embedder(
        args.model_dir,
        args.model_path,
        torch_device_arg(args),
        torch_device_required_arg(args),
        torch_disable_tf32_arg(args),
    )
    onnx_embedder = load_onnx_embedder(args)
    np = onnx_embedder._np

    rows = []
    for fixture in fixtures:
        torch_result = torch_embedder.embed(fixture.image_bytes, fixture.content_type)
        onnx_result = onnx_embedder.embed(fixture.image_bytes, fixture.content_type)
        torch_vector = np.asarray(torch_result.vector, dtype=np.float32)
        onnx_vector = np.asarray(onnx_result.vector, dtype=np.float32)
        diff = np.abs(torch_vector - onnx_vector)
        l2_diff = float(np.linalg.norm(torch_vector - onnx_vector))
        torch_norm = float(np.linalg.norm(torch_vector))
        onnx_norm = float(np.linalg.norm(onnx_vector))
        cosine = float(np.dot(torch_vector, onnx_vector) / max(torch_norm * onnx_norm, 1e-12))
        rows.append(
            with_row_schema(
                SCOPE_LOCAL_MODEL_ONLY,
                {
                    "label": fixture.label,
                    "dimension": int(torch_vector.shape[0]),
                    "max_abs_diff": float(diff.max()),
                    "l2_diff": l2_diff,
                    "mean_abs_diff": float(diff.mean()),
                    "cosine": cosine,
                    "torch_norm": torch_norm,
                    "onnx_norm": onnx_norm,
                },
            )
        )

    summary = with_schema(
        SCOPE_LOCAL_MODEL_ONLY,
        {
            "status": "ok",
            "statistics": STATISTICS_SCHEMA,
            "fixtures": len(fixtures),
            "torch_model": torch_embedder.model_name,
            "torch_backend": torch_embedder.backend,
            "torch_device": torch_embedder.device,
            "onnx_model": onnx_embedder.model_name,
            "onnx_backend": onnx_embedder.backend,
            "max_abs_diff": max(row["max_abs_diff"] for row in rows),
            "max_l2_diff": max(row["l2_diff"] for row in rows),
            "mean_abs_diff": statistics.fmean(row["mean_abs_diff"] for row in rows),
            "min_cosine": min(row["cosine"] for row in rows),
            "mean_cosine": statistics.fmean(row["cosine"] for row in rows),
            "rows": rows,
        },
    )
    write_outputs(args.output_dir, "comparison", summary, rows)
    return summary


def benchmark_runtimes(args: argparse.Namespace) -> dict[str, Any]:
    fixtures = collect_fixtures(args.fixtures, args.limit, args.label_mode)
    batch_sizes = parse_batch_sizes(args.batch_sizes)
    torch_embedder = load_torch_embedder(
        args.model_dir,
        args.model_path,
        torch_device_arg(args),
        torch_device_required_arg(args),
        torch_disable_tf32_arg(args),
    )
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
                synchronize_if_cuda(embedder)
                started = time.perf_counter()
                results = embedder.embed_batch(inputs)
                synchronize_if_cuda(embedder)
                elapsed_ms = (time.perf_counter() - started) * 1000.0
                if len(results) != batch_size:
                    raise RuntimeError(f"Unexpected result count: expected={batch_size}, actual={len(results)}")
                total_ms.append(elapsed_ms)

            rows.append(
                summarize_latency(
                    runtime_name,
                    embedder.backend,
                    batch_size,
                    total_ms,
                    int(getattr(embedder, "vector_dim", 0) or 0),
                )
            )

    summary = with_schema(
        SCOPE_LOCAL_MODEL_ONLY,
        {
            "status": "ok",
            "statistics": STATISTICS_SCHEMA,
            "fixtures": len(fixtures),
            "warmup": args.warmup,
            "runs": args.runs,
            "batch_sizes": batch_sizes,
            "torch_model": torch_embedder.model_name,
            "torch_device": torch_embedder.device,
            "onnx_model": onnx_embedder.model_name,
            "rows": rows,
        },
    )
    write_outputs(args.output_dir, "benchmark", summary, rows)
    return summary


def batch_compare(args: argparse.Namespace) -> dict[str, Any]:
    fixtures = collect_fixtures(args.fixtures, args.limit, args.label_mode)
    if len(fixtures) < args.batch_size:
        raise RuntimeError(f"At least {args.batch_size} fixture images are required.")

    selected = fixtures[: args.batch_size]
    embedder = load_torch_embedder(
        args.model_dir,
        args.model_path,
        torch_device_arg(args),
        torch_device_required_arg(args),
        torch_disable_tf32_arg(args),
    )

    for _ in range(args.warmup):
        run_sequential_embed(embedder, selected)
        run_batch_embed(embedder, selected)

    sequential_ms: list[float] = []
    batch_ms: list[float] = []
    dimension = int(getattr(embedder, "vector_dim", 0) or 0)
    for _ in range(args.runs):
        synchronize_if_cuda(embedder)
        started = time.perf_counter()
        sequential_results = run_sequential_embed(embedder, selected)
        synchronize_if_cuda(embedder)
        sequential_ms.append((time.perf_counter() - started) * 1000.0)

        synchronize_if_cuda(embedder)
        started = time.perf_counter()
        batch_results = run_batch_embed(embedder, selected)
        synchronize_if_cuda(embedder)
        batch_ms.append((time.perf_counter() - started) * 1000.0)

        result = (batch_results or sequential_results)[0]
        dimension = int(getattr(result, "dimension", dimension) or dimension)

    summary = build_batch_compare_summary(
        embedder=embedder,
        fixtures=selected,
        batch_size=args.batch_size,
        warmup=args.warmup,
        runs=args.runs,
        sequential_ms=sequential_ms,
        batch_ms=batch_ms,
        dimension=dimension,
    )
    write_outputs(args.output_dir, "batch_compare", summary, summary["rows"])
    return summary


def load_torch_embedder(
    model_dir: str,
    model_path: str,
    embed_device: str = "cpu",
    embed_device_required: bool = False,
    disable_tf32: bool = False,
) -> DogNoseIdentification2Embedder:
    embedder = DogNoseIdentification2Embedder(
        model_dir=model_dir,
        model_path=model_path.strip() or None,
        embed_device=embed_device,
        embed_device_required=embed_device_required,
        cuda_allow_tf32=not disable_tf32,
    )
    if not embedder.load():
        raise RuntimeError(f"PyTorch embedder load failed: {embedder.load_error}")
    if disable_tf32:
        disable_torch_tf32(embedder)
    return embedder


def torch_device_arg(args: argparse.Namespace) -> str:
    return str(getattr(args, "embed_device", "cpu") or "cpu")


def torch_device_required_arg(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "embed_device_required", False))


def torch_disable_tf32_arg(args: argparse.Namespace) -> bool:
    return not bool(getattr(args, "allow_tf32", False))


def disable_torch_tf32(embedder: Any) -> None:
    torch = getattr(embedder, "_torch", None)
    if torch is None:
        return
    if hasattr(torch.backends, "cuda"):
        torch.backends.cuda.matmul.allow_tf32 = False
    if hasattr(torch.backends, "cudnn"):
        torch.backends.cudnn.allow_tf32 = False


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


def synchronize_if_cuda(embedder: Any) -> None:
    device = str(getattr(embedder, "device", "") or "").lower()
    torch = getattr(embedder, "_torch", None)
    if torch is not None and device.startswith("cuda") and torch.cuda.is_available():
        torch.cuda.synchronize()


def run_sequential_embed(embedder: Any, fixtures: list[FixtureImage]) -> list[Any]:
    results = [embedder.embed(item.image_bytes, item.content_type) for item in fixtures]
    if len(results) != len(fixtures):
        raise RuntimeError(f"Unexpected sequential result count: expected={len(fixtures)}, actual={len(results)}")
    return results


def run_batch_embed(embedder: Any, fixtures: list[FixtureImage]) -> list[Any]:
    inputs = [EmbedInput(item.image_bytes, item.content_type) for item in fixtures]
    results = embedder.embed_batch(inputs)
    if len(results) != len(fixtures):
        raise RuntimeError(f"Unexpected batch result count: expected={len(fixtures)}, actual={len(results)}")
    return results


def build_batch_compare_summary(
    *,
    embedder: Any,
    fixtures: list[FixtureImage],
    batch_size: int,
    warmup: int,
    runs: int,
    sequential_ms: list[float],
    batch_ms: list[float],
    dimension: int,
) -> dict[str, Any]:
    stats = summarize_batch_comparison(sequential_ms, batch_ms)
    row = with_row_schema(
        SCOPE_LOCAL_DIRECT_EMBEDDER,
        {
            "runtime": "torch",
            "backend": str(getattr(embedder, "backend", "")),
            "dimension": dimension,
            "batch_size": batch_size,
            "runs": runs,
            **stats,
        },
    )
    return with_schema(
        SCOPE_LOCAL_DIRECT_EMBEDDER,
        {
            "status": "ok",
            "statistics": STATISTICS_SCHEMA,
            "runtime": "torch",
            "backend": str(getattr(embedder, "backend", "")),
            "dimension": dimension,
            "model": str(getattr(embedder, "model_name", "")),
            "checkpoint": safe_path_name(getattr(embedder, "_resolved_model_path", None)),
            "fixtures": len(fixtures),
            "fixture_labels": [item.label for item in fixtures],
            "batch_size": batch_size,
            "warmup": warmup,
            "runs": runs,
            **stats,
            "rows": [row],
        },
    )


def summarize_batch_comparison(sequential_ms: list[float], batch_ms: list[float]) -> dict[str, float]:
    sequential_mean = statistics.fmean(sequential_ms)
    sequential_p50 = percentile(sequential_ms, 50)
    sequential_p95 = percentile(sequential_ms, 95)
    batch_mean = statistics.fmean(batch_ms)
    batch_p50 = percentile(batch_ms, 50)
    batch_p95 = percentile(batch_ms, 95)
    mean_saved = sequential_mean - batch_mean
    return {
        "sequential_mean_ms": sequential_mean,
        "sequential_p50_ms": sequential_p50,
        "sequential_p95_ms": sequential_p95,
        "batch_mean_ms": batch_mean,
        "batch_p50_ms": batch_p50,
        "batch_p95_ms": batch_p95,
        "mean_saved_ms": mean_saved,
        "mean_reduction_percent": reduction_percent(sequential_mean, batch_mean),
        "p95_reduction_percent": reduction_percent(sequential_p95, batch_p95),
        "speedup": speedup(sequential_mean, batch_mean),
    }


def reduction_percent(original_ms: float, new_ms: float) -> float:
    if original_ms <= 0 or math.isnan(original_ms):
        return math.nan
    return ((original_ms - new_ms) / original_ms) * 100.0


def speedup(original_ms: float, new_ms: float) -> float:
    if new_ms <= 0 or math.isnan(new_ms):
        return math.inf
    return original_ms / new_ms


def collect_fixtures(paths: list[str], limit: int, label_mode: str = "index") -> list[FixtureImage]:
    if label_mode not in {"basename", "index"}:
        raise ValueError("--label-mode must be basename or index.")

    hits: list[Path] = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            hits.extend(
                sorted(
                    (p for p in path.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES),
                    key=fixture_sort_key,
                )
            )
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
    for index, path in enumerate(unique, start=1):
        fixtures.append(
            FixtureImage(
                label=fixture_label(path, index, label_mode),
                content_type=content_type_for(path),
                image_bytes=path.read_bytes(),
            )
        )
    return fixtures


def fixture_sort_key(path: Path) -> list[tuple[int, int | str]]:
    parts = re.split(r"(\d+)", path.name.lower())
    return [(0, int(part)) if part.isdigit() else (1, part) for part in parts]


def fixture_label(path: Path, index: int, label_mode: str) -> str:
    if label_mode == "basename":
        return path.name
    return f"fixture_{index:03d}"


def content_type_for(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if suffix == ".png":
        return "image/png"
    raise ValueError(f"Unsupported image extension: {path}")


def parse_batch_sizes(raw: str) -> list[int]:
    parsed = [parse_positive_int(part.strip(), "--batch-sizes") for part in raw.split(",") if part.strip()]
    if not parsed:
        raise ValueError("--batch-sizes must contain positive integers.")

    values: list[int] = []
    for value in parsed:
        if value not in values:
            values.append(value)
    return values


def positive_int(raw: str) -> int:
    try:
        return parse_positive_int(raw, "value")
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def non_negative_int(raw: str) -> int:
    try:
        value = int(str(raw).strip())
    except ValueError as exc:
        raise argparse.ArgumentTypeError("value must be an integer.") from exc
    if value < 0:
        raise argparse.ArgumentTypeError("value must be zero or a positive integer.")
    return value


def parse_positive_int(raw: str, option_name: str) -> int:
    try:
        value = int(str(raw).strip())
    except ValueError as exc:
        raise ValueError(f"{option_name} must contain positive integers.") from exc
    if value <= 0:
        raise ValueError(f"{option_name} must contain positive integers.")
    return value


def make_batches(fixtures: list[FixtureImage], batch_size: int, count: int) -> list[list[FixtureImage]]:
    batches = []
    for batch_index in range(count):
        start = batch_index * batch_size
        batches.append([fixtures[(start + offset) % len(fixtures)] for offset in range(batch_size)])
    return batches


def summarize_latency(
    runtime_name: str,
    backend: str,
    batch_size: int,
    total_ms: list[float],
    dimension: int,
) -> dict[str, Any]:
    per_image_ms = [value / batch_size for value in total_ms]
    return with_row_schema(
        SCOPE_LOCAL_MODEL_ONLY,
        {
            "runtime": runtime_name,
            "backend": backend,
            "dimension": dimension,
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
        },
    )


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
        assert_sanitized_payload(rows)
        with (root / f"{stem}.csv").open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)


def write_json(path: Path, data: dict[str, Any]) -> None:
    assert_sanitized_payload(data)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def with_schema(scope: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {"schema_version": SCHEMA_VERSION, "benchmark_scope": scope, **payload}


def with_row_schema(scope: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {"schema_version": SCHEMA_VERSION, "benchmark_scope": scope, **payload}


def safe_path_name(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    candidates = [
        PureWindowsPath(text).name,
        PurePosixPath(text).name,
        Path(text).name,
    ]
    names = [candidate for candidate in candidates if candidate]
    return min(names, key=len) if names else text


def assert_sanitized_payload(payload: Any) -> None:
    validate_sanitized_value(payload, [])


def validate_sanitized_value(value: Any, path: list[str]) -> None:
    key = path[-1].lower() if path else ""
    if key in {"vector", "vectors", "embedding", "embeddings", "image_bytes", "raw_image", "raw_vector"}:
        raise ValueError(f"Unsafe raw data field in benchmark output: {'.'.join(path)}")

    if isinstance(value, str):
        if looks_like_absolute_path(value):
            raise ValueError(f"Unsafe absolute path in benchmark output: {'.'.join(path)}")
        return

    if isinstance(value, dict):
        for child_key, child_value in value.items():
            validate_sanitized_value(child_value, [*path, str(child_key)])
        return

    if isinstance(value, (list, tuple)):
        if len(value) > 16 and all(isinstance(item, (int, float)) for item in value):
            raise ValueError(f"Unsafe raw vector-like array in benchmark output: {'.'.join(path)}")
        for index, child_value in enumerate(value):
            validate_sanitized_value(child_value, [*path, str(index)])


def looks_like_absolute_path(value: str) -> bool:
    text = value.strip()
    if not text:
        return False
    if re.match(r"^[A-Za-z]:[\\/]", text):
        return True
    if text.startswith(("/", "\\")):
        return True
    if PureWindowsPath(text).is_absolute() or PurePosixPath(text).is_absolute():
        return True
    lowered = text.replace("\\", "/").lower()
    return "/users/" in lowered or "/home/" in lowered


if __name__ == "__main__":
    raise SystemExit(main())
