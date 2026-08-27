import importlib.util
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("quality_impact", REPO / "scripts/quality_impact.py")
assert SPEC and SPEC.loader
QUALITY_IMPACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QUALITY_IMPACT)


class QualityImpactPlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = QUALITY_IMPACT.load_manifest(REPO / "config/quality-impact.json")

    def plan(self, *paths):
        return QUALITY_IMPACT.build_plan(list(paths), self.manifest, "unit-test")

    def test_message_ui_selects_real_pr_evidence(self):
        plan = self.plan("Apps/PushGo-iOS/UI/Screens/MessageListScreen.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertIn("messages", plan["impacted_capabilities"])
        self.assertIn("iOS accurate content/search/delete/relaunch UI journeys", plan["minimum_evidence"])
        self.assertTrue(plan["manual_impact_review_required"])

    def test_shared_store_expands_across_capabilities_and_escalates(self):
        plan = self.plan("Shared/Repositories/LocalDataStore.swift")

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertTrue({"messages", "events", "things", "ingress-recovery"}.issubset(plan["impacted_capabilities"]))
        self.assertTrue(plan["known_evidence_gaps"])

    def test_runtime_change_requires_release_isolation(self):
        plan = self.plan("Shared/UI/AutomationRuntime.swift")

        self.assertEqual("release", plan["recommended_lane"])
        self.assertIn("release-runtime-isolation", plan["impacted_capabilities"])

    def test_unmapped_product_screen_is_blocked(self):
        path = "Apps/PushGo-iOS/UI/Screens/NewCapabilityScreen.swift"
        plan = self.plan(path)

        self.assertEqual("BLOCKED", plan["plan_status"])
        self.assertEqual([path], plan["unmapped_product_paths"])

    def test_document_only_change_runs_no_product_lane(self):
        plan = self.plan("README.md", "docs/quality/capability-coverage.md")

        self.assertEqual("NOT_RUN", plan["plan_status"])
        self.assertEqual("not-run", plan["recommended_lane"])
        self.assertFalse(plan["manual_impact_review_required"])

    def test_selector_test_change_requires_representative_quality_evidence(self):
        plan = self.plan("scripts/tests/test_quality_impact.py")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertIn("quality-system-trustworthiness", plan["impacted_capabilities"])

    def test_system_consumer_upgrades_message_change_to_nightly(self):
        plan = self.plan(
            "Shared/UI/MessageListViewModel.swift",
            "Shared/SystemIntegration/PushGoSpotlightIndexer.swift",
        )

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertIn("spotlight-user-activity", plan["impacted_capabilities"])


if __name__ == "__main__":
    unittest.main()
