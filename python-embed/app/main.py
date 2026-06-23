"""
PetNose - Python Embedding Service

Contract notes:
  - /embed response fields must stay: status, vector, dimension, model
  - mock-v1 must remain stable for existing smoke tests
"""

from __future__ import annotations

import os
import time
import logging
import math
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile

from .embedding import create_embedder_from_env
from .embedding.base import BaseEmbedder, EmbedInput, EmbedResult, EmbedderError, EmbedderNotReadyError
from .nose_extraction import (
    DogNoseExtractor,
    FACE_CHECK_PURPOSE,
    INTERNAL_ERROR,
    INVALID_IMAGE,
    NoseExtractionResult,
    cosine_similarity,
)


def _parse_float_env(name: str, default: float) -> float:
    value = os.getenv(name)
    try:
        return float(value) if value is not None and value.strip() else default
    except ValueError:
        return default


def _parse_int_env(name: str, default: int) -> int:
    value = os.getenv(name)
    try:
        return int(value) if value is not None and value.strip() else default
    except ValueError:
        return default


def _parse_bool_env(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None or not value.strip():
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


MAX_IMAGE_SIZE: int = int(os.getenv("MAX_IMAGE_BYTES", str(20 * 1024 * 1024)))
MAX_BATCH_IMAGES: int = int(os.getenv("MAX_BATCH_IMAGES", os.getenv("MAX_EMBED_BATCH_IMAGES", "5")))
MAX_BATCH_TOTAL_BYTES: int = int(os.getenv("MAX_BATCH_TOTAL_BYTES", str(80 * 1024 * 1024)))
ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/jpg"}
PROFILE_NOSE_MATCH_THRESHOLD: float = _parse_float_env("PROFILE_NOSE_MATCH_THRESHOLD", 0.65)
PROFILE_NOSE_MATCH_MIN_PASS_COUNT: int = _parse_int_env("PROFILE_NOSE_MATCH_MIN_PASS_COUNT", 4)
PROFILE_NOSE_MATCH_AGGREGATE: str = os.getenv("PROFILE_NOSE_MATCH_AGGREGATE", "median").strip().lower() or "median"
PROFILE_NOSE_MATCH_EXPECTED_COUNT: int = 5
PROFILE_NOSE_MATCH_EXPECTED_DIMENSION: int = 2048
NOSE_IMAGES_COUNT_INVALID = "NOSE_IMAGES_COUNT_INVALID"
EMBEDDING_DIMENSION_MISMATCH = "EMBEDDING_DIMENSION_MISMATCH"
DEMO_TRACE_ENABLED: bool = _parse_bool_env("DEMO_TRACE_ENABLED", False)
DEMO_TRACE_LOG_PER_IMAGE: bool = _parse_bool_env(
    "DEMO_TRACE_LOG_PER_IMAGE",
    _parse_bool_env("DEMO_TRACE_PROFILE_COMPARE_LOG_PER_IMAGE", True),
)
DEMO_TRACE_HEALTH_ACCESS_LOG: bool = _parse_bool_env("DEMO_TRACE_HEALTH_ACCESS_LOG", False)

_embedder: BaseEmbedder | None = None
_nose_extractor: DogNoseExtractor | None = None


def _is_health_access_log(message: str) -> bool:
    return '"GET /health HTTP/' in message or "GET /health " in message


class HealthAccessLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        if DEMO_TRACE_HEALTH_ACCESS_LOG:
            return True
        return not _is_health_access_log(record.getMessage())


def _install_health_access_log_filter() -> None:
    logger = logging.getLogger("uvicorn.access")
    if not any(isinstance(item, HealthAccessLogFilter) for item in logger.filters):
        logger.addFilter(HealthAccessLogFilter())


_install_health_access_log_filter()


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _embedder, _nose_extractor
    _embedder = create_embedder_from_env()
    loaded = _embedder.load()
    _nose_extractor = DogNoseExtractor.from_env()
    mode = "MOCK" if _embedder.requested_model_name == "mock-v1" else "REAL"
    print(
        "[EmbedService] start - "
        f"mode={mode}, requested_model={_embedder.requested_model_name}, "
        f"resolved_model={_embedder.model_name}, loaded={loaded}, dim={_embedder.vector_dim}"
    )
    if _embedder.load_error:
        print(f"[EmbedService] load_error={_embedder.load_error}")
    print(
        "[EmbedService] nose_extraction - "
        f"enabled={_nose_extractor.config.enabled}, detector={_nose_extractor.detector_name}, "
        f"crop_size={_nose_extractor.config.crop_size}"
    )
    yield
    print("[EmbedService] 종료")


app = FastAPI(title="PetNose Embed Service", version="0.2.0", lifespan=lifespan)


def _require_embedder() -> BaseEmbedder:
    if _embedder is None:
        raise HTTPException(
            status_code=500,
            detail={
                "error": "SERVICE_NOT_INITIALIZED",
                "message": "Embedding service is not initialized.",
            },
        )
    return _embedder


def _require_nose_extractor() -> DogNoseExtractor:
    global _nose_extractor
    if _nose_extractor is None:
        _nose_extractor = DogNoseExtractor.from_env()
    return _nose_extractor


def _request_id(request: Request) -> str:
    return request.headers.get("x-request-id") or "-"


def _elapsed_ms(started: float) -> int:
    return round((time.perf_counter() - started) * 1000)


def _fmt_score(value: float | None) -> str:
    return "null" if value is None else f"{value:.4f}"


def _fmt_percent(value: float | None) -> str:
    return "null" if value is None else f"{value * 100:.1f}"


def _demo_trace(message: str) -> None:
    if DEMO_TRACE_ENABLED:
        print(f"[DEMO_TRACE] {message}", flush=True)


def _crop_text(result: NoseExtractionResult | None) -> str:
    if result is None or result.crop_width is None or result.crop_height is None:
        return "null"
    return f"{result.crop_width}x{result.crop_height}"


def _bbox_text(result: NoseExtractionResult | None) -> str:
    if result is None or result.bbox_xyxy is None:
        return "null"
    return "[" + ",".join(f"{value:.1f}" for value in result.bbox_xyxy) + "]"


def _purpose_text(purpose: str | None) -> str:
    return FACE_CHECK_PURPOSE if (purpose or "").strip().lower() == FACE_CHECK_PURPOSE else "generic"


def _quality_response(result: NoseExtractionResult | None) -> dict[str, object] | None:
    if result is None or result.quality is None:
        return None
    return result.quality.to_response()


def _quality_passed(result: NoseExtractionResult | None) -> object:
    return None if result is None or result.quality is None else result.quality.passed


def _quality_metric(result: NoseExtractionResult | None, name: str) -> object:
    if result is None or result.quality is None:
        return None
    return getattr(result.quality, name)


async def _read_validated_image(image: UploadFile) -> EmbedInput:
    content = await image.read()
    if not content:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "INVALID_IMAGE",
                "message": "이미지 내용이 비어 있습니다.",
            },
        )

    if len(content) > MAX_IMAGE_SIZE:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "IMAGE_TOO_LARGE",
                "message": f"이미지 크기가 제한({MAX_IMAGE_SIZE // 1024 // 1024}MB)을 초과합니다.",
            },
        )

    content_type = (image.content_type or "").lower()
    if content_type not in ALLOWED_CONTENT_TYPES:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "UNSUPPORTED_FORMAT",
                "message": f"지원하지 않는 이미지 형식입니다: {content_type}",
            },
        )

    return EmbedInput(image_bytes=content, content_type=content_type)


