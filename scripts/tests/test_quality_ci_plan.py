import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_plan", ROOT / "scripts/quality_ci_plan.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AcceptanceSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", "test@example.invalid")
        self.base = self.commit("base.txt")
        self.previous = self.commit("core-product.txt")
        self.head = self.commit("test-helper.txt")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def commit(self, filename):
        (self.repo / filename).write_text(filename)
        self.git("add", filename)
        self.git("commit", "-qm", filename)
        return self.git("rev-parse", "HEAD")

    def select(self, draft=True, action="synchronize", before=None):
        event = {"pull_request": {"draft": draft}, "action": action,
                 "before": self.previous if before is None else before}
        return module.execution_range(self.repo, event, self.base, self.head)

    def test_draft_patch_retains_separate_earlier_product_obligation(self):
        base, purpose = self.select()
        self.assertEqual(purpose, "draft-patch-diagnostic")
        self.assertEqual(self.git("diff", "--name-only", f"{base}...{self.head}"), "test-helper.txt")
        self.assertEqual(set(self.git("diff", "--name-only", f"{self.base}...{self.head}").splitlines()),
                         {"core-product.txt", "test-helper.txt"})

    def test_ready_for_review_restores_earlier_product_change(self):
        self.assertEqual(self.select(False, "ready_for_review"), (self.base, "cumulative-acceptance"))

    def test_ready_pr_synchronize_cannot_select_only_last_patch(self):
        self.assertEqual(self.select(False), (self.base, "cumulative-acceptance"))

    def test_missing_previous_tip_retains_cumulative_scope(self):
        self.assertEqual(self.select(before="0" * 40), (self.base, "draft-cumulative-diagnostic"))
        self.assertEqual(self.select(before="f" * 40), (self.base, "draft-cumulative-diagnostic"))

    def test_force_push_unrelated_previous_tip_retains_cumulative_scope(self):
        self.git("checkout", "--orphan", "unrelated")
        self.git("rm", "-rf", ".")
        unrelated = self.commit("other.txt")
        self.assertEqual(self.select(before=unrelated), (self.base, "draft-cumulative-diagnostic"))

    def test_draft_reopen_without_patch_retains_cumulative_scope(self):
        self.assertEqual(self.select(action="reopened"), (self.base, "draft-cumulative-diagnostic"))

    def test_draft_ui_repair_runs_its_native_methods_only(self):
        plan = {"platform": "apple", "changed_product_paths": [],
                "selected_rule_ids": ["quality-system", "ios-ui-test-source"],
                "required_ui_test_scopes": {"ios": ["real/method"]}, "recommended_lane": "pr"}
        self.assertEqual(module.select_execution_lane(plan, "draft-patch-diagnostic"), "changed-tests")
        self.assertEqual(module.select_execution_lane(plan, "cumulative-acceptance"), "pr")
        plan["changed_product_paths"] = ["Shared/Repositories/LocalDataStore.swift"]
        self.assertEqual(module.select_execution_lane(plan, "draft-patch-diagnostic"), "pr")
        plan["changed_product_paths"] = []
        plan["selected_rule_ids"].append("quality-preparation-contract")
        self.assertEqual(module.select_execution_lane(plan, "draft-patch-diagnostic"), "pr")

    def test_workflow_can_pass_the_existing_check_argument_and_runs_on_readiness(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/quality_ci_plan.py"), "--help"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--check", result.stdout)
        workflow = next((ROOT / ".github/workflows").glob("*-quality.yml")).read_text()
        self.assertIn("ready_for_review", workflow)
        self.assertIn('--event "$GITHUB_EVENT_PATH"', workflow)


if __name__ == "__main__":
    unittest.main()
