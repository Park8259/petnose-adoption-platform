from __future__ import annotations

from collections.abc import Sequence
import os
from pathlib import Path
import re
from typing import Any

from .base import BaseEmbedder, EmbedInput, EmbedResult, EmbedderError, EmbedderNotReadyError
from .image_preprocess import decode_rgb_image


class DogNoseIdentification2OnnxEmbedder(BaseEmbedder):
    """
    ONNX Runtime CPU adapter for exported dog_nose_identification2 embeddings.

    The exported graph is expected to return the same L2-normalized 2048-dim
    embedding as the torch+timm embedder. Serving remains CPU-only.
    """

    def __init__(
        self,
        model_dir: str,
        onnx_path: str | None,
        model_tag: str = "s101_224",
        default_image_size: int = 224,
    ) -> None:
        super().__init__(requested_model_name="dog-nose-identification2")
        self.model_name = f"dog-nose-identification2:{model_tag}"
        self.backend = "onnxruntime-cpu"
        self.device = "cpu"

        self._model_dir = Path(model_dir)
        self._configured_onnx_path = Path(onnx_path) if onnx_path else None
        self._resolved_onnx_path: Path | None = None
        self._onnx_path_exists: bool = False
        self._image_size: int = default_image_size
        self._model_tag = model_tag

        self._np: Any = None
        self._ort: Any = None
        self._session: Any = None
        self._input_name: str | None = None
        self._output_name: str | None = None

    def load(self) -> bool:
        try:
            try:
                import numpy as np  # type: ignore
                import onnxruntime as ort  # type: ignore
            except Exception as exc:  # pragma: no cover - environment dependent
                raise EmbedderError(
                    "ONNX Runtime 의존성이 없습니다. requirements-onnx.txt 설치가 필요합니다."
                ) from exc

            self._np = np
            self._ort = ort

            self._resolved_onnx_path = self._resolve_onnx_path()
            self._onnx_path_exists = self._resolved_onnx_path is not None and self._resolved_onnx_path.exists()
            if not self._onnx_path_exists:
                raise EmbedderError("ONNX 모델 파일을 찾지 못했습니다. DOG_NOSE_ONNX_PATH 또는 DOG_NOSE_MODEL_DIR를 확인하세요.")

            assert self._resolved_onnx_path is not None
            session_options = ort.SessionOptions()
            session_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            self._apply_thread_options(session_options)

            session = ort.InferenceSession(
                str(self._resolved_onnx_path),
                sess_options=session_options,
                providers=["CPUExecutionProvider"],
            )
            providers = session.get_providers()
            if providers != ["CPUExecutionProvider"]:
                raise EmbedderError(f"ONNX Runtime CPU provider만 허용됩니다. providers={providers}")

            inputs = session.get_inputs()
            outputs = session.get_outputs()
            if len(inputs) != 1 or len(outputs) < 1:
                raise EmbedderError(
                    f"지원하지 않는 ONNX graph 입출력 개수입니다: inputs={len(inputs)}, outputs={len(outputs)}"
                )

            self._session = session
            self._input_name = inputs[0].name
            self._output_name = outputs[0].name
            self._image_size = self._infer_image_size(inputs[0].shape, self._resolved_onnx_path, self._model_tag)
            self.vector_dim = self._infer_vector_dim(outputs[0].shape)
            self.model_loaded = True
            self.load_error = None
            return True
        except Exception as exc:
            self.model_loaded = False
            self.load_error = str(exc)
            return False

    def embed(self, image_bytes: bytes, content_type: str | None = None) -> EmbedResult:
        return self.embed_batch([EmbedInput(image_bytes=image_bytes, content_type=content_type)])[0]

    def embed_batch(self, images: Sequence[EmbedInput]) -> list[EmbedResult]:
        if (
            not self.model_loaded
            or self._session is None
            or self._input_name is None
            or self._output_name is None
            or self._np is None
        ):
            raise EmbedderNotReadyError("ONNX Runtime 모델이 아직 로드되지 않았습니다.")
        if not images:
            return []

        batch = self._np.stack([self._preprocess(item.image_bytes) for item in images], axis=0)
        batch = batch.astype(self._np.float32, copy=False)
        output = self._session.run([self._output_name], {self._input_name: batch})[0]
        features = self._np.asarray(output, dtype=self._np.float32)
        if features.ndim != 2:
            raise EmbedderError(f"ONNX 출력 shape가 2D embedding이 아닙니다: shape={features.shape}")

        features = self._l2_normalize(features)
        vectors = features.astype(self._np.float32, copy=False).tolist()
        results: list[EmbedResult] = []
        for vector in vectors:
            if not vector:
                raise EmbedderError("ONNX 출력 벡터가 비어 있습니다.")

            dimension = len(vector)
            self.vector_dim = dimension
            results.append(EmbedResult(vector=vector, dimension=dimension, model=self.model_name))
        return results

    def health_dict(self) -> dict[str, Any]:
        data = super().health_dict()
        data.update(
            {
                "model_path": str(self._resolved_onnx_path) if self._resolved_onnx_path else None,
                "model_path_exists": self._onnx_path_exists,
                "image_size": self._image_size,
            }
        )
        return data

    def _preprocess(self, image_bytes: bytes):
        from PIL import Image  # type: ignore

        image = decode_rgb_image(image_bytes)
        resampling = getattr(Image, "Resampling", Image).BICUBIC
        image = image.resize((self._image_size, self._image_size), resample=resampling)
        array = self._np.asarray(image, dtype=self._np.float32) / 255.0
        if array.ndim != 3 or array.shape[2] != 3:
            raise EmbedderError(f"RGB 이미지 shape가 아닙니다: shape={array.shape}")

        mean = self._np.asarray([0.485, 0.456, 0.406], dtype=self._np.float32)
        std = self._np.asarray([0.229, 0.224, 0.225], dtype=self._np.float32)
        array = (array - mean) / std
        return self._np.transpose(array, (2, 0, 1))

    def _l2_normalize(self, features):
        norm = self._np.linalg.norm(features, ord=2, axis=1, keepdims=True)
        norm = self._np.maximum(norm, self._np.asarray(1e-12, dtype=self._np.float32))
        return features / norm

    def _resolve_onnx_path(self) -> Path | None:
        if self._configured_onnx_path:
            return self._configured_onnx_path

        candidate_roots = [self._model_dir]
        inner = self._model_dir / "dog_nose_identification2"
        if inner.exists():
            candidate_roots.append(inner)

        tag = self._model_tag
        preferred_rel = [
            Path(f"logs/{tag}/model_final.onnx"),
            Path(f"logs/{tag}/dog_nose_{tag}.onnx"),
            Path(f"logs/{tag}/dog_nose_identification2_{tag}.onnx"),
            Path(f"dog_nose_{tag}.onnx"),
            Path(f"dog_nose_identification2_{tag}.onnx"),
        ]
        for root in candidate_roots:
            for rel in preferred_rel:
                path = root / rel
                if path.exists():
                    return path

        for root in candidate_roots:
            hits = sorted(root.rglob("*.onnx"))
            if hits:
                return hits[0]
        return None

    @staticmethod
    def _infer_image_size(input_shape: Sequence[Any], onnx_path: Path, model_tag: str) -> int:
        if len(input_shape) == 4 and isinstance(input_shape[2], int) and input_shape[2] > 0:
            return int(input_shape[2])
        for text in (model_tag, onnx_path.parent.name, onnx_path.stem):
            match = re.search(r"_(\d+)(?:$|[^0-9])", text)
            if match:
                return int(match.group(1))
        return 224

    @staticmethod
    def _infer_vector_dim(output_shape: Sequence[Any]) -> int:
        if len(output_shape) >= 2 and isinstance(output_shape[1], int) and output_shape[1] > 0:
            return int(output_shape[1])
        return 2048

    @staticmethod
    def _apply_thread_options(session_options: Any) -> None:
        intra_threads = _read_positive_int_env("DOG_NOSE_ORT_INTRA_OP_THREADS")
        inter_threads = _read_positive_int_env("DOG_NOSE_ORT_INTER_OP_THREADS")
        if intra_threads is not None:
            session_options.intra_op_num_threads = intra_threads
        if inter_threads is not None:
            session_options.inter_op_num_threads = inter_threads


def _read_positive_int_env(name: str) -> int | None:
    value = os.getenv(name, "").strip()
    if not value:
        return None
    parsed = int(value)
    return parsed if parsed > 0 else None