async def _read_upload_bytes(image: UploadFile) -> bytes:
    content = await image.read()
    if not content:
        raise ValueError("empty image")
    if len(content) > MAX_IMAGE_SIZE:
        raise ValueError("image too large")
    return content


def _ensure_model_loaded(embedder: BaseEmbedder) -> None:
    if not embedder.model_loaded:
        raise HTTPException(
            status_code=503,
            detail={
                "error": "MODEL_NOT_READY",
                "message": embedder.load_error or "모델이 아직 로드되지 않았습니다.",
            },
        )


def _embed_payload(result: EmbedResult) -> dict[str, object]:
    _validate_embed_result(result)

    return {
        "status": "ok",
        "vector": result.vector,
        "dimension": result.dimension,
        "model": result.model,
    }


def _validate_embed_result(result: EmbedResult) -> None:
    if not result.vector:
        raise EmbedderError("출력 벡터가 비어 있습니다.")


def _embed_exception_to_http(exc: Exception) -> HTTPException:
    if isinstance(exc, EmbedderNotReadyError):
        return HTTPException(
            status_code=503,
            detail={
                "error": "MODEL_NOT_READY",
                "message": str(exc),
            },
        )
    if isinstance(exc, ValueError):
        return HTTPException(
            status_code=400,
            detail={
                "error": "INVALID_IMAGE",
                "message": str(exc),
            },
        )
    if isinstance(exc, EmbedderError):
        return HTTPException(
            status_code=500,
            detail={
                "error": "EMBED_FAILED",
                "message": str(exc),
            },
        )
    return HTTPException(
        status_code=500,
        detail={
            "error": "EMBED_FAILED",
            "message": f"임베딩 생성 중 오류가 발생했습니다: {str(exc)}",
        },
    )


