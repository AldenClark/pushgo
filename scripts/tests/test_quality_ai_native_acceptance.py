import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "quality_ai_native_acceptance", REPO / "scripts/quality_ai_native_acceptance.py"
)
assert SPEC and SPEC.loader
ACCEPTANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ACCEPTANCE)


class QualityAINativeAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "quality@example.test")
        self.git("config", "user.name", "Quality Tests")
        self.write("App/Feature.swift", "let feature = \"base\"\n")
        self.write("Tests/FeatureTests.swift", "func testFeature() {}\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.write("App/Feature.swift", "let feature = \"target\"\n")
        self.write("Tests/FeatureTests.swift", "func testFeature() { assert(true) }\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "target")
        self.target = self.git("rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.directory.cleanup()

    def git(self, *arguments: str) -> str:
        process = subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=True,
        )
        return process.stdout.strip()

    def write(self, relative: str, content: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def bundle(self, *, calibration: list[dict[str, object]] | None = None) -> Path:
        packet_path = Path("build/quality-results/ai-packets/task.json")
        packet = {
            "id": "task-1",
            "task_prompt": "Keep the feature usable after the change.",
            "user_outcome": "The user can reach the feature and sees the accurate result.",
            "credible_counterexample": "A stale value is shown while the test still sees a screen.",
            "required_response": ["purpose", "oracle", "lane"],
        }
        packet_bytes = json.dumps(packet, sort_keys=True).encode("utf-8")
        self.write(packet_path.as_posix(), packet_bytes.decode("utf-8"))
        receipt_path = Path("build/quality-results/native-summary.json")
        receipt = {
            "schema_version": 2,
            "recorded_at": "2026-09-02T00:00:00+00:00",
            "source_revision": self.target,
            "source_dirty": False,
            "run_identity": "local:ai-task-1:1",
            "platform": "apple",
            "lane": "focused",
            "product_capability_status": "PASSED",
            "test_system_status": "PASSED",
            "selected_claims": ["feature accurate result"],
            "executed_claims": ["feature accurate result"],
            "incomplete_selected_claims": [],
            "not_run": [],
            "test_system_issue_ids": [],
            "waiver_id": None,
            "reason": None,
            "scope_notice": "This receipt covers the executed claim only.",
        }
        self.write(receipt_path.as_posix(), json.dumps(receipt, indent=2))
        review = {
            "reviewer_id": "human-reviewer-1",
            "independent": True,
            "blind_before_target": True,
            "packet_sha256": hashlib.sha256(packet_bytes).hexdigest(),
            "blind_completed_at": "2026-09-02T00:01:00+00:00",
            "target_revealed_at": "2026-09-02T00:02:00+00:00",
            "reviewed_at": "2026-09-02T00:03:00+00:00",
            "verdict": "SUPPORTED",
            "purpose": "SUPPORTED",
            "oracle": "SUPPORTED",
            "lane": "SUPPORTED",
            "execution": "SUPPORTED",
            "boundaries": "SUPPORTED",
            "notes": "The real entry, action, accurate result and boundary are supported.",
        }
        bundle = {
            "schema_version": 1,
            "objective": "ai-native-delivery",
            "platform": "apple",
            "task_id": "task-1",
            "ai_actor_id": "ai-agent-1",
            "answer_hidden": True,
            "packet_path": packet_path.as_posix(),
            "packet_sha256": hashlib.sha256(packet_bytes).hexdigest(),
            "base_commit": self.base,
            "target_commit": self.target,
            "implementation": {
                "product_paths": ["App/Feature.swift"],
                "quality_paths": ["Tests/FeatureTests.swift"],
                "user_purpose": "The user reaches the feature and sees the accurate result.",
                "oracle": {
                    "reachable_entry": "Primary feature entry",
                    "user_action": "Open the feature and perform the real action",
                    "observable_outcomes": ["Accurate result is visible and usable"],
                    "persistence_or_system_boundary": "Result survives the required relaunch",
                    "negative_control": "Returning a stale value must fail the test",
                },
            },
            "native_execution": {
                "receipt": receipt_path.as_posix(),
                "lane": "focused",
                "run_identity": "local:ai-task-1:1",
            },
            "semantic_review": review,
        }
        if calibration is not None:
            bundle["calibration"] = calibration
        bundle_path = self.root / "build/quality-results/ai-native-bundle.json"
        bundle_path.parent.mkdir(parents=True, exist_ok=True)
        bundle_path.write_text(json.dumps(bundle, indent=2), encoding="utf-8")
        return bundle_path

    def test_clean_bundle_waits_for_later_calibration(self) -> None:
        bundle = self.bundle()

        report = ACCEPTANCE.evaluate_bundle(self.root, bundle)

        self.assertEqual("READY_FOR_LONGITUDINAL_CALIBRATION", report["assessment_status"])
        self.assertTrue(report["evidence"]["native_execution"])
        self.assertTrue(report["evidence"]["independent_semantic_review"])
        self.assertFalse(report["evidence"]["longitudinal_calibration"])
        self.assertIn("no later real-change calibration record", report["findings"])

    def test_clean_bundle_with_distinct_later_task_is_supported(self) -> None:
        self.write("App/Feature.swift", "let feature = \"calibration\"\n")
        self.git("add", "App/Feature.swift")
        self.git("commit", "-q", "-m", "calibration")
        calibration_commit = self.git("rev-parse", "HEAD")
        calibration_receipt_path = Path("build/quality-results/calibration-summary.json")
        calibration_receipt = {
            "schema_version": 2,
            "recorded_at": "2026-09-02T00:09:00+00:00",
            "source_revision": calibration_commit,
            "source_dirty": False,
            "run_identity": "local:calibration-task-1:1",
            "platform": "apple",
            "lane": "focused",
            "product_capability_status": "PASSED",
            "test_system_status": "PASSED",
            "selected_claims": ["calibration purpose"],
            "executed_claims": ["calibration purpose"],
            "incomplete_selected_claims": [],
            "not_run": [],
            "test_system_issue_ids": [],
            "waiver_id": None,
            "reason": None,
            "scope_notice": "This receipt covers the executed calibration claim only.",
        }
        self.write(calibration_receipt_path.as_posix(), json.dumps(calibration_receipt, indent=2))
        selection_path = Path("build/quality-results/calibration-impact.json")
        selection = {
            "schema_version": 1,
            "platform": "apple",
            "plan_status": "READY",
            "change_source": f"git:{self.target}...{calibration_commit}",
            "changed_files": ["App/Feature.swift"],
            "selection_blockers": [],
            "unmapped_product_paths": [],
        }
        self.write(selection_path.as_posix(), json.dumps(selection, indent=2))
        bundle = self.bundle(
            calibration=[
                {
                    "task_id": "later-task-1",
                    "base_commit": self.target,
                    "target_commit": calibration_commit,
                    "selection_report": selection_path.as_posix(),
                    "native_receipt": calibration_receipt_path.as_posix(),
                    "lane": "focused",
                    "run_identity": "local:calibration-task-1:1",
                    "reviewer_id": "human-reviewer-2",
                    "reviewed_at": "2026-09-02T00:10:00+00:00",
                    "selection_replayed": True,
                    "native_executed": True,
                    "user_purpose_verified": True,
                    "oracle_verified": True,
                }
            ]
        )

        report = ACCEPTANCE.evaluate_bundle(self.root, bundle)

        self.assertEqual("SUPPORTED", report["assessment_status"])
        self.assertEqual([], report["findings"])

    def test_packet_answer_leak_is_rejected(self) -> None:
        bundle = self.bundle()
        packet_path = self.root / "build/quality-results/ai-packets/task.json"
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
        packet["semantic_review"] = {"verdict": "SUPPORTED"}
        packet_bytes = json.dumps(packet).encode("utf-8")
        packet_path.write_bytes(packet_bytes)
        payload = json.loads(bundle.read_text(encoding="utf-8"))
        payload["packet_sha256"] = hashlib.sha256(packet_bytes).hexdigest()
        payload["semantic_review"]["packet_sha256"] = payload["packet_sha256"]
        bundle.write_text(json.dumps(payload), encoding="utf-8")

        with self.assertRaisesRegex(ACCEPTANCE.AcceptanceContractError, "leaks answer key"):
            ACCEPTANCE.evaluate_bundle(self.root, bundle)

    def test_receipt_must_be_bound_to_target_commit(self) -> None:
        bundle = self.bundle()
        receipt_path = self.root / "build/quality-results/native-summary.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["source_revision"] = self.base
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

        with self.assertRaisesRegex(ACCEPTANCE.AcceptanceContractError, "source_revision"):
            ACCEPTANCE.evaluate_bundle(self.root, bundle)

    def test_unexecuted_native_claim_keeps_assessment_partial(self) -> None:
        bundle = self.bundle()
        receipt_path = self.root / "build/quality-results/native-summary.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["product_capability_status"] = "NOT_RUN"
        receipt["executed_claims"] = []
        receipt["incomplete_selected_claims"] = receipt["selected_claims"]
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

        report = ACCEPTANCE.evaluate_bundle(self.root, bundle)

        self.assertEqual("PARTIAL", report["assessment_status"])
        self.assertIn("native receipt selected claims were not all executed", report["findings"])

    def test_supported_review_cannot_hide_a_partial_axis(self) -> None:
        bundle = self.bundle()
        payload = json.loads(bundle.read_text(encoding="utf-8"))
        payload["semantic_review"]["oracle"] = "PARTIAL"
        bundle.write_text(json.dumps(payload), encoding="utf-8")

        with self.assertRaisesRegex(ACCEPTANCE.AcceptanceContractError, "every review axis"):
            ACCEPTANCE.evaluate_bundle(self.root, bundle)

    def test_product_and_quality_paths_must_both_be_in_target_diff(self) -> None:
        bundle = self.bundle()
        payload = json.loads(bundle.read_text(encoding="utf-8"))
        payload["implementation"]["quality_paths"] = ["Tests/Missing.swift"]
        bundle.write_text(json.dumps(payload), encoding="utf-8")

        with self.assertRaisesRegex(ACCEPTANCE.AcceptanceContractError, "not in target diff"):
            ACCEPTANCE.evaluate_bundle(self.root, bundle)


if __name__ == "__main__":
    unittest.main()
