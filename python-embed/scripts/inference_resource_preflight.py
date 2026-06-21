from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import statistics
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any, Callable


PYTHON_EMBED_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_EMBED_ROOT))

from app.embedding.base import EmbedInput  # noqa: E402
from app.embedding.dog_nose_identification2_embedder import DogNoseIdentification2Embedder  # noqa: E402
from app.embedding.dog_nose_identification2_onnx_embedder import DogNoseIdentification2OnnxEmbedder  # noqa: E402
from app.nose_extraction import (  # noqa: E402
    DEFAULT_CLASS_NAMES,
    LEGACY_YOLOV5_BACKEND,
    DogNoseExtractionConfig,
    DogNoseExtractor,
    LegacyYolov5DogNoseDetector,
    NoseDetection,
    UltralyticsDogNoseDetector,
    _crop_padded_square,
    _is_valid_bbox,
    _load_rgb_image,
    _resize_image,
)


SCHEMA_VERSION = 1
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}


@dataclass(frozen=True, slots=True)
class WorkloadResult:
    status: str
    stages_ms: dict[str, float]
    payload: dict[str, Any]
    crop_bytes: bytes | None = None


class ResourceSampler:
    def __init__(self, interval_seconds: float = 0.25) -> None:
        self.interval_seconds = interval_seconds
        self.samples: list[dict[str, Any]] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._process = None

    def __enter__(self) -> "ResourceSampler":
        try:
            import psutil  # type: ignore

            self._process = psutil.Process()
            self._process.cpu_percent(interval=None)
        except Exception:
            self._process = None
        self._thread = threading.Thread(target=self._run, name="resource-sampler", daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=max(2.0, self.interval_seconds * 4.0))

    def _run(self) -> None:
        while not self._stop.is_set():
            sample = {"timestamp": time.time()}
            sample.update(sample_process(self._process))
            sample.update(sample_gpu())
            self.samples.append(sample)
            self._stop.wait(self.interval_seconds)

    def summary(self) -> dict[str, Any]:
        return summarize_resource_samples(self.samples)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run local YOLO + embedding inference preflight with sanitized resource summaries."
    )
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--case-name", required=True)
    parser.add_argument("--profile-image", required=True)
    parser.add_argument("--nose-images", nargs="*", default=[])
    parser.add_argument("--detection-images", nargs="*", default=[])
    parser.add_argument("--yolo-weights", required=True)
    parser.add_argument("--yolo-repo", default="")
    parser.add_argument("--detector-backend", default=LEGACY_YOLOV5_BACKEND)
    parser.add_argument("--detector-device", default="cpu")
    parser.add_argument("--conf-threshold", type=float, default=0.35)
    parser.add_argument("--class-id", type=int, default=0)
    parser.add_argument("--class-names", default=",".join(DEFAULT_CLASS_NAMES))
    parser.add_argument("--model-dir", default="")
    parser.add_argument("--model-path", default="")
    parser.add_argument("--embedding-runtime", choices=("none", "torch", "onnxruntime"), default="none")
    parser.add_argument("--embed-device", default="cpu")
    parser.add_argument("--embed-device-required", action="store_true")
    parser.add_argument("--onnx-path", default="")
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--min-seconds", type=float, default=0.0)
    parser.add_argument("--sample-interval-ms", type=int, default=250)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    profile_path = require_image(args.profile_image)
    nose_paths = [require_image(path) for path in args.nose_images]
    detection_paths = [require_image(path) for path in (args.detection_images or [args.profile_image])]

    detector_load_started = time.perf_counter()
    detector = load_detector(args)
    detector_load_ms = (time.perf_counter() - detector_load_started) * 1000.0

    embedder = None
    embedder_load_ms = None
    if args.embedding_runtime != "none":
        embedder_load_started = time.perf_counter()
        embedder = load_embedder(args)
        embedder_load_ms = (time.perf_counter() - embedder_load_started) * 1000.0

    config = DogNoseExtractionConfig(
        enabled=True,
        weights_path=args.yolo_weights,
        detector_backend=args.detector_backend,
        yolov5_repo_path=args.yolo_repo or None,
        detector_device=args.detector_device,
        conf_threshold=args.conf_threshold,
        crop_size=224,
        bbox_expand=1.40,
        class_id=args.class_id,
        class_names=frozenset(parse_class_names(args.class_names)),
    )
    extractor = DogNoseExtractor(config=config, detector=detector)

    functional_rows = [
        detection_payload(extractor, image_path, label=f"detection_fixture_{index:03d}")
        for index, image_path in enumerate(detection_paths, start=1)
    ]

    workload: Callable[[], WorkloadResult]
    if args.embedding_runtime == "none":
        profile_bytes = profile_path.read_bytes()
        workload = lambda: run_detection_staged(extractor, profile_bytes)
    else:
        if embedder is None:
            raise RuntimeError("embedder was not initialized")
        if len(nose_paths) != 5:
            raise RuntimeError("--nose-images must contain exactly five images for integrated profile-match-batch.")
        workload = lambda: run_integrated_staged(extractor, embedder, profile_path, nose_paths, args.embedding_runtime)

    for _ in range(max(0, args.warmup)):
        workload()

    samples: list[WorkloadResult] = []
    started = time.perf_counter()
    with ResourceSampler(interval_seconds=max(args.sample_interval_ms, 1) / 1000.0) as sampler:
        while len(samples) < max(1, args.runs) or (time.perf_counter() - started) < max(0.0, args.min_seconds):
            samples.append(workload())
    wall_ms = (time.perf_counter() - started) * 1000.0

    stage_names = sorted({name for sample in samples for name in sample.stages_ms})
    stage_rows = [
        {"stage": stage, **summarize_numbers([sample.stages_ms[stage] for sample in samples if stage in sample.stages_ms])}
        for stage in stage_names
    ]
    representative_payload = samples[-1].payload if samples else {}
    resource_summary = sampler.summary()

    summary = {
        "schema_version": SCHEMA_VERSION,
        "case_name": args.case_name,
        "status": "ok",
        "runs": len(samples),
        "wall_ms": wall_ms,
        "detector_backend": args.detector_backend,
        "detector_device": getattr(detector, "device", args.detector_device),
        "detector_requested_device": args.detector_device,
        "detector_load_ms": detector_load_ms,
        "model_class_names": getattr(getattr(detector, "_model", None), "names", None),
        "yolo_weight": {
            "basename": safe_path_name(args.yolo_weights),
            "size_bytes": Path(args.yolo_weights).stat().st_size,
            "sha256": sha256_file(Path(args.yolo_weights)),
        },
        "yolo_repo": {
            "safe_id": safe_repo_id(args.yolo_repo),
            "hubconf_exists": bool(args.yolo_repo and (Path(args.yolo_repo) / "hubconf.py").is_file()),
        },
        "embedding_runtime": args.embedding_runtime,
        "embedding_backend": getattr(embedder, "backend", None),
        "embedding_device": getattr(embedder, "device", None),
        "embedding_model": getattr(embedder, "model_name", None),
        "embedding_dimension": getattr(embedder, "vector_dim", None),
        "embedding_load_ms": embedder_load_ms,
        "onnx_artifact": safe_path_name(args.onnx_path) if args.onnx_path else None,
        "functional_detection": functional_rows,
        "representative_payload": representative_payload,
        "stage_latency": stage_rows,
        "resource_summary": resource_summary,
        "resource_sample_count": len(sampler.samples),
        "fixture_counts": {
            "detection_images": len(detection_paths),
            "profile_images": 1,
            "nose_images": len(nose_paths),
        },
    }
    assert_sanitized_payload(summary)

    write_json(output_dir / f"{args.case_name}_summary.json", summary)
    write_csv(output_dir / f"{args.case_name}_stage_latency.csv", stage_rows)
    write_csv(output_dir / f"{args.case_name}_functional_detection.csv", functional_rows)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