def _profile_match_failure(
    *,
    threshold: float,
    failure_reason: str,
    extraction: NoseExtractionResult | None = None,
    model: str | None = None,
    dimension: int | None = None,
) -> dict[str, object]:
    return {
        "matched": False,
        "similarity_score": None,
        "threshold": threshold,
        "threshold_calibrated": False,
        "profile_nose_extracted": extraction.extracted if extraction else False,
        "profile_crop_width": extraction.crop_width if extraction else None,
        "profile_crop_height": extraction.crop_height if extraction else None,
        "profile_confidence": extraction.confidence if extraction else None,
        "model": model,
        "dimension": dimension,
        "failure_reason": failure_reason,
    }


def _profile_match_batch_failure(
    *,
    threshold: float,
    required_pass_count: int,
    failure_reason: str,
    extraction: NoseExtractionResult | None = None,
    model: str | None = None,
    dimension: int | None = None,
    request_id: str | None = None,
    started: float | None = None,
) -> dict[str, object]:
    body = {
        "matched": False,
        "threshold": threshold,
        "threshold_calibrated": False,
        "pass_count": 0,
        "required_pass_count": required_pass_count,
        "aggregate": _profile_match_aggregate(),
        "median_score": None,
        "mean_score": None,
        "min_score": None,
        "max_score": None,
        "profile_nose_extracted": extraction.extracted if extraction else False,
        "profile_confidence": extraction.confidence if extraction else None,
        "profile_crop_width": extraction.crop_width if extraction else None,
        "profile_crop_height": extraction.crop_height if extraction else None,
        "model": model,
        "dimension": dimension,
        "scores": [],
        "profile_vs_centroid_score": None,
        "profile_vs_centroid_passed": None,
        "centroid_dimension": None,
        "failure_reason": failure_reason,
    }
    if request_id is not None:
        elapsed = _elapsed_ms(started) if started is not None else "null"
        _demo_trace(
            "component=python flow=profile_match_batch step=failed "
            f"request_id={request_id} failure_reason={failure_reason} "
            f"profile_nose_extracted={body['profile_nose_extracted']} "
            f"profile_confidence={_fmt_score(body['profile_confidence'])} "
            f"model={model} dimension={dimension} elapsed_ms={elapsed}"
        )
    return body


