import io
import json
import os
import subprocess
import tempfile
import unittest
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from scripts import quality_observation_collect as collector


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/quality_observation_collect.py"


class QualityObservationCollectTests(unittest.TestCase):
    artifact_time = datetime(2026, 8, 20, 0, 5, tzinfo=timezone.utc)

    def archive(self, entries: dict[str, bytes]) -> bytes:
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as bundle:
            for name, content in entries.items():
                bundle.writestr(name, content)
        return output.getvalue()

    def test_selects_only_live_prefixed_artifacts_inside_window(self) -> None:
        artifacts = [
            {"id": 1, "name": "apple-quality-receipts-pr", "expired": False, "created_at": "2026-08-20T00:00:00Z", "workflow_run": {"id": 101}},
            {"id": 2, "name": "apple-quality-receipts-old", "expired": False, "created_at": "2026-07-01T00:00:00Z", "workflow_run": {"id": 102}},
            {"id": 3, "name": "apple-quality-receipts-expired", "expired": True, "created_at": "2026-08-21T00:00:00Z", "workflow_run": {"id": 103}},
            {"id": 4, "name": "android-quality-receipts-pr", "expired": False, "created_at": "2026-08-22T00:00:00Z", "workflow_run": {"id": 104}},
            {"id": 5, "name": "apple-quality-receipts-spoof", "expired": False, "created_at": "2026-08-22T00:00:00Z", "workflow_run": {"id": 999}},
        ]
        selected = collector.select_artifacts(
            artifacts,
            "apple-quality-receipts-",
            datetime(2026, 8, 10, tzinfo=timezone.utc),
            {101, 102, 103, 104},
        )
        self.assertEqual([1], [item["id"] for item in selected])

    def test_extracts_only_formal_receipts_without_preserving_archive_paths(self) -> None:
        archive = self.archive(
            {
                "build/quality-results/apple-pr-summary.json": b"{}",
                "build/quality-results/diagnostic.json": b"{}",
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(
                1,
                collector.extract_receipts(
                    archive,
                    root,
                    42,
                    101,
                    "revision-101",
                    self.artifact_time,
                ),
            )
            self.assertEqual(b"{}", (root / "42/apple-pr-summary.json").read_bytes())
            self.assertFalse((root / "42/diagnostic.json").exists())

    def test_rejects_archive_path_traversal(self) -> None:
        archive = self.archive({"../stolen-summary.json": b"{}"})
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(collector.CollectionError, "unsafe path"):
                collector.extract_receipts(
                    archive,
                    Path(directory),
                    9,
                    101,
                    "revision-101",
                    self.artifact_time,
                )

    def test_rejects_duplicate_receipt_basenames(self) -> None:
        archive = self.archive({"a/run-summary.json": b"{}", "b/run-summary.json": b"{}"})
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(collector.CollectionError, "duplicate receipt names"):
                collector.extract_receipts(
                    archive,
                    Path(directory),
                    10,
                    101,
                    "revision-101",
                    self.artifact_time,
                )

    def test_rejects_receipt_bound_to_a_different_workflow_run(self) -> None:
        receipt = json.dumps(
            {
                "recorded_at": "2026-08-20T00:00:00Z",
                "run_identity": "github:999:1:quality",
            }
        ).encode()
        archive = self.archive({"apple-pr-summary.json": receipt})
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(collector.CollectionError, "does not match"):
                collector.extract_receipts(
                    archive,
                    Path(directory),
                    11,
                    101,
                    "revision-101",
                    self.artifact_time,
                )

    def test_accepts_receipt_bound_to_its_workflow_run_and_artifact_time(self) -> None:
        receipt = json.dumps(
            {
                "recorded_at": "2026-08-20T00:00:00Z",
                "run_identity": "github:101:2:quality",
                "source_revision": "revision-101",
            }
        ).encode()
        archive = self.archive({"apple-pr-summary.json": receipt})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(
                1,
                collector.extract_receipts(
                    archive,
                    root,
                    13,
                    101,
                    "revision-101",
                    self.artifact_time,
                ),
            )
            self.assertTrue((root / "13/apple-pr-summary.json").is_file())

    def test_rejects_receipt_date_outside_its_artifact_window(self) -> None:
        receipt = json.dumps(
            {
                "recorded_at": "2026-08-01T00:00:00Z",
                "run_identity": "github:101:1:quality",
            }
        ).encode()
        archive = self.archive({"apple-pr-summary.json": receipt})
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(collector.CollectionError, "predates"):
                collector.extract_receipts(
                    archive,
                    Path(directory),
                    12,
                    101,
                    "revision-101",
                    self.artifact_time,
                )

    def test_rejects_receipt_bound_to_a_different_source_revision(self) -> None:
        receipt = json.dumps(
            {
                "recorded_at": "2026-08-20T00:00:00Z",
                "run_identity": "github:101:1:quality",
                "source_revision": "substituted-revision",
            }
        ).encode()
        archive = self.archive({"apple-pr-summary.json": receipt})
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(collector.CollectionError, "source revision does not match"):
                collector.extract_receipts(
                    archive,
                    Path(directory),
                    14,
                    101,
                    "revision-101",
                    self.artifact_time,
                )

    def test_cross_host_artifact_redirect_does_not_forward_github_token(self) -> None:
        request = urllib.request.Request(
            "https://api.github.com/repos/example/repo/actions/artifacts/1/zip",
            headers={"Authorization": "Bearer secret"},
        )
        redirected = collector.SafeRedirectHandler().redirect_request(
            request,
            None,
            302,
            "Found",
            {},
            "https://signed-storage.example/artifact.zip",
        )
        self.assertIsNotNone(redirected)
        self.assertNotIn("Authorization", redirected.headers)

    def test_rejects_insecure_api_before_using_token(self) -> None:
        environment = os.environ.copy()
        environment["QUALITY_GITHUB_TOKEN"] = "secret"
        process = subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--repository",
                "example/repo",
                "--workflow",
                "apple-quality.yml",
                "--artifact-name-prefix",
                "apple-quality-receipts-",
                "--output",
                "/tmp/unused-quality-observation-input",
                "--api-url",
                "http://api.example.test",
            ],
            cwd=REPO,
            env=environment,
            text=True,
            capture_output=True,
        )
        self.assertEqual(2, process.returncode)
        self.assertIn("API URL must use HTTPS", process.stdout)
        self.assertNotIn("secret", process.stdout)


if __name__ == "__main__":
    unittest.main()
