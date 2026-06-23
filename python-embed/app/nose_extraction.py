from __future__ import annotations

import base64
import math
import os
from dataclasses import dataclass, field
from io import BytesIO
from pathlib import Path
from typing import Any, Protocol


DETECTOR_UNAVAILABLE = "DETECTOR_UNAVAILABLE"
INVALID_IMAGE = "INVALID_IMAGE"
NO_NOSE_DETECTED = "NO_NOSE_DETECTED"
MULTIPLE_NOSES_DETECTED = "MULTIPLE_NOSES_DETECTED"
LOW_CONFIDENCE = "LOW_CONFIDENCE"
INTERNAL_ERROR = "INTERNAL_ERROR"
NOSE_TOO_LARGE_FOR_FACE_CHECK = "NOSE_TOO_LARGE_FOR_FACE_CHECK"
NOSE_TOO_SMALL_FOR_FACE_CHECK = "NOSE_TOO_SMALL_FOR_FACE_CHECK"
NOSE_TOUCHES_IMAGE_EDGE = "NOSE_TOUCHES_IMAGE_EDGE"
NOSE_OFF_CENTER = "NOSE_OFF_CENTER"

DEFAULT_CLASS_NAMES = ("nose", "dog_nose", "pet_nose")
DEFAULT_DETECTOR_BACKEND = "ultralytics"
LEGACY_YOLOV5_BACKEND = "yolov5_legacy"
FACE_CHECK_PURPOSE = "face_check"


@dataclass(frozen=True, slots=True)
class NoseDetection:
    bbox_xyxy: tuple[float, float, float, float]
    confidence: float
    class_id: int | None = None
    class_name: str | None = None


class DogNoseDetector(Protocol):
    name: str

    def detect(self, image: Any) -> list[NoseDetection]:
        """Return dog-nose candidate detections for an RGB PIL image."""


@dataclass(frozen=True, slots=True)
class FaceCheckQualityConfig:
    enabled: bool
    nose_min_area_ratio: float
    nose_max_area_ratio: float
    nose_max_width_ratio: float
    nose_max_height_ratio: float
    edge_margin_ratio: float
    center_x_min: float
    center_x_max: float
    center_y_min: float
    center_y_max: float

    @classmethod
    def from_env(cls) -> "FaceCheckQualityConfig":
        return cls(
            enabled=_parse_bool(os.getenv("FACE_CHECK_QUALITY_ENABLED"), default=True),
            nose_min_area_ratio=max(0.0, _parse_float(os.getenv("FACE_CHECK_NOSE_MIN_AREA_RATIO"), 0.003)),
            nose_max_area_ratio=max(0.0, _parse_float(os.getenv("FACE_CHECK_NOSE_MAX_AREA_RATIO"), 0.25)),
            nose_max_width_ratio=max(0.0, _parse_float(os.getenv("FACE_CHECK_NOSE_MAX_WIDTH_RATIO"), 0.60)),
            nose_max_height_ratio=max(0.0, _parse_float(os.getenv("FACE_CHECK_NOSE_MAX_HEIGHT_RATIO"), 0.60)),
            edge_margin_ratio=max(0.0, _parse_float(os.getenv("FACE_CHECK_EDGE_MARGIN_RATIO"), 0.02)),
            center_x_min=_parse_float(os.getenv("FACE_CHECK_CENTER_X_MIN"), 0.20),
            center_x_max=_parse_float(os.getenv("FACE_CHECK_CENTER_X_MAX"), 0.80),
            center_y_min=_parse_float(os.getenv("FACE_CHECK_CENTER_Y_MIN"), 0.25),
            center_y_max=_parse_float(os.getenv("FACE_CHECK_CENTER_Y_MAX"), 0.85),
        )


@dataclass(frozen=True, slots=True)
class DogNoseExtractionConfig:
    enabled: bool
    weights_path: str | None
    detector_backend: str
    yolov5_repo_path: str | None
    conf_threshold: float
    crop_size: int
    bbox_expand: float
    class_id: int | None
    class_names: frozenset[str]
    face_check_quality: FaceCheckQualityConfig = field(default_factory=FaceCheckQualityConfig.from_env)

    @classmethod
    def from_env(cls) -> "DogNoseExtractionConfig":
        return cls(
            enabled=_parse_bool(os.getenv("DOG_NOSE_EXTRACT_ENABLED"), default=False),
            weights_path=_blank_to_none(os.getenv("DOG_NOSE_DETECTOR_WEIGHTS")),
            detector_backend=_parse_detector_backend(os.getenv("DOG_NOSE_DETECTOR_BACKEND")),
            yolov5_repo_path=_blank_to_none(os.getenv("DOG_NOSE_YOLOV5_REPO")),
            conf_threshold=_parse_float(os.getenv("DOG_NOSE_DETECT_CONF_THRESHOLD"), 0.35),
            crop_size=max(1, _parse_int(os.getenv("DOG_NOSE_CROP_SIZE"), 224)),
            bbox_expand=max(1.0, _parse_float(os.getenv("DOG_NOSE_BBOX_EXPAND"), 1.40)),
            class_id=_parse_optional_int(os.getenv("DOG_NOSE_CLASS_ID"), 0),
            class_names=frozenset(_parse_class_names(os.getenv("DOG_NOSE_CLASS_NAMES"))),
            face_check_quality=FaceCheckQualityConfig.from_env(),
        )


