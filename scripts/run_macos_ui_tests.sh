#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-macOS}"
test_scopes="${TEST_SCOPES:-${TEST_SCOPE:-}}"
max_retries="${MAX_RETRIES:-0}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/build/.deriveddata-macos-ui}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/macos-ui}"
runner_status_file="${QUALITY_RUNNER_STATUS_FILE:-}"
runner_issue_file="${QUALITY_RUNNER_ISSUE_FILE:-}"
problem_reporter_cleaner="$repo_root/scripts/close_macos_problem_reporter.sh"
test_app_executable="$derived_data_path/Build/Products/Debug/PushGo.app/Contents/MacOS/PushGo"
test_runner_executable="$derived_data_path/Build/Products/Debug/PushGo-macOSUITests-Runner.app/Contents/MacOS/PushGo-macOSUITests-Runner"
caffeinate_pid=""
problem_reporter_monitor_pid=""
problem_reporter_monitor_log=""
apple_ui_lease_file="${PUSHGO_APPLE_UI_LEASE_FILE:-$repo_root/build/.pushgo-apple-ui-tests.lock}"

# Share one PushGo-local host lease with the iOS UI runner. Concurrent heavy
# Apple UI builds can starve macOS scene creation and be killed by the system
# watchdog before any product oracle starts.
mkdir -p "$(dirname "$apple_ui_lease_file")"
exec 9>"$apple_ui_lease_file"
if ! /usr/bin/lockf -s -t 0 9; then
  echo "status=BLOCKED"
  echo "reason=pushgo_apple_ui_lease_busy"
  exit 2
fi

if [[ ! "$max_retries" =~ ^[0-9]+$ ]] || (( max_retries != 0 )); then
  echo "status=BLOCKED"
  echo "reason=macos_ui_retries_are_disabled:$max_retries"
  exit 2
fi

positive_scopes=(
  "PushGo-macOSUITests/PushGo_macOSUITests/testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState"
  "PushGo-macOSUITests/PushGo_macOSUITests/testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testHistoryCleanupRemovesOnlyOldMessagesAndPersistsAcrossRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testMarkdownFixtureRendersMajorStructuresInTheRealDetail"
  "PushGo-macOSUITests/PushGo_macOSUITests/testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist"
  "PushGo-macOSUITests/PushGo_macOSUITests/testUnreadBadgeAndChannelLifecyclePersistThroughRealUserActions"
  "PushGo-macOSUITests/PushGo_macOSUITests/testMessageDeletionRestoresThenCommitsAccurateCanonicalStateAcrossRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSlowMessageLoadWarnsBeforeDataCompletes"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion"
  "PushGo-macOSUITests/PushGo_macOSUITests/testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSidebarNavigationCoversPrimaryScreens"
  "PushGo-macOSUITests/PushGo_macOSUITests/testEventDetailCloseAndRelaunchPreserveAccurateProjection"
  "PushGo-macOSUITests/PushGo_macOSUITests/testThingRelationsOpenAccurateDetailsAndSurviveRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testGatewayCandidateMustRegisterBeforeCommitAndPersistsAfterRelaunch"
)

risk_scopes=(
  "PushGo-macOSUITests/PushGo_macOSUITests/testFatalStoreInitializationStopsReadWriteAndRecoversAfterRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testMessageLoadFailureRetryRecoversToFunctionalState"
  "PushGo-macOSUITests/PushGo_macOSUITests/testMessageRefreshFailureKeepsSnapshotAndRetryPersistsAccurateResult"
  "PushGo-macOSUITests/PushGo_macOSUITests/testEventCloseFailureKeepsAccurateDetailBlocksDuplicateAndRetryPersists"
  "PushGo-macOSUITests/PushGo_macOSUITests/testDecryptionProtectedStoreFailureDoesNotConfigureBeforeRetry"
  "PushGo-macOSUITests/PushGo_macOSUITests/testEncryptedMessageWrongKeyThenCorrectKeyRecoversAndSurvivesRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testCorruptEncryptedMessageFailsSafelyAndSurvivesRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testInvalidServerAddressShowsInlineFeedbackInsteadOfToast"
  "PushGo-macOSUITests/PushGo_macOSUITests/testGatewayLocalCommitFailureRollsBackBeforeRetryCommits"
)

# Real Notification Center delivery is a high-value positive system boundary,
# but it requires host authorization and has a materially different cost and
# precondition profile from App-owned UI. Keep it discoverable and independently
# runnable without charging every ordinary macOS batch.
system_scopes=(
  "PushGo-macOSUITests/PushGo_macOSUITests/testSystemNotificationClickPersistsAccurateMessageAndSurvivesRelaunch"
)

# One-time oracle calibration for Runtime/preparation changes. It is intentionally
# excluded from both the ordinary positive set and the broad Nightly risk set.
preparation_scopes=(
  "PushGo-macOSUITests/PushGo_macOSUITests/testInvalidQualitySessionStopsBeforeBusinessUIWithinTenSeconds"
)

close_stale_test_processes() {
  local process_pattern
  for process_pattern in "^$test_app_executable($| )" "^$test_runner_executable($| )"; do
    pkill -TERM -f "$process_pattern" >/dev/null 2>&1 || true
  done
  sleep 0.1
  for process_pattern in "^$test_app_executable($| )" "^$test_runner_executable($| )"; do
    pkill -KILL -f "$process_pattern" >/dev/null 2>&1 || true
  done
}

finish() {
  local command_status=$?
  trap - EXIT INT TERM
  if [[ -n "$caffeinate_pid" ]]; then
    kill "$caffeinate_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$problem_reporter_monitor_pid" ]]; then
    kill "$problem_reporter_monitor_pid" >/dev/null 2>&1 || true
    wait "$problem_reporter_monitor_pid" 2>/dev/null || true
  fi
  close_stale_test_processes
  "$problem_reporter_cleaner" || true
  exit "$command_status"
}
trap finish EXIT INT TERM