def load_detector(args: argparse.Namespace):
    backend = str(args.detector_backend).strip().lower()
    if backend == LEGACY_YOLOV5_BACKEND:
        detector = LegacyYolov5DogNoseDetector(args.yolo_weights, args.yolo_repo, args.detector_device)
    else:
        detector = UltralyticsDogNoseDetector(args.yolo_weights, args.detector_device)
    if not detector.load():
        raise RuntimeError(f"detector load failed: {detector.load_error}")
    return detector


def load_embedder(args: argparse.Namespace):
    if args.embedding_runtime == "torch":
        embedder = DogNoseIdentification2Embedder(
            model_dir=args.model_dir,
            model_path=args.model_path or None,
            embed_device=args.embed_device,
            embed_device_required=args.embed_device_required,
        )
    elif args.embedding_runtime == "onnxruntime":
        embedder = DogNoseIdentification2OnnxEmbedder(
            model_dir=args.model_dir,
            onnx_path=args.onnx_path or None,
            model_tag="s101_224",
            default_image_size=224,
        )
    else:
        raise RuntimeError(f"unsupported embedding runtime: {args.embedding_runtime}")
    if not embedder.load():
        raise RuntimeError(f"embedder load failed: {embedder.load_error}")
    return embedder


def run_detection_staged(extractor: DogNoseExtractor, image_bytes: bytes) -> WorkloadResult:
    stages: dict[str, float] = {}
    started_total = time.perf_counter()

    image = timed_stage(stages, "image_decode", lambda: _load_rgb_image(image_bytes))
    def predict():
        synchronize_detector_if_cuda(extractor.detector)
        output = extractor.detector.detect(image)  # type: ignore[union-attr]
        synchronize_detector_if_cuda(extractor.detector)
        return output

    detections = timed_stage(stages, "yolo_model_predict", predict)
    detection = timed_stage(stages, "bbox_filtering", lambda: select_detection(extractor, detections))
    if detection is None:
        stages["total"] = (time.perf_counter() - started_total) * 1000.0
        return WorkloadResult(
            status="no_detection",
            stages_ms=stages,
            payload={"extracted": False, "failure_reason": "NO_NOSE_DETECTED"},
        )

    crop = timed_stage(
        stages,
        "square_crop",
        lambda: _crop_padded_square(image, detection.bbox_xyxy, extractor.config.bbox_expand),
    )

    def resize_and_encode() -> bytes:
        resized = _resize_image(crop, extractor.config.crop_size)
        output = BytesIO()
        resized.save(output, format="PNG")
        return output.getvalue()

    crop_bytes = timed_stage(stages, "resize_png_encode", resize_and_encode)
    stages["total"] = (time.perf_counter() - started_total) * 1000.0
    return WorkloadResult(
        status="ok",
        stages_ms=stages,
        payload={
            "extracted": True,
            "confidence": round(float(detection.confidence), 6),
            "bbox_xyxy": [round(float(value), 3) for value in detection.bbox_xyxy],
            "crop_width": extractor.config.crop_size,
            "crop_height": extractor.config.crop_size,
            "crop_bytes": len(crop_bytes),
            "failure_reason": None,
        },
        crop_bytes=crop_bytes,
    )


