import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class QualityLaneCostContractTests(unittest.TestCase):
    def test_event_close_convergence_reuses_one_existing_positive_journey_per_platform(self) -> None:
        quality_test = (REPO / "scripts/quality_test.sh").read_text()
        mac_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        ios_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        mac_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()
        ios_method = ios_source.split(
            "func testEventClosePersistsAndOngoingFilterReflectsRealProjection()", 1
        )[1].split("func testEventCloseFailureKeepsAccurateDetailBlocksDuplicateAndRetryPersists()", 1)[0]
        mac_method = mac_source.split(
            "func testEventDetailCloseAndRelaunchPreserveAccurateProjection()", 1
        )[1].split("func testEventCloseFailureKeepsAccurateDetailBlocksDuplicateAndRetryPersists()", 1)[0]

        self.assertEqual(
            1,
            quality_test.count("testEventClosePersistsAndOngoingFilterReflectsRealProjection"),
        )
        self.assertEqual(
            1,
            mac_runner.count("testEventDetailCloseAndRelaunchPreserveAccurateProjection"),
        )
        self.assertIn("Cancelling close must leave the canonical Event ongoing.", ios_method)
        self.assertIn("action.event.close.cancel", mac_method)
        for method in (ios_method, mac_method):
            self.assertIn("filter.events.ongoing", method)
            self.assertIn("thing.related.event.quality-event-active", method)
            self.assertIn("event.timeline.count.2", method)
            self.assertIn("field.event.detail.status.closed", method)
        self.assertIn("action.event.delete", mac_method)
        self.assertIn("P3 Event Control", mac_method)

    def test_apple_ui_runners_share_one_pushgo_local_nonblocking_host_lease(self) -> None:
        ios_runner = (REPO / "scripts/run_ios_ui_tests.sh").read_text()
        mac_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()

        for runner in (ios_runner, mac_runner):
            self.assertIn("build/.pushgo-apple-ui-tests.lock", runner)
            self.assertIn("/usr/bin/lockf -s -t 0 9", runner)
            self.assertIn("reason=pushgo_apple_ui_lease_busy", runner)
            self.assertNotIn("killall Simulator", runner)
            self.assertNotIn("killall CoreSimulator", runner)

    def test_high_unread_navigation_reuses_both_core_positive_journeys(self) -> None:
        quality_test = (REPO / "scripts/quality_test.sh").read_text()
        mac_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        runtime = (REPO / "Shared/UI/AutomationRuntime.swift").read_text()
        ios_test = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        mac_test = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()

        self.assertIn("(1..<100).map { qualityHighUnreadNavigationMessage(index: $0) }", runtime)
        self.assertIn('message["received_at"] = "2025-12-31T00:00:00Z"', runtime)
        self.assertEqual(1, quality_test.count("testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen"))
        self.assertEqual(1, mac_runner.count("testSidebarNavigationCoversPrimaryScreens"))
        self.assertIn('messagesTab.value as? String,\n            "99+"', ios_test)
        self.assertIn('unreadBadge.value as? String,\n            "99+"', mac_test)

    def test_macos_minimize_restore_reuses_the_existing_window_journey(self) -> None:
        runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        ui_test = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()

        self.assertEqual(
            1,
            runner.count(
                "testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow"
            ),
        )
        method = ui_test.split(
            "func testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow()",
            1,
        )[1].split("\n    @MainActor", 1)[0]
        self.assertIn("XCUIIdentifierMinimizeWindow", method)
        self.assertIn("Minimize and restore must preserve the same App-owned session", method)
        self.assertIn("Restoring a minimized main window must not create a duplicate window", method)
        minimize_restore = method.split("XCUIIdentifierMinimizeWindow", 1)[1].split(
            'identifier: "action.messages.refresh"', 1
        )[0]
        self.assertIn("minimizedStatusItem.click()", minimize_restore)
        self.assertNotIn("minimizedStatusItem.rightClick()", minimize_restore)
        self.assertIn("XCUIIdentifierCloseWindow", method)
        self.assertIn("Open main window", method)

    def test_ios_slow_load_performance_negative_control_reuses_positive_build(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        ui_runner = (REPO / "scripts/run_ios_ui_tests.sh").read_text()
        control = (REPO / "scripts/run_ios_performance_negative_control.sh").read_text()
        performance = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSPerformanceTests.swift").read_text()

        performance_function = runner.split("run_performance() {", 1)[1].split("\n}", 1)[0]
        self.assertEqual(1, performance_function.count("run_ios_performance_negative_control.sh"))
        self.assertLess(
            performance_function.index('claims+=("iOS prepared 1k Store'),
            performance_function.index("run_ios_performance_negative_control.sh"),
        )
        self.assertIn("QUALITY_REUSE_BUILT_TESTS=1", performance_function)
        self.assertIn("func testSlowLargeMessageLoadTripsAccurateContentBudget()", performance)
        self.assertIn("messageLoadDelayMilliseconds: 8_000", performance)
        self.assertIn("XCTExpectedFailure.Options()", performance)
        self.assertIn("expectationOptions.isStrict = true", performance)
        self.assertIn("expectationOptions.issueMatcher", performance)
        self.assertIn("budget=8000ms", performance)
        self.assertIn("QUALITY_REUSE_BUILT_TESTS", ui_runner)
        self.assertIn("QUALITY_ALLOW_EXPECTED_FAILURES", ui_runner)
        self.assertIn("ios_reusable_built_tests_missing", ui_runner)
        self.assertIn("QUALITY_ALLOW_EXPECTED_FAILURES=1", control)
        self.assertIn('"product_status": "NOT_RUN"', control)
        self.assertIn('"test_system_status": "PASSED"', control)
        self.assertIn("launch-to-accurate-content took", control)
        self.assertNotIn("sleep ", control)
        self.assertRegex(
            runner,
            r'elif \[\[ \$status -eq 4 \]\]; then\n'
            r'\s+write_result NOT_RUN FAILED "a required test-system sensitivity control',
        )

    def test_ios_data_field_negative_control_reuses_the_same_positive_build(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        ui_runner = (REPO / "scripts/run_ios_ui_tests.sh").read_text()
        control = (REPO / "scripts/run_ios_data_field_negative_control.sh").read_text()
        performance = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSPerformanceTests.swift").read_text()

        performance_function = runner.split("run_performance() {", 1)[1].split("\n}", 1)[0]
        self.assertEqual(1, performance_function.count("run_ios_data_field_negative_control.sh"))
        self.assertLess(
            performance_function.index('claims+=("iOS prepared 1k Store'),
            performance_function.index("run_ios_data_field_negative_control.sh"),
        )
        self.assertIn("QUALITY_REUSE_BUILT_TESTS=1", performance_function)
        self.assertIn("func testLargeMessageDataFieldOracleRejectsWrongCanonicalBody()", performance)
        self.assertIn("XCTExpectedFailure.Options()", performance)
        self.assertIn("expectationOptions.isStrict = true", performance)
        self.assertIn("expectationOptions.issueMatcher", performance)
        self.assertIn("Deliberately wrong canonical body 999.", performance)
        self.assertIn("QUALITY_REUSE_BUILT_TESTS", ui_runner)
        self.assertIn("QUALITY_ALLOW_EXPECTED_FAILURES=1", control)
        self.assertIn('"product_status": "NOT_RUN"', control)
        self.assertIn('"test_system_status": "PASSED"', control)
        self.assertNotIn("sleep ", control)

    def test_changed_runner_help_exits_before_tests_or_stale_lane_selection(self) -> None:
        runner = (REPO / "scripts/quality_changed.sh").read_text()

        help_guard = runner.index('if [[ "${1:-}" == "-h"')
        script_tests = runner.index("python3 -m unittest discover")
        lane_execution = runner.index('exec "$repo_root/scripts/quality_test.sh"')
        self.assertLess(help_guard, script_tests)
        self.assertLess(help_guard, lane_execution)

    def test_changed_runner_reads_the_same_fresh_plan_path_it_writes(self) -> None:
        runner = (REPO / "scripts/quality_changed.sh").read_text()

        self.assertIn('impact_args=("$@")', runner)
        self.assertIn('impact_file="${impact_args[$((index + 1))]}"', runner)
        self.assertIn('impact_file="${argument#--output=}"', runner)
        self.assertIn('impact_args+=(--output "$impact_file")', runner)
        self.assertIn(
            'python3 "$repo_root/scripts/quality_impact.py" "${impact_args[@]}" --check',
            runner,
        )
        self.assertIn(
            'json.load(open(sys.argv[1]))["recommended_lane"]',
            runner,
        )

    def test_ci_receipts_outlive_the_full_observation_window(self) -> None:
        workflow = (REPO / ".github/workflows/apple-quality.yml").read_text()
        receipt_upload = workflow.split("- name: Upload compact longitudinal receipts", 1)[1]

        self.assertIn("if-no-files-found: error", receipt_upload)
        self.assertIn("retention-days: 21", receipt_upload)
        self.assertIn("path: build/quality-results/*-summary.json", receipt_upload)
        self.assertNotIn("**/*.xcresult", receipt_upload)
        diagnostic_upload = workflow.split("- name: Upload diagnostic evidence", 1)[1].split(
            "- name: Upload compact longitudinal receipts", 1
        )[0]
        self.assertIn("retention-days: 14", diagnostic_upload)
        self.assertIn("!build/quality-results/*-summary.json", diagnostic_upload)
        global_permissions = workflow.split("permissions:", 1)[1].split("concurrency:", 1)[0]
        self.assertNotIn("actions: read", global_permissions)
        observation_job = workflow.split("\n  observation:\n", 1)[1]
        self.assertIn("github.event.schedule == '17 18 * * *'", observation_job)
        self.assertIn("needs: quality", observation_job)
        self.assertIn("actions: read", observation_job)
        self.assertIn("quality_observation_collect.py", observation_job)
        self.assertIn("--workflow apple-quality.yml", observation_job)
        self.assertIn("quality_observation.py", observation_job)
        self.assertNotIn("--require-ready", observation_job)
        self.assertIn("if-no-files-found: error", observation_job)

    def test_pr_ui_is_unique_discoverable_positive_breadth(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        test_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        discovered = set(re.findall(r"func (test[A-Za-z0-9_]+)\s*\(", test_source))
        scopes = self._scopes(runner, "pr_ui_scopes")
        extended_positive = self._scopes(runner, "extended_positive_ui_scopes")
        nightly_scopes = self._scopes(runner, "nightly_negative_ui_scopes")

        self.assertEqual(len(scopes), len(set(scopes)))
        self.assertLessEqual(len(scopes), 4)
        self.assertEqual(13, len(scopes + extended_positive))
        all_curated = scopes + extended_positive + nightly_scopes
        self.assertEqual(len(all_curated), len(set(all_curated)))
        self.assertFalse([scope for scope in all_curated if scope.rsplit("/", 1)[-1] not in discovered])
        for required_fragment in ("PrimaryNavigation", "StandardMessages", "MessageWorkflow", "SettingsServer"):
            self.assertTrue(any(required_fragment in scope for scope in scopes), required_fragment)
        for required_fragment in ("EventClosePersists", "Thing", "Channel", "PageVisibility"):
            self.assertTrue(any(required_fragment in scope for scope in extended_positive), required_fragment)
        for deferred_fragment in ("Failure", "Corrupt", "Slow", "Delete"):
            self.assertFalse(any(deferred_fragment in scope for scope in scopes), deferred_fragment)
        self.assertTrue(
            any("RejectsInvalidAndUnregisteredCandidates" in scope for scope in nightly_scopes)
        )
        self.assertFalse(any("FunctionalEmptyState" in scope for scope in scopes))
        self.assertFalse(any("MessageSearchReturnsOnly" in scope for scope in scopes))
        self.assertEqual(1, test_source.count("messageSearchDelayMilliseconds: 2_000"))
        self.assertEqual(
            1,
            test_source.count('assertElementExists("state.messages.search.loading"'),
        )
        self.assertIn('positive_ui_scopes="$pr_ui_scopes,$extended_positive_ui_scopes"', runner)
        self.assertIn('nightly_ui_scopes="$positive_ui_scopes,$nightly_negative_ui_scopes"', runner)
        ios_positive_body = runner.split("  ios-positive)\n", 1)[1].split("    ;;", 1)[0]
        self.assertEqual(1, ios_positive_body.count("run_ios_positive"))
        self.assertNotIn("nightly_negative_ui_scopes", ios_positive_body)
        positive_function = runner.split("run_ios_positive() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('TEST_SCOPES="$positive_ui_scopes"', positive_function)
        self.assertIn("MAX_RETRIES=0", positive_function)
        self.assertLess(
            runner.index('TEST_SCOPES="$positive_ui_scopes"'),
            runner.index('TEST_SCOPES="$nightly_negative_ui_scopes"'),
            "Nightly/Release must finish positive journeys before fault injection.",
        )
        self.assertIn(
            'selected_claims+=("iOS explicitly selected UI journeys: $requested_scopes")',
            runner,
        )
        self.assertIn(
            'claims+=("iOS explicitly selected UI journeys: $requested_scopes")',
            runner,
        )
        self.assertIn(
            'macos_pr_ui_scope="PushGo-macOSUITests/PushGo_macOSUITests/testSidebarNavigationCoversPrimaryScreens"',
            runner,
        )
        pr_body = runner.split("  pr)\n", 1)[1].split("    ;;", 1)[0]
        self.assertEqual(1, pr_body.count('TEST_SCOPES="$macos_pr_ui_scope" run_macos_ui positive'))

    def test_primary_navigation_ui_reuses_existing_cross_platform_pr_oracles(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        pr_scopes = self._scopes(runner, "pr_ui_scopes")
        ios_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        macos_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()
        ios_journey = ios_source.split(
            "func testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen()", 1
        )[1].split("func testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch()", 1)[0]
        macos_journey = macos_source.split(
            "func testSidebarNavigationCoversPrimaryScreens()", 1
        )[1].split("func testEventDetailCloseAndRelaunchPreserveAccurateProjection()", 1)[0]

        self.assertEqual(
            1,
            sum(
                "testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen" in scope
                for scope in pr_scopes
            ),
        )
        self.assertEqual(
            1,
            runner.count(
                'macos_pr_ui_scope="PushGo-macOSUITests/PushGo_macOSUITests/'
                'testSidebarNavigationCoversPrimaryScreens"'
            ),
        )
        for journey in (ios_journey, macos_journey):
            self.assertIn("pushgo://open?kind=event&id=quality-event-active", journey)
            self.assertIn("Event fixture for app-owned UI validation.", journey)
            self.assertIn("pushgo://open?kind=thing&id=quality-thing-rich", journey)
            self.assertIn("Fixture thing summary", journey)
            self.assertNotIn("pushgo://open?kind=event&id=list", journey)
            self.assertNotIn("pushgo://open?kind=thing&id=list", journey)

    def test_pr_message_and_gateway_journeys_keep_positive_oracles_without_negative_cost(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        test_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        runtime = (REPO / "Shared/UI/AutomationRuntime.swift").read_text()
        badge_helper = test_source.split(
            "private func assertMessagesTabBadgeCount(", 1
        )[1].split("private func messagesTabBadgeCount(", 1)[0]
        positive_gateway = test_source.split(
            "func testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch()", 1
        )[1].split(
            "func testSettingsServerRejectsInvalidAndUnregisteredCandidatesWithoutLeakingSheetError()",
            1,
        )[0]

        self.assertIn("messages = (0..<52).map(qualityWorkflowFixtureMessage)", runtime)
        self.assertNotIn("messages = (0..<125).map(qualityWorkflowFixtureMessage)", runtime)
        self.assertIn("let tabBar = app.tabBars.firstMatch", badge_helper)
        self.assertIn("tabBar.buttons.element(boundBy: 0)", badge_helper)
        self.assertIn('["Messages", "消息", "訊息"]', badge_helper)
        self.assertNotIn('let messagesTab = app.buttons["tab.messages"]', badge_helper)
        self.assertNotIn("failGatewaySwitchValidationOnce", positive_gateway)
        self.assertNotIn("not a valid url", positive_gateway)
        self.assertTrue(
            any(
                scope.endswith(
                    "/testSettingsServerRejectsInvalidAndUnregisteredCandidatesWithoutLeakingSheetError"
                )
                for scope in self._scopes(runner, "nightly_negative_ui_scopes")
            )
        )

    def test_real_macos_update_install_is_release_or_focused_only(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        update_runner = (REPO / "scripts/run_macos_update_install_test.sh").read_text()

        self.assertIn("macos-update-install)\n    run_macos_update_install", runner)
        release_body = runner.split("  release)\n", 1)[1].split("  *)\n", 1)[0]
        self.assertEqual(1, release_body.count("run_macos_update_install"))
        for lane in ("pr", "nightly", "macos"):
            body = runner.split(f"  {lane})\n", 1)[1].split("    ;;", 1)[0]
            self.assertNotIn("run_macos_update_install", body)

        self.assertEqual(1, update_runner.count('click-identifier "$bundle_id" action.settings.check_for_updates'))
        self.assertEqual(1, update_runner.count('"Install Update" "安装更新" "安裝更新"'))
        self.assertIn('"business_retries": 0', update_runner)

    def test_real_macos_system_notification_is_release_or_focused_only(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        macos_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        macos_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()

        self.assertIn("macos-system-notification)\n    run_macos_system_notification", runner)
        release_body = runner.split("  release)\n", 1)[1].split("  *)\n", 1)[0]
        self.assertEqual(1, release_body.count("run_macos_system_notification"))
        for lane in ("pr", "nightly", "macos"):
            body = runner.split(f"  {lane})\n", 1)[1].split("    ;;", 1)[0]
            self.assertNotIn("run_macos_system_notification", body)

        system = self._array_scopes(macos_runner, "system_scopes")
        self.assertEqual(
            [
                "PushGo-macOSUITests/PushGo_macOSUITests/"
                "testSystemNotificationClickPersistsAccurateMessageAndSurvivesRelaunch"
            ],
            system,
        )
        self.assertIn("MAX_RETRIES=0", runner.split("run_macos_system_notification() {", 1)[1].split("\n}", 1)[0])
        authorization = macos_source.split(
            "private func resolveMacNotificationAuthorizationIfNeeded",
            1,
        )[1].split("\n    @MainActor", 1)[0]
        self.assertIn('identifier: "quality-runtime.ready"', authorization)
        self.assertIn('identifier: "quality-command.succeeded"', authorization)
        self.assertIn('identifier: "quality-command.failed"', authorization)
        self.assertIn("while Date() < deadline", authorization)
        self.assertNotIn("alert.waitForExistence(timeout: 2)", authorization)

    def test_macos_preparation_calibration_is_not_charged_to_ordinary_batches(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        macos_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()

        preparation = self._array_scopes(macos_runner, "preparation_scopes")
        self.assertEqual(
            [
                "PushGo-macOSUITests/PushGo_macOSUITests/"
                "testInvalidQualitySessionStopsBeforeBusinessUIWithinTenSeconds"
            ],
            preparation,
        )
        self.assertIn("preparation)\n    run_preparation_contract", runner)
        for variable in ("positive_scopes", "risk_scopes", "system_scopes"):
            self.assertNotIn(preparation[0], self._array_scopes(macos_runner, variable))

    def test_channel_ui_impact_checks_run_one_platform_owner_journey(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()

        self.assertEqual(1, runner.count("apple-ios-channel-positive)"))
        self.assertEqual(1, runner.count("apple-macos-channel-positive)"))
        self.assertEqual(
            1,
            runner.count(
                'TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/'
                'testChannelCreateRenameAndBothUnsubscribeOutcomesPersist"'
            ),
        )
        self.assertEqual(
            1,
            runner.count(
                'TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/'
                'testUnreadBadgeAndChannelLifecyclePersistThroughRealUserActions"'
            ),
        )

    def test_settings_ui_impact_checks_reuse_minimum_platform_purpose_journeys(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        ios_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        macos_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()

        self.assertEqual(1, runner.count("apple-ios-settings-positive-extension)"))
        self.assertEqual(1, runner.count("apple-macos-settings-positive)"))
        self.assertEqual(
            1,
            runner.count(
                'TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/'
                'testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch,'
                'PushGo-iOSUITests/PushGo_iOSUITests/'
                'testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch"'
            ),
        )
        self.assertEqual(
            1,
            runner.count(
                'TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/'
                'testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch,'
                'PushGo-macOSUITests/PushGo_macOSUITests/'
                'testGatewayCandidateMustRegisterBeforeCommitAndPersistsAfterRelaunch,'
                'PushGo-macOSUITests/PushGo_macOSUITests/'
                'testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey"'
            ),
        )
        self.assertNotIn(
            "testGatewayLocalCommitFailureRollsBackBeforeRetryCommits",
            runner.split("apple-macos-settings-positive)", 1)[1].split(";;", 1)[0],
        )
        ios_visibility = ios_source.split(
            "func testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch()",
            1,
        )[1].split("\n    func test", 1)[0]
        macos_visibility = macos_source.split(
            "func testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch()",
            1,
        )[1].split("\n    @MainActor\n    func ", 1)[0]
        macos_gateway_positive = macos_source.split(
            "func testGatewayCandidateMustRegisterBeforeCommitAndPersistsAfterRelaunch()",
            1,
        )[1].split("\n    @MainActor\n    func ", 1)[0]
        macos_gateway_risk = macos_source.split(
            "func testInvalidServerAddressShowsInlineFeedbackInsteadOfToast()",
            1,
        )[1].split("\n    @MainActor\n    func ", 1)[0]
        ios_visibility_oracle = ios_source.split(
            "private func assertDataTabVisibility(",
            1,
        )[1].split("\n    private func ", 1)[0]
        for body in (ios_visibility, macos_visibility):
            self.assertIn('"toggle.settings.page.messages"', body)
        self.assertIn("messagesVisible: false", ios_visibility)
        self.assertIn("messagesVisible: true", ios_visibility)
        self.assertIn('"P2 Split Seed Message"', ios_visibility_oracle)
        self.assertIn('"P2 Split Seed Message"', macos_visibility)
        self.assertNotIn("failGatewaySwitchValidationOnce: true", macos_gateway_positive)
        self.assertIn("failGatewaySwitchValidationOnce: true", macos_gateway_risk)
        self.assertIn("invalidAddressFeedback", macos_gateway_risk)
        self.assertIn('predicate: NSPredicate(format: "label != %@"', macos_gateway_risk)
        self.assertIn("A rejected candidate must not replace", macos_gateway_risk)

    def test_shared_form_impact_uses_one_accessibility_and_one_macos_batch(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        ios_body = runner.split("apple-ios-shared-form-accessibility)", 1)[1].split(";;", 1)[0]
        macos_body = runner.split("apple-macos-shared-form-purpose)", 1)[1].split(";;", 1)[0]

        self.assertEqual(1, runner.count("apple-ios-shared-form-accessibility)"))
        self.assertEqual(1, runner.count("apple-macos-shared-form-purpose)"))
        self.assertEqual(
            1,
            ios_body.count(
                "testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation"
            ),
        )
        self.assertEqual(1, macos_body.count("testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch"))
        self.assertEqual(1, macos_body.count("testInvalidServerAddressShowsInlineFeedbackInsteadOfToast"))
        for deferred in (
            "GatewayLocalCommitFailure",
            "DecryptionProtectedStoreFailure",
            "CorruptEncryptedMessage",
            "ChannelCreateLocalFailure",
        ):
            self.assertNotIn(deferred, ios_body + macos_body)

    def test_shared_image_preview_reuses_ios_pr_and_adds_only_one_macos_scope(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        ios_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        macos_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()
        runtime = (REPO / "Shared/UI/AutomationRuntime.swift").read_text()
        handler = runner.split("apple-macos-shared-image-preview-positive)", 1)[1].split(";;", 1)[0]
        standard = "testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch"
        ios_standard_body = ios_source.split("func " + standard + "()", 1)[1].split("\n    func ", 1)[0]
        macos_standard_body = macos_source.split("func " + standard + "()", 1)[1].split(
            "\n    @MainActor", 1
        )[0]

        self.assertEqual(1, runner.count("apple-macos-shared-image-preview-positive)"))
        self.assertEqual(1, handler.count(standard))
        self.assertTrue(
            any(scope.endswith("/" + standard) for scope in self._scopes(runner, "pr_ui_scopes"))
        )
        for deferred in ("Failure", "Corrupt", "WrongKey", "Undo", "LocalCommitFailure"):
            self.assertNotIn(deferred, handler)
        self.assertIn('identifier: "action.message.copy_metadata_value.0"', macos_standard_body)
        self.assertIn('identifier: "action.message.copy_link"', macos_standard_body)
        self.assertIn('"quality-fixture"', macos_standard_body)
        self.assertIn('"https://pushgo.dev/quality-message"', macos_standard_body)
        self.assertIn('identifier: "action.message.open_link"', ios_standard_body)
        self.assertIn('bundleIdentifier: "com.apple.mobilesafari"', ios_standard_body)
        self.assertIn('"pushgo.dev/quality-message"', ios_standard_body)
        self.assertIn('assertElementExists("sheet.message.detail"', ios_standard_body)
        self.assertIn('rawPayload["metadata"] = ["environment": "quality-fixture"]', runtime)
        self.assertIn('message["url"] = "https://pushgo.dev/quality-message"', runtime)

    def _scopes(self, source: str, variable: str) -> list[str]:
        match = re.search(rf'^{variable}="([^"]+)"$', source, re.MULTILINE)
        self.assertIsNotNone(match, variable)
        return match.group(1).split(",")

    def _array_scopes(self, source: str, variable: str) -> list[str]:
        match = re.search(rf"^{variable}=\((.*?)^\)", source, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, variable)
        return re.findall(r'"(PushGo-macOSUITests/[^\"]+)"', match.group(1))


if __name__ == "__main__":
    unittest.main()
