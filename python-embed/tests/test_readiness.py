from __future__ import annotations

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import main
from app.embedding.base import BaseEmbedder, EmbedResult


class FakeReadyEmbedder(BaseEmbedder):
    def __init__(
        self,
        *,
        loaded: bool = True,
        model: str = "dog-nose-identification2:s101_224",
        vector_dim: int = 2048,
        backend: str = "torch+timm",
        device: str = "cpu",
        requested_device: str = "cpu",
        device_required: bool = False,
        model_path_exists: bool = True,
        load_error: str | None = None,
    ) -> None:
        super().__init__("dog-nose-identification2")
        self.model_loaded = loaded
        self.model_name = model
        self.vector_dim = vector_dim
        self.backend = backend
        self.device = device
        self.requested_device = requested_device
        self.embed_device_required = device_required
        self.model_path_exists = model_path_exists
        self.load_error = load_error

    def load(self) -> bool:
        return self.model_loaded

    def embed(self, image_bytes: bytes, content_type: str | None = None) -> EmbedResult:
        return EmbedResult(vector=[1.0] * self.vector_dim, dimension=self.vector_dim, model=self.model_name)

    def health_dict(self) -> dict[str, object]:
        data = super().health_dict()
        data.update(
            {
                "requested_device": self.requested_device,
                "embed_device_required": self.embed_device_required,
                "model_path_exists": self.model_path_exists,
                "image_size": 224,
            }
        )
        return data


class ReadinessEndpointTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TestClient(main.app)
        self.original_embedder = main._embedder

    def tearDown(self) -> None:
        main._embedder = self.original_embedder

    def test_existing_health_endpoint_stays_backward_compatible(self) -> None:
        main._embedder = FakeReadyEmbedder(loaded=False, load_error="not loaded")

        response = self.client.get("/health")

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "ok")
        self.assertFalse(body["model_loaded"])
        self.assertEqual(body["load_error"], "not loaded")

    def test_ready_returns_503_when_service_is_not_initialized(self) -> None:
        main._embedder = None

        response = self.client.get("/health/ready")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["reasons"][0]["code"], "SERVICE_NOT_INITIALIZED")

    def test_ready_returns_503_when_model_is_not_loaded(self) -> None:
        main._embedder = FakeReadyEmbedder(loaded=False)

        response = self.ready_request()

        self.assertEqual(response.status_code, 503)
        self.assert_reason(response, "MODEL_NOT_LOADED")

    def test_ready_returns_503_without_raw_load_error_when_model_load_failed(self) -> None:
        raw_load_error = r"C:\private\models\model_final.pth token=secret"
        main._embedder = FakeReadyEmbedder(loaded=False, load_error=raw_load_error)

        response = self.ready_request()

        self.assertEqual(response.status_code, 503)
        body_text = response.text
        self.assert_reason(response, "MODEL_LOAD_ERROR")
        self.assertNotIn("C:\\private", body_text)
        self.assertNotIn("token=secret", body_text)
        self.assertNotIn(raw_load_error, body_text)

    def test_ready_returns_503_when_dimension_mismatches(self) -> None:
        main._embedder = FakeReadyEmbedder(vector_dim=128)

        response = self.ready_request()

        self.assertEqual(response.status_code, 503)
        self.assert_reason(response, "VECTOR_DIM_MISMATCH")

    def test_ready_returns_503_when_gpu_required_but_actual_device_is_cpu(self) -> None:
        main._embedder = FakeReadyEmbedder(
            device="cpu",
            requested_device="cuda:0",
            device_required=True,
        )

        response = self.ready_request(extra_env={"EMBED_DEVICE": "cuda:0", "EMBED_DEVICE_REQUIRED": "true"})

        self.assertEqual(response.status_code, 503)
        self.assert_reason(response, "CUDA_REQUESTED_BUT_NOT_ACTIVE")
        self.assertFalse(response.json()["device_required_satisfied"])

    def test_ready_accepts_cpu_real_model_runtime(self) -> None:
        main._embedder = FakeReadyEmbedder(device="cpu", requested_device="cpu")

        response = self.ready_request()

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "ready")
        self.assertTrue(body["model_loaded"])
        self.assertEqual(body["backend"], "torch+timm")
        self.assertEqual(body["vector_dim"], 2048)
        self.assertEqual(body["device"], "cpu")
        self.assertTrue(body["model_path_exists"])

    def test_ready_accepts_mocked_gpu_real_model_runtime(self) -> None:
        main._embedder = FakeReadyEmbedder(
            device="cuda:0",
            requested_device="cuda:0",
            device_required=True,
        )

        response = self.ready_request(extra_env={"EMBED_DEVICE": "cuda:0", "EMBED_DEVICE_REQUIRED": "true"})

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "ready")
        self.assertTrue(body["device"].startswith("cuda"))
        self.assertTrue(body["device_required"])
        self.assertTrue(body["device_required_satisfied"])

    def ready_request(self, extra_env: dict[str, str] | None = None):
        env = {
            "EMBED_MODEL": "dog-nose-identification2",
            "EMBED_VECTOR_DIM": "2048",
            "EMBED_DEVICE": "cpu",
            "EMBED_DEVICE_REQUIRED": "false",
        }
        if extra_env:
            env.update(extra_env)
        with patch.dict(os.environ, env, clear=False):
            return self.client.get("/health/ready")

    @staticmethod
    def assert_reason(response, code: str) -> None:
        reasons = response.json()["reasons"]
        assert code in {reason["code"] for reason in reasons}, reasons


if __name__ == "__main__":
    unittest.main()
