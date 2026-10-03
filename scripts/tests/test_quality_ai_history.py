import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AI_HISTORY = load("quality_ai_history", REPO / "scripts/quality_ai_history.py")
QUALITY_IMPACT = load("quality_impact_for_history_test", REPO / "scripts/quality_impact.py")


class QualityAIHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.corpus = json.loads((REPO / "config/quality-ai-task-history.json").read_text())
        cls.manifest = QUALITY_IMPACT.load_manifest(REPO / "config/quality-impact.json")

    def test_current_historical_task_contracts_hold(self):
        report = AI_HISTORY.evaluate_corpus(REPO, self.corpus, self.manifest, QUALITY_IMPACT)

        self.assertEqual("READY_FOR_RECORDED_SEMANTIC_REVIEW", report["status"])
        self.assertGreaterEqual(report["task_count"], 10)
        self.assertEqual([], report["failed_task_ids"])
        self.assertTrue(
            all(task["semantic_review_status"] == "RECORDED_NOT_AUTOMATICALLY_VERIFIED" for task in report["tasks"])
        )

    def test_missing_semantic_capability_fails_replay(self):
        corpus = copy.deepcopy(self.corpus)
        corpus["tasks"][0]["required_capabilities"].append("negative-control-missing-capability")

        report = AI_HISTORY.evaluate_corpus(REPO, corpus, self.manifest, QUALITY_IMPACT)

        self.assertEqual("FAILED", report["status"])
        self.assertIn(corpus["tasks"][0]["id"], report["failed_task_ids"])

    def test_lane_underselection_fails_replay(self):
        corpus = copy.deepcopy(self.corpus)
        notification = next(task for task in corpus["tasks"] if task["id"] == "ios-system-notification-route")
        notification["minimum_lane"] = "release"

        report = AI_HISTORY.evaluate_corpus(REPO, corpus, self.manifest, QUALITY_IMPACT)

        self.assertEqual("FAILED", report["status"])
        self.assertIn(notification["id"], report["failed_task_ids"])

    def test_missing_required_co_change_fails_replay(self):
        corpus = copy.deepcopy(self.corpus)
        corpus["tasks"][0]["required_changed_path_groups"].append(
            {"description": "deliberately absent group", "patterns": ["Never/Exists/**"]}
        )

        report = AI_HISTORY.evaluate_corpus(REPO, corpus, self.manifest, QUALITY_IMPACT)

        self.assertEqual("FAILED", report["status"])
        self.assertIn(corpus["tasks"][0]["id"], report["failed_task_ids"])

    def test_corpus_cannot_shrink_below_monthly_sample_floor(self):
        corpus = copy.deepcopy(self.corpus)
        corpus["tasks"] = corpus["tasks"][:9]

        with self.assertRaisesRegex(ValueError, "at least 10"):
            AI_HISTORY.validate_corpus(corpus, self.manifest)

    def test_same_real_commit_cannot_inflate_sample_count(self):
        corpus = copy.deepcopy(self.corpus)
        corpus["tasks"][1]["commit"] = corpus["tasks"][0]["commit"]

        with self.assertRaisesRegex(ValueError, "duplicate historical commit"):
            AI_HISTORY.evaluate_corpus(REPO, corpus, self.manifest, QUALITY_IMPACT)

    def test_blind_packets_disclose_acceptance_contract_without_target_or_answers(self):
        output = AI_HISTORY.blind_packets(REPO, self.corpus)

        self.assertEqual(len(self.corpus["tasks"]), len(output["packets"]))
        for task, packet in zip(self.corpus["tasks"], output["packets"], strict=True):
            full_commit, _, _ = AI_HISTORY.changed_paths(REPO, task["commit"])
            self.assertEqual(
                {
                    "id",
                    "task_prompt",
                    *AI_HISTORY.BLIND_PACKET_CONTRACT_FIELDS,
                    "required_response",
                    "materialize_command",
                },
                set(packet),
            )
            self.assertNotIn("commit", packet)
            self.assertNotIn("base_commit", packet)
            self.assertNotIn("semantic_review", packet)
            self.assertNotIn("minimum_lane", packet)
            self.assertNotIn("required_capabilities", packet)
            self.assertNotIn("required_changed_path_groups", packet)
            for field in AI_HISTORY.BLIND_PACKET_CONTRACT_FIELDS:
                self.assertIn(field, packet)
                self.assertEqual(task[field], packet[field])
            serialized = json.dumps(packet, ensure_ascii=False, sort_keys=True)
            self.assertNotIn(full_commit, serialized)
            self.assertNotIn(task["commit"], serialized)
            self.assertNotIn('"semantic_review"', serialized)
            self.assertIn("--materialize-task", packet["materialize_command"])

    def test_blind_packet_contract_is_detached_from_answer_corpus(self):
        output = AI_HISTORY.blind_packets(REPO, self.corpus)
        packet = output["packets"][0]
        original_outcome = self.corpus["tasks"][0]["user_outcome"]

        packet["user_outcome"] = "mutated-review-input"

        self.assertEqual(
            original_outcome,
            self.corpus["tasks"][0]["user_outcome"],
        )

    def test_materialized_snapshot_is_history_free_parent_without_review_answers(self):
        task = self.corpus["tasks"][0]
        full_commit, changed_paths, parent = AI_HISTORY.changed_paths(REPO, task["commit"])
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "snapshot"
            AI_HISTORY.materialize_history_free_snapshot(
                REPO,
                self.corpus,
                task["id"],
                output,
            )

            self.assertFalse((output / ".git").exists())
            for relative in AI_HISTORY.BLIND_REVIEW_ONLY_PATHS:
                self.assertFalse((output / relative).exists(), relative)

            compared = False
            for path in changed_paths:
                parent_bytes = subprocess.run(
                    ["git", "show", f"{parent}:{path}"],
                    cwd=REPO,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                target_bytes = subprocess.run(
                    ["git", "show", f"{full_commit}:{path}"],
                    cwd=REPO,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                snapshot_path = output / path
                if (
                    parent_bytes.returncode == 0
                    and target_bytes.returncode == 0
                    and parent_bytes.stdout != target_bytes.stdout
                    and snapshot_path.is_file()
                ):
                    self.assertEqual(parent_bytes.stdout, snapshot_path.read_bytes())
                    compared = True
                    break
            self.assertTrue(compared, "fixture task must contain a changed parent file")

    def test_materialization_refuses_to_overwrite_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "already-exists"
            output.mkdir()
            with self.assertRaisesRegex(ValueError, "must not already exist"):
                AI_HISTORY.materialize_history_free_snapshot(
                    REPO,
                    self.corpus,
                    self.corpus["tasks"][0]["id"],
                    output,
                )


if __name__ == "__main__":
    unittest.main()
