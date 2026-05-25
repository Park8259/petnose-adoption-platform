from __future__ import annotations

from collections.abc import Sequence
import re
from pathlib import Path
from typing import Any

from .base import BaseEmbedder, EmbedInput, EmbedResult, EmbedderError, EmbedderNotReadyError
from .image_preprocess import decode_rgb_image


class DogNoseIdentification2Embedder(BaseEmbedder):
    """
    Real embedder adapter for the local dog_nose_identification2 assets.

    Evidence source:
      - dog_nose_inference_colab.ipynb
      - ResNeSt-101 backbone + GeM + BNNeck
      - Embedding output is L2-normalized before cosine comparison
    """

    def __init__(
        self,
        model_dir: str,
        model_path: str | None,
        embed_device: str = "cpu",
        default_image_size: int = 224,
    ) -> None:
        super().__init__(requested_model_name="dog-nose-identification2")
        self.model_name = "dog-nose-identification2"
        self.backend = "torch+timm"
        self.device = embed_device

        self._model_dir = Path(model_dir)
        self._configured_model_path = Path(model_path) if model_path else None
        self._resolved_model_path: Path | None = None
        self._model_path_exists: bool = False
        self._image_size: int = default_image_size

        self._torch: Any = None
        self._timm: Any = None
        self._transforms: Any = None
        self._model: Any = None
        self._preprocess: Any = None
        self._runtime_device: Any = None

    def load(self) -> bool:
        try:
            try:
                import torch  # type: ignore
                import timm  # type: ignore
                from torchvision import transforms  # type: ignore
            except Exception as exc:  # pragma: no cover - environment dependent
                raise EmbedderError(
                    "실제 모델 의존성이 없습니다. requirements-real.txt 설치 또는 "
                    "PYTHON_EMBED_INSTALL_REAL_DEPS=1 빌드가 필요합니다."
                ) from exc

            self._torch = torch
            self._timm = timm
            self._transforms = transforms

            self._resolved_model_path = self._resolve_checkpoint_path()
            self._model_path_exists = self._resolved_model_path is not None and self._resolved_model_path.exists()
            if not self._model_path_exists:
                raise EmbedderError(
                    "모델 체크포인트를 찾지 못했습니다. DOG_NOSE_MODEL_PATH 또는 DOG_NOSE_MODEL_DIR를 확인하세요."
                )

            assert self._resolved_model_path is not None
            self._image_size = self._infer_image_size_from_path(self._resolved_model_path, default_size=224)
            checkpoint = self._torch_load_checkpoint(self._resolved_model_path)
            raw_state = self._extract_model_state(checkpoint)
            num_classes = self._infer_num_classes(raw_state)

            model = self._build_model(num_classes=num_classes, image_size=self._image_size)
            self._load_matching_tensors(model, raw_state)
            model.eval()

            runtime_device = self._select_device(self.device)
            model.to(runtime_device)
            self._runtime_device = runtime_device
            self._model = model

            self._preprocess = self._transforms.Compose(
                [
                    self._transforms.Resize(
                        (self._image_size, self._image_size),
                        interpolation=self._transforms.InterpolationMode.BICUBIC,
                    ),
                    self._transforms.ToTensor(),
                    self._transforms.Normalize(
                        mean=[0.485, 0.456, 0.406],
                        std=[0.229, 0.224, 0.225],
                    ),
                ]
            )

            # Notebook/architecture 근거상 embedding dimension은 backbone num_features (expected 2048).
            self.vector_dim = int(getattr(model.backbone, "num_features", 2048))
            model_tag = self._resolved_model_path.parent.name
            self.model_name = f"dog-nose-identification2:{model_tag}"
            self.device = str(runtime_device)

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
        if not self.model_loaded or self._model is None or self._preprocess is None:
            raise EmbedderNotReadyError("실제 모델이 아직 로드되지 않았습니다.")
        if not images:
            return []

        tensors = []
        for item in images:
            image = decode_rgb_image(item.image_bytes)
            tensors.append(self._preprocess(image))

        batch = self._torch.stack(tensors).to(self._runtime_device)

        with self._torch.inference_mode():
            feature = self._model(batch, return_logits=False)
            # dog_nose_inference_colab.ipynb 셀 13 근거: L2 normalize 후 cosine 사용
            feature = self._torch.nn.functional.normalize(feature, p=2, dim=1)

        vectors = feature.detach().cpu().float().tolist()
        results: list[EmbedResult] = []
        for vector in vectors:
            if not vector:
                raise EmbedderError("모델 출력 벡터가 비어 있습니다.")

            dimension = len(vector)
            self.vector_dim = dimension
            results.append(EmbedResult(vector=vector, dimension=dimension, model=self.model_name))
        return results

    def health_dict(self) -> dict[str, Any]:
        data = super().health_dict()
        data.update(
            {
                "model_path": str(self._resolved_model_path) if self._resolved_model_path else None,
                "model_path_exists": self._model_path_exists,
                "image_size": self._image_size,
            }
        )
        return data

    def _resolve_checkpoint_path(self) -> Path | None:
        if self._configured_model_path:
            return self._configured_model_path

        candidate_roots = [self._model_dir]
        # 방어적 처리: model_dir가 outer folder일 경우 inner project folder 자동 탐색.
        inner = self._model_dir / "dog_nose_identification2"
        if inner.exists():
            candidate_roots.append(inner)

        preferred_rel = [
            Path("logs/s101_224/model_final.pth"),
            Path("logs/s101_256/model_final.pth"),
            Path("logs/s101_288/model_final.pth"),
            Path("logs/S200_224/model_final.pth"),
        ]

        for root in candidate_roots:
            for rel in preferred_rel:
                p = root / rel
                if p.exists():
                    return p

        for root in candidate_roots:
            hits = sorted(root.rglob("model_final.pth"))
            if hits:
                return hits[0]
            ext_hits = []
            for ext in ("*.pth", "*.pt", "*.ckpt", "*.onnx", "*.h5", "*.keras"):
                ext_hits.extend(root.rglob(ext))
            if ext_hits:
                ext_hits = sorted(ext_hits)
                return ext_hits[0]
        return None

    @staticmethod
    def _infer_image_size_from_path(checkpoint_path: Path, default_size: int) -> int:
        tag = checkpoint_path.parent.name
        match = re.search(r"_(\d+)$", tag)
        if not match:
            return default_size
        size = int(match.group(1))
        return size if size > 0 else default_size

    def _select_device(self, requested: str):
        req = (requested or "cpu").lower()
        if req.startswith("cuda") and self._torch.cuda.is_available():
            return self._torch.device(req)
        return self._torch.device("cpu")

    def _torch_load_checkpoint(self, path: Path):
        try:
            return self._torch.load(path, map_location="cpu", weights_only=False)
        except TypeError:
            return self._torch.load(path, map_location="cpu")

    @staticmethod
    def _extract_model_state(checkpoint: Any) -> dict[str, Any]:
        if isinstance(checkpoint, dict):
            for key in ("model", "state_dict", "net"):
                value = checkpoint.get(key)
                if isinstance(value, dict):
                    return value
            return checkpoint
        raise EmbedderError(f"지원하지 않는 checkpoint 형식입니다: {type(checkpoint)}")

    def _infer_num_classes(self, state_dict: dict[str, Any]) -> int:
        classifier_candidates: list[tuple[str, tuple[int, ...]]] = []
        for key, value in state_dict.items():
            if not self._torch.is_tensor(value):
                continue
            clean_key = self._strip_prefix(key)
            if "classifier" in clean_key.lower() and value.ndim == 2:
                classifier_candidates.append((clean_key, tuple(value.shape)))
        if classifier_candidates:
            key, shape = max(classifier_candidates, key=lambda item: item[1][0])
            _ = key
            return int(shape[0])
        # 기준 코드에 fallback 6000이 명시되어 있음.
        return 6000

    def _build_model(self, num_classes: int, image_size: int):
        torch = self._torch
        nn = torch.nn
        F = torch.nn.functional
        timm = self._timm

        class GeM(nn.Module):
            def __init__(self, p: float = 3.0, eps: float = 1e-6):
                super().__init__()
                self.p = nn.Parameter(torch.ones(1) * p)
                self.eps = eps

            def forward(self, x):
                p = self.p.clamp(min=self.eps)
                x = x.clamp(min=self.eps).pow(p)
                x = F.avg_pool2d(x, kernel_size=(x.size(-2), x.size(-1)))
                return x.pow(1.0 / p).flatten(1)

        class BNNeckHead(nn.Module):
            def __init__(self, in_features: int, num_classes_: int):
                super().__init__()
                self.pool_layer = GeM()
                self.bottleneck = nn.BatchNorm1d(in_features)
                self.bottleneck.bias.requires_grad_(False)
                self.classifier = nn.Linear(in_features, num_classes_, bias=False)
                nn.init.normal_(self.classifier.weight, std=0.001)

            def forward(self, feature_map, return_logits: bool = False):
                pooled = self.pool_layer(feature_map)
                embedding = self.bottleneck(pooled)
                if return_logits:
                    logits = self.classifier(embedding)
                    return embedding, logits
                return embedding

        class DogNoseS101(nn.Module):
            def __init__(self, classes: int, size: int):
                super().__init__()
                self.image_size = size
                self.backbone = timm.create_model(
                    "resnest101e",
                    pretrained=False,
                    num_classes=0,
                    global_pool="",
                )
                in_features = int(getattr(self.backbone, "num_features", 2048))
                self.heads = BNNeckHead(in_features=in_features, num_classes_=classes)

            def forward(self, x, return_logits: bool = False):
                feature_map = self.backbone.forward_features(x)
                return self.heads(feature_map, return_logits=return_logits)

        return DogNoseS101(classes=num_classes, size=image_size)

    @staticmethod
    def _strip_prefix(key: str) -> str:
        changed = True
        out = key
        while changed:
            changed = False
            for prefix in ("module.", "model."):
                if out.startswith(prefix):
                    out = out[len(prefix):]
                    changed = True
        return out

    def _candidate_target_keys(self, source_key: str) -> list[str]:
        key = self._strip_prefix(source_key)
        candidates = [key]
        replacements = [
            ("heads.bnneck.", "heads.bottleneck."),
            ("heads.batchnorm.", "heads.bottleneck."),
            ("bnneck.", "heads.bottleneck."),
            ("bottleneck.", "heads.bottleneck."),
            ("classifier.", "heads.classifier."),
            ("pool_layer.", "heads.pool_layer."),
            ("global_pool.", "heads.pool_layer."),
            ("pool.", "heads.pool_layer."),
        ]
        for src, dst in replacements:
            if key.startswith(src):
                candidates.append(dst + key[len(src):])
        if not key.startswith("backbone."):
            candidates.append("backbone." + key)
        if key.startswith("backbone.base."):
            candidates.append("backbone." + key[len("backbone.base."):])
        if key.startswith("heads.bottleneck.0."):
            candidates.append("heads.bottleneck." + key[len("heads.bottleneck.0."):])
        # duplicate 제거
        return list(dict.fromkeys(candidates))

    def _load_matching_tensors(self, model: Any, state_dict: dict[str, Any]) -> None:
        torch = self._torch
        model_state = model.state_dict()
        remapped: dict[str, Any] = {}
        loaded_params = 0

        for source_key, source_value in state_dict.items():
            if not torch.is_tensor(source_value):
                continue
            for target_key in self._candidate_target_keys(source_key):
                if target_key not in model_state:
                    continue
                if tuple(model_state[target_key].shape) == tuple(source_value.shape):
                    remapped[target_key] = source_value
                    loaded_params += int(source_value.numel())
                    break

        incompatible = model.load_state_dict(remapped, strict=False)
        _ = incompatible
        total_params = sum(int(v.numel()) for v in model_state.values())
        loaded_ratio = loaded_params / max(total_params, 1)

        # Notebook also enforces a minimum matched ratio for safety.
        if loaded_ratio < 0.60:
            raise EmbedderError(
                "checkpoint 파라미터 매칭률이 너무 낮습니다. "
                f"loaded_ratio={loaded_ratio:.2%}, checkpoint={self._resolved_model_path}"
            )
