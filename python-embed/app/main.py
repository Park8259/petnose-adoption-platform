"""
PetNose - Python Embedding Service

Contract notes:
  - /embed response fields must stay: status, vector, dimension, model
  - mock-v1 must remain stable for existing smoke tests
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, HTTPException, UploadFile

from .embedding import create_embedder_from_env
from .embedding.base import BaseEmbedder, EmbedInput, EmbedResult, EmbedderError, EmbedderNotReadyError

MAX_IMAGE_SIZE: int = int(os.getenv("MAX_IMAGE_BYTES", str(20 * 1024 * 1024)))
MAX_BATCH_IMAGES: int = int(os.getenv("MAX_BATCH_IMAGES", os.getenv("MAX_EMBED_BATCH_IMAGES", "5")))
MAX_BATCH_TOTAL_BYTES: int = int(os.getenv("MAX_BATCH_TOTAL_BYTES", str(80 * 1024 * 1024)))
ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/jpg"}

_embedder: BaseEmbedder | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _embedder
    _embedder = create_embedder_from_env()
    loaded = _embedder.load()
    mode = "MOCK" if _embedder.requested_model_name == "mock-v1" else "REAL"
    print(
        "[EmbedService] start - "
        f"mode={mode}, requested_model={_embedder.requested_model_name}, "
        f"resolved_model={_embedder.model_name}, loaded={loaded}, dim={_embedder.vector_dim}"
    )
    if _embedder.load_error:
        print(f"[EmbedService] load_error={_embedder.load_error}")
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


@app.post("/embed-batch")
async def embed_batch(images: list[UploadFile] | None = File(default=None)):
    embedder = _require_embedder()

    if not images:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "INVALID_IMAGE",
                "message": "이미지 목록이 비어 있습니다.",
            },
        )

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
