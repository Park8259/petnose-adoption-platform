"""
PetNose - Python Embedding Service

Contract notes:
  - /embed response fields must stay: status, vector, dimension, model
  - mock-v1 must remain stable for existing smoke tests
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse

from .embedding import create_embedder_from_env
from .embedding.base import BaseEmbedder, EmbedInput, EmbedResult, EmbedderError, EmbedderNotReadyError
from .nose_extraction import (
    DogNoseExtractor,
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

_embedder: BaseEmbedder | None = None
_nose_extractor: DogNoseExtractor | None = None


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
        f"detector_device={_nose_extractor.detector_device}, crop_size={_nose_extractor.config.crop_size}"
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
) -> dict[str, object]:
    return {
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
        "failure_reason": failure_reason,
    }


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


def _safe_readiness_reason(code: str, message: str) -> dict[str, str]:
    return {"code": code, "message": message}


def _readiness_payload(embedder: BaseEmbedder) -> tuple[int, dict[str, object]]:
    data = embedder.health_dict()
    expected_model = os.getenv("EMBED_MODEL", embedder.requested_model_name).strip() or embedder.requested_model_name
    expected_dim = _parse_int_env("EMBED_VECTOR_DIM", int(data.get("vector_dim") or 0))
    model = str(data.get("model") or "")
    backend = data.get("backend")
    device = str(data.get("device") or "")
    requested_device = str(data.get("requested_device") or os.getenv("EMBED_DEVICE", "cpu") or "cpu")
    requested_device_lower = requested_device.lower()
    device_lower = device.lower()
    model_loaded = bool(data.get("model_loaded"))
    vector_dim = int(data.get("vector_dim") or 0)
    model_path_exists = data.get("model_path_exists")
    device_required = bool(data.get("embed_device_required", _parse_bool_env("EMBED_DEVICE_REQUIRED")))

    reasons: list[dict[str, str]] = []

    if not model_loaded:
        code = "MODEL_LOAD_ERROR" if data.get("load_error") else "MODEL_NOT_LOADED"
        reasons.append(
            _safe_readiness_reason(
                code,
                "Embedding model is not loaded.",
            )
        )

    if expected_model == "dog-nose-identification2" and not model.startswith("dog-nose-identification2"):
        reasons.append(
            _safe_readiness_reason(
                "MODEL_MISMATCH",
                "Loaded model does not match the dog-nose-identification2 runtime.",
            )
        )

    if expected_model == "dog-nose-identification2" and backend != "torch+timm":
        reasons.append(
            _safe_readiness_reason(
                "BACKEND_MISMATCH",
                "Dog nose production readiness requires the torch+timm backend.",
            )
        )

    if expected_dim > 0 and vector_dim != expected_dim:
        reasons.append(
            _safe_readiness_reason(
                "VECTOR_DIM_MISMATCH",
                "Embedding vector dimension does not match the configured runtime.",
            )
        )

    if expected_model == "dog-nose-identification2" and model_path_exists is not True:
        reasons.append(
            _safe_readiness_reason(
                "MODEL_PATH_NOT_READY",
                "Dog nose model checkpoint is not available to the container.",
            )
        )

    if requested_device_lower.startswith("cuda") and not device_lower.startswith("cuda"):
        reasons.append(
            _safe_readiness_reason(
                "CUDA_REQUESTED_BUT_NOT_ACTIVE",
                "CUDA was requested, but the loaded model is not using a CUDA device.",
            )
        )

    if device_required and requested_device_lower and not requested_device_lower.startswith("cuda"):
        if device_lower != requested_device_lower:
            reasons.append(
                _safe_readiness_reason(
                    "REQUIRED_DEVICE_MISMATCH",
                    "The loaded model device does not match the required device.",
                )
            )

    if device_required and requested_device_lower.startswith("cuda") and device_lower.startswith("cuda"):
        device_required_satisfied = True
    elif device_required:
        device_required_satisfied = False
    else:
        device_required_satisfied = True

    if not device_required_satisfied and not any(reason["code"] == "CUDA_REQUESTED_BUT_NOT_ACTIVE" for reason in reasons):
        reasons.append(
            _safe_readiness_reason(
                "REQUIRED_DEVICE_MISMATCH",
                "The loaded model device does not satisfy EMBED_DEVICE_REQUIRED.",
            )
        )

    ready = not reasons
    body: dict[str, object] = {
        "status": "ready" if ready else "not_ready",
        "model_loaded": model_loaded,
        "model": model,
        "vector_dim": vector_dim,
        "backend": backend,
        "device": device,
        "requested_device": requested_device,
        "device_required": device_required,
        "device_required_satisfied": device_required_satisfied,
        "model_path_exists": model_path_exists,
        "image_size": data.get("image_size"),
        "checks": {
            "model_loaded": model_loaded,
            "model_matches_expected": expected_model != "dog-nose-identification2"
            or model.startswith("dog-nose-identification2"),
            "backend_matches_expected": expected_model != "dog-nose-identification2" or backend == "torch+timm",
            "vector_dim_matches_expected": expected_dim <= 0 or vector_dim == expected_dim,
            "model_path_exists": expected_model != "dog-nose-identification2" or model_path_exists is True,
            "device_matches_requested": not requested_device_lower.startswith("cuda") or device_lower.startswith("cuda"),
            "device_required_satisfied": device_required_satisfied,
        },
        "reasons": reasons,
    }
    return (200 if ready else 503), body


@app.get("/health/ready")
def readiness():
    if _embedder is None:
        return JSONResponse(
            status_code=503,
            content={
                "status": "not_ready",
                "model_loaded": False,
                "reasons": [
                    _safe_readiness_reason(
                        "SERVICE_NOT_INITIALIZED",
                        "Embedding service is not initialized.",
                    )
                ],
            },
        )

    status_code, body = _readiness_payload(_embedder)
    return JSONResponse(status_code=status_code, content=body)


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
async def extract_profile_nose(image: UploadFile = File(...)):
    extractor = _require_nose_extractor()

    try:
        image_bytes = await _read_upload_bytes(image)
    except ValueError:
        return extractor.failure_result(INVALID_IMAGE).to_response()

    result = extractor.extract(image_bytes)
    return result.to_response()


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
    profile_image: UploadFile = File(...),
    nose_image: list[UploadFile] = File(...),
):
    extractor = _require_nose_extractor()
    threshold = PROFILE_NOSE_MATCH_THRESHOLD
    required_pass_count = PROFILE_NOSE_MATCH_MIN_PASS_COUNT

    try:
        profile_bytes = await _read_upload_bytes(profile_image)
    except ValueError:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INVALID_IMAGE,
        )

    extraction = extractor.extract(profile_bytes)
    if not extraction.extracted or extraction.crop_bytes is None:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=extraction.failure_reason or INTERNAL_ERROR,
            extraction=extraction,
        )

    if len(nose_image) != PROFILE_NOSE_MATCH_EXPECTED_COUNT:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=NOSE_IMAGES_COUNT_INVALID,
            extraction=extraction,
        )

    try:
        nose_inputs = [await _read_validated_image(image) for image in nose_image]
    except HTTPException:
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INVALID_IMAGE,
            extraction=extraction,
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
        )

    if len(nose_results) != len(nose_inputs):
        return _profile_match_batch_failure(
            threshold=threshold,
            required_pass_count=required_pass_count,
            failure_reason=INTERNAL_ERROR,
            extraction=extraction,
            model=profile_result.model,
            dimension=profile_result.dimension,
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
        )

    pass_count = sum(1 for score in similarity_values if score >= threshold)
    median_score = round(_median(similarity_values), 6)
    matched = pass_count >= required_pass_count and median_score >= threshold

    return {
        "matched": matched,
        "threshold": threshold,
        "threshold_calibrated": False,
        "pass_count": pass_count,
        "required_pass_count": required_pass_count,
        "aggregate": _profile_match_aggregate(),
        "median_score": median_score,
        "mean_score": round(sum(similarity_values) / len(similarity_values), 6),
        "min_score": min(similarity_values),
        "max_score": max(similarity_values),
        "profile_nose_extracted": True,
        "profile_confidence": extraction.confidence,
        "profile_crop_width": extraction.crop_width,
        "profile_crop_height": extraction.crop_height,
        "model": profile_result.model,
        "dimension": profile_result.dimension,
        "scores": scores,
        "failure_reason": None,
    }


@app.post("/embed-batch")
async def embed_batch(request: Request):
    embedder = _require_embedder()

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

        return {
            "status": "ok",
            "model": model,
            "dimension": dimension,
            "count": len(items),
            "items": items,
        }
    except Exception as exc:
        raise _embed_exception_to_http(exc) from exc
