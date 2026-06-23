from __future__ import annotations

import base64
import logging
import os
import unittest
from contextlib import redirect_stdout
from io import BytesIO, StringIO
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
    NOSE_OFF_CENTER,
    NOSE_TOO_LARGE_FOR_FACE_CHECK,
    NOSE_TOO_SMALL_FOR_FACE_CHECK,
    NOSE_TOUCHES_IMAGE_EDGE,
    DogNoseExtractionConfig,
    DogNoseExtractor,
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
        conf_threshold=0.35,
        crop_size=224,
        bbox_expand=1.40,
        class_id=0,
        class_names=frozenset({"nose", "dog_nose", "pet_nose"}),
    )
    detector = FakeDetector(detections or []) if detections is not None else None
    return DogNoseExtractor(config=config, detector=detector)


class DogNoseExtractorTest(unittest.TestCase):
    def test_demo_trace_default_is_disabled(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(main._parse_bool_env("DEMO_TRACE_ENABLED", False))

    def test_profile_match_threshold_env_parse_falls_back_on_invalid_value(self) -> None:
        with patch.dict(os.environ, {"PROFILE_NOSE_MATCH_THRESHOLD": "not-a-number"}):
            self.assertEqual(main._parse_float_env("PROFILE_NOSE_MATCH_THRESHOLD", 0.65), 0.65)

    def test_score_summary_calculates_percent_flow_inputs(self) -> None:
        summary = main._score_summary([0.70, 0.71, 0.72, 0.73, 0.60], 0.65)

        self.assertEqual(summary["min"], 0.60)
        self.assertEqual(summary["max"], 0.73)
        self.assertEqual(summary["mean"], 0.692)
        self.assertEqual(summary["median"], 0.71)
        self.assertEqual(summary["pass_count"], 4)
        self.assertEqual(summary["fail_count"], 1)

    def test_health_access_filter_suppresses_only_health_when_disabled(self) -> None:
        original = main.DEMO_TRACE_HEALTH_ACCESS_LOG
        filter_ = main.HealthAccessLogFilter()
        health_record = logging.LogRecord(
            "uvicorn.access",
            logging.INFO,
            "",
            1,
            '127.0.0.1:12345 - "GET /health HTTP/1.1" 200 OK',
            (),
            None,
        )
        register_record = logging.LogRecord(
            "uvicorn.access",
            logging.INFO,
            "",
            1,
            '127.0.0.1:12345 - "POST /internal/nose/profile-match-batch HTTP/1.1" 200 OK',
            (),
            None,
        )
        try:
            main.DEMO_TRACE_HEALTH_ACCESS_LOG = False
            self.assertFalse(filter_.filter(health_record))
            self.assertTrue(filter_.filter(register_record))

            main.DEMO_TRACE_HEALTH_ACCESS_LOG = True
            self.assertTrue(filter_.filter(health_record))
        finally:
            main.DEMO_TRACE_HEALTH_ACCESS_LOG = original

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

    def test_face_check_quality_normal_bbox_passes(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection((100.0, 80.0, 180.0, 160.0), 0.92, class_id=0, class_name="nose"),
            ]
        )

        result = extractor.extract(make_png(), purpose="face_check")

        self.assertTrue(result.extracted)
        self.assertIsNotNone(result.quality)
        self.assertTrue(result.quality.passed)
        self.assertEqual(result.quality.purpose, "face_check")
        self.assertEqual(result.quality.nose_area_ratio, 0.083333)
        self.assertIsNone(result.quality.failure_reason)

    def test_face_check_quality_rejects_nose_only_closeup(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection((20.0, 20.0, 300.0, 220.0), 0.92, class_id=0, class_name="nose"),
            ]
        )

        result = extractor.extract(make_png(), purpose="face_check")

        self.assertFalse(result.extracted)
        self.assertEqual(result.failure_reason, NOSE_TOO_LARGE_FOR_FACE_CHECK)
        self.assertIsNotNone(result.quality)
        self.assertFalse(result.quality.passed)
        self.assertGreater(result.quality.nose_area_ratio or 0.0, 0.25)

    def test_face_check_quality_rejects_too_small_nose(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection((10.0, 10.0, 18.0, 18.0), 0.92, class_id=0, class_name="nose"),
            ]
        )

        result = extractor.extract(make_png(), purpose="face_check")

        self.assertFalse(result.extracted)
        self.assertEqual(result.failure_reason, NOSE_TOO_SMALL_FOR_FACE_CHECK)
        self.assertLess(result.quality.nose_area_ratio or 1.0, 0.003)

    def test_face_check_quality_rejects_edge_cropped_nose(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection((0.0, 80.0, 80.0, 160.0), 0.92, class_id=0, class_name="nose"),
            ]
        )

        result = extractor.extract(make_png(), purpose="face_check")

        self.assertFalse(result.extracted)
        self.assertEqual(result.failure_reason, NOSE_TOUCHES_IMAGE_EDGE)
        self.assertEqual(result.quality.edge_margin_ratio, 0.0)

    def test_face_check_quality_rejects_off_center_nose(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection((10.0, 80.0, 90.0, 160.0), 0.92, class_id=0, class_name="nose"),
            ]
        )

        result = extractor.extract(make_png(), purpose="face_check")

        self.assertFalse(result.extracted)
        self.assertEqual(result.failure_reason, NOSE_OFF_CENTER)
        self.assertLess(result.quality.center_x or 1.0, 0.20)

    def test_face_check_quality_is_not_applied_to_generic_purpose(self) -> None:
        extractor = make_extractor(
            [
                NoseDetection((20.0, 20.0, 300.0, 220.0), 0.92, class_id=0, class_name="nose"),
            ]
        )

        result = extractor.extract(make_png(), purpose="nose_image")

        self.assertTrue(result.extracted)
        self.assertIsNone(result.quality)


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
        self.assertIsNotNone(body["crop_base64"])

        crop = Image.open(BytesIO(base64.b64decode(body["crop_base64"])))
        self.assertEqual(crop.size, (224, 224))

    def test_extract_endpoint_applies_face_check_quality_when_requested(self) -> None:
        main._nose_extractor = make_extractor(
            [
                NoseDetection((20.0, 20.0, 300.0, 220.0), 0.92, class_id=0, class_name="nose"),
            ]
        )

        response = self.client.post(
            "/internal/nose/extract",
            files={"image": ("profile.png", make_png(), "image/png")},
            data={"purpose": "face_check"},
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertFalse(body["extracted"])
        self.assertEqual(body["failure_reason"], NOSE_TOO_LARGE_FOR_FACE_CHECK)
        self.assertFalse(body["quality"]["passed"])
        self.assertEqual(body["quality"]["purpose"], "face_check")

    def test_extract_embed_endpoint_returns_embedding_without_crop_base64(self) -> None:
        main._embedder = FakeEmbedder()

        response = self.client.post(
            "/internal/nose/extract-embed",
            files={"image": ("profile.png", make_png(), "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["extracted"])
        self.assertEqual(body["crop_width"], 224)
        self.assertEqual(body["crop_height"], 224)
        self.assertEqual(body["confidence"], 0.92)
        self.assertEqual(body["model"], "fake-v1:test")
        self.assertEqual(body["dimension"], 4)
        self.assertEqual(body["embedding"], [1.0, 0.0, 0.0, 0.0])
        self.assertIsNone(body["failure_reason"])
        self.assertNotIn("crop_base64", body)

    def test_extract_embed_endpoint_applies_face_check_quality_when_requested(self) -> None:
        main._nose_extractor = make_extractor(
            [
                NoseDetection((20.0, 20.0, 300.0, 220.0), 0.92, class_id=0, class_name="nose"),
            ]
        )
        main._embedder = FakeEmbedder()

        response = self.client.post(
            "/internal/nose/extract-embed",
            files={"image": ("profile.png", make_png(), "image/png")},
            data={"purpose": "face_check"},
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertFalse(body["extracted"])
        self.assertIsNone(body["embedding"])
        self.assertEqual(body["failure_reason"], NOSE_TOO_LARGE_FOR_FACE_CHECK)
        self.assertFalse(body["quality"]["passed"])

    def test_extract_embed_detector_unavailable_returns_failure_without_embedding(self) -> None:
        main._nose_extractor = make_extractor(None)
        main._embedder = FakeEmbedder()

        response = self.client.post(
            "/internal/nose/extract-embed",
            files={"image": ("profile.png", make_png(), "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertFalse(body["extracted"])
        self.assertIsNone(body["embedding"])
        self.assertEqual(body["failure_reason"], DETECTOR_UNAVAILABLE)
        self.assertNotIn("crop_base64", body)

    def test_extract_embed_demo_trace_excludes_crop_base64_and_vectors(self) -> None:
        main._embedder = FakeEmbedder()
        original_enabled = main.DEMO_TRACE_ENABLED
        main.DEMO_TRACE_ENABLED = True
        output = StringIO()
        try:
            with redirect_stdout(output):
                response = self.client.post(
                    "/internal/nose/extract-embed",
                    headers={"X-Request-Id": "extract-embed-test"},
                    files={"image": ("profile.png", make_png(), "image/png")},
                )
        finally:
            main.DEMO_TRACE_ENABLED = original_enabled

        self.assertEqual(response.status_code, 200)
        logs = output.getvalue()
        self.assertIn("[DEMO_TRACE]", logs)
        self.assertIn("request_id=extract-embed-test", logs)
        self.assertIn("flow=extract_embed", logs)
        self.assertNotIn("crop_base64", logs)
        self.assertNotIn("embedding", logs)
        self.assertNotIn("vector", logs)

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
        self.assertIsNotNone(body["profile_vs_centroid_score"])
        self.assertTrue(body["profile_vs_centroid_passed"])
        self.assertEqual(body["centroid_dimension"], 2048)
        self.assertIsNone(body["failure_reason"])

    def test_profile_match_batch_demo_trace_excludes_crop_base64_and_vectors(self) -> None:
        main._embedder = FakeSequence2048Embedder([0.70, 0.71, 0.72, 0.73, 0.60])
        original_enabled = main.DEMO_TRACE_ENABLED
        main.DEMO_TRACE_ENABLED = True
        output = StringIO()
        try:
            with redirect_stdout(output):
                response = self.client.post(
                    "/internal/nose/profile-match-batch",
                    headers={"X-Request-Id": "trace-test"},
                    files=[
                        ("profile_image", ("profile.png", make_png(), "image/png")),
                        ("nose_image", ("nose-1.png", make_png(), "image/png")),
                        ("nose_image", ("nose-2.png", make_png(), "image/png")),
                        ("nose_image", ("nose-3.png", make_png(), "image/png")),
                        ("nose_image", ("nose-4.png", make_png(), "image/png")),
                        ("nose_image", ("nose-5.png", make_png(), "image/png")),
                    ],
                )
        finally:
            main.DEMO_TRACE_ENABLED = original_enabled

        self.assertEqual(response.status_code, 200)
        logs = output.getvalue()
        self.assertIn("[DEMO_TRACE]", logs)
        self.assertIn("request_id=trace-test", logs)
        self.assertIn("flow=profile_match_batch", logs)
        self.assertIn("step=centroid_compare", logs)
        self.assertNotIn("crop_base64", logs)
        self.assertNotIn("vector", logs)

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