@dataclass(frozen=True, slots=True)
class FaceCheckQualityResult:
    purpose: str
    passed: bool
    nose_area_ratio: float | None
    nose_width_ratio: float | None
    nose_height_ratio: float | None
    edge_margin_ratio: float | None
    center_x: float | None
    center_y: float | None
    failure_reason: str | None

    def to_response(self) -> dict[str, object]:
        return {
            "purpose": self.purpose,
            "passed": self.passed,
            "nose_area_ratio": self.nose_area_ratio,
            "nose_width_ratio": self.nose_width_ratio,
            "nose_height_ratio": self.nose_height_ratio,
            "edge_margin_ratio": self.edge_margin_ratio,
            "center_x": self.center_x,
            "center_y": self.center_y,
            "failure_reason": self.failure_reason,
        }


@dataclass(frozen=True, slots=True)
class NoseExtractionResult:
    extracted: bool
    crop_width: int | None
    crop_height: int | None
    confidence: float | None
    bbox_xyxy: list[float] | None
    bbox_expand: float
    detector: str
    crop_bytes: bytes | None
    failure_reason: str | None
    quality: FaceCheckQualityResult | None = None

    def to_response(self) -> dict[str, object]:
        crop_base64 = None
        if self.crop_bytes is not None:
            crop_base64 = base64.b64encode(self.crop_bytes).decode("ascii")

        response = {
            "extracted": self.extracted,
            "crop_width": self.crop_width,
            "crop_height": self.crop_height,
            "confidence": self.confidence,
            "bbox_xyxy": self.bbox_xyxy,
            "bbox_expand": self.bbox_expand,
            "detector": self.detector,
            "crop_base64": crop_base64,
            "failure_reason": self.failure_reason,
        }
        if self.quality is not None:
            response["quality"] = self.quality.to_response()
        return response


class UltralyticsDogNoseDetector:
    name = "ultralytics"

    def __init__(self, weights_path: str) -> None:
        self.weights_path = weights_path
        self._model: Any | None = None
        self.load_error: str | None = None

    @classmethod
    def create_if_available(cls, weights_path: str | None) -> "UltralyticsDogNoseDetector | None":
        if not weights_path or not Path(weights_path).is_file():
            return None

        detector = cls(weights_path)
        return detector if detector.load() else None

    def load(self) -> bool:
        try:
            from ultralytics import YOLO  # type: ignore
        except Exception as exc:  # pragma: no cover - depends on optional local install
            self.load_error = f"ultralytics import failed: {exc}"
            return False

        try:
            self._model = YOLO(self.weights_path)
            return True
        except Exception as exc:  # pragma: no cover - depends on optional local weights
            self.load_error = f"YOLO detector load failed: {exc}"
            return False

    def detect(self, image: Any) -> list[NoseDetection]:
        if self._model is None:
            raise RuntimeError("YOLO detector is not loaded.")

        results = self._model.predict(image, verbose=False)
        names = getattr(self._model, "names", {}) or {}
        detections: list[NoseDetection] = []

        for result in results:
            boxes = getattr(result, "boxes", None)
            if boxes is None:
                continue

            for box in boxes:
                xyxy = _tensorish_to_list(getattr(box, "xyxy", None))
                if xyxy and isinstance(xyxy[0], list):
                    xyxy = xyxy[0]
                if not xyxy or len(xyxy) != 4:
                    continue

                confidence = _tensorish_to_scalar(getattr(box, "conf", None))
                class_id_value = _tensorish_to_scalar(getattr(box, "cls", None))
                class_id = int(class_id_value) if class_id_value is not None else None
                class_name = _class_name_for_id(names, class_id)

                detections.append(
                    NoseDetection(
                        bbox_xyxy=tuple(float(value) for value in xyxy),
                        confidence=float(confidence or 0.0),
                        class_id=class_id,
                        class_name=class_name,
                    )
                )

        return detections