def _extract_embed_failure(
    *,
    failure_reason: str,
    extraction: NoseExtractionResult | None = None,
    model: str | None = None,
    dimension: int | None = None,
    request_id: str | None = None,
    started: float | None = None,
) -> dict[str, object]:
    body = {
        "extracted": extraction.extracted if extraction else False,
        "confidence": extraction.confidence if extraction else None,
        "bbox_xyxy": extraction.bbox_xyxy if extraction else None,
        "crop_width": extraction.crop_width if extraction else None,
        "crop_height": extraction.crop_height if extraction else None,
        "model": model,
        "dimension": dimension,
        "embedding": None,
        "quality": _quality_response(extraction),
        "failure_reason": failure_reason,
    }
    if request_id is not None:
        elapsed = _elapsed_ms(started) if started is not None else "null"
        _demo_trace(
            "component=python flow=extract_embed step=failed "
            f"request_id={request_id} extracted={body['extracted']} "
            f"confidence={_fmt_score(body['confidence'])} bbox={_bbox_text(extraction)} "
            f"crop={_crop_text(extraction)} model={model} dimension={dimension} "
            f"quality_passed={_quality_passed(extraction)} "
            f"failure_reason={failure_reason} elapsed_ms={elapsed}"
        )
    return body


def _profile_match_aggregate() -> str:
    return "median" if PROFILE_NOSE_MATCH_AGGREGATE != "median" else PROFILE_NOSE_MATCH_AGGREGATE


def _embedding_dimension_valid(embedder: BaseEmbedder, result: EmbedResult) -> bool:
    if result.dimension <= 0 or len(result.vector) != result.dimension:
        return False
    return embedder.vector_dim <= 0 or result.dimension == embedder.vector_dim