if [[ -n "$runner_status_file" ]]; then
  mkdir -p "$(dirname "$runner_status_file")"
fi

"$repo_root/scripts/require_unlocked_apple_ui_console.sh" macos

# Keep a long UI lane from reaching the login screen after a successful
# preflight. This changes only idle-sleep behavior for the lifetime of this
# runner and is always released by the exit trap.
/usr/bin/caffeinate -dimsu -w $$ &
caffeinate_pid=$!

"$problem_reporter_cleaner"
close_stale_test_processes
mkdir -p "$results_root"
problem_reporter_monitor_log="$(mktemp -t pushgo-problem-reporter-monitor.XXXXXX.log)"
"$problem_reporter_cleaner" --watch-pid "$$" >>"$problem_reporter_monitor_log" 2>&1 &
problem_reporter_monitor_pid=$!

common_args=(
  -project "$project_path"
  -scheme "$scheme"
  -configuration Debug
  -destination "platform=macOS,arch=arm64"
  -derivedDataPath "$derived_data_path"
  -onlyUsePackageVersionsFromResolvedFile
  -disableAutomaticPackageResolution
  -skipPackageUpdates
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -collect-test-diagnostics never
  CODE_SIGNING_ALLOWED=YES
)

if [[ -n "$test_scopes" ]]; then
  IFS=',' read -r -a scope_list <<< "$test_scopes"
else
  case "${MACOS_SCOPE_SET:-positive}" in
    positive)
      scope_list=("${positive_scopes[@]}")
      ;;
    full)
      scope_list=("${positive_scopes[@]}" "${risk_scopes[@]}")
      ;;
    system)
      scope_list=("${system_scopes[@]}")
      ;;
    preparation)
      scope_list=("${preparation_scopes[@]}")
      ;;
    *)
      echo "status=BLOCKED"
      echo "reason=unsupported_macos_scope_set:${MACOS_SCOPE_SET}"
      exit 2
      ;;
  esac
fi
for scope in "${scope_list[@]}"; do
  [[ -n "$scope" ]] && common_args+=("-only-testing:${scope}")
done

if [[ -n "$runner_status_file" ]]; then
  printf 'PASSED\n' > "$runner_status_file"
fi

echo "==> macOS build-for-testing"
xcodebuild "${common_args[@]}" build-for-testing

result_bundle="$results_root/run-$(date +%Y%m%d-%H%M%S).xcresult"
log_file="$(mktemp -t pushgo-macos-ui.XXXXXX.log)"
"$problem_reporter_cleaner"
echo "==> macOS App-owned UI journeys (zero retry)"
set +e
xcodebuild "${common_args[@]}" -resultBundlePath "$result_bundle" test-without-building 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e
"$problem_reporter_cleaner"

if ! kill -0 "$problem_reporter_monitor_pid" >/dev/null 2>&1; then
  wait "$problem_reporter_monitor_pid" || monitor_status=$?
  [[ -z "$runner_status_file" ]] || printf 'BLOCKED\n' > "$runner_status_file"
  echo "status=BLOCKED"
  echo "reason=macos_problem_reporter_cleanup_failed:${monitor_status:-unknown}"
  echo "monitor_log=$problem_reporter_monitor_log"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 2
fi

if [[ $status -eq 0 ]]; then
  if ! python3 "$repo_root/scripts/verify_apple_test_execution.py" --result-bundle "$result_bundle"; then
    [[ -z "$runner_status_file" ]] || printf 'FAILED\n' > "$runner_status_file"
    echo "status=FAILED_TEST_SYSTEM"
    echo "reason=selected_macos_ui_scope_executed_zero_tests"
    echo "result_bundle=$result_bundle"
    exit 3
  fi
  rm -f "$problem_reporter_monitor_log"
  problem_reporter_monitor_log=""
  rm -f "$log_file"
  echo "status=PASSED"
  echo "result_bundle=$result_bundle"
  exit 0
fi

if grep -q "macos_problem_reporter_cleanup_failed" "$log_file"; then
  [[ -z "$runner_status_file" ]] || printf 'BLOCKED\n' > "$runner_status_file"
  echo "status=BLOCKED"
  echo "reason=macos_problem_reporter_cleanup_failed"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 2
fi

# App-owned readiness, authorization, and desktop-transition failures occur
# before a product oracle can start. They are zero-retry test-system blockers,
# never product failures and never a route to a green receipt.
if classification="$(python3 "$repo_root/scripts/quality_test_system_issues.py" --match-file "$log_file")" \
  && printf '%s\n' "$classification" | grep -q 'classification_issue_ids=.*apple-quality-precondition'; then
  printf '%s\n' "$classification"
  issue_ids="$(printf '%s\n' "$classification" | sed -n 's/^classification_issue_ids=//p')"
  if [[ -n "$runner_issue_file" && -n "$issue_ids" ]]; then
    printf '%s\n' "$issue_ids" | tr ',' '\n' >> "$runner_issue_file"
  fi
  [[ -z "$runner_status_file" ]] || printf 'BLOCKED\n' > "$runner_status_file"
  echo "status=BLOCKED"
  echo "reason=app_owned_quality_precondition_failed"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 2
fi

if ! grep -q "Test Case '-\\[" "$log_file"; then
  [[ -z "$runner_status_file" ]] || printf 'BLOCKED\n' > "$runner_status_file"
  echo "status=BLOCKED"
  echo "reason=macos_ui_runner_failed_before_product_oracle"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 2
fi

echo "status=FAILED"
echo "log=$log_file"
echo "result_bundle=$result_bundle"
exit 1