class LegacyYolov5DogNoseDetector:
    name = LEGACY_YOLOV5_BACKEND

    def __init__(self, weights_path: str, repo_path: str) -> None:
        self.weights_path = weights_path
        self.repo_path = repo_path
        self._model: Any | None = None
        self.load_error: str | None = None

    @classmethod
    def create_if_available(
        cls,
        weights_path: str | None,
        repo_path: str | None,
    ) -> "LegacyYolov5DogNoseDetector | None":
        if not weights_path or not Path(weights_path).is_file():
            return None
        if not repo_path or not Path(repo_path).is_dir() or not (Path(repo_path) / "hubconf.py").is_file():
            return None

        detector = cls(weights_path, repo_path)
        return detector if detector.load() else None

    def load(self) -> bool:
        try:
            import torch  # type: ignore

            # Local POC only: this executes the configured local YOLOv5 repo and PyTorch checkpoint.
            self._model = torch.hub.load(
                self.repo_path,
                "custom",
                path=self.weights_path,
                source="local",
                verbose=False,
                device="cpu",
            )
            return True
        except Exception as exc:  # pragma: no cover - depends on optional local YOLOv5 runtime
            self.load_error = f"legacy YOLOv5 detector load failed: {exc}"
            return False

    def detect(self, image: Any) -> list[NoseDetection]:
        if self._model is None:
            raise RuntimeError("Legacy YOLOv5 detector is not loaded.")

        results = self._model(image)
        names = getattr(self._model, "names", {}) or {}
        detections: list[NoseDetection] = []

        xyxy_batches = getattr(results, "xyxy", None) or []
        for rows in xyxy_batches:
            rows = _tensorish_to_list(rows)
            if rows is None:
                continue
            for row in rows:
                if not isinstance(row, list) or len(row) < 6:
                    continue
                class_id = int(float(row[5]))
                detections.append(
                    NoseDetection(
                        bbox_xyxy=tuple(float(value) for value in row[:4]),
                        confidence=float(row[4]),
                        class_id=class_id,
                        class_name=_class_name_for_id(names, class_id),
                    )
                )

        return detections


