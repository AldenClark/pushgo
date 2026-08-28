import copy
import importlib.util
import json
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

    def test_blind_packets_do_not_disclose_target_commits_or_answers(self):
        output = AI_HISTORY.blind_packets(REPO, self.corpus)

        self.assertEqual(len(self.corpus["tasks"]), len(output["packets"]))
        for packet in output["packets"]:
            self.assertNotIn("commit", packet)
            self.assertNotIn("semantic_review", packet)
            self.assertNotIn("required_capabilities", packet)
            self.assertIn("--materialize-task", packet["materialize_command"])


if __name__ == "__main__":
    unittest.main()
