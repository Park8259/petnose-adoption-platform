from __future__ import annotations

import os

from .base import BaseEmbedder, EmbedderError
from .mock_embedder import MockEmbedder


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None or not value.strip():
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def create_embedder_from_env() -> BaseEmbedder:
    embed_model = os.getenv("EMBED_MODEL", "mock-v1").strip()
    vector_dim = int(os.getenv("EMBED_VECTOR_DIM", "128"))

    if embed_model == "mock-v1":
        return MockEmbedder(vector_dim=vector_dim)

    if embed_model == "dog-nose-identification2":
        model_dir = os.getenv("DOG_NOSE_MODEL_DIR", "/models/dog_nose_identification2")
        runtime = os.getenv("DOG_NOSE_RUNTIME", "torch").strip().lower()

        if runtime in {"torch", "pytorch", "timm"}:
            from .dog_nose_identification2_embedder import DogNoseIdentification2Embedder

            model_path = os.getenv("DOG_NOSE_MODEL_PATH", "").strip() or None
            embed_device = os.getenv("EMBED_DEVICE", "cpu")
            embed_device_required = _env_bool("EMBED_DEVICE_REQUIRED")
            return DogNoseIdentification2Embedder(
                model_dir=model_dir,
                model_path=model_path,
                embed_device=embed_device,
                embed_device_required=embed_device_required,
            )

        if runtime in {"onnx", "onnxruntime", "ort"}:
            from .dog_nose_identification2_onnx_embedder import DogNoseIdentification2OnnxEmbedder

            onnx_path = os.getenv("DOG_NOSE_ONNX_PATH", "").strip() or None
            model_tag = os.getenv("DOG_NOSE_MODEL_TAG", "s101_224").strip() or "s101_224"
            image_size = int(os.getenv("DOG_NOSE_IMAGE_SIZE", "224"))
            return DogNoseIdentification2OnnxEmbedder(
                model_dir=model_dir,
                onnx_path=onnx_path,
                model_tag=model_tag,
                default_image_size=image_size,
            )

        raise EmbedderError(
            f"지원하지 않는 DOG_NOSE_RUNTIME입니다: {runtime}. "
            "지원값: torch, onnxruntime"
        )

    raise EmbedderError(
        f"지원하지 않는 EMBED_MODEL입니다: {embed_model}. "
        "지원값: mock-v1, dog-nose-identification2"
    )
