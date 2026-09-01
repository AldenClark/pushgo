import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class QualityLaneCostContractTests(unittest.TestCase):
    def test_apple_runners_do_not_silently_promote_native_runtime_warnings(self) -> None:
        for runner_name in (
            "run_ios_ui_tests.sh",
            "run_macos_ui_tests.sh",
            "run_ios_system_notification_test.sh",
        ):
            with self.subTest(runner=runner_name):
                runner = (REPO / "scripts" / runner_name).read_text()
                self.assertIn("--reject-runtime-warnings", runner)
                self.assertIn("registered_apple_runtime_warning", runner)
                self.assertIn("unknown_apple_runtime_warning", runner)
                self.assertIn("status=FLAKY", runner)

    def test_macos_ui_text_entry_uses_the_real_paste_command_not_xctest_typing(self) -> None:
        source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()

        self.assertNotIn(".typeText(", source)
        self.assertIn("field.typeKey(\"v\", modifierFlags: .command)", source)

    def test_search_recovery_impact_checks_run_only_the_exact_user_journeys(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()

        checks = {
            "apple-ios-message-search-recovery": (
                "PushGo-iOSUITests/PushGo_iOSUITests/"
                "testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail"
            ),
            "apple-macos-message-search-recovery": (
                "PushGo-macOSUITests/PushGo_macOSUITests/"
                "testMessageSearchFailureShowsOwnedRetryAndRecoversToExactDetail"
            ),
        }
        for check, scope in checks.items():
            with self.subTest(check=check):
                body = runner.split(f"      {check})", 1)[1].split("        ;;", 1)[0]
                self.assertIn(scope, body)
                self.assertIn("MAX_RETRIES=0", body)
                self.assertNotIn("nightly_negative_ui_scopes", body)

    def test_ios_performance_lane_persists_user_outcome_metrics_from_xcresult(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        extractor = (REPO / "scripts/extract_ios_performance_evidence.py").read_text()
        performance_function = runner.split("run_performance() {", 1)[1].split("\n}", 1)[0]

        self.assertIn("apple-ios-performance-runner.log", performance_function)
        self.assertIn("ios_performance_result_bundle_missing", performance_function)
        self.assertIn("extract_ios_performance_evidence.py", performance_function)
        self.assertIn("apple-ios-performance-evidence.json", performance_function)
        self.assertIn("testPreparedLargeMessageStoreColdLaunchReachesAccurateContent", extractor)
        self.assertIn("simulator_launch_to_accurate_content_seconds", extractor)
        self.assertIn("matching detail", extractor)
        self.assertIn('"simulator_only": True', extractor)
        self.assertIn('"physical_release_baseline": "NOT_RUN"', extractor)

    def test_entity_tab_reselection_reuses_existing_positive_journeys(self) -> None:
        runtime = (REPO / "Shared/UI/AutomationRuntime.swift").read_text()
        source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        event_method = source.split(
            "func testEventClosePersistsAndOngoingFilterReflectsRealProjection()", 1
        )[1].split(
            "func testEventCloseFailureKeepsAccurateDetailBlocksDuplicateAndRetryPersists()", 1
        )[0]
        thing_method = source.split(
            "func testThingLifecycleFiltersRelationsAndUnavailableTargetFallback()", 1
        )[1].split("\n    @MainActor", 1)[0]

        self.assertEqual(1, source.count("func testEventClosePersistsAndOngoingFilterReflectsRealProjection()"))
        self.assertEqual(1, source.count("func testThingLifecycleFiltersRelationsAndUnavailableTargetFallback()"))
        self.assertEqual(2, runtime.count("(0..<16).map(quality"))
        self.assertIn('identifier: "event.row.quality-event-navigation-08"', event_method)
        self.assertIn('identifier: "thing.row.quality-thing-navigation-08"', thing_method)
        for method, top_row in (
            (event_method, "event.row.quality-event-active"),
            (thing_method, "thing.row.quality-thing-rich"),
        ):
            self.assertIn("collapsed", method)
            self.assertIn(".doubleTap()", method)
            self.assertIn(top_row, method)
            self.assertIn("must actually leave its off-top control position", method)

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
        ios_system_notification_runner = (
            REPO / "scripts/run_ios_system_notification_test.sh"
        ).read_text()

        for runner in (ios_runner, mac_runner, ios_system_notification_runner):
            self.assertIn("build/.pushgo-apple-ui-tests.lock", runner)
            self.assertIn("/usr/bin/lockf -s -t 0 9", runner)
            self.assertIn("reason=pushgo_apple_ui_lease_busy", runner)
            self.assertIn("-parallel-testing-enabled NO", runner)
            self.assertIn("-maximum-parallel-testing-workers 1", runner)
            self.assertIn("-collect-test-diagnostics never", runner)
            self.assertNotIn("killall Simulator", runner)
            self.assertNotIn("killall CoreSimulator", runner)

    def test_apple_ui_runner_background_helpers_do_not_retain_shared_lease(self) -> None:
        ios_runner = (REPO / "scripts/run_ios_ui_tests.sh").read_text()
        mac_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()

        # The host lease is held by descriptor 9. Background cleanup/keep-awake
        # helpers must close that descriptor so a sequential lane can hand the
        # lease to the next Apple runner immediately after the current runner
        # exits.
        expected_watcher = (
            '"$problem_reporter_cleaner" --watch-pid "$$" \\\n'
            '  >>"$problem_reporter_monitor_log" 2>&1 9>&- &'
        )
        self.assertIn(expected_watcher, ios_runner)
        self.assertIn(") 9>&- &", ios_runner)
        self.assertIn("/usr/bin/caffeinate -dimsu -w $$ 9>&- &", mac_runner)
        self.assertIn(expected_watcher, mac_runner)

    def test_ios_channel_copy_reuses_existing_lifecycle_and_external_system_oracle(self) -> None:
        ios_runner = (REPO / "scripts/run_ios_ui_tests.sh").read_text()
        ios_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        method_name = "testChannelCreateRenameAndBothUnsubscribeOutcomesPersist"
        method = ios_source.split(f"func {method_name}()", 1)[1].split(
            "func testChannelRemoteRejectionStaysInSheetAndRetryPersists()", 1
        )[0]

        self.assertEqual(1, ios_source.count(f"func {method_name}()"))
        self.assertIn('let copiedChannelID = "01H00000000000000000000003"', method)
        self.assertIn("tapWhenHittable(\n            createdRow", method)
        self.assertNotIn("waitForExistence(timeout: 5)", method.split("let copiedChannelID", 1)[1])
        self.assertIn(f'channel_copy_scope="PushGo-iOSUITests/PushGo_iOSUITests/{method_name}"', ios_runner)
        self.assertIn('xcrun simctl pbcopy "$target"', ios_runner)
        self.assertIn('xcrun simctl pbpaste "$target"', ios_runner)
        self.assertIn('external_pasteboard_oracle=PASSED', ios_runner)
        self.assertNotIn("func testChannelCopy", ios_source)

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

    def test_macos_large_window_reuses_existing_primary_navigation_journey(self) -> None:
        mac_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        mac_test = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()

        self.assertEqual(1, mac_runner.count("testSidebarNavigationCoversPrimaryScreens"))
        self.assertEqual(1, mac_test.count("func testSidebarNavigationCoversPrimaryScreens()"))
        journey = mac_test.split(
            "func testSidebarNavigationCoversPrimaryScreens()", 1
        )[1].split("func testEventDetailCloseAndRelaunchPreserveAccurateProjection()", 1)[0]
        large_window = journey.split("let largeWindowFrame", 1)[1]

        self.assertIn("requestedSize: CGSize(width: 1_360, height: 840)", journey)
        self.assertEqual(1, journey.count("configuredQualityApp("))
        self.assertEqual(1, journey.count("launchQuality("))
        self.assertIn("largeWindowFrame.width", large_window)
        self.assertIn("minimumWindowFrame.width + 250", large_window)
        self.assertIn('unreadBadge.value as? String, "99+"', large_window)
        self.assertIn("unreadBadge.frame.minX", large_window)
        self.assertIn("Persisted through the provider refresh ingress path.", large_window)
        self.assertIn('identifier: "action.message.delete"', large_window)
        self.assertNotIn('openSidebarTab("events", in: context.app)', large_window)

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
        self.assertIn('openSidebarTab("messages", in: context.app)', method)
        self.assertIn("let keyboardDestinations = [", method)
        self.assertIn('"screen.events.list"', method)
        self.assertIn('"screen.things.list"', method)
        self.assertIn('"screen.channels"', method)
        self.assertIn('"screen.settings"', method)
        self.assertIn("context.app.typeKey(.downArrow", method)
        self.assertIn("context.app.typeKey(.upArrow", method)
        self.assertIn("Keyboard navigation must return to the same accurate canonical Messages content", method)
        self.assertIn('context.app.menuItems["Quit application"]', method)
        self.assertIn("XCUIApplication.State.notRunning.rawValue", method)
        self.assertIn('$0.bundleIdentifier == "io.ethan.pushgo"', method)
        self.assertIn("survivingPushGoProcesses.isEmpty", method)
        self.assertNotIn("context.app.windows.count", method.split("let terminated", 1)[1])
        self.assertIn("A normal status-item Quit must not leave a crash dialog", method)

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

    def test_macos_performance_is_weekly_release_only_and_checks_accurate_content(self) -> None:
        orchestrator = (REPO / "scripts/quality_test.sh").read_text()
        macos_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        macos_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSPerformanceTests.swift").read_text()

        performance_scope = (
            "PushGo-macOSUITests/PushGo_macOSUITests/"
            "testPreparedLargeMessageStoreColdLaunchReachesAccurateContent"
        )
        self.assertIn(f'macos_performance_ui_scope="{performance_scope}"', orchestrator)
        performance_function = orchestrator.split("run_performance() {", 1)[1].split("\n}", 1)[0]
        self.assertEqual(1, performance_function.count('TEST_SCOPES="$macos_performance_ui_scope"'))
        for lane in ("pr", "nightly", "macos"):
            lane_body = orchestrator.split(f"  {lane})\n", 1)[1].split("    ;;", 1)[0]
            self.assertNotIn("macos_performance_ui_scope", lane_body)
        self.assertIn(f'"{performance_scope}"', macos_runner)
        self.assertNotIn(performance_scope, self._array_scopes(macos_runner, "positive_scopes"))
        self.assertNotIn(performance_scope, self._array_scopes(macos_runner, "risk_scopes"))

        method = macos_source.split(
            "func testPreparedLargeMessageStoreColdLaunchReachesAccurateContent()",
            1,
        )[1].split("\n    @MainActor", 1)[0]
        self.assertIn('fixture: "messages.large"', method)
        self.assertIn("options.iterationCount = 5", method)
        self.assertIn("XCTApplicationLaunchMetric", method)
        self.assertIn('identifier: "message.row.00000000-0000-0000-0000-0000000003e8"', method)
        self.assertIn('exactRow.label.contains("Quality message 999")', method)
        self.assertIn('staticTexts["Deterministic app-owned performance fixture row 999."]', method)
        self.assertIn("XCTAssertLessThanOrEqual", method)
        self.assertNotIn("sleep(", method)

    def test_macos_slow_load_negative_control_reuses_positive_build(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        ui_runner = (REPO / "scripts/run_macos_ui_tests.sh").read_text()
        control = (REPO / "scripts/run_macos_performance_negative_control.sh").read_text()
        performance = (
            REPO / "Tests/PushGo-macOSUITests/PushGo_macOSPerformanceTests.swift"
        ).read_text()

        performance_function = runner.split("run_performance() {", 1)[1].split("\n}", 1)[0]
        self.assertEqual(
            1,
            performance_function.count("run_macos_performance_negative_control.sh"),
        )
        self.assertLess(
            performance_function.index('claims+=("macOS prepared 1k Store'),
            performance_function.index("run_macos_performance_negative_control.sh"),
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
        self.assertIn("macos_reusable_built_tests_missing", ui_runner)
        sensitivity_scope = (
            "PushGo-macOSUITests/PushGo_macOSUITests/"
            "testSlowLargeMessageLoadTripsAccurateContentBudget"
        )
        self.assertEqual(
            [sensitivity_scope],
            self._array_scopes(ui_runner, "performance_sensitivity_scopes"),
        )
        self.assertIn(
            'macos_expected_failures_require_exact_sensitivity_scope',
            ui_runner,
        )
        self.assertIn(f'performance_scope="{sensitivity_scope}"', control)
        self.assertIn("QUALITY_ALLOW_EXPECTED_FAILURES=1", control)
        self.assertIn('"product_status": "NOT_RUN"', control)
        self.assertIn('"test_system_status": "PASSED"', control)
        self.assertIn("launch-to-accurate-content took", control)
        self.assertIn("xcresulttool get test-results summary", control)
        self.assertIn('"expectedFailures": 1', control)
        self.assertIn('"passedTests": 0', control)
        self.assertIn('"failedTests": 0', control)
        self.assertIn('"native_result_bundle": result_bundle', control)
        self.assertNotIn("sleep ", control)

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
        lane_runner = (REPO / "scripts/quality_test.sh").read_text()

        self.assertIn(
            'results_root="${QUALITY_RESULTS_ROOT:-$repo_root/build/quality-results}"',
            lane_runner,
        )
        self.assertIn(
            'result_file="${QUALITY_RESULT_FILE:-$results_root/apple-$lane-summary.json}"',
            lane_runner,
        )
        self.assertIn(
            'results_root="${QUALITY_RESULTS_ROOT:-$repo_root/build/quality-results}"',
            runner,
        )
        self.assertIn('export QUALITY_RESULTS_ROOT="$results_root"', runner)
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

    def test_impact_selected_channel_sheet_claim_is_identical_to_executed_claim(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        body = runner.split("      apple-ios-channel-sheet-error-owner)", 1)[1].split(
            "        ;;", 1
        )[0]
        claim = "iOS impact-selected Channel Sheet error stays with its failed action"
        self.assertEqual(1, body.count(f'        selected_claims+=("{claim}")'))
        self.assertEqual(1, body.count(f'        claims+=("{claim}")'))
        self.assertNotIn("iOS Channel rejection stays in its Sheet", body)

    def test_dedicated_apple_evidence_runners_follow_the_lane_result_root(self) -> None:
        runner_expectations = {
            "run_ios_performance_negative_control.sh": "ios-performance-negative",
            "run_macos_performance_negative_control.sh": "macos-performance-negative",
            "run_ios_data_field_negative_control.sh": "ios-data-field-negative",
            "run_macos_update_install_test.sh": "macos-update-install",
        }

        for runner_name, evidence_directory in runner_expectations.items():
            with self.subTest(runner=runner_name):
                runner = (REPO / "scripts" / runner_name).read_text()
                self.assertIn("QUALITY_RESULTS_ROOT", runner)
                self.assertIn(evidence_directory, runner)
                self.assertNotIn(
                    f'$repo_root/build/quality-results/{evidence_directory}',
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
        self.assertEqual(12, len(scopes + extended_positive))
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
        macos_function = runner.split("run_macos_ui() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('local requested_scopes="${TEST_SCOPES:-}"', macos_function)
        self.assertIn(
            'local claim="macOS ${scope_set} App-owned user-purpose journeys"',
            macos_function,
        )
        self.assertIn('if [[ -n "$requested_scopes" ]]', macos_function)
        self.assertIn(
            'claim="macOS explicitly selected UI journeys: $requested_scopes"',
            macos_function,
        )
        macos_lines = [line.strip() for line in macos_function.splitlines()]
        self.assertEqual(1, macos_lines.count('selected_claims+=("$claim")'))
        self.assertEqual(1, macos_lines.count('claims+=("$claim")'))
        self.assertIn(
            'macos_pr_ui_scope="PushGo-macOSUITests/PushGo_macOSUITests/testSidebarNavigationCoversPrimaryScreens"',
            runner,
        )
        pr_body = runner.split("  pr)\n", 1)[1].split("    ;;", 1)[0]
        self.assertEqual(1, pr_body.count('TEST_SCOPES="$macos_pr_ui_scope" run_macos_ui positive'))
        self.assertNotIn(
            "macOS one-start broad positive navigation with accurate objects and readable unread state",
            pr_body,
        )

    def test_successful_refresh_reuses_existing_cross_platform_relaunch_journeys(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        ios_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        macos_source = (REPO / "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift").read_text()
        standard = "testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch"
        ios_standard = ios_source.split("func " + standard + "()", 1)[1].split("\n    func ", 1)[0]
        macos_standard = macos_source.split("func " + standard + "()", 1)[1].split(
            "\n    @MainActor", 1
        )[0]

        self.assertTrue(any(scope.endswith("/" + standard) for scope in self._scopes(runner, "pr_ui_scopes")))
        self.assertNotIn("testMessageRefreshPersistsNewProviderResultAndOpensItsRealDetail", ios_source)
        self.assertNotIn("testMessageRefreshPersistsNewProviderResultAndOpensItsRealDetail", runner)
        for journey in (ios_standard, macos_standard):
            self.assertGreaterEqual(journey.count('messageRefreshScenario: "new_message"'), 2)
            self.assertIn('"action.messages.refresh"', journey)
            self.assertIn('"P2 Refresh Result"', journey)
            self.assertIn('"Persisted through the provider refresh ingress path."', journey)
            self.assertIn("exactly one unread message", journey)
            self.assertIn("read state must remain accurate after relaunch", journey)

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

        self.assertIn('messageRefreshScenario: "new_message"', macos_journey)
        self.assertIn('identifier: "action.messages.refresh"', macos_journey)
        self.assertIn('"P2 Refresh Result"', macos_journey)
        self.assertIn('"Persisted through the provider refresh ingress path."', macos_journey)
        self.assertIn("newly persisted provider result must initially expose its unread row semantics", macos_journey)
        self.assertIn("Opening the refreshed result must update that exact row to read semantics", macos_journey)

        self.assertIn('"pushgo.dev/guides/getting-started/"', ios_journey)
        self.assertIn('"https://pushgo.dev/guides/getting-started/"', ios_journey)
        self.assertIn("safari.textFields.matching", ios_journey)
        self.assertIn(
            "exact Getting Started destination, not merely any pushgo.dev page",
            ios_journey,
        )

    def test_pr_message_and_gateway_journeys_keep_positive_oracles_without_negative_cost(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()
        test_source = (REPO / "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift").read_text()
        runtime = (REPO / "Shared/UI/AutomationRuntime.swift").read_text()
        channel_controller = (REPO / "Shared/Application/ChannelSubscriptionController.swift").read_text()
        badge_helper = test_source.split(
            "private func assertMessagesTabBadgeCount(", 1
        )[1].split("private func messagesTabBadgeCount(", 1)[0]
        positive_gateway = test_source.split(
            "func testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch()", 1
        )[1].split(
            "func testSettingsServerRejectsInvalidAndUnregisteredCandidatesWithoutLeakingSheetError()",
            1,
        )[0]

        self.assertIn("messages = (0..<125).map(qualityWorkflowFixtureMessage)", runtime)
        self.assertNotIn("messages = (0..<52).map(qualityWorkflowFixtureMessage)", runtime)
        for title in (
            "Quality workflow 124",
            "Quality workflow 75",
            "Quality workflow 74",
            "Quality workflow 25",
            "Quality workflow 1",
            "Quality workflow 0",
        ):
            self.assertIn(title, test_source)
        self.assertIn("production page 3", test_source)
        self.assertIn("var observedWorkflowIndices = Set<Int>()", test_source)
        self.assertIn("Set(0..<125)", test_source)
        self.assertIn("must remain bound to Quality workflow", test_source)
        self.assertIn("preserve contiguous newest-first order", test_source)
        self.assertIn("let tabBar = app.tabBars.firstMatch", badge_helper)
        self.assertIn("tabBar.buttons.element(boundBy: 0)", badge_helper)
        self.assertIn('["Messages", "消息", "訊息"]', badge_helper)
        self.assertNotIn('let messagesTab = app.buttons["tab.messages"]', badge_helper)
        self.assertNotIn("failGatewaySwitchValidationOnce", positive_gateway)
        self.assertNotIn("not a valid url", positive_gateway)
        self.assertIn("expectedChannelMutationGatewayURL: normalizedAddress", positive_gateway)
        self.assertIn('identifier: "action.channels.add"', positive_gateway)
        self.assertIn('identifier: "channel.row.01H00000000000000000000003"', positive_gateway)
        self.assertIn("The exact post-switch Channel result must remain", positive_gateway)
        self.assertIn("try requireExpectedGateway(baseURL)", runtime)
        self.assertIn('code: "quality_channel_wrong_gateway"', runtime)
        for mutation in ("subscribe", "rename", "unsubscribe"):
            self.assertIn(f"channelMutationRoundTrip.{mutation}(", channel_controller)
        self.assertGreaterEqual(channel_controller.count("baseURL: config.baseURL"), 4)
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
        app_delegate_source = (REPO / "Apps/PushGo-macOS/App/PushGoAppDelegate.swift").read_text()

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
                "testDeniedNotificationSettingsCardRecoversAfterSystemEnable",
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
        notification_journey = macos_source.split(
            "func testSystemNotificationClickPersistsAccurateMessageAndSurvivesRelaunch",
            1,
        )[1].split("\n    @MainActor", 1)[0]
        self.assertIn("label CONTAINS", notification_journey)
        self.assertIn("value CONTAINS", notification_journey)
        self.assertNotIn('label == %@", title', notification_journey)

        permission_recovery = macos_source.split(
            "func testDeniedNotificationSettingsCardRecoversAfterSystemEnable",
            1,
        )[1].split("\n    @MainActor", 1)[0]
        self.assertIn("skipPushAuthorization: false", permission_recovery)
        self.assertIn("allowCrossAppDataAccess: true", permission_recovery)
        self.assertIn('let sessionID = "macos-permission-', permission_recovery)
        self.assertIn('identifier: "allow-notifications"', permission_recovery)
        self.assertIn('identifier: "action.settings.notification.open_system_settings"', permission_recovery)
        self.assertNotIn("skipPushAuthorization: true", permission_recovery)
        activation = app_delegate_source.split(
            "func applicationDidBecomeActive(_: Notification)",
            1,
        )[1].split("\n    }", 1)[0]
        self.assertIn("PushRegistrationService.shared.applicationDidBecomeActive()", activation)

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
        self.assertEqual(1, runner.count("apple-ios-channel-sheet-error-owner)"))
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

    def test_store_impact_check_runs_the_real_migration_and_reopen_oracle(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()

        self.assertEqual(1, runner.count("apple-store-migration-reopen)"))
        store_check = runner.split("apple-store-migration-reopen)", 1)[1].split(
            "        ;;", 1
        )[0]
        self.assertIn(
            "swift test --package-path \"$repo_root\" --filter "
            "currentV24StorePreservesPendingDeletionThroughV25AndReopen",
            store_check,
        )
        self.assertIn("identity, state, deadline, and Undo semantics", store_check)

    def test_core_only_store_impact_uses_a_bounded_disk_reserve_without_weakening_ui_reserve(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()

        self.assertIn('"$lane" == "changed-tests"', runner)
        self.assertIn('checks == {"apple-store-migration-reopen"}', runner)
        self.assertIn("all(isinstance(items, list) and not items for items in scopes.values())", runner)
        self.assertIn("print(1073741824)", runner)
        self.assertIn("print(5368709120)", runner)
        self.assertIn('QUALITY_MIN_FREE_BYTES:-5368709120', runner)

    def test_message_unavailable_route_impact_checks_run_only_the_owning_journeys(self) -> None:
        runner = (REPO / "scripts/quality_test.sh").read_text()

        self.assertEqual(1, runner.count("apple-ios-message-unavailable-route)"))
        self.assertEqual(1, runner.count("apple-macos-message-unavailable-route)"))
        unavailable_body = runner.split("apple-ios-message-unavailable-route)", 1)[1].split(
            "        ;;", 1
        )[0]
        self.assertIn(
            'TEST_SCOPES="PushGo-iOSUITests/PushGo_iOSUITests/'
            'testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch"',
            unavailable_body,
        )
        self.assertEqual(
            1,
            runner.count(
                'TEST_SCOPES="PushGo-macOSUITests/PushGo_macOSUITests/'
                'testUnavailableMessageRouteReturnsToListAndKeepsMessagesUsable"'
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
                'testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch,'
                'PushGo-iOSUITests/PushGo_iOSUITests/'
                'testSettingsGatewaySyncFailureReportsCommittedGatewayAndPendingRecovery,'
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
                'testGatewaySyncFailureReportsCommittedGatewayAndPendingRecovery,'
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
        ios_gateway_positive = ios_source.split(
            "func testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch()",
            1,
        )[1].split("\n    func test", 1)[0]
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
        self.assertIn("expectedChannelMutationGatewayURL: normalizedAddress", macos_gateway_positive)
        self.assertIn('identifier: "action.channels.add"', macos_gateway_positive)
        self.assertIn('identifier: "channel.row.01H00000000000000000000003"', macos_gateway_positive)
        self.assertIn("The exact post-switch Channel result must remain", macos_gateway_positive)
        self.assertIn('channelMutationScenario: "accepted"', ios_gateway_positive)
        self.assertIn("A post-commit Channel operation must use", ios_gateway_positive)
        self.assertIn("Relaunch must not reload channel data owned by the previous gateway", ios_gateway_positive)
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