def _median(values: list[float]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2 == 1:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def _score_summary(values: list[float], threshold: float) -> dict[str, float | int | None]:
    if not values:
        return {
            "min": None,
            "max": None,
            "mean": None,
            "median": None,
            "pass_count": 0,
            "fail_count": 0,
        }
    pass_count = sum(1 for value in values if value >= threshold)
    return {
        "min": min(values),
        "max": max(values),
        "mean": round(sum(values) / len(values), 6),
        "median": round(_median(values), 6),
        "pass_count": pass_count,
        "fail_count": len(values) - pass_count,
    }


def _vector_norm(vector: list[float]) -> float:
    if not vector:
        raise ValueError("empty vector")
    return math.sqrt(sum(value * value for value in vector))


def _finite_vector(vector: list[float]) -> bool:
    return bool(vector) and all(math.isfinite(value) for value in vector)


def _normalized_centroid(vectors: list[list[float]]) -> list[float]:
    if not vectors:
        raise ValueError("empty vectors")
    dimension = len(vectors[0])
    if dimension == 0 or any(len(vector) != dimension for vector in vectors):
        raise ValueError("dimension mismatch")
    if any(not _finite_vector(vector) for vector in vectors):
        raise ValueError("non-finite vector")

    sums = [0.0] * dimension
    for vector in vectors:
        for index, value in enumerate(vector):
            sums[index] += value
    mean = [value / len(vectors) for value in sums]
    norm = _vector_norm(mean)
    if norm == 0.0:
        raise ValueError("zero centroid norm")
    return [value / norm for value in mean]


@app.get("/health")
def health():
    embedder = _require_embedder()
    data = embedder.health_dict()
    # Backward-compatible keys (Spring and existing diagnostics)
    return {
        "status": "ok",
        "model_loaded": data["model_loaded"],
        "model": data["model"],
        "vector_dim": data["vector_dim"],
        "backend": data.get("backend"),
        "device": data.get("device"),
        "model_path_exists": data.get("model_path_exists"),
        "load_error": data.get("load_error"),
        "image_size": data.get("image_size"),
    }


@app.post("/embed")
async def embed(image: UploadFile = File(...)):
    embedder = _require_embedder()
    embed_input = await _read_validated_image(image)
    _ensure_model_loaded(embedder)

    try:
        result = embedder.embed(embed_input.image_bytes, embed_input.content_type)
        return _embed_payload(result)
    except Exception as exc:
        raise _embed_exception_to_http(exc) from exc


@app.post("/internal/nose/extract")
async def extract_profile_nose(
    request: Request,
    image: UploadFile = File(...),
    purpose: str | None = Form(None),
):
    extractor = _require_nose_extractor()
    started = time.perf_counter()
    request_id = _request_id(request)

    try:
        image_bytes = await _read_upload_bytes(image)
    except ValueError:
        result = extractor.failure_result(INVALID_IMAGE)
        _demo_trace(
            "component=python flow=nose_extract step=done "
            f"request_id={request_id} purpose={_purpose_text(purpose)} backend={extractor.detector_name} "
            f"enabled={extractor.config.enabled} extracted={result.extracted} "
            f"confidence={_fmt_score(result.confidence)} bbox={_bbox_text(result)} "
            f"quality_passed={_quality_passed(result)} "
            f"crop={_crop_text(result)} failure_reason={result.failure_reason} "
            f"elapsed_ms={_elapsed_ms(started)}"
        )
        return result.to_response()

    result = extractor.extract(image_bytes, purpose=purpose)
    _demo_trace(
        "component=python flow=nose_extract step=done "
        f"request_id={request_id} purpose={_purpose_text(purpose)} backend={extractor.detector_name} "
        f"enabled={extractor.config.enabled} extracted={result.extracted} "
        f"confidence={_fmt_score(result.confidence)} bbox={_bbox_text(result)} "
        f"quality_passed={_quality_passed(result)} "
        f"crop={_crop_text(result)} failure_reason={result.failure_reason} "
        f"elapsed_ms={_elapsed_ms(started)}"
    )
    return result.to_response()


@app.post("/internal/nose/extract-embed")
async def extract_nose_embedding(
    request: Request,
    image: UploadFile = File(...),
    purpose: str | None = Form(None),
):
    extractor = _require_nose_extractor()
    started = time.perf_counter()
    request_id = _request_id(request)

    try:
        image_bytes = await _read_upload_bytes(image)
    except ValueError:
        return _extract_embed_failure(
            failure_reason=INVALID_IMAGE,
            extraction=extractor.failure_result(INVALID_IMAGE),
            request_id=request_id,
            started=started,
        )

    extraction = extractor.extract(image_bytes, purpose=purpose)
    if not extraction.extracted or extraction.crop_bytes is None:
        return _extract_embed_failure(
            failure_reason=extraction.failure_reason or INTERNAL_ERROR,
            extraction=extraction,
            request_id=request_id,
            started=started,
        )

    embedder = _require_embedder()
    if not embedder.model_loaded:
        return _extract_embed_failure(
            failure_reason="MODEL_NOT_READY",
            extraction=extraction,
            model=embedder.model_name,
            dimension=embedder.vector_dim or None,
            request_id=request_id,
            started=started,
        )

    try:
        result = embedder.embed(extraction.crop_bytes, "image/png")
    except Exception:
        return _extract_embed_failure(
            failure_reason="EMBED_FAILED",
            extraction=extraction,
            model=embedder.model_name,
            dimension=embedder.vector_dim or None,
            request_id=request_id,
            started=started,
        )

    if not _embedding_dimension_valid(embedder, result):
        return _extract_embed_failure(
            failure_reason=EMBEDDING_DIMENSION_MISMATCH,
            extraction=extraction,
            model=result.model,
            dimension=result.dimension,
            request_id=request_id,
            started=started,
        )

    _demo_trace(
        "component=python flow=extract_embed step=done "
        f"request_id={request_id} purpose={_purpose_text(purpose)} extracted=true "
        f"confidence={_fmt_score(extraction.confidence)} bbox={_bbox_text(extraction)} "
        f"crop={_crop_text(extraction)} model={result.model} dimension={result.dimension} "
        f"quality_passed={_quality_passed(extraction)} "
        f"failure_reason=None elapsed_ms={_elapsed_ms(started)}"
    )
    return {
        "extracted": True,
        "confidence": extraction.confidence,
        "bbox_xyxy": extraction.bbox_xyxy,
        "crop_width": extraction.crop_width,
        "crop_height": extraction.crop_height,
        "model": result.model,
        "dimension": result.dimension,
        "embedding": result.vector,
        "quality": _quality_response(extraction),
        "failure_reason": None,
    }


@app.post("/internal/nose/profile-match")
async def profile_nose_match(
    profile_image: UploadFile = File(...),
    nose_image: UploadFile = File(...),
):
    extractor = _require_nose_extractor()
    threshold = PROFILE_NOSE_MATCH_THRESHOLD

    try:
        profile_bytes = await _read_upload_bytes(profile_image)
    except ValueError:
        return _profile_match_failure(threshold=threshold, failure_reason=INVALID_IMAGE)

    extraction = extractor.extract(profile_bytes)
    if not extraction.extracted or extraction.crop_bytes is None:
        return _profile_match_failure(
            threshold=threshold,
            failure_reason=extraction.failure_reason or INTERNAL_ERROR,
            extraction=extraction,
        )

    try:
        nose_input = await _read_validated_image(nose_image)
    except HTTPException:
        return _profile_match_failure(
            threshold=threshold,
            failure_reason=INVALID_IMAGE,
            extraction=extraction,
        )

    embedder = _require_embedder()
    if not embedder.model_loaded:
        return _profile_match_failure(
            threshold=threshold,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=embedder.model_name,
            dimension=embedder.vector_dim or None,
        )

    try:
        profile_result = embedder.embed(extraction.crop_bytes, "image/png")
        nose_result = embedder.embed(nose_input.image_bytes, nose_input.content_type)
    except Exception:
        return _profile_match_failure(
            threshold=threshold,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=embedder.model_name,
            dimension=embedder.vector_dim or None,
        )

    if (
        not _embedding_dimension_valid(embedder, profile_result)
        or not _embedding_dimension_valid(embedder, nose_result)
        or profile_result.dimension != nose_result.dimension
    ):
        return _profile_match_failure(
            threshold=threshold,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=profile_result.model,
            dimension=profile_result.dimension,
        )

    try:
        similarity = cosine_similarity(profile_result.vector, nose_result.vector)
    except ValueError:
        return _profile_match_failure(
            threshold=threshold,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=profile_result.model,
            dimension=profile_result.dimension,
        )

    return {
        "matched": similarity >= threshold,
        "similarity_score": round(similarity, 6),
        "threshold": threshold,
        "threshold_calibrated": False,
        "profile_nose_extracted": True,
        "profile_crop_width": extraction.crop_width,
        "profile_crop_height": extraction.crop_height,
        "profile_confidence": extraction.confidence,
        "model": profile_result.model,
        "dimension": profile_result.dimension,
        "failure_reason": None,
    }


@app.post("/internal/nose/profile-match-batch")
async def profile_nose_match_batch(
    request: Request,
    profile_image: UploadFile = File(...),
    nose_image: list[UploadFile] = File(...),
):
    extractor = _require_nose_extractor()
    threshold = PROFILE_NOSE_MATCH_THRESHOLD
    required_pass_count = PROFILE_NOSE_MATCH_MIN_PASS_COUNT
    started = time.perf_counter()
    request_id = _request_id(request)
    _demo_trace(
        "component=python flow=profile_match_batch step=start "
        f"request_id={request_id} nose_count={len(nose_image)} threshold={threshold:.4f} "
        f"required_pass={required_pass_count}"
    )

    try:
        profile_bytes = await _read_upload_bytes(profile_image)
    except ValueError:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INVALID_IMAGE,
            request_id=request_id,
            started=started,
        )

    extraction = extractor.extract(profile_bytes)
    if not extraction.extracted or extraction.crop_bytes is None:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=extraction.failure_reason or INTERNAL_ERROR,
            extraction=extraction,
            request_id=request_id,
            started=started,
        )

    if len(nose_image) != PROFILE_NOSE_MATCH_EXPECTED_COUNT:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=NOSE_IMAGES_COUNT_INVALID,
            extraction=extraction,
            request_id=request_id,
            started=started,
        )

    try:
        nose_inputs = [await _read_validated_image(image) for image in nose_image]
    except HTTPException:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INVALID_IMAGE,
            extraction=extraction,
            request_id=request_id,
            started=started,
        )

    embedder = _require_embedder()
    if not embedder.model_loaded:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=embedder.model_name,
            dimension=embedder.vector_dim or None,
            request_id=request_id,
            started=started,
        )

    try:
        profile_result = embedder.embed(extraction.crop_bytes, "image/png")
        nose_results = embedder.embed_batch(nose_inputs)
    except Exception:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=embedder.model_name,
            dimension=embedder.vector_dim or None,
            request_id=request_id,
            started=started,
        )

    if len(nose_results) != len(nose_inputs):
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=profile_result.model,
            dimension=profile_result.dimension,
            request_id=request_id,
            started=started,
        )

    if (
        not _embedding_dimension_valid(embedder, profile_result)
        or profile_result.dimension != PROFILE_NOSE_MATCH_EXPECTED_DIMENSION
        or any(not _embedding_dimension_valid(embedder, result) for result in nose_results)
        or any(result.dimension != profile_result.dimension for result in nose_results)
    ):
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=EMBEDDING_DIMENSION_MISMATCH,
            extraction=extraction,
            model=profile_result.model,
            dimension=profile_result.dimension,
            request_id=request_id,
            started=started,
        )

    scores: list[dict[str, object]] = []
    similarity_values: list[float] = []
    try:
        for index, nose_result in enumerate(nose_results, start=1):
            similarity = round(cosine_similarity(profile_result.vector, nose_result.vector), 6)
            similarity_values.append(similarity)
            scores.append(
                {
                    "index": index,
                    "similarity_score": similarity,
                    "passed": similarity >= threshold,
                }
            )
    except ValueError:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=profile_result.model,
            dimension=profile_result.dimension,
            request_id=request_id,
            started=started,
        )

    score_summary = _score_summary(similarity_values, threshold)
    pass_count = int(score_summary["pass_count"] or 0)
    median_score = float(score_summary["median"] or 0.0)
    matched = pass_count >= required_pass_count and median_score >= threshold
    profile_vs_centroid_score: float | None = None
    profile_vs_centroid_passed: bool | None = None
    centroid_dimension: int | None = None
    centroid_norm: float | None = None

    try:
        centroid_vector = _normalized_centroid([result.vector for result in nose_results])
        centroid_dimension = len(centroid_vector)
        centroid_norm = _vector_norm(centroid_vector)
        profile_vs_centroid_score = round(cosine_similarity(profile_result.vector, centroid_vector), 6)
        profile_vs_centroid_passed = profile_vs_centroid_score >= threshold
        _demo_trace(
            "component=python flow=profile_match_batch step=centroid_compare "
            f"request_id={request_id} profile_vs_centroid={_fmt_score(profile_vs_centroid_score)} "
            f"profile_vs_centroid_percent={_fmt_percent(profile_vs_centroid_score)} "
            f"threshold={threshold:.4f} passed={profile_vs_centroid_passed} "
            f"centroid_dimension={centroid_dimension} centroid_norm={_fmt_score(centroid_norm)}"
        )
    except ValueError as exc:
        _demo_trace(
            "component=python flow=profile_match_batch step=centroid_compare_failed "
            f"request_id={request_id} failure_reason={type(exc).__name__}"
        )

    body = {
        "matched": matched,
        "threshold": threshold,
        "threshold_calibrated": False,
        "pass_count": pass_count,
        "required_pass_count": required_pass_count,
        "aggregate": _profile_match_aggregate(),
        "median_score": median_score,
        "mean_score": score_summary["mean"],
        "min_score": score_summary["min"],
        "max_score": score_summary["max"],
        "profile_nose_extracted": True,
        "profile_confidence": extraction.confidence,
        "profile_crop_width": extraction.crop_width,
        "profile_crop_height": extraction.crop_height,
        "model": profile_result.model,
        "dimension": profile_result.dimension,
        "scores": scores,
        "profile_vs_centroid_score": profile_vs_centroid_score,
        "profile_vs_centroid_passed": profile_vs_centroid_passed,
        "centroid_dimension": centroid_dimension,
        "failure_reason": None,
    }
    _demo_trace(
        "component=python flow=profile_match_batch step=summary "
        f"request_id={request_id} extracted=true "
        f"profile_confidence={_fmt_score(extraction.confidence)} nose_count={len(nose_results)} "
        f"model={profile_result.model} dimension={profile_result.dimension} "
        f"threshold={threshold:.4f} pass={pass_count} required_pass={required_pass_count} "
        f"min={_fmt_score(body['min_score'])} max={_fmt_score(body['max_score'])} "
        f"mean={_fmt_score(body['mean_score'])} median={_fmt_score(body['median_score'])} "
        f"matched={matched} elapsed_ms={_elapsed_ms(started)}"
    )
    if DEMO_TRACE_ENABLED and DEMO_TRACE_LOG_PER_IMAGE:
        for item in scores:
            score = item.get("similarity_score")
            _demo_trace(
                "component=python flow=profile_match_batch step=per_image "
                f"request_id={request_id} index={item.get('index')} "
                f"score={_fmt_score(score)} percent={_fmt_percent(score)} "
                f"passed={item.get('passed')}"
            )
    return body


