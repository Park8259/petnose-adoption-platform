from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any


class EmbedderError(Exception):
    """Base exception for embedder failures."""


class EmbedderNotReadyError(EmbedderError):
    """Raised when model is not loaded yet."""


@dataclass(slots=True)
class EmbedResult:
    vector: list[float]
    dimension: int
    model: str


@dataclass(frozen=True, slots=True)
class EmbedInput:
    image_bytes: bytes
    content_type: str | None = None


class BaseEmbedder(ABC):
    """
    Common embedder interface.

    Spring Boot contract compatibility:
      - response fields must stay: status, vector, dimension, model
    """

    def __init__(self, requested_model_name: str) -> None:
        self.requested_model_name = requested_model_name
        self.model_name: str = requested_model_name
        self.vector_dim: int = 0
        self.backend: str = "unknown"
        self.device: str = "cpu"
        self.model_loaded: bool = False
        self.load_error: str | None = None

    @abstractmethod
    def load(self) -> bool:
        """Load model resources. Returns True when successful."""

    @abstractmethod
    def embed(self, image_bytes: bytes, content_type: str | None = None) -> EmbedResult:
        """Create an embedding vector from image bytes."""

    def embed_batch(self, images: Sequence[EmbedInput]) -> list[EmbedResult]:
        """Create embedding vectors from multiple images."""
        return [self.embed(image.image_bytes, image.content_type) for image in images]

    def health_dict(self) -> dict[str, Any]:
        return {
            "model_loaded": self.model_loaded,
            "model": self.model_name,
            "vector_dim": self.vector_dim,
            "backend": self.backend,
            "device": self.device,
            "load_error": self.load_error,
        }
