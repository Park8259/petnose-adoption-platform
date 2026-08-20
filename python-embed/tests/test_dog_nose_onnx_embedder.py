from __future__ import annotations

import importlib.util
import math
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from app import main
from app.embedding import create_embedder_from_env
from app.embedding.base import EmbedInput, EmbedderError
from app.embedding.dog_nose_identification2_onnx_embedder import (
    DogNoseIdentification2OnnxEmbedder,
)
from synthetic_onnx_model import make_png_bytes, write_synthetic_onnx_model


ONNX_DEPS_AVAILABLE = (
    importlib.util.find_spec("onnx") is not None
    and importlib.util.find_spec("onnxruntime") is not None
)
ONNX_DEPS_REQUIRED = os.getenv("PETNOSE_REQUIRE_ONNX_TESTS", "").strip().lower() in {"1", "true", "yes"}

if ONNX_DEPS_REQUIRED and not ONNX_DEPS_AVAILABLE:
    raise RuntimeError("PETNOSE_REQUIRE_ONNX_TESTS=1 requires onnx and onnxruntime to be installed.")


def require_onnx_deps(test):
    return unittest.skipUnless(ONNX_DEPS_AVAILABLE, "onnx and onnxruntime are optional dependencies")(test)


class DogNoseRuntimeFactoryDefaultTest(unittest.TestCase):
    def test_dog_nose_omitted_runtime_defaults_to_torch(self) -> None:
        with patch.dict(os.environ, {"EMBED_MODEL": "dog-nose-identification2"}, clear=True):
            embedder = create_embedder_from_env()

        self.assertEqual(embedder.backend, "torch+timm")
        self.assertEqual(embedder.requested_model_name, "dog-nose-identification2")


class OnnxThreadOptionsTest(unittest.TestCase):
    class FakeSessionOptions:
        def __init__(self) -> None:
            self.intra_op_num_threads = 0
            self.inter_op_num_threads = 0

    def test_positive_thread_env_values_are_applied(self) -> None:
        options = self.FakeSessionOptions()

        with patch.dict(
            os.environ,
            {
                "DOG_NOSE_ORT_INTRA_OP_THREADS": "2",
                "DOG_NOSE_ORT_INTER_OP_THREADS": "3",
            },
        ):
            DogNoseIdentification2OnnxEmbedder._apply_thread_options(options)

        self.assertEqual(options.intra_op_num_threads, 2)
        self.assertEqual(options.inter_op_num_threads, 3)

    def test_blank_zero_and_negative_thread_env_values_keep_defaults(self) -> None:
        options = self.FakeSessionOptions()

        with patch.dict(
            os.environ,
            {
                "DOG_NOSE_ORT_INTRA_OP_THREADS": "0",
                "DOG_NOSE_ORT_INTER_OP_THREADS": "-1",
            },
        ):
            DogNoseIdentification2OnnxEmbedder._apply_thread_options(options)

        self.assertEqual(options.intra_op_num_threads, 0)
        self.assertEqual(options.inter_op_num_threads, 0)

        with patch.dict(
            os.environ,
            {
                "DOG_NOSE_ORT_INTRA_OP_THREADS": "",
                "DOG_NOSE_ORT_INTER_OP_THREADS": "",
            },
        ):
            DogNoseIdentification2OnnxEmbedder._apply_thread_options(options)

        self.assertEqual(options.intra_op_num_threads, 0)
        self.assertEqual(options.inter_op_num_threads, 0)


