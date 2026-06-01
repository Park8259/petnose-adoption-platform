from __future__ import annotations

import unittest
from pathlib import Path
import sys

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import main
from app.embedding.base import BaseEmbedder, EmbedInput, EmbedResult


PNG_BYTES = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
    b"\x00\x00\x00\nIDATx\x9cc\xf8\x0f\x00\x01\x01\x01\x00"
    b"\x18\xdd\x8d\xb0\x00\x00\x00\x00IEND\xaeB`\x82"
)


class FakeEmbedder(BaseEmbedder):
    def __init__(self, *, loaded: bool = True) -> None:
        super().__init__("fake-v1")
        self.model_name = "fake-v1:test"
        self.vector_dim = 4
        self.backend = "test"
        self.model_loaded = loaded
        self.load_error = None if loaded else "not loaded"

    def load(self) -> bool:
        return self.model_loaded

    def embed(self, image_bytes: bytes, content_type: str | None = None) -> EmbedResult:
        seed = float(len(image_bytes))
        return EmbedResult(
            vector=[seed, seed + 1.0, seed + 2.0, seed + 3.0],
            dimension=self.vector_dim,
            model=self.model_name,
        )

    def embed_batch(self, images: list[EmbedInput]) -> list[EmbedResult]:
        return [self.embed(image.image_bytes, image.content_type) for image in images]


class EmbedBatchEndpointTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TestClient(main.app)
        self.original_embedder = main._embedder
        self.original_max_batch_images = main.MAX_BATCH_IMAGES
        self.original_max_batch_total_bytes = main.MAX_BATCH_TOTAL_BYTES
        main._embedder = FakeEmbedder()
        main.MAX_BATCH_IMAGES = 5
        main.MAX_BATCH_TOTAL_BYTES = 80 * 1024 * 1024

    def tearDown(self) -> None:
        main._embedder = self.original_embedder
        main.MAX_BATCH_IMAGES = self.original_max_batch_images
        main.MAX_BATCH_TOTAL_BYTES = self.original_max_batch_total_bytes

    def test_embed_single_keeps_existing_response_contract(self) -> None:
        response = self.client.post(
            "/embed",
            files={"image": ("single.png", PNG_BYTES, "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["model"], "fake-v1:test")
        self.assertEqual(body["dimension"], 4)
        self.assertEqual(len(body["vector"]), 4)

    def test_embed_batch_accepts_three_repeated_images_fields(self) -> None:
        response = self.client.post("/embed-batch", files=self._image_files(3))

        self.assert_batch_response(response, 3)

    def test_embed_batch_accepts_five_repeated_images_fields(self) -> None:
        response = self.client.post("/embed-batch", files=self._image_files(5))

        self.assert_batch_response(response, 5)

    def test_embed_batch_missing_images_returns_400(self) -> None:
        response = self.client.post("/embed-batch")

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["detail"]["error"], "INVALID_IMAGE")

    def test_embed_batch_empty_image_returns_400(self) -> None:
        response = self.client.post(
            "/embed-batch",
            files=[("images", ("empty.png", b"", "image/png"))],
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["detail"]["error"], "INVALID_IMAGE")

    def test_embed_batch_unsupported_content_type_returns_400(self) -> None:
        response = self.client.post(
            "/embed-batch",
            files=[("images", ("nose.txt", b"not an image", "text/plain"))],
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["detail"]["error"], "UNSUPPORTED_FORMAT")

    def test_embed_batch_rejects_too_many_images(self) -> None:
        main.MAX_BATCH_IMAGES = 2

        response = self.client.post("/embed-batch", files=self._image_files(3))

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["detail"]["error"], "BATCH_TOO_LARGE")

    def test_embed_batch_rejects_total_bytes_over_limit(self) -> None:
        main.MAX_BATCH_TOTAL_BYTES = len(PNG_BYTES) * 2

        response = self.client.post("/embed-batch", files=self._image_files(3))

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["detail"]["error"], "BATCH_TOTAL_TOO_LARGE")

    def test_embed_batch_model_not_loaded_returns_503(self) -> None:
        main._embedder = FakeEmbedder(loaded=False)

        response = self.client.post("/embed-batch", files=self._image_files(3))

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"]["error"], "MODEL_NOT_READY")

    def assert_batch_response(self, response, expected_count: int) -> None:
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["model"], "fake-v1:test")
        self.assertEqual(body["dimension"], 4)
        self.assertEqual(body["count"], expected_count)
        self.assertIn("items", body)
        self.assertNotIn("results", body)
        self.assertEqual(len(body["items"]), expected_count)
        self.assertEqual(
            [item["index"] for item in body["items"]],
            list(range(expected_count)),
        )
        self.assertEqual(body["count"], len(body["items"]))

    @staticmethod
    def _image_files(count: int) -> list[tuple[str, tuple[str, bytes, str]]]:
        return [
            ("images", (f"{index + 1}.png", PNG_BYTES, "image/png"))
            for index in range(count)
        ]
