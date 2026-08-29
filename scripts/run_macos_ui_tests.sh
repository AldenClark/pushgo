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
problem_reporter_cleaner="$repo_root/scripts/close_macos_problem_reporter.sh"
test_app_executable="$derived_data_path/Build/Products/Debug/PushGo.app/Contents/MacOS/PushGo"
test_runner_executable="$derived_data_path/Build/Products/Debug/PushGo-macOSUITests-Runner.app/Contents/MacOS/PushGo-macOSUITests-Runner"
caffeinate_pid=""

if [[ ! "$max_retries" =~ ^[0-9]+$ ]] || (( max_retries != 0 )); then
  echo "status=BLOCKED"
  echo "reason=macos_ui_retries_are_disabled:$max_retries"
  exit 2
fi

default_scopes=(
  "PushGo-macOSUITests/PushGo_macOSUITests/testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState"
  "PushGo-macOSUITests/PushGo_macOSUITests/testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSlowMessageLoadWarnsBeforeDataCompletes"
  "PushGo-macOSUITests/PushGo_macOSUITests/testMessageLoadFailureRetryRecoversToFunctionalState"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion"
  "PushGo-macOSUITests/PushGo_macOSUITests/testMessageRefreshFailureKeepsSnapshotAndRetryPersistsAccurateResult"
  "PushGo-macOSUITests/PushGo_macOSUITests/testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSidebarNavigationCoversPrimaryScreens"
  "PushGo-macOSUITests/PushGo_macOSUITests/testEventDetailCloseAndRelaunchPreserveAccurateProjection"
  "PushGo-macOSUITests/PushGo_macOSUITests/testThingRelationsOpenAccurateDetailsAndSurviveRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey"
  "PushGo-macOSUITests/PushGo_macOSUITests/testDecryptionProtectedStoreFailureDoesNotConfigureBeforeRetry"
  "PushGo-macOSUITests/PushGo_macOSUITests/testEncryptedMessageWrongKeyThenCorrectKeyRecoversAndSurvivesRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testCorruptEncryptedMessageFailsSafelyAndSurvivesRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testInvalidServerAddressShowsInlineFeedbackInsteadOfToast"
  "PushGo-macOSUITests/PushGo_macOSUITests/testGatewayCandidateMustRegisterBeforeCommitAndPersistsAfterRelaunch"
  "PushGo-macOSUITests/PushGo_macOSUITests/testGatewayLocalCommitFailureRollsBackBeforeRetryCommits"
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
  CODE_SIGNING_ALLOWED=YES
)

if [[ -n "$test_scopes" ]]; then
  IFS=',' read -r -a scope_list <<< "$test_scopes"
else
  scope_list=("${default_scopes[@]}")
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

if [[ $status -eq 0 ]]; then
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
