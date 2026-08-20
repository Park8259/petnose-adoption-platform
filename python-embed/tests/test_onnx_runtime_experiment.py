from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts import onnx_runtime_experiment as experiment


def windows_abs(*parts: str) -> str:
    return "C:" + "\\" + "\\".join(parts)


def posix_abs(*parts: str) -> str:
    return "/" + "/".join(parts)


class FakeResult:
    def __init__(self, dimension: int = 2048) -> None:
        self.dimension = dimension


class FakeEmbedder:
    backend = "torch+timm"
    model_name = "dog-nose-identification2:s101_224"
    vector_dim = 2048
    _resolved_model_path = Path(windows_abs("private", "models", "model_final.pth"))

    def __init__(self) -> None:
        self.embed_calls = 0
        self.batch_calls: list[int] = []

    def embed(self, image_bytes: bytes, content_type: str | None = None) -> FakeResult:
        self.embed_calls += 1
        return FakeResult(self.vector_dim)

    def embed_batch(self, images) -> list[FakeResult]:
        self.batch_calls.append(len(images))
        return [FakeResult(self.vector_dim) for _ in images]


class PercentileTest(unittest.TestCase):
    def test_percentile_single_value(self) -> None:
        self.assertEqual(experiment.percentile([7.0], 95), 7.0)

    def test_percentile_odd_and_even_counts_use_linear_interpolation(self) -> None:
        self.assertEqual(experiment.percentile([3.0, 1.0, 2.0], 50), 2.0)
        self.assertEqual(experiment.percentile([1.0, 2.0, 3.0, 4.0], 50), 2.5)
        self.assertAlmostEqual(experiment.percentile([1.0, 2.0, 3.0, 4.0], 95), 3.85)


