import importlib.util
import re
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

    def test_entity_screen_change_prefers_positive_pr_evidence(self):
        plan = self.plan("Apps/PushGo-macOS/UI/Screens/ThingSplitScreen.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertTrue({"events", "things"}.issubset(plan["impacted_capabilities"]))

    def test_entity_state_owner_change_keeps_nightly_evidence(self):
        plan = self.plan("Shared/UI/EntityScreens.swift")

        self.assertEqual("nightly", plan["recommended_lane"])

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

    def test_apple_ui_runner_preconditions_are_quality_system_changes(self):
        for path in (
            "scripts/require_unlocked_apple_ui_console.sh",
            "scripts/run_ios_ui_tests.sh",
            "scripts/run_macos_ui_tests.sh",
            "scripts/run_watchos_ui_tests.sh",
        ):
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual("READY", plan["plan_status"])
                self.assertEqual("pr", plan["recommended_lane"])
                self.assertIn(
                    "quality-system-trustworthiness",
                    plan["impacted_capabilities"],
                )
                self.assertIn("Apple PR representative lane", plan["minimum_evidence"])

    def test_macos_positive_and_risk_sets_cover_every_discoverable_journey(self):
        test_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()
        runner_source = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        orchestrator_source = (REPO / "scripts/quality_test.sh").read_text()
        discoverable = set(re.findall(r"^\s+func (test[A-Za-z0-9_]+)\(", test_source, re.MULTILINE))
        positive = self._macos_scopes(runner_source, "positive_scopes")
        risk = self._macos_scopes(runner_source, "risk_scopes")

        self.assertEqual(25, len(discoverable))
        self.assertEqual(16, len(positive))
        self.assertEqual(9, len(risk))
        self.assertFalse(positive & risk)
        self.assertEqual(
            discoverable,
            positive | risk,
            "Every discoverable macOS journey must belong to the positive or risk set.",
        )
        for deferred_fragment in (
            "Fatal",
            "Failure",
            "Corrupt",
            "WrongKey",
            "DeleteUndo",
            "InvalidServer",
            "LocalCommitFailure",
        ):
            self.assertFalse(any(deferred_fragment in scope for scope in positive), deferred_fragment)
        self.assertIn('case "${MACOS_SCOPE_SET:-positive}" in', runner_source)
        self.assertIn("run_macos_ui positive", orchestrator_source)
        self.assertEqual(2, orchestrator_source.count("run_macos_ui full"))

    def _macos_scopes(self, source: str, variable: str) -> set[str]:
        match = re.search(rf"^{variable}=\((.*?)^\)", source, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, variable)
        return set(
            re.findall(
                r'"PushGo-macOSUITests/PushGo_macOSUITests/(test[A-Za-z0-9_]+)"',
                match.group(1),
            )
        )

    def test_performance_test_change_selects_performance_lane(self):
        plan = self.plan("Tests/PushGo-iOSUITests/PushGo_iOSPerformanceTests.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("performance", plan["recommended_lane"])
        self.assertIn("performance-evidence-trustworthiness", plan["impacted_capabilities"])
        self.assertIn(
            "iOS prepared 1k Store launch-to-accurate-content purpose metric",
            plan["minimum_evidence"],
        )

    def test_physical_performance_runner_is_not_ignored(self):
        plan = self.plan("scripts/run_ios_physical_performance.sh")

        self.assertEqual("performance", plan["recommended_lane"])
        self.assertNotIn("scripts/run_ios_physical_performance.sh", plan["ignored_paths"])

    def test_system_notification_journey_change_runs_its_real_nightly_evidence(self):
        for path in (
            "Tests/PushGo-iOSUITests/PushGo_iOSSystemNotificationTests.swift",
            "scripts/run_ios_system_notification_test.sh",
        ):
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual("READY", plan["plan_status"])
                self.assertEqual("nightly", plan["recommended_lane"])
                self.assertIn("notification-system-delivery", plan["impacted_capabilities"])
                self.assertIn(
                    "iOS Simulator real permission/delivery/hot-and-terminated-process tap/detail/read/relaunch journeys plus direct Mark as read and destructive Delete actions with durable canonical oracles",
                    plan["minimum_evidence"],
                )

    def test_app_owned_cold_launch_lease_requires_release_isolation(self):
        plan = self.plan("Shared/Utilities/AppConstants.swift")

        self.assertEqual("release", plan["recommended_lane"])
        self.assertIn("app-owned-quality-runtime", plan["impacted_capabilities"])
        self.assertIn("release-runtime-isolation", plan["impacted_capabilities"])

    def test_product_and_performance_changes_promote_to_release_superset(self):
        plan = self.plan(
            "Shared/Repositories/LocalDataStore.swift",
            "Tests/PushGo-iOSUITests/PushGo_iOSPerformanceTests.swift",
        )

        self.assertEqual("release", plan["recommended_lane"])
        self.assertIn("messages", plan["impacted_capabilities"])
        self.assertIn("performance-evidence-trustworthiness", plan["impacted_capabilities"])

    def test_machine_consumed_appcast_runs_contract_without_full_release_lane(self):
        plan = self.plan("release/appcast.xml")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertIn("update-distribution", plan["impacted_capabilities"])
        self.assertEqual(["apple-update-distribution-contract"], plan["required_checks"])

    def test_fastlane_change_requires_release_contract_and_build(self):
        plan = self.plan("fastlane/Fastfile")

        self.assertEqual("release", plan["recommended_lane"])
        self.assertIn("apple-release-static-contract", plan["required_checks"])

    def test_temporary_update_repair_workflow_is_not_treated_as_documentation(self):
        plan = self.plan(".github/workflows/repair-v1.3.0-update-permissions.yml")

        self.assertEqual("release", plan["recommended_lane"])
        self.assertIn("apple-release-static-contract", plan["required_checks"])

    def test_system_consumer_upgrades_message_change_to_nightly(self):
        plan = self.plan(
            "Shared/UI/MessageListViewModel.swift",
            "Shared/SystemIntegration/PushGoSpotlightIndexer.swift",
        )

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertIn("spotlight-user-activity", plan["impacted_capabilities"])

    def test_ios_app_delegate_change_selects_notification_system_evidence(self):
        plan = self.plan("Apps/PushGo-iOS/App/PushGoAppDelegate.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertIn("notification-route-actions", plan["impacted_capabilities"])
        self.assertIn(
            "iOS Simulator real system-notification journey for iOS/shared route changes",
            plan["minimum_evidence"],
        )

    def test_app_environment_change_keeps_gateway_settings_evidence(self):
        plan = self.plan("Apps/PushGo-macOS/App/AppEnvironment.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("release", plan["recommended_lane"])
        self.assertIn("gateway-settings", plan["impacted_capabilities"])
        self.assertIn(
            "real server invalid/candidate-registration-failure/no-commit/retry/normalize/data-scope/relaunch journey",
            plan["minimum_evidence"],
        )

    def test_ios_channel_screen_selects_only_ios_positive_owner_evidence(self):
        plan = self.plan("Apps/PushGo-iOS/UI/Screens/ChannelManagementScreen.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertEqual(["channels"], plan["impacted_capabilities"])
        self.assertEqual(["apple-ios-channel-positive"], plan["required_checks"])
        self.assertNotIn("gateway-settings", plan["impacted_capabilities"])
        self.assertNotIn("decryption-settings", plan["impacted_capabilities"])

    def test_macos_channel_screen_selects_only_macos_positive_owner_evidence(self):
        plan = self.plan("Apps/PushGo-macOS/UI/Screens/ChannelManagementView.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertEqual(["channels"], plan["impacted_capabilities"])
        self.assertEqual(["apple-macos-channel-positive"], plan["required_checks"])

    def test_shared_channel_controller_retains_reconciliation_lane(self):
        plan = self.plan("Shared/Application/ChannelSubscriptionController.swift")

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertEqual(["channels"], plan["impacted_capabilities"])
        self.assertEqual([], plan["required_checks"])
        self.assertIn("relaunch reconciliation", " ".join(plan["escalation_reasons"]))

    def test_settings_screen_no_longer_selects_channel_lifecycle(self):
        plan = self.plan("Apps/PushGo-iOS/UI/Screens/SettingsView.swift")

        self.assertEqual("pr", plan["recommended_lane"])
        self.assertNotIn("channels", plan["impacted_capabilities"])
        self.assertIn("gateway-settings", plan["impacted_capabilities"])
        self.assertIn("notification-sound", plan["impacted_capabilities"])
        self.assertEqual(["apple-ios-settings-positive-extension"], plan["required_checks"])

    def test_macos_settings_screen_selects_platform_purpose_evidence(self):
        plan = self.plan("Apps/PushGo-macOS/UI/Screens/SettingsView.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertEqual(
            ["decryption-settings", "gateway-settings", "notification-sound", "page-visibility"],
            plan["impacted_capabilities"],
        )
        self.assertEqual(["apple-macos-settings-positive"], plan["required_checks"])

    def test_shared_settings_view_model_retains_nightly_risk_evidence(self):
        plan = self.plan("Shared/UI/SettingsViewModel.swift")

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertEqual([], plan["required_checks"])
        self.assertIn("protected material", " ".join(plan["escalation_reasons"]))
        self.assertIn("notification-sound", plan["impacted_capabilities"])

    def test_ios_main_tab_ui_uses_pr_navigation_evidence_without_macos_window_risk(self):
        plan = self.plan("Apps/PushGo-iOS/UI/Screens/MainTabContainerView.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertEqual(["app-launch", "primary-navigation"], plan["impacted_capabilities"])
        self.assertNotIn("mac-window-status-item", plan["impacted_capabilities"])

    def test_macos_main_tab_ui_uses_pr_dynamic_sidebar_evidence_without_window_risk(self):
        plan = self.plan("Apps/PushGo-macOS/UI/Screens/MainTabContainerView.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertEqual(["app-launch", "primary-navigation"], plan["impacted_capabilities"])
        self.assertNotIn("mac-window-status-item", plan["impacted_capabilities"])
        self.assertIn("unread title/badge", " ".join(plan["minimum_evidence"]))

    def test_macos_window_presenter_retains_nightly_window_lifecycle_evidence(self):
        plan = self.plan("Shared/Application/MacMainWindowPresenter.swift")

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertIn("mac-window-status-item", plan["impacted_capabilities"])
        self.assertIn("close/reopen", " ".join(plan["minimum_evidence"]))

    def test_shared_form_controls_select_cross_platform_purpose_evidence_without_media(self):
        plan = self.plan("Shared/UI/AppFormControls.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertEqual(
            ["apple-ios-shared-form-accessibility", "apple-macos-shared-form-purpose"],
            plan["required_checks"],
        )
        self.assertIn("accessibility-localization", plan["impacted_capabilities"])
        self.assertIn("gateway-settings", plan["impacted_capabilities"])
        self.assertIn("message-detail", plan["impacted_capabilities"])
        self.assertNotIn("delete-undo", plan["impacted_capabilities"])
        self.assertNotIn("message-media", plan["impacted_capabilities"])

    def test_shared_image_preview_owner_uses_existing_ios_pr_and_one_macos_positive(self):
        plan = self.plan("Shared/UI/KeyboardDismiss.swift")

        self.assertEqual("pr", plan["recommended_lane"])
        self.assertEqual(
            ["apple-macos-shared-image-preview-positive"],
            plan["required_checks"],
        )
        self.assertIn("message-media", plan["impacted_capabilities"])
        self.assertNotIn("notification-sound", plan["impacted_capabilities"])

    def test_toast_and_sound_editor_remain_nightly_risk_owners(self):
        for path in ("Shared/UI/ToastView.swift", "Shared/UI/NotificationSoundEditorView.swift"):
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual("nightly", plan["recommended_lane"])

    def test_system_settings_component_from_history_is_mapped_to_real_consumers(self):
        plan = self.plan("Shared/UI/SystemIntegrationSettingsGroup.swift")

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertIn("controls-intents-shortcuts", plan["impacted_capabilities"])

    def test_root_view_change_keeps_accessibility_localization_evidence(self):
        plan = self.plan("Shared/UI/RootView.swift")

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertIn("accessibility-localization", plan["impacted_capabilities"])

    def test_notification_semantic_test_change_keeps_ingress_outcomes(self):
        plan = self.plan("Tests/PushGoAppleCoreTests/NotificationHandlingTests.swift")

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertTrue(
            {"decryption-settings", "messages", "ingress-ack"}.issubset(
                plan["impacted_capabilities"]
            )
        )


if __name__ == "__main__":
    unittest.main()