@require_onnx_deps
class DogNoseOnnxEmbedderIntegrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.onnx_path = self.tmp_path / "smoke.onnx"
        write_synthetic_onnx_model(self.onnx_path)
        self.image_bytes = make_png_bytes()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_missing_onnx_file_returns_not_ready_with_clear_load_error(self) -> None:
        embedder = self._embedder(self.tmp_path / "missing.onnx")

        self.assertFalse(embedder.load())
        self.assertFalse(embedder.model_loaded)
        self.assertIn("ONNX 모델 파일", embedder.load_error or "")

    def test_synthetic_session_loads_cpu_provider_and_health_metadata(self) -> None:
        embedder = self._loaded_embedder()

        self.assertEqual(embedder._session.get_providers(), ["CPUExecutionProvider"])
        self.assertEqual(embedder._input_name, "images")
        self.assertEqual(embedder._output_name, "embeddings")

        health = embedder.health_dict()
        self.assertEqual(health["backend"], "onnxruntime-cpu")
        self.assertEqual(health["device"], "cpu")
        self.assertTrue(health["model_loaded"])
        self.assertEqual(health["vector_dim"], 2048)
        self.assertEqual(health["image_size"], 224)
        self.assertTrue(health["model_path_exists"])

    def test_embed_single_returns_normalized_2048_vector(self) -> None:
        embedder = self._loaded_embedder()

        result = embedder.embed(self.image_bytes, "image/png")

        self.assertEqual(result.dimension, 2048)
        self.assertEqual(len(result.vector), 2048)
        self.assert_normalized_finite(result.vector)

    def test_embed_batch_returns_five_normalized_2048_vectors(self) -> None:
        embedder = self._loaded_embedder()
        images = [
            EmbedInput(image_bytes=make_png_bytes(index), content_type="image/png")
            for index in range(5)
        ]

        results = embedder.embed_batch(images)

        self.assertEqual(len(results), 5)
        for result in results:
            self.assertEqual(result.dimension, 2048)
            self.assertEqual(len(result.vector), 2048)
            self.assert_normalized_finite(result.vector)

    def test_embed_batch_empty_returns_empty_list(self) -> None:
        embedder = self._loaded_embedder()

        self.assertEqual(embedder.embed_batch([]), [])

    def test_invalid_output_shape_raises_clear_embedder_error(self) -> None:
        invalid_path = self.tmp_path / "invalid-output-shape.onnx"
        write_synthetic_onnx_model(invalid_path, invalid_output_shape=True)
        embedder = self._loaded_embedder(invalid_path)

        with self.assertRaisesRegex(EmbedderError, "2D embedding"):
            embedder.embed(self.image_bytes, "image/png")

    def test_fastapi_health_embed_and_batch_contracts(self) -> None:
        embedder = self._loaded_embedder()
        client = TestClient(main.app)
        original_embedder = main._embedder
        original_max_batch_images = main.MAX_BATCH_IMAGES
        try:
            main._embedder = embedder
            main.MAX_BATCH_IMAGES = 5

            health_response = client.get("/health")
            self.assertEqual(health_response.status_code, 200)
            health = health_response.json()
            self.assertEqual(health["backend"], "onnxruntime-cpu")
            self.assertEqual(health["device"], "cpu")
            self.assertTrue(health["model_loaded"])
            self.assertEqual(health["vector_dim"], 2048)
            self.assertEqual(health["image_size"], 224)

            embed_response = client.post(
                "/embed",
                files={"image": ("nose.png", self.image_bytes, "image/png")},
            )
            self.assertEqual(embed_response.status_code, 200)
            embed_body = embed_response.json()
            self.assertEqual(embed_body["status"], "ok")
            self.assertEqual(embed_body["dimension"], 2048)
            self.assertEqual(len(embed_body["vector"]), 2048)

            batch_response = client.post("/embed-batch", files=self._batch_files(5))
            self.assertEqual(batch_response.status_code, 200)
            batch_body = batch_response.json()
            self.assertEqual(batch_body["status"], "ok")
            self.assertEqual(batch_body["dimension"], 2048)
            self.assertEqual(batch_body["count"], 5)
            self.assertEqual(len(batch_body["items"]), 5)
            self.assertTrue(all(len(item["vector"]) == 2048 for item in batch_body["items"]))
        finally:
            main._embedder = original_embedder
            main.MAX_BATCH_IMAGES = original_max_batch_images

    def _loaded_embedder(self, onnx_path: Path | None = None) -> DogNoseIdentification2OnnxEmbedder:
        embedder = self._embedder(onnx_path or self.onnx_path)
        self.assertTrue(embedder.load(), embedder.load_error)
        return embedder

    def _embedder(self, onnx_path: Path) -> DogNoseIdentification2OnnxEmbedder:
        return DogNoseIdentification2OnnxEmbedder(
            model_dir=str(self.tmp_path),
            onnx_path=str(onnx_path),
            model_tag="s101_224",
            default_image_size=224,
        )

    @staticmethod
    def assert_normalized_finite(vector: list[float]) -> None:
        norm = math.sqrt(sum(value * value for value in vector))
        assert all(math.isfinite(value) for value in vector)
        assert abs(norm - 1.0) < 1e-5

    @staticmethod
    def _batch_files(count: int) -> list[tuple[str, tuple[str, bytes, str]]]:
        return [
            ("images", (f"nose-{index + 1}.png", make_png_bytes(index), "image/png"))
            for index in range(count)
        ]