class BatchSizeParsingTest(unittest.TestCase):
    def test_parse_batch_sizes_accepts_positive_values_and_deduplicates(self) -> None:
        self.assertEqual(experiment.parse_batch_sizes("1, 5, 5"), [1, 5])

    def test_parse_batch_sizes_rejects_empty_zero_negative_and_non_numeric_values(self) -> None:
        for value in ("", "0", "-1", "1, nope"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    experiment.parse_batch_sizes(value)


class FixtureDiscoveryTest(unittest.TestCase):
    def test_collect_fixtures_supports_image_extensions_and_numeric_sorting(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            (root / "nose-10.jpg").write_bytes(b"ten")
            (root / "nose-2.png").write_bytes(b"two")
            (root / "nose-1.jpeg").write_bytes(b"one")
            (root / "ignore.txt").write_text("ignored", encoding="utf-8")

            fixtures = experiment.collect_fixtures([str(root)], limit=0, label_mode="basename")

        self.assertEqual([item.label for item in fixtures], ["nose-1.jpeg", "nose-2.png", "nose-10.jpg"])
        self.assertEqual([item.content_type for item in fixtures], ["image/jpeg", "image/png", "image/jpeg"])

    def test_collect_fixtures_can_emit_index_labels_and_apply_limit(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            for index in range(1, 4):
                (root / f"nose-{index}.png").write_bytes(str(index).encode("ascii"))

            fixtures = experiment.collect_fixtures([str(root)], limit=2, label_mode="index")

        self.assertEqual([item.label for item in fixtures], ["fixture_001", "fixture_002"])

    def test_collect_fixtures_rejects_missing_or_unsupported_paths(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            unsupported = root / "fixture.gif"
            unsupported.write_bytes(b"gif")

            with self.assertRaises(FileNotFoundError):
                experiment.collect_fixtures([str(root / "missing.png")], limit=0)

            with self.assertRaises(FileNotFoundError):
                experiment.collect_fixtures([str(unsupported)], limit=0)


class BatchCompareSummaryTest(unittest.TestCase):
    def test_summarize_batch_comparison_reports_saved_time_reduction_and_speedup(self) -> None:
        stats = experiment.summarize_batch_comparison(
            sequential_ms=[100.0, 120.0],
            batch_ms=[60.0, 70.0],
        )

        self.assertEqual(stats["sequential_mean_ms"], 110.0)
        self.assertEqual(stats["batch_mean_ms"], 65.0)
        self.assertEqual(stats["mean_saved_ms"], 45.0)
        self.assertAlmostEqual(stats["mean_reduction_percent"], 40.9090909)
        self.assertAlmostEqual(stats["p95_reduction_percent"], ((119.0 - 69.5) / 119.0) * 100.0)
        self.assertAlmostEqual(stats["speedup"], 110.0 / 65.0)

    def test_batch_compare_uses_real_sequential_calls_and_batch_calls(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            for index in range(1, 6):
                (root / f"nose-{index}.png").write_bytes(str(index).encode("ascii"))

            fake = FakeEmbedder()
            args = argparse.Namespace(
                fixtures=[str(root)],
                limit=0,
                label_mode="index",
                batch_size=5,
                warmup=1,
                runs=2,
                model_dir="<model-dir>",
                model_path="<checkpoint-path>",
                output_dir="",
            )
            perf_counter_values = iter([0.00, 0.10, 0.10, 0.15, 0.15, 0.27, 0.27, 0.34])

            with patch.object(experiment, "load_torch_embedder", return_value=fake):
                with patch.object(experiment.time, "perf_counter", side_effect=lambda: next(perf_counter_values)):
                    summary = experiment.batch_compare(args)

        self.assertEqual(fake.embed_calls, 15)
        self.assertEqual(fake.batch_calls, [5, 5, 5])
        self.assertEqual(summary["schema_version"], 1)
        self.assertEqual(summary["benchmark_scope"], "local-direct-embedder")
        self.assertEqual(summary["runtime"], "torch")
        self.assertEqual(summary["backend"], "torch+timm")
        self.assertEqual(summary["dimension"], 2048)
        self.assertEqual(summary["fixture_labels"], [f"fixture_{index:03d}" for index in range(1, 6)])
        self.assertAlmostEqual(summary["sequential_mean_ms"], 110.0)
        self.assertAlmostEqual(summary["batch_mean_ms"], 60.0)


class OutputSanitizationTest(unittest.TestCase):
    def test_safe_path_name_returns_only_basename(self) -> None:
        self.assertEqual(experiment.safe_path_name(windows_abs("private", "models", "model_final.pth")), "model_final.pth")
        self.assertEqual(experiment.safe_path_name(posix_abs("tmp", "petnose", "dog_nose_s101_224.onnx")), "dog_nose_s101_224.onnx")

    def test_sanitization_rejects_absolute_paths_and_raw_vectors(self) -> None:
        with self.assertRaises(ValueError):
            experiment.assert_sanitized_payload({"onnx_path": windows_abs("private", "model.onnx")})

        with self.assertRaises(ValueError):
            experiment.assert_sanitized_payload({"rows": [{"vector": [0.1, 0.2]}]})

        with self.assertRaises(ValueError):
            experiment.assert_sanitized_payload({"rows": [{"values": [float(index) for index in range(17)]}]})

    def test_write_outputs_do_not_include_absolute_paths_or_vectors(self) -> None:
        fixtures = [
            experiment.FixtureImage(label=f"fixture_{index:03d}", content_type="image/png", image_bytes=b"image")
            for index in range(1, 6)
        ]
        summary = experiment.build_batch_compare_summary(
            embedder=FakeEmbedder(),
            fixtures=fixtures,
            batch_size=5,
            warmup=2,
            runs=2,
            sequential_ms=[100.0, 120.0],
            batch_ms=[60.0, 70.0],
            dimension=2048,
        )

        with tempfile.TemporaryDirectory() as raw_root:
            output_dir = Path(raw_root) / "out"
            experiment.write_outputs(str(output_dir), "batch_compare", summary, summary["rows"])
            summary_text = (output_dir / "batch_compare_summary.json").read_text(encoding="utf-8")
            csv_text = (output_dir / "batch_compare.csv").read_text(encoding="utf-8")

        combined = summary_text + csv_text
        self.assertNotIn(windows_abs("private"), combined)
        self.assertNotIn(str(output_dir), combined)
        self.assertNotIn('"vector"', combined)
        loaded = json.loads(summary_text)
        self.assertEqual(loaded["schema_version"], 1)
        self.assertEqual(loaded["benchmark_scope"], "local-direct-embedder")
        self.assertIn("statistics", loaded)
        self.assertEqual(loaded["rows"][0]["schema_version"], 1)


class CliHelpTest(unittest.TestCase):
    def test_cli_help_includes_existing_commands_and_batch_compare(self) -> None:
        output = self.capture_help(["onnx_runtime_experiment.py", "--help"])

        for command in ("export", "compare", "benchmark", "batch-compare"):
            self.assertIn(command, output)
        self.assertIn("Mean", output)
        self.assertIn("P95", output)

    def test_subcommand_help_exits_cleanly(self) -> None:
        for command in ("export", "compare", "benchmark", "batch-compare"):
            with self.subTest(command=command):
                output = self.capture_help(["onnx_runtime_experiment.py", command, "--help"])
                self.assertIn("Mean", output)

    @staticmethod
    def capture_help(argv: list[str]) -> str:
        buffer = io.StringIO()
        with patch.object(sys, "argv", argv):
            with redirect_stdout(buffer):
                with unittest.TestCase().assertRaises(SystemExit) as raised:
                    experiment.main()
        if raised.exception.code != 0:
            raise AssertionError(f"help exited with {raised.exception.code}")
        return buffer.getvalue()


if __name__ == "__main__":
    unittest.main()