def run_integrated_staged(
    extractor: DogNoseExtractor,
    embedder: Any,
    profile_path: Path,
    nose_paths: list[Path],
    embedding_runtime: str,
) -> WorkloadResult:
    stages: dict[str, float] = {}
    started_total = time.perf_counter()

    detection = run_detection_staged(extractor, profile_path.read_bytes())
    stages.update(detection.stages_ms)
    if detection.status != "ok":
        return detection

    if detection.crop_bytes is None:
        raise RuntimeError("profile crop bytes missing from successful detection")

    image_inputs = [detection.crop_bytes, *[path.read_bytes() for path in nose_paths]]
    vectors = embed_images_staged(embedder, image_inputs, embedding_runtime, stages)
    scores = timed_stage(stages, "similarity_aggregation", lambda: cosine_scores(vectors[0], vectors[1:]))
    median_score = statistics.median(scores)
    pass_count = sum(1 for score in scores if score >= 0.65)
    stages["total"] = (time.perf_counter() - started_total) * 1000.0

    return WorkloadResult(
        status="ok",
        stages_ms=stages,
        payload={
            "profile_nose_extracted": True,
            "dimension": len(vectors[0]),
            "scores_count": len(scores),
            "min_score": min(scores),
            "median_score": median_score,
            "mean_score": statistics.fmean(scores),
            "max_score": max(scores),
            "pass_count": pass_count,
            "required_pass_count": 4,
            "threshold": 0.65,
            "matched": pass_count >= 4 and median_score >= 0.65,
            "failure_reason": None,
        },
    )


def embed_images_staged(embedder: Any, image_bytes: list[bytes], embedding_runtime: str, stages: dict[str, float]) -> list[list[float]]:
    if embedding_runtime == "torch":
        tensors = timed_stage(
            stages,
            "embedding_preprocessing",
            lambda: [embedder._preprocess(_load_rgb_image(raw)) for raw in image_bytes],
        )
        batch = embedder._torch.stack(tensors).to(embedder._runtime_device)

        def infer():
            synchronize_if_cuda(embedder)
            with embedder._torch.inference_mode():
                output = embedder._model(batch, return_logits=False)
            synchronize_if_cuda(embedder)
            return output

        feature = timed_stage(stages, "embedding_inference", infer)

        def normalize():
            normalized = embedder._torch.nn.functional.normalize(feature, p=2, dim=1)
            synchronize_if_cuda(embedder)
            return normalized.detach().cpu().float().tolist()

        return timed_stage(stages, "l2_normalization", normalize)

    batch = timed_stage(
        stages,
        "embedding_preprocessing",
        lambda: embedder._np.stack([embedder._preprocess(raw) for raw in image_bytes], axis=0).astype(embedder._np.float32),
    )
    output = timed_stage(
        stages,
        "embedding_inference",
        lambda: embedder._session.run([embedder._output_name], {embedder._input_name: batch})[0],
    )
    return timed_stage(stages, "l2_normalization", lambda: embedder._l2_normalize(output).astype(embedder._np.float32).tolist())


