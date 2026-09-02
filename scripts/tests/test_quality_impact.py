import importlib.util
import re
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


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

    @staticmethod
    def swift_ui_test_source(value: str = "before", method: str = "testChangedPurpose") -> str:
        return f"""import XCTest

final class PushGo_iOSUITests: XCTestCase {{
    func testStablePurpose() {{
        XCTAssertTrue(true)
    }}

    func {method}() {{
        XCTAssertEqual("{value}", "expected")
    }}

    private func sharedFixture() -> String {{
        "fixture"
    }}
}}
"""

    def test_changed_ui_test_method_selects_exact_xctest_scope(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        old_source = self.swift_ui_test_source("before")
        new_source = self.swift_ui_test_source("after")
        changed_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if '"after"' in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            f"@@ -{changed_line} +{changed_line} @@\n-old\n+new\n",
        )

        self.assertEqual("exact-method", impact["selection"])
        self.assertEqual(1, impact["expected_test_count"])
        self.assertEqual(
            ["PushGo-iOSUITests/PushGo_iOSUITests/testChangedPurpose"],
            impact["scopes"],
        )
        plan = QUALITY_IMPACT.build_plan(
            [path], self.manifest, "unit-test", {path: impact}
        )
        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("changed-tests", plan["recommended_lane"])
        self.assertEqual("exact-method", plan["ui_test_scope_selection"])
        self.assertEqual(impact["scopes"], plan["required_ui_test_scopes"]["ios"])
        self.assertEqual([], plan["required_ui_test_scopes"]["macos"])

    def test_changed_ui_test_helper_expands_to_runnable_changed_class(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        old_source = self.swift_ui_test_source()
        new_source = old_source.replace('"fixture"', '"changed fixture"')
        changed_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if "changed fixture" in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            f"@@ -{changed_line} +{changed_line} @@\n-old\n+new\n",
        )

        self.assertEqual("changed-class", impact["selection"])
        self.assertEqual(
            [
                "PushGo-iOSUITests/PushGo_iOSUITests/testChangedPurpose",
                "PushGo-iOSUITests/PushGo_iOSUITests/testStablePurpose",
            ],
            impact["scopes"],
        )
        self.assertEqual({"default": impact["scopes"]}, impact["profile_scopes"])
        self.assertEqual(2, impact["expected_test_count"])

    def test_changed_ui_test_helper_selects_only_direct_callers(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        old_source = self.swift_ui_test_source().replace(
            '        XCTAssertEqual("before", "expected")\n',
            '        _ = sharedFixture()\n        XCTAssertEqual("before", "expected")\n',
        )
        new_source = old_source.replace('        "fixture"', '        "changed fixture"')
        changed_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if "changed fixture" in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            f"@@ -{changed_line} +{changed_line} @@\n-old\n+new\n",
        )

        self.assertEqual("exact-method", impact["selection"])
        self.assertEqual(1, impact["expected_test_count"])
        self.assertEqual(
            ["PushGo-iOSUITests/PushGo_iOSUITests/testChangedPurpose"],
            impact["scopes"],
        )

    def test_pure_assertion_insertion_inside_existing_method_stays_exact(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        old_source = self.swift_ui_test_source()
        inserted = '        XCTAssertEqual("second", "second")\n'
        new_source = old_source.replace(
            '        XCTAssertEqual("before", "expected")\n',
            '        XCTAssertEqual("before", "expected")\n' + inserted,
        )
        new_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if '"second"' in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            f"@@ -{new_line - 1},0 +{new_line},1 @@\n+assertion\n",
        )

        self.assertEqual("exact-method", impact["selection"])
        self.assertEqual(
            ["PushGo-iOSUITests/PushGo_iOSUITests/testChangedPurpose"],
            impact["scopes"],
        )

    def test_pure_assertion_deletion_inside_existing_method_stays_exact(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        extra = '        XCTAssertEqual("second", "second")\n'
        new_source = self.swift_ui_test_source()
        old_source = new_source.replace(
            '        XCTAssertEqual("before", "expected")\n',
            '        XCTAssertEqual("before", "expected")\n' + extra,
        )
        old_line = next(
            index for index, line in enumerate(old_source.splitlines(), 1) if '"second"' in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            f"@@ -{old_line},1 +{old_line - 1},0 @@\n-assertion\n",
        )

        self.assertEqual("exact-method", impact["selection"])
        self.assertEqual(
            ["PushGo-iOSUITests/PushGo_iOSUITests/testChangedPurpose"],
            impact["scopes"],
        )

    def test_new_ui_test_method_selects_the_new_exact_xctest_scope(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        old_source = self.swift_ui_test_source()
        insertion = """\n    func testNewPurpose() {\n        XCTAssertTrue(true)\n    }\n"""
        new_source = old_source.replace("\n    private func sharedFixture", insertion + "\n    private func sharedFixture")
        new_lines = new_source.splitlines()
        new_start = next(
            index for index, line in enumerate(new_lines, 1) if "func testNewPurpose" in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            f"@@ -10,0 +{new_start},3 @@\n+new method\n",
        )

        self.assertEqual("exact-method", impact["selection"])
        self.assertEqual(
            ["PushGo-iOSUITests/PushGo_iOSUITests/testNewPurpose"],
            impact["scopes"],
        )

    def test_existing_change_plus_new_ui_test_selects_only_both_exact_scopes(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        old_source = self.swift_ui_test_source("before")
        insertion = """\n    func testNewPurpose() {\n        XCTAssertTrue(true)\n    }\n"""
        new_source = self.swift_ui_test_source("after").replace(
            "\n    private func sharedFixture",
            insertion + "\n    private func sharedFixture",
        )
        old_changed_line = next(
            index for index, line in enumerate(old_source.splitlines(), 1) if '"before"' in line
        )
        new_changed_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if '"after"' in line
        )
        new_method_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if "func testNewPurpose" in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            (
                f"@@ -{old_changed_line},1 +{new_changed_line},1 @@\n-old\n+new\n"
                f"@@ -{new_method_line - 1},0 +{new_method_line},3 @@\n+new method\n"
            ),
        )

        self.assertEqual("exact-method", impact["selection"])
        self.assertEqual(
            [
                "PushGo-iOSUITests/PushGo_iOSUITests/testChangedPurpose",
                "PushGo-iOSUITests/PushGo_iOSUITests/testNewPurpose",
            ],
            impact["scopes"],
        )

    def test_existing_change_plus_new_test_and_helper_change_expands_to_class(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        old_source = self.swift_ui_test_source("before")
        insertion = """\n    func testNewPurpose() {\n        XCTAssertTrue(true)\n    }\n"""
        new_source = self.swift_ui_test_source("after").replace(
            "\n    private func sharedFixture",
            insertion + "\n    private func sharedFixture",
        ).replace('"fixture"', '"changed fixture"')
        old_changed_line = next(
            index for index, line in enumerate(old_source.splitlines(), 1) if '"before"' in line
        )
        new_changed_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if '"after"' in line
        )
        new_method_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if "func testNewPurpose" in line
        )
        old_helper_line = next(
            index for index, line in enumerate(old_source.splitlines(), 1) if '"fixture"' in line
        )
        new_helper_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if '"changed fixture"' in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            (
                f"@@ -{old_changed_line},1 +{new_changed_line},1 @@\n-old\n+new\n"
                f"@@ -{new_method_line - 1},0 +{new_method_line},3 @@\n+new method\n"
                f"@@ -{old_helper_line},1 +{new_helper_line},1 @@\n-old helper\n+new helper\n"
            ),
        )

        self.assertEqual("changed-class", impact["selection"])
        self.assertEqual(3, impact["expected_test_count"])
        self.assertEqual(
            {
                "PushGo-iOSUITests/PushGo_iOSUITests/testChangedPurpose",
                "PushGo-iOSUITests/PushGo_iOSUITests/testNewPurpose",
                "PushGo-iOSUITests/PushGo_iOSUITests/testStablePurpose",
            },
            set(impact["scopes"]),
        )

    def test_deleted_ui_test_source_blocks_before_any_unrelated_scope_runs(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            self.swift_ui_test_source(),
            None,
            "@@ -1,15 +0,0 @@\n",
        )
        plan = QUALITY_IMPACT.build_plan(
            [path], self.manifest, "unit-test", {path: impact}
        )

        self.assertEqual("blocked", impact["selection"])
        self.assertEqual("BLOCKED", plan["plan_status"])
        self.assertIn("was deleted", plan["selection_blockers"][0])
        self.assertEqual([], plan["required_ui_test_scopes"]["ios"])

    def test_committed_ui_test_source_rename_blocks_until_mapping_is_updated(self):
        old_path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        new_path = "Tests/PushGo-iOSUITests/RenamedUITests.swift"
        args = SimpleNamespace(base=None, head="HEAD")
        with mock.patch.object(
            QUALITY_IMPACT,
            "git_text",
            return_value=f"R100\t{old_path}\t{new_path}\n",
        ):
            impacts = QUALITY_IMPACT.swift_ui_test_impacts(
                args, REPO, [new_path], "working-tree"
            )
        plan = QUALITY_IMPACT.build_plan(
            [new_path], self.manifest, "working-tree", impacts
        )

        self.assertEqual("BLOCKED", plan["plan_status"])
        self.assertEqual("blocked", plan["ui_test_scope_selection"])
        self.assertIn("was renamed", plan["selection_blockers"][0])

    def test_whole_class_selection_partitions_special_execution_profiles(self):
        cases = (
            (
                "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift",
                "accessibility",
                (
                    "testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation",
                ),
                33,
            ),
            (
                "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift",
                "system",
                (
                    "testDeniedNotificationSettingsCardRecoversAfterSystemEnable",
                    "testSystemNotificationClickPersistsAccurateMessageAndSurvivesRelaunch",
                ),
                32,
            ),
        )
        for path, special_profile, methods, expected_count in cases:
            with self.subTest(path=path):
                source = (REPO / path).read_text()
                impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
                    path, None, source, None
                )
                plan = QUALITY_IMPACT.build_plan(
                    [path], self.manifest, "unit-test", {path: impact}
                )

                self.assertEqual("changed-class", impact["selection"])
                self.assertEqual(expected_count, impact["expected_test_count"])
                self.assertEqual(expected_count, len(impact["scopes"]))
                self.assertEqual(
                    len(methods),
                    len(plan["required_ui_test_profile_scopes"][impact["platform"]][special_profile]),
                )
                self.assertEqual(
                    set(methods),
                    {
                        scope.rsplit("/", 1)[-1]
                        for scope in plan["required_ui_test_profile_scopes"][impact["platform"]][special_profile]
                    },
                )

    def test_removed_or_renamed_ui_test_blocks_instead_of_running_unrelated_fixed_scope(self):
        path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        old_source = self.swift_ui_test_source()
        new_source = self.swift_ui_test_source(method="testRenamedPurpose")
        old_line = next(
            index for index, line in enumerate(old_source.splitlines(), 1) if "testChangedPurpose" in line
        )
        new_line = next(
            index for index, line in enumerate(new_source.splitlines(), 1) if "testRenamedPurpose" in line
        )
        impact = QUALITY_IMPACT.resolve_swift_ui_test_change(
            path,
            old_source,
            new_source,
            f"@@ -{old_line} +{new_line} @@\n-old\n+new\n",
        )
        plan = QUALITY_IMPACT.build_plan(
            [path], self.manifest, "unit-test", {path: impact}
        )

        self.assertEqual("blocked", impact["selection"])
        self.assertEqual("BLOCKED", plan["plan_status"])
        self.assertEqual([], plan["required_ui_test_scopes"]["ios"])
        self.assertIn("removed or renamed", plan["selection_blockers"][0])

    def test_changed_ui_test_platforms_keep_separate_native_runner_scopes(self):
        ios_path = "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift"
        mac_path = "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift"
        impacts = {
            ios_path: {
                "platform": "ios",
                "selection": "exact-method",
                "scopes": ["PushGo-iOSUITests/PushGo_iOSUITests/testOne"],
                "blocker": None,
            },
            mac_path: {
                "platform": "macos",
                "selection": "changed-class",
                "scopes": ["PushGo-macOSUITests/PushGo_macOSUITests"],
                "blocker": None,
            },
        }
        plan = QUALITY_IMPACT.build_plan(
            [ios_path, mac_path], self.manifest, "unit-test", impacts
        )

        self.assertEqual("changed-tests", plan["recommended_lane"])
        self.assertEqual("mixed", plan["ui_test_scope_selection"])
        self.assertEqual(impacts[ios_path]["scopes"], plan["required_ui_test_scopes"]["ios"])
        self.assertEqual(impacts[mac_path]["scopes"], plan["required_ui_test_scopes"]["macos"])

    def test_changed_tests_lane_executes_resolved_platform_scopes_and_cannot_be_empty(self):
        orchestrator = (REPO / "scripts/quality_test.sh").read_text()

        self.assertIn('plan.get("required_ui_test_scopes", {})', orchestrator)
        self.assertIn('TEST_SCOPES="$scope_list"', orchestrator)
        self.assertIn('QUALITY_EXPECTED_TEST_COUNT="$scope_expected_count"', orchestrator)
        self.assertIn('impact.get("expected_test_count")', orchestrator)
        self.assertIn("impact plan contains unresolved selection blockers", orchestrator)
        self.assertIn('scope.count("/") != 2', orchestrator)
        self.assertIn('plan.get("required_ui_test_profile_scopes", {})', orchestrator)
        self.assertIn("run_accessibility_localization", orchestrator)
        self.assertIn("run_macos_system_notification", orchestrator)
        self.assertIn('"$repo_root/scripts/run_ios_ui_tests.sh"', orchestrator)
        self.assertIn('"$repo_root/scripts/run_macos_ui_tests.sh"', orchestrator)
        self.assertIn('"$repo_root/scripts/run_watchos_ui_tests.sh"', orchestrator)
        self.assertIn("changed_tests_lane_requires_resolved_impact_scopes", orchestrator)

    def test_focused_lane_routes_scope_to_matching_apple_runner(self):
        orchestrator = (REPO / "scripts/quality_test.sh").read_text()

        self.assertIn('focused_lane_requires_single_platform', orchestrator)
        self.assertIn('focused_lane_invalid_apple_scope', orchestrator)
        self.assertIn('selected_claims+=("focused macOS UI: $focused_scopes")', orchestrator)
        self.assertIn('MACOS_SCOPE_SET=default', orchestrator)
        self.assertIn('"$repo_root/scripts/run_macos_ui_tests.sh"', orchestrator)
        self.assertIn('"$repo_root/scripts/run_ios_ui_tests.sh"', orchestrator)

    def test_message_ui_selects_real_pr_evidence(self):
        plan = self.plan("Apps/PushGo-iOS/UI/Screens/MessageListScreen.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertIn("messages", plan["impacted_capabilities"])
        self.assertIn("iOS accurate content/search/delete/relaunch UI journeys", plan["minimum_evidence"])
        self.assertIn("apple-ios-message-unavailable-route", plan["required_checks"])
        self.assertTrue(plan["manual_impact_review_required"])

    def test_search_ui_selects_exact_cross_platform_recovery_oracles(self):
        plan = self.plan("Apps/PushGo-iOS/UI/Screens/MessageSearchScreen.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertIn("search-filter", plan["impacted_capabilities"])
        self.assertEqual(
            {"apple-ios-message-search-recovery", "apple-macos-message-search-recovery"},
            set(plan["required_checks"]),
        )
        self.assertIn(
            "iOS and macOS failed search must not masquerade as empty or stale results; Retry reaches one exact canonical result and matching detail",
            plan["minimum_evidence"],
        )

    def test_shared_deletion_owner_selects_exact_restore_and_commit_lifecycles(self):
        plan = self.plan("Shared/Application/PendingLocalDeletionController.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertIn("delete-undo", plan["impacted_capabilities"])
        self.assertEqual(
            {
                "apple-ios-message-delete-undo",
                "apple-ios-message-delete-commit",
                "apple-macos-message-delete-lifecycle",
            },
            set(plan["required_checks"]),
        )

    def test_shared_store_expands_across_capabilities_and_escalates(self):
        plan = self.plan("Shared/Repositories/LocalDataStore.swift")

        self.assertEqual("pr", plan["recommended_lane"])
        self.assertTrue({"messages", "events", "things", "ingress-recovery"}.issubset(plan["impacted_capabilities"]))
        self.assertEqual(["apple-store-migration-reopen"], plan["required_checks"])
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
        self.assertIn("apple-preparation-contract", plan["required_checks"])

    def test_provider_route_notification_symbol_selects_notification_owner(self):
        path = "Shared/Application/ProviderRouteController.swift"
        plan = QUALITY_IMPACT.build_plan(
            [path],
            self.manifest,
            "working-tree",
            symbol_impacts={path: {"ensureProviderRoute"}},
        )

        self.assertIn("ingress-notification-background", plan["selected_rule_ids"])
        self.assertNotIn("channels-settings-shared-owner", plan["selected_rule_ids"])
        self.assertIn("notification-route-actions", plan["impacted_capabilities"])
        self.assertIn("apple-macos-system-notification", plan["required_checks"])

    def test_provider_route_gateway_symbol_selects_gateway_owner_without_notification_ui(self):
        path = "Shared/Application/ProviderRouteController.swift"
        plan = QUALITY_IMPACT.build_plan(
            [path],
            self.manifest,
            "working-tree",
            symbol_impacts={path: {"cleanupPreviousGatewayDeviceRoute"}},
        )

        self.assertIn("channels-settings-shared-owner", plan["selected_rule_ids"])
        self.assertNotIn("ingress-notification-background", plan["selected_rule_ids"])
        self.assertIn("gateway-settings", plan["impacted_capabilities"])
        self.assertIn("apple-ios-settings-positive-extension", plan["required_checks"])
        self.assertIn("apple-macos-settings-positive", plan["required_checks"])
        self.assertNotIn("apple-macos-system-notification", plan["required_checks"])

    def test_provider_route_cross_semantic_prepare_selects_both_owners(self):
        path = "Shared/Application/ProviderRouteController.swift"
        plan = QUALITY_IMPACT.build_plan(
            [path],
            self.manifest,
            "working-tree",
            symbol_impacts={path: {"prepareProviderRoute"}},
        )

        self.assertIn("channels-settings-shared-owner", plan["selected_rule_ids"])
        self.assertIn("ingress-notification-background", plan["selected_rule_ids"])

    def test_provider_route_persistence_dependency_cannot_skip_notification_owner(self):
        path = "Shared/Application/ProviderRouteController.swift"
        plan = QUALITY_IMPACT.build_plan(
            [path],
            self.manifest,
            "working-tree",
            symbol_impacts={path: {"persistProviderDeviceKey"}},
        )

        self.assertIn("channels-settings-shared-owner", plan["selected_rule_ids"])
        self.assertIn("ingress-notification-background", plan["selected_rule_ids"])
        self.assertIn("apple-macos-system-notification", plan["required_checks"])

    def test_provider_route_known_but_unmapped_helper_blocks_instead_of_silently_narrowing(self):
        path = "Shared/Application/ProviderRouteController.swift"
        plan = QUALITY_IMPACT.build_plan(
            [path],
            self.manifest,
            "working-tree",
            symbol_impacts={path: {"deviceKeySaveErrorDescription"}},
        )

        self.assertEqual("BLOCKED", plan["plan_status"])
        self.assertEqual([path], plan["unmapped_product_paths"])

    def test_provider_route_unscoped_symbol_change_widens_to_both_owners(self):
        path = "Shared/Application/ProviderRouteController.swift"
        plan = QUALITY_IMPACT.build_plan(
            [path],
            self.manifest,
            "working-tree",
            symbol_impacts={path: {"__unscoped__"}},
        )

        self.assertIn("channels-settings-shared-owner", plan["selected_rule_ids"])
        self.assertIn("ingress-notification-background", plan["selected_rule_ids"])

    def test_notification_owner_symbol_scope_does_not_filter_other_ingress_files(self):
        path = "Shared/Application/NotificationOpenController.swift"
        plan = QUALITY_IMPACT.build_plan(
            [path],
            self.manifest,
            "working-tree",
            symbol_impacts={path: {"openMessage"}},
        )

        self.assertIn("ingress-notification-background", plan["selected_rule_ids"])

    def test_preparation_surface_change_selects_the_dedicated_contract(self):
        plan = self.plan("Shared/UI/RootView.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertIn("apple-preparation-contract", plan["required_checks"])
        self.assertIn("app-owned-quality-runtime", plan["impacted_capabilities"])

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

    def test_read_only_ui_entrypoint_report_does_not_start_a_product_lane(self):
        for path in (
            "scripts/quality_ui_entrypoints.py",
            "scripts/tests/test_quality_ui_entrypoints.py",
        ):
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual("NOT_RUN", plan["plan_status"])
                self.assertEqual("not-run", plan["recommended_lane"])
                self.assertEqual(["quality-ui-entrypoint-discovery"], plan["selected_rule_ids"])
                self.assertIn("quality-gap-discovery", plan["impacted_capabilities"])
                self.assertNotIn("quality-system-trustworthiness", plan["impacted_capabilities"])

    def test_other_quality_reports_still_require_representative_product_evidence(self):
        plan = self.plan("scripts/quality_result.py")

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
        test_source = "\n".join(
            path.read_text()
            for path in sorted((REPO / "Tests/PushGo-macOSUITests").glob("*.swift"))
        )
        runner_source = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        orchestrator_source = (REPO / "scripts/quality_test.sh").read_text()
        discoverable = set(re.findall(r"^\s+func (test[A-Za-z0-9_]+)\(", test_source, re.MULTILINE))
        positive = self._macos_scopes(runner_source, "positive_scopes")
        risk = self._macos_scopes(runner_source, "risk_scopes")
        system = self._macos_scopes(runner_source, "system_scopes")
        preparation = self._macos_scopes(runner_source, "preparation_scopes")
        performance = self._macos_scopes(runner_source, "performance_scopes")
        performance_sensitivity = self._macos_scopes(
            runner_source,
            "performance_sensitivity_scopes",
        )

        self.assertEqual(34, len(discoverable))
        self.assertEqual(16, len(positive))
        self.assertEqual(13, len(risk))
        self.assertEqual(2, len(system))
        self.assertEqual(1, len(preparation))
        self.assertEqual(1, len(performance))
        self.assertEqual(1, len(performance_sensitivity))
        self.assertFalse(positive & risk)
        special = system | preparation | performance | performance_sensitivity
        self.assertFalse((positive | risk) & special)
        self.assertFalse(system & (preparation | performance | performance_sensitivity))
        self.assertFalse(preparation & (performance | performance_sensitivity))
        self.assertFalse(performance & performance_sensitivity)
        self.assertEqual(
            discoverable,
            positive | risk | special,
            "Every discoverable macOS journey must belong to the positive, risk, real-system, preparation, performance, or sensitivity set.",
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
        self.assertIn('performance)\n      scope_list=("${performance_scopes[@]}")', runner_source)
        self.assertIn('classification_issue_ids=.*apple-quality-precondition', runner_source)
        self.assertIn('reason=app_owned_quality_precondition_failed', runner_source)
        self.assertIn('runner_issue_file="${QUALITY_RUNNER_ISSUE_FILE:-}"', runner_source)
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
            "iOS and macOS prepared 1k Store launch-to-accurate-content purpose metrics and slow-load sensitivity controls",
            plan["minimum_evidence"],
        )

    def test_macos_performance_sources_select_performance_lane(self):
        for path in (
            "Tests/PushGo-macOSUITests/PushGo_macOSPerformanceTests.swift",
            "scripts/run_macos_performance_negative_control.sh",
        ):
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual("READY", plan["plan_status"])
                self.assertEqual("performance", plan["recommended_lane"])
                self.assertIn(
                    "performance-evidence-trustworthiness",
                    plan["impacted_capabilities"],
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
            "iOS Simulator real permission/delivery/hot-and-terminated-process tap/detail/read/relaunch journeys plus direct Mark as read and destructive Delete actions with durable canonical oracles",
            plan["minimum_evidence"],
        )
        self.assertNotIn("apple-macos-system-notification", plan["required_checks"])

    def test_macos_app_delegate_change_selects_only_macos_system_notification_supplement(self):
        plan = self.plan("Apps/PushGo-macOS/App/PushGoAppDelegate.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertIn("notification-route-actions", plan["impacted_capabilities"])
        self.assertEqual(["apple-macos-system-notification"], plan["required_checks"])
        self.assertNotIn(
            "iOS Simulator real system-notification journey for iOS/shared route changes",
            plan["minimum_evidence"],
        )

    def test_shared_notification_change_selects_both_platform_system_consumers(self):
        plan = self.plan("Shared/Application/NotificationActionCoordinator.swift")

        self.assertEqual("nightly", plan["recommended_lane"])
        self.assertIn("apple-macos-system-notification", plan["required_checks"])
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
        self.assertEqual(
            ["apple-ios-channel-positive", "apple-ios-channel-sheet-error-owner"],
            plan["required_checks"],
        )
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
        self.assertEqual(
            [
                "app-launch",
                "message-detail",
                "messages",
                "notification-route-actions",
                "primary-navigation",
            ],
            plan["impacted_capabilities"],
        )
        self.assertNotIn("mac-window-status-item", plan["impacted_capabilities"])
        self.assertEqual(["apple-ios-message-unavailable-route"], plan["required_checks"])

    def test_macos_main_tab_ui_uses_pr_dynamic_sidebar_evidence_without_window_risk(self):
        plan = self.plan("Apps/PushGo-macOS/UI/Screens/MainTabContainerView.swift")

        self.assertEqual("READY", plan["plan_status"])
        self.assertEqual("pr", plan["recommended_lane"])
        self.assertEqual(
            [
                "app-launch",
                "message-detail",
                "messages",
                "notification-route-actions",
                "primary-navigation",
            ],
            plan["impacted_capabilities"],
        )
        self.assertNotIn("mac-window-status-item", plan["impacted_capabilities"])
        self.assertIn("unread title/badge", " ".join(plan["minimum_evidence"]))
        self.assertEqual(["apple-macos-message-unavailable-route"], plan["required_checks"])

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