class DogNoseExtractor:
    def __init__(
        self,
        config: DogNoseExtractionConfig | None = None,
        detector: DogNoseDetector | None = None,
    ) -> None:
        self.config = config or DogNoseExtractionConfig.from_env()
        self.detector = detector

    @classmethod
    def from_env(cls) -> "DogNoseExtractor":
        config = DogNoseExtractionConfig.from_env()
        detector = None
        if config.enabled:
            if config.detector_backend == LEGACY_YOLOV5_BACKEND:
                detector = LegacyYolov5DogNoseDetector.create_if_available(
                    config.weights_path,
                    config.yolov5_repo_path,
                )
            else:
                detector = UltralyticsDogNoseDetector.create_if_available(config.weights_path)
        return cls(config=config, detector=detector)

    @property
    def detector_name(self) -> str:
        if self.config.enabled and self.detector is not None:
            return self.detector.name
        return "unavailable"

    def is_available(self) -> bool:
        return self.config.enabled and self.detector is not None

    def failure_result(
        self,
        failure_reason: str,
        *,
        confidence: float | None = None,
        bbox_xyxy: list[float] | None = None,
        quality: FaceCheckQualityResult | None = None,
    ) -> NoseExtractionResult:
        return NoseExtractionResult(
            extracted=False,
            crop_width=None,
            crop_height=None,
            confidence=confidence,
            bbox_xyxy=bbox_xyxy,
            bbox_expand=self.config.bbox_expand,
            detector=self.detector_name,
            crop_bytes=None,
            failure_reason=failure_reason,
            quality=quality,
        )

    def extract(self, image_bytes: bytes, purpose: str | None = None) -> NoseExtractionResult:
        if not self.is_available():
            return self.failure_result(DETECTOR_UNAVAILABLE)

        if not image_bytes:
            return self.failure_result(INVALID_IMAGE)

        try:
            image = _load_rgb_image(image_bytes)
            detections = self.detector.detect(image)
            return self._extract_from_detections(image, detections, purpose)
        except InvalidImageError:
            return self.failure_result(INVALID_IMAGE)
        except Exception:
            return self.failure_result(INTERNAL_ERROR)

    def _extract_from_detections(
        self,
        image: Any,
        detections: list[NoseDetection],
        purpose: str | None = None,
    ) -> NoseExtractionResult:
        class_matches = [detection for detection in detections if self._matches_expected_class(detection)]
        if not class_matches:
            return self.failure_result(NO_NOSE_DETECTED)

        high_confidence = [
            detection
            for detection in class_matches
            if detection.confidence >= self.config.conf_threshold and _is_valid_bbox(detection.bbox_xyxy)
        ]
        if not high_confidence:
            return self.failure_result(LOW_CONFIDENCE)

        # Rejecting multiple valid noses is safer for profile preview than picking a dog implicitly.
        if len(high_confidence) > 1:
            return self.failure_result(MULTIPLE_NOSES_DETECTED)

        detection = high_confidence[0]
        quality = self._face_check_quality(image, detection, purpose)
        if quality is not None and not quality.passed:
            return self.failure_result(
                quality.failure_reason or INTERNAL_ERROR,
                confidence=round(float(detection.confidence), 6),
                bbox_xyxy=[round(float(value), 3) for value in detection.bbox_xyxy],
                quality=quality,
            )

        crop = _crop_padded_square(image, detection.bbox_xyxy, self.config.bbox_expand)
        crop = _resize_image(crop, self.config.crop_size)

        output = BytesIO()
        crop.save(output, format="PNG")
        crop_bytes = output.getvalue()

        return NoseExtractionResult(
            extracted=True,
            crop_width=self.config.crop_size,
            crop_height=self.config.crop_size,
            confidence=round(float(detection.confidence), 6),
            bbox_xyxy=[round(float(value), 3) for value in detection.bbox_xyxy],
            bbox_expand=self.config.bbox_expand,
            detector=self.detector_name,
            crop_bytes=crop_bytes,
            failure_reason=None,
            quality=quality,
        )

    def _face_check_quality(
        self,
        image: Any,
        detection: NoseDetection,
        purpose: str | None,
    ) -> FaceCheckQualityResult | None:
        if _normalize_purpose(purpose) != FACE_CHECK_PURPOSE:
            return None

        x1, y1, x2, y2 = detection.bbox_xyxy
        image_width = max(1.0, float(image.width))
        image_height = max(1.0, float(image.height))
        bbox_width = max(0.0, float(x2 - x1))
        bbox_height = max(0.0, float(y2 - y1))
        nose_area_ratio = _rounded_ratio((bbox_width * bbox_height) / (image_width * image_height))
        nose_width_ratio = _rounded_ratio(bbox_width / image_width)
        nose_height_ratio = _rounded_ratio(bbox_height / image_height)
        edge_margin_ratio = _rounded_ratio(
            min(
                max(0.0, x1) / image_width,
                max(0.0, y1) / image_height,
                max(0.0, image_width - x2) / image_width,
                max(0.0, image_height - y2) / image_height,
            )
        )
        center_x = _rounded_ratio(((x1 + x2) / 2.0) / image_width)
        center_y = _rounded_ratio(((y1 + y2) / 2.0) / image_height)

        failure_reason = None
        config = self.config.face_check_quality
        if config.enabled:
            if nose_area_ratio < config.nose_min_area_ratio:
                failure_reason = NOSE_TOO_SMALL_FOR_FACE_CHECK
            elif (
                nose_area_ratio > config.nose_max_area_ratio
                or nose_width_ratio > config.nose_max_width_ratio
                or nose_height_ratio > config.nose_max_height_ratio
            ):
                failure_reason = NOSE_TOO_LARGE_FOR_FACE_CHECK
            elif edge_margin_ratio < config.edge_margin_ratio:
                failure_reason = NOSE_TOUCHES_IMAGE_EDGE
            elif (
                center_x < config.center_x_min
                or center_x > config.center_x_max
                or center_y < config.center_y_min
                or center_y > config.center_y_max
            ):
                failure_reason = NOSE_OFF_CENTER

        return FaceCheckQualityResult(
            purpose=FACE_CHECK_PURPOSE,
            passed=failure_reason is None,
            nose_area_ratio=nose_area_ratio,
            nose_width_ratio=nose_width_ratio,
            nose_height_ratio=nose_height_ratio,
            edge_margin_ratio=edge_margin_ratio,
            center_x=center_x,
            center_y=center_y,
            failure_reason=failure_reason,
        )

    def _matches_expected_class(self, detection: NoseDetection) -> bool:
        class_name = (detection.class_name or "").strip().lower()
        if class_name:
            return class_name in self.config.class_names
        return self.config.class_id is not None and detection.class_id == self.config.class_id


class InvalidImageError(Exception):
    pass


def cosine_similarity(left: list[float], right: list[float]) -> float:
    if len(left) != len(right) or not left:
        raise ValueError("vectors must be non-empty and have the same dimension")

    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(a * a for a in left))
    right_norm = math.sqrt(sum(b * b for b in right))
    if left_norm == 0.0 or right_norm == 0.0:
        raise ValueError("vectors must have non-zero norm")
    return dot / (left_norm * right_norm)