def select_detection(extractor: DogNoseExtractor, detections: list[NoseDetection]) -> NoseDetection | None:
    class_matches = [detection for detection in detections if extractor._matches_expected_class(detection)]
    high_confidence = [
        detection
        for detection in class_matches
        if detection.confidence >= extractor.config.conf_threshold and _is_valid_bbox(detection.bbox_xyxy)
    ]
    if len(high_confidence) != 1:
        return None
    return high_confidence[0]


def detection_payload(extractor: DogNoseExtractor, image_path: Path, label: str) -> dict[str, Any]:
    result = extractor.extract(image_path.read_bytes())
    return {
        "schema_version": SCHEMA_VERSION,
        "label": label,
        "extracted": result.extracted,
        "confidence": result.confidence,
        "bbox_valid": bool(result.bbox_xyxy and len(result.bbox_xyxy) == 4),
        "crop_width": result.crop_width,
        "crop_height": result.crop_height,
        "failure_reason": result.failure_reason,
        "detector": result.detector,
        "detector_device": result.detector_device,
    }


def timed_stage(stages: dict[str, float], name: str, func: Callable[[], Any]) -> Any:
    started = time.perf_counter()
    value = func()
    stages[name] = stages.get(name, 0.0) + (time.perf_counter() - started) * 1000.0
    return value


def synchronize_if_cuda(embedder: Any) -> None:
    device = str(getattr(embedder, "device", "") or "").lower()
    torch = getattr(embedder, "_torch", None)
    if torch is not None and device.startswith("cuda") and torch.cuda.is_available():
        torch.cuda.synchronize()


def synchronize_detector_if_cuda(detector: Any) -> None:
    device = str(getattr(detector, "device", "") or "").lower()
    if not device.startswith("cuda"):
        return
    try:
        import torch  # type: ignore

        if torch.cuda.is_available():
            torch.cuda.synchronize()
    except Exception:
        return


def cosine_scores(profile: list[float], noses: list[list[float]]) -> list[float]:
    return [cosine(profile, nose) for nose in noses]


def cosine(left: list[float], right: list[float]) -> float:
    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(a * a for a in left))
    right_norm = math.sqrt(sum(b * b for b in right))
    return dot / max(left_norm * right_norm, 1e-12)


def sample_process(process: Any) -> dict[str, Any]:
    if process is None:
        return {
            "process_cpu_percent": None,
            "process_rss_mib": None,
            "process_thread_count": None,
            "system_cpu_percent": None,
            "system_ram_percent": None,
        }
    try:
        import psutil  # type: ignore

        memory = process.memory_info()
        vm = psutil.virtual_memory()
        return {
            "process_cpu_percent": process.cpu_percent(interval=None),
            "process_rss_mib": memory.rss / (1024 * 1024),
            "process_thread_count": process.num_threads(),
            "system_cpu_percent": psutil.cpu_percent(interval=None),
            "system_ram_percent": vm.percent,
        }
    except Exception:
        return {}