@app.post("/embed-batch")
async def embed_batch(request: Request):
    embedder = _require_embedder()
    started = time.perf_counter()
    request_id = _request_id(request)

    form = await request.form()
    raw_images = form.getlist("images")

    if not raw_images:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "INVALID_IMAGE",
                "message": "이미지 목록이 비어 있습니다.",
            },
        )

    images: list[UploadFile] = []
    for index, item in enumerate(raw_images):
        if not hasattr(item, "filename") or not hasattr(item, "read"):
            raise HTTPException(
                status_code=400,
                detail={
                    "error": "INVALID_IMAGE",
                    "message": "images multipart field는 file이어야 합니다.",
                    "index": index,
                },
            )
        images.append(item)

    if len(images) > MAX_BATCH_IMAGES:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "BATCH_TOO_LARGE",
                "message": f"이미지 개수가 제한({MAX_BATCH_IMAGES})을 초과합니다.",
            },
        )

    embed_inputs = [await _read_validated_image(image) for image in images]
    total_bytes = sum(len(item.image_bytes) for item in embed_inputs)
    if total_bytes > MAX_BATCH_TOTAL_BYTES:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "BATCH_TOTAL_TOO_LARGE",
                "message": f"전체 이미지 크기가 제한({MAX_BATCH_TOTAL_BYTES // 1024 // 1024}MB)을 초과합니다.",
            },
        )

    _ensure_model_loaded(embedder)
    _demo_trace(
        "component=python flow=embed_batch step=start "
        f"request_id={request_id} image_count={len(embed_inputs)} model_loaded={embedder.model_loaded}"
    )

    try:
        results = embedder.embed_batch(embed_inputs)
        if len(results) != len(embed_inputs):
            raise EmbedderError(
                f"batch 결과 개수가 요청 개수와 다릅니다: expected={len(embed_inputs)}, actual={len(results)}"
            )
        if not results:
            raise EmbedderError("batch 결과가 비어 있습니다.")

        items = []
        for index, result in enumerate(results):
            _validate_embed_result(result)
            items.append(
                {
                    "index": index,
                    "filename": images[index].filename,
                    "vector": result.vector,
                }
            )

        model = results[0].model
        dimension = results[0].dimension

        body = {
            "status": "ok",
            "model": model,
            "dimension": dimension,
            "count": len(items),
            "items": items,
        }
        _demo_trace(
            "component=python flow=embed_batch step=done "
            f"request_id={request_id} image_count={len(items)} model={model} "
            f"dimension={dimension} elapsed_ms={_elapsed_ms(started)}"
        )
        return body
    except Exception as exc:
        raise _embed_exception_to_http(exc) from exc
