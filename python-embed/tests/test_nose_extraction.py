from __future__ import annotations

import base64
import os
import tempfile
import types
import unittest
from io import BytesIO
from pathlib import Path
import sys
from unittest.mock import patch

from fastapi.testclient import TestClient
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import main
from app.embedding.base import BaseEmbedder, EmbedResult
from app.nose_extraction import (
    DETECTOR_UNAVAILABLE,
    LEGACY_YOLOV5_BACKEND,
    MULTIPLE_NOSES_DETECTED,
    NO_NOSE_DETECTED,
    DogNoseExtractionConfig,
    DogNoseExtractor,
    LegacyYolov5DogNoseDetector,
    NoseDetection,
)


def make_png(width: int = 320, height: int = 240) -> bytes:
    image = Image.new("RGB", (width, height), (120, 80, 40))
    output = BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


class FakeDetector:
    name = "fake"

    def __init__(self, detections: list[NoseDetection]) -> None:
        self.detections = detections

    def detect(self, image) -> list[NoseDetection]:
        return self.detections


class FakeEmbedder(BaseEmbedder):
    def __init__(self) -> None:
        super().__init__("fake-v1")
        self.model_name = "fake-v1:test"
        self.vector_dim = 4
        self.model_loaded = True

    def load(self) -> bool:
        return True

    def embed(self, image_bytes: bytes, content_type: str | None = None) -> EmbedResult:
        return EmbedResult(vector=[1.0, 0.0, 0.0, 0.0], dimension=4, model=self.model_name)


class FakeSequence2048Embedder(BaseEmbedder):
    def __init__(self, scores: list[float] | None = None, dimension: int = 2048) -> None:
        super().__init__("dog-nose-identification2")
        self.model_name = "dog-nose-identification2:s101_224"
        self.vector_dim = dimension
        self.model_loaded = True
        self._scores = scores or [1.0, 1.0, 1.0, 1.0, 1.0]
        self._calls = 0

    def load(self) -> bool:
        return True

    def embed(self, image_bytes: bytes, content_type: str | None = None) -> EmbedResult:
        if self._calls == 0:
            self._calls += 1
            return EmbedResult(vector=unit_vector(1.0, self.vector_dim), dimension=self.vector_dim, model=self.model_name)
        score = self._scores[min(self._calls - 1, len(self._scores) - 1)]
        self._calls += 1
        return EmbedResult(vector=unit_vector(score, self.vector_dim), dimension=self.vector_dim, model=self.model_name)


def unit_vector(score: float, dimension: int) -> list[float]:
    vector = [0.0] * dimension
    vector[0] = score
    if dimension > 1:
        vector[1] = max(0.0, 1.0 - score * score) ** 0.5
    return vector


def make_extractor(detections: list[NoseDetection] | None) -> DogNoseExtractor:
    config = DogNoseExtractionConfig(
        enabled=True,
        weights_path=None,
        detector_backend="ultralytics",
        yolov5_repo_path=None,
        detector_device="cpu",
        conf_threshold=0.35,
        crop_size=224,
        bbox_expand=1.40,
        class_id=0,
        class_names=frozenset({"nose", "dog_nose", "pet_nose"}),
    )
    detector = FakeDetector(detections or []) if detections is not None else None
    return DogNoseExtractor(config=config, detector=detector)