def sample_gpu() -> dict[str, Any]:
    query = (
        "name,utilization.gpu,utilization.memory,memory.used,memory.total,"
        "power.draw,temperature.gpu"
    )
    try:
        completed = subprocess.run(
            ["nvidia-smi", f"--query-gpu={query}", "--format=csv,noheader,nounits"],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except Exception:
        return {
            "gpu_name": None,
            "gpu_util_percent": None,
            "gpu_memory_util_percent": None,
            "gpu_memory_used_mib": None,
            "gpu_memory_total_mib": None,
            "gpu_power_w": None,
            "gpu_temperature_c": None,
        }
    line = completed.stdout.strip().splitlines()[0]
    parts = [part.strip() for part in line.split(",")]
    return {
        "gpu_name": parts[0] if len(parts) > 0 else None,
        "gpu_util_percent": parse_float(parts[1]) if len(parts) > 1 else None,
        "gpu_memory_util_percent": parse_float(parts[2]) if len(parts) > 2 else None,
        "gpu_memory_used_mib": parse_float(parts[3]) if len(parts) > 3 else None,
        "gpu_memory_total_mib": parse_float(parts[4]) if len(parts) > 4 else None,
        "gpu_power_w": parse_float(parts[5]) if len(parts) > 5 else None,
        "gpu_temperature_c": parse_float(parts[6]) if len(parts) > 6 else None,
    }


def summarize_resource_samples(samples: list[dict[str, Any]]) -> dict[str, Any]:
    keys = [
        "process_cpu_percent",
        "process_rss_mib",
        "process_thread_count",
        "system_cpu_percent",
        "system_ram_percent",
        "gpu_util_percent",
        "gpu_memory_util_percent",
        "gpu_memory_used_mib",
        "gpu_memory_total_mib",
        "gpu_power_w",
        "gpu_temperature_c",
    ]
    summary = {"sample_count": len(samples), "gpu_name": first_non_null(samples, "gpu_name")}
    for key in keys:
        values = [sample.get(key) for sample in samples if isinstance(sample.get(key), (int, float))]
        summary[key] = summarize_numbers(values) if values else None
    return summary


def summarize_numbers(values: list[float]) -> dict[str, float | int | None]:
    clean = [float(value) for value in values if isinstance(value, (int, float)) and math.isfinite(float(value))]
    if not clean:
        return {"count": 0, "mean": None, "p50": None, "p95": None, "min": None, "max": None}
    return {
        "count": len(clean),
        "mean": statistics.fmean(clean),
        "p50": percentile(clean, 50),
        "p95": percentile(clean, 95),
        "min": min(clean),
        "max": max(clean),
    }


def percentile(values: list[float], percent: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * (percent / 100.0)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def first_non_null(samples: list[dict[str, Any]], key: str) -> Any:
    for sample in samples:
        value = sample.get(key)
        if value is not None:
            return value
    return None


def parse_float(value: Any) -> float | None:
    try:
        return float(value)
    except Exception:
        return None


def parse_class_names(raw: str) -> tuple[str, ...]:
    return tuple(item.strip().lower() for item in raw.split(",") if item.strip())


def require_image(raw: str) -> Path:
    path = Path(raw)
    if not path.is_file() or path.suffix.lower() not in IMAGE_SUFFIXES:
        raise FileNotFoundError(f"image fixture not found or unsupported: {safe_path_name(raw)}")
    return path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, data: dict[str, Any]) -> None:
    assert_sanitized_payload(data)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    assert_sanitized_payload(rows)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def safe_repo_id(path: str) -> str | None:
    if not path:
        return None
    parts = [part for part in Path(path).parts if part not in {Path(path).anchor, "\\", "/"}]
    return "/".join(parts[-3:]) if parts else safe_path_name(path)


def safe_path_name(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    candidates = [PureWindowsPath(text).name, PurePosixPath(text).name, Path(text).name]
    names = [candidate for candidate in candidates if candidate]
    return min(names, key=len) if names else text


def assert_sanitized_payload(payload: Any) -> None:
    validate_sanitized_value(payload, [])


def validate_sanitized_value(value: Any, path: list[str]) -> None:
    key = path[-1].lower() if path else ""
    if key in {"vector", "vectors", "embedding", "embeddings", "image_bytes", "raw_image", "raw_vector", "crop_base64"}:
        raise ValueError(f"unsafe raw data field in output: {'.'.join(path)}")
    if key == "crop_bytes" and not isinstance(value, (int, float, type(None))):
        raise ValueError(f"unsafe crop payload in output: {'.'.join(path)}")
    if isinstance(value, str):
        if looks_like_absolute_path(value):
            raise ValueError(f"unsafe absolute path in output: {'.'.join(path)}")
        return
    if isinstance(value, dict):
        for child_key, child_value in value.items():
            validate_sanitized_value(child_value, [*path, str(child_key)])
        return
    if isinstance(value, (list, tuple)):
        if len(value) > 16 and all(isinstance(item, (int, float)) for item in value):
            raise ValueError(f"unsafe vector-like array in output: {'.'.join(path)}")
        for index, child_value in enumerate(value):
            validate_sanitized_value(child_value, [*path, str(index)])


def looks_like_absolute_path(value: str) -> bool:
    text = value.strip()
    if not text:
        return False
    if PureWindowsPath(text).is_absolute() or PurePosixPath(text).is_absolute():
        return True
    lowered = text.replace("\\", "/").lower()
    return "/users/" in lowered or "/home/" in lowered


if __name__ == "__main__":
    raise SystemExit(main())
