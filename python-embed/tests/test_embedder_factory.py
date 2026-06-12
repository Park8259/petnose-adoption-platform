from __future__ import annotations

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.embedding import create_embedder_from_env
from app.embedding.base import EmbedderError


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
