from __future__ import annotations

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.embedding import create_embedder_from_env
from app.embedding.base import EmbedderError
from app.embedding.dog_nose_identification2_embedder import DogNoseIdentification2Embedder


class CreateEmbedderFromEnvTest(unittest.TestCase):
    def test_dog_nose_defaults_to_torch_runtime(self) -> None:
        with patch.dict(os.environ, {"EMBED_MODEL": "dog-nose-identification2", "DOG_NOSE_RUNTIME": "torch"}):
            embedder = create_embedder_from_env()

        self.assertEqual(embedder.backend, "torch+timm")

    def test_dog_nose_can_select_onnxruntime(self) -> None:
        with patch.dict(
            os.environ,
            {
                "EMBED_MODEL": "dog-nose-identification2",
                "DOG_NOSE_RUNTIME": "onnxruntime",
                "DOG_NOSE_ONNX_PATH": r"C:\tmp\dog_nose_s101_224.onnx",
            },
        ):
            embedder = create_embedder_from_env()

        self.assertEqual(embedder.backend, "onnxruntime-cpu")
        self.assertEqual(embedder.model_name, "dog-nose-identification2:s101_224")

    def test_dog_nose_rejects_non_scope_runtime(self) -> None:
        with patch.dict(os.environ, {"EMBED_MODEL": "dog-nose-identification2", "DOG_NOSE_RUNTIME": "openvino"}):
            with self.assertRaises(EmbedderError):
                create_embedder_from_env()

    def test_dog_nose_reads_required_cuda_device_policy(self) -> None:
        with patch.dict(
            os.environ,
            {
                "EMBED_MODEL": "dog-nose-identification2",
                "DOG_NOSE_RUNTIME": "torch",
                "EMBED_DEVICE": "cuda:0",
                "EMBED_DEVICE_REQUIRED": "true",
            },
        ):
            embedder = create_embedder_from_env()

        self.assertEqual(embedder.backend, "torch+timm")
        self.assertEqual(embedder.device, "cuda:0")
        self.assertTrue(embedder.embed_device_required)


class StrictCudaDevicePolicyTest(unittest.TestCase):
    class FakeCuda:
        def __init__(self, available: bool) -> None:
            self.available = available

        def is_available(self) -> bool:
            return self.available

    class FakeTorch:
        def __init__(self, cuda_available: bool) -> None:
            self.cuda = StrictCudaDevicePolicyTest.FakeCuda(cuda_available)

        @staticmethod
        def device(name: str) -> str:
            return name

    def test_optional_cuda_request_falls_back_to_cpu_for_compatibility(self) -> None:
        embedder = DogNoseIdentification2Embedder(
            model_dir="/models",
            model_path=None,
            embed_device="cuda:0",
            embed_device_required=False,
        )
        embedder._torch = self.FakeTorch(cuda_available=False)

        self.assertEqual(embedder._select_device("cuda:0"), "cpu")

    def test_required_cuda_request_fails_when_cuda_is_unavailable(self) -> None:
        embedder = DogNoseIdentification2Embedder(
            model_dir="/models",
            model_path=None,
            embed_device="cuda:0",
            embed_device_required=True,
        )
        embedder._torch = self.FakeTorch(cuda_available=False)

        with self.assertRaisesRegex(EmbedderError, "requires CUDA"):
            embedder._select_device("cuda:0")

    def test_required_cuda_request_uses_cuda_when_available(self) -> None:
        embedder = DogNoseIdentification2Embedder(
            model_dir="/models",
            model_path=None,
            embed_device="cuda:0",
            embed_device_required=True,
        )
        embedder._torch = self.FakeTorch(cuda_available=True)

        self.assertEqual(embedder._select_device("cuda:0"), "cuda:0")
