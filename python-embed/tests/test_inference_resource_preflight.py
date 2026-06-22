from __future__ import annotations

from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts import inference_resource_preflight as preflight  # noqa: E402


class InferenceResourcePreflightTest(unittest.TestCase):
    def test_summarize_numbers_reports_expected_percentiles(self) -> None:
        summary = preflight.summarize_numbers([10.0, 20.0, 30.0])

        self.assertEqual(summary["count"], 3)
        self.assertEqual(summary["mean"], 20.0)
        self.assertEqual(summary["p50"], 20.0)
        self.assertEqual(summary["p95"], 29.0)
        self.assertEqual(summary["min"], 10.0)
        self.assertEqual(summary["max"], 30.0)

    def test_output_sanitization_rejects_paths_vectors_and_crop_base64(self) -> None:
        with self.assertRaises(ValueError):
            preflight.assert_sanitized_payload({"path": r"C:\Users\private\model_final.pth"})

        with self.assertRaises(ValueError):
            preflight.assert_sanitized_payload({"vector": [0.1, 0.2]})

        with self.assertRaises(ValueError):
            preflight.assert_sanitized_payload({"crop_base64": "abc"})

    def test_output_sanitization_allows_safe_artifact_summary(self) -> None:
        preflight.assert_sanitized_payload(
            {
                "case_name": "demo",
                "yolo_weight": {"basename": "best.pt", "sha256": "a" * 64, "size_bytes": 123},
                "resource_summary": {"sample_count": 30, "gpu_name": "NVIDIA GeForce RTX 3070"},
            }
        )

    def test_safe_repo_id_keeps_only_tail_segments_for_windows_and_posix_paths(self) -> None:
        paths = [
            r"C:\Dev\_petnose_fix\.codex_local\reference_repos\dognose_recognition_management_service\backend\dogback\yolov05",
            "/home/runner/work/petnose-adoption-platform/petnose-adoption-platform/.codex_local/"
            "reference_repos/dognose_recognition_management_service/backend/dogback/yolov05",
        ]

        for raw_path in paths:
            with self.subTest(raw_path=raw_path):
                safe_id = preflight.safe_repo_id(raw_path)

                self.assertEqual(safe_id, "backend/dogback/yolov05")
                self.assertNotIn("\\", safe_id or "")
                self.assertNotIn("C:", safe_id or "")
                self.assertNotIn("/home/runner", safe_id or "")
                preflight.assert_sanitized_payload({"yolo_repo_safe_id": safe_id})


if __name__ == "__main__":
    unittest.main()