class DogNoseExtractorTest(unittest.TestCase):
    class FakeCuda:
        def __init__(self, available: bool) -> None:
            self.available = available

        def is_available(self) -> bool:
            return self.available

    class FakeHub:
        def __init__(self) -> None:
            self.calls: list[dict[str, object]] = []

        def load(self, *args, **kwargs):
            self.calls.append({"args": args, **kwargs})
            return object()

    @staticmethod
    def fake_torch(cuda_available: bool, hub: "DogNoseExtractorTest.FakeHub"):
        return types.SimpleNamespace(cuda=DogNoseExtractorTest.FakeCuda(cuda_available), hub=hub)

    def test_profile_match_threshold_env_parse_falls_back_on_invalid_value(self) -> None:
        with patch.dict(os.environ, {"PROFILE_NOSE_MATCH_THRESHOLD": "not-a-number"}):
            self.assertEqual(main._parse_float_env("PROFILE_NOSE_MATCH_THRESHOLD", 0.65), 0.65)

    def test_detector_device_env_defaults_to_cpu_and_accepts_cuda_auto(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(DogNoseExtractionConfig.from_env().detector_device, "cpu")

        with patch.dict(os.environ, {"DOG_NOSE_DETECTOR_DEVICE": "cuda:0"}):
            self.assertEqual(DogNoseExtractionConfig.from_env().detector_device, "cuda:0")

        with patch.dict(os.environ, {"DOG_NOSE_DETECTOR_DEVICE": "auto"}):
            self.assertEqual(DogNoseExtractionConfig.from_env().detector_device, "auto")

        with patch.dict(os.environ, {"DOG_NOSE_DETECTOR_DEVICE": "gpu"}):
            self.assertEqual(DogNoseExtractionConfig.from_env().detector_device, "cpu")

    def test_legacy_yolov5_backend_env_is_optional_and_requires_local_repo(self) -> None:
        with patch.dict(
            os.environ,
            {
                "DOG_NOSE_EXTRACT_ENABLED": "true",
                "DOG_NOSE_DETECTOR_BACKEND": LEGACY_YOLOV5_BACKEND,
                "DOG_NOSE_DETECTOR_WEIGHTS": __file__,
                "DOG_NOSE_YOLOV5_REPO": str(Path(__file__).parent),
            },
        ):
            extractor = DogNoseExtractor.from_env()

        self.assertEqual(extractor.config.detector_backend, LEGACY_YOLOV5_BACKEND)
        self.assertFalse(extractor.is_available())

    def test_legacy_yolov5_load_passes_configured_device_to_torch_hub(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "yolov05"
            repo.mkdir()
            (repo / "hubconf.py").write_text("# fake hubconf\n", encoding="utf-8")
            weights = root / "best.pt"
            weights.write_bytes(b"fake")
            hub = self.FakeHub()
            detector = LegacyYolov5DogNoseDetector(str(weights), str(repo), device="cuda:0")

            with patch.dict(sys.modules, {"torch": self.fake_torch(True, hub)}):
                self.assertTrue(detector.load(), detector.load_error)

        self.assertEqual(detector.device, "cuda:0")
        self.assertEqual(hub.calls[0]["device"], "cuda:0")

    def test_legacy_yolov5_explicit_cuda_does_not_silent_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "yolov05"
            repo.mkdir()
            (repo / "hubconf.py").write_text("# fake hubconf\n", encoding="utf-8")
            weights = root / "best.pt"
            weights.write_bytes(b"fake")
            hub = self.FakeHub()
            detector = LegacyYolov5DogNoseDetector(str(weights), str(repo), device="cuda:0")

            with patch.dict(sys.modules, {"torch": self.fake_torch(False, hub)}):
                self.assertFalse(detector.load())

        self.assertIn("CUDA is not available", detector.load_error or "")
        self.assertEqual(hub.calls, [])

    def test_legacy_yolov5_auto_device_uses_cpu_when_cuda_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "yolov05"
            repo.mkdir()
            (repo / "hubconf.py").write_text("# fake hubconf\n", encoding="utf-8")
            weights = root / "best.pt"
            weights.write_bytes(b"fake")
            hub = self.FakeHub()
            detector = LegacyYolov5DogNoseDetector(str(weights), str(repo), device="auto")

            with patch.dict(sys.modules, {"torch": self.fake_torch(False, hub)}):
                self.assertTrue(detector.load(), detector.load_error)

        self.assertEqual(detector.device, "cpu")
        self.assertEqual(hub.calls[0]["device"], "cpu")

    def test_extracts_224_square_crop_with_expansion_and_padding(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection(
                    bbox_xyxy=(0.0, 8.0, 48.0, 56.0),
                    confidence=0.91,
                    class_id=0,
                    class_name="nose",
                )
            ]
        )

        result = extractor.extract(make_png())

        self.assertTrue(result.extracted)
        self.assertEqual(result.crop_width, 224)
        self.assertEqual(result.crop_height, 224)
        self.assertIsNone(result.failure_reason)

        image = Image.open(BytesIO(result.crop_bytes or b""))
        self.assertEqual(image.size, (224, 224))

    def test_detector_unavailable_returns_failure_without_crashing(self) -> None:
        extractor = make_extractor(None)

        result = extractor.extract(make_png())

        self.assertFalse(result.extracted)
        self.assertEqual(result.detector, "unavailable")
        self.assertEqual(result.failure_reason, DETECTOR_UNAVAILABLE)

    def test_multiple_valid_noses_are_rejected(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection((20.0, 20.0, 90.0, 90.0), 0.88, class_id=0, class_name="nose"),
                NoseDetection((160.0, 40.0, 230.0, 110.0), 0.86, class_id=0, class_name="nose"),
            ]
        )

        result = extractor.extract(make_png())

        self.assertFalse(result.extracted)
        self.assertEqual(result.failure_reason, MULTIPLE_NOSES_DETECTED)

    def test_named_non_nose_class_is_not_accepted_by_class_id_only(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection((20.0, 20.0, 90.0, 90.0), 0.88, class_id=0, class_name="person"),
            ]
        )

        result = extractor.extract(make_png())

        self.assertFalse(result.extracted)
        self.assertEqual(result.failure_reason, NO_NOSE_DETECTED)


class NoseExtractionEndpointTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TestClient(main.app)
        self.original_extractor = main._nose_extractor
        self.original_embedder = main._embedder
        main._nose_extractor = make_extractor(
            [
                NoseDetection(
                    bbox_xyxy=(100.0, 80.0, 180.0, 160.0),
                    confidence=0.92,
                    class_id=0,
                    class_name="nose",
                )
            ]
        )

    def tearDown(self) -> None:
        main._nose_extractor = self.original_extractor
        main._embedder = self.original_embedder

    def test_extract_endpoint_returns_base64_crop(self) -> None:
        response = self.client.post(
            "/internal/nose/extract",
            files={"image": ("profile.png", make_png(), "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["extracted"])
        self.assertEqual(body["crop_width"], 224)
        self.assertEqual(body["crop_height"], 224)
        self.assertEqual(body["detector"], "fake")
        self.assertEqual(body["detector_device"], "cpu")
        self.assertIsNotNone(body["crop_base64"])

        crop = Image.open(BytesIO(base64.b64decode(body["crop_base64"])))
        self.assertEqual(crop.size, (224, 224))

    def test_profile_match_endpoint_uses_extracted_crop_and_existing_embedder(self) -> None:
        main._embedder = FakeEmbedder()

        response = self.client.post(
            "/internal/nose/profile-match",
            files={
                "profile_image": ("profile.png", make_png(), "image/png"),
                "nose_image": ("nose.png", make_png(), "image/png"),
            },
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["matched"])
        self.assertEqual(body["similarity_score"], 1.0)
        self.assertFalse(body["threshold_calibrated"])
        self.assertTrue(body["profile_nose_extracted"])
        self.assertEqual(body["dimension"], 4)
        self.assertIsNone(body["failure_reason"])

    def test_profile_match_batch_returns_five_scores_and_policy(self) -> None:
        main._embedder = FakeSequence2048Embedder([0.70, 0.71, 0.72, 0.73, 0.60])

        response = self.client.post(
            "/internal/nose/profile-match-batch",
            files=[
                ("profile_image", ("profile.png", make_png(), "image/png")),
                ("nose_image", ("nose-1.png", make_png(), "image/png")),
                ("nose_image", ("nose-2.png", make_png(), "image/png")),
                ("nose_image", ("nose-3.png", make_png(), "image/png")),
                ("nose_image", ("nose-4.png", make_png(), "image/png")),
                ("nose_image", ("nose-5.png", make_png(), "image/png")),
            ],
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["matched"])
        self.assertEqual(body["threshold"], 0.65)
        self.assertFalse(body["threshold_calibrated"])
        self.assertEqual(body["pass_count"], 4)
        self.assertEqual(body["required_pass_count"], 4)
        self.assertEqual(body["aggregate"], "median")
        self.assertEqual(body["median_score"], 0.71)
        self.assertEqual(len(body["scores"]), 5)
        self.assertEqual(body["scores"][0]["index"], 1)
        self.assertEqual(body["dimension"], 2048)
        self.assertIsNone(body["failure_reason"])

    def test_profile_match_batch_detector_unavailable_returns_failure(self) -> None:
        main._nose_extractor = make_extractor(None)
        main._embedder = FakeSequence2048Embedder()

        response = self.client.post(
            "/internal/nose/profile-match-batch",
            files=[
                ("profile_image", ("profile.png", make_png(), "image/png")),
                ("nose_image", ("nose-1.png", make_png(), "image/png")),
                ("nose_image", ("nose-2.png", make_png(), "image/png")),
                ("nose_image", ("nose-3.png", make_png(), "image/png")),
                ("nose_image", ("nose-4.png", make_png(), "image/png")),
                ("nose_image", ("nose-5.png", make_png(), "image/png")),
            ],
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertFalse(body["matched"])
        self.assertFalse(body["profile_nose_extracted"])
        self.assertEqual(body["failure_reason"], DETECTOR_UNAVAILABLE)
        self.assertEqual(body["scores"], [])

    def test_profile_match_batch_dimension_mismatch_returns_failure(self) -> None:
        main._embedder = FakeSequence2048Embedder(dimension=128)

        response = self.client.post(
            "/internal/nose/profile-match-batch",
            files=[
                ("profile_image", ("profile.png", make_png(), "image/png")),
                ("nose_image", ("nose-1.png", make_png(), "image/png")),
                ("nose_image", ("nose-2.png", make_png(), "image/png")),
                ("nose_image", ("nose-3.png", make_png(), "image/png")),
                ("nose_image", ("nose-4.png", make_png(), "image/png")),
                ("nose_image", ("nose-5.png", make_png(), "image/png")),
            ],
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertFalse(body["matched"])
        self.assertEqual(body["dimension"], 128)
        self.assertEqual(body["failure_reason"], "EMBEDDING_DIMENSION_MISMATCH")