def _load_rgb_image(image_bytes: bytes) -> Any:
    try:
        from PIL import Image, UnidentifiedImageError  # type: ignore

        image = Image.open(BytesIO(image_bytes))
        return image.convert("RGB")
    except ModuleNotFoundError as exc:
        raise InvalidImageError("Pillow is not installed.") from exc
    except (UnidentifiedImageError, OSError) as exc:
        raise InvalidImageError("image bytes could not be decoded.") from exc


def _crop_padded_square(image: Any, bbox_xyxy: tuple[float, float, float, float], bbox_expand: float) -> Any:
    x1, y1, x2, y2 = bbox_xyxy
    width = x2 - x1
    height = y2 - y1
    side = max(1, int(math.ceil(max(width, height) * bbox_expand)))

    center_x = (x1 + x2) / 2.0
    center_y = (y1 + y2) / 2.0
    crop_left = int(math.floor(center_x - side / 2.0))
    crop_top = int(math.floor(center_y - side / 2.0))
    crop_right = crop_left + side
    crop_bottom = crop_top + side

    source_left = max(0, crop_left)
    source_top = max(0, crop_top)
    source_right = min(image.width, crop_right)
    source_bottom = min(image.height, crop_bottom)

    from PIL import Image  # type: ignore

    canvas = Image.new("RGB", (side, side), (0, 0, 0))
    if source_right > source_left and source_bottom > source_top:
        crop = image.crop((source_left, source_top, source_right, source_bottom))
        canvas.paste(crop, (source_left - crop_left, source_top - crop_top))
    return canvas


def _resize_image(image: Any, size: int) -> Any:
    from PIL import Image  # type: ignore

    resampling = getattr(Image, "Resampling", Image).LANCZOS
    return image.resize((size, size), resampling)


def _is_valid_bbox(bbox_xyxy: tuple[float, float, float, float]) -> bool:
    x1, y1, x2, y2 = bbox_xyxy
    return all(math.isfinite(value) for value in bbox_xyxy) and x2 > x1 and y2 > y1


def _normalize_purpose(purpose: str | None) -> str:
    return (purpose or "").strip().lower()


def _rounded_ratio(value: float) -> float:
    return round(float(value), 6)


def _parse_bool(value: str | None, *, default: bool) -> bool:
    if value is None or value.strip() == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def _parse_float(value: str | None, default: float) -> float:
    try:
        return float(value) if value is not None and value.strip() else default
    except ValueError:
        return default


def _parse_int(value: str | None, default: int) -> int:
    try:
        return int(value) if value is not None and value.strip() else default
    except ValueError:
        return default


def _parse_optional_int(value: str | None, default: int | None) -> int | None:
    if value is None or value.strip() == "":
        return default
    if value.strip().lower() in {"none", "null"}:
        return None
    try:
        return int(value)
    except ValueError:
        return default


def _parse_detector_backend(value: str | None) -> str:
    if value is None or value.strip() == "":
        return DEFAULT_DETECTOR_BACKEND
    backend = value.strip().lower()
    if backend in {DEFAULT_DETECTOR_BACKEND, LEGACY_YOLOV5_BACKEND}:
        return backend
    return DEFAULT_DETECTOR_BACKEND


def _parse_class_names(value: str | None) -> tuple[str, ...]:
    if value is None or value.strip() == "":
        return DEFAULT_CLASS_NAMES
    return tuple(item.strip().lower() for item in value.split(",") if item.strip())


def _blank_to_none(value: str | None) -> str | None:
    if value is None or value.strip() == "":
        return None
    return value.strip()


def _tensorish_to_list(value: Any) -> Any:
    if value is None:
        return None
    if hasattr(value, "detach"):
        value = value.detach()
    if hasattr(value, "cpu"):
        value = value.cpu()
    if hasattr(value, "tolist"):
        value = value.tolist()
    return value


def _tensorish_to_scalar(value: Any) -> float | None:
    value = _tensorish_to_list(value)
    while isinstance(value, list):
        if not value:
            return None
        value = value[0]
    if value is None:
        return None
    return float(value)


def _class_name_for_id(names: Any, class_id: int | None) -> str | None:
    if class_id is None:
        return None
    if isinstance(names, dict):
        value = names.get(class_id) or names.get(str(class_id))
        return str(value) if value is not None else None
    if isinstance(names, list) and 0 <= class_id < len(names):
        return str(names[class_id])
    return None
