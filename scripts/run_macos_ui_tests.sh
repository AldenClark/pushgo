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
  "PushGo-macOSUITests/PushGo_macOSUITests/testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSidebarNavigationCoversPrimaryScreens"
  "PushGo-macOSUITests/PushGo_macOSUITests/testSettingsSidebarCanOpenDecryptionOverlay"
  "PushGo-macOSUITests/PushGo_macOSUITests/testInvalidServerAddressShowsInlineFeedbackInsteadOfToast"
)

close_problem_reporter() {
  local reporter_pid
  while IFS= read -r reporter_pid; do
    [[ -z "$reporter_pid" ]] || kill "$reporter_pid" >/dev/null 2>&1 || true
  done < <(pgrep -f '/System/Library/CoreServices/Problem Reporter.app/Contents/MacOS/Problem Reporter' || true)
}

finish() {
  local command_status=$?
  trap - EXIT INT TERM
  close_problem_reporter
  exit "$command_status"
}
trap finish EXIT INT TERM

close_problem_reporter
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
  mkdir -p "$(dirname "$runner_status_file")"
  printf 'PASSED\n' > "$runner_status_file"
fi

echo "==> macOS build-for-testing"
xcodebuild "${common_args[@]}" build-for-testing

result_bundle="$results_root/run-$(date +%Y%m%d-%H%M%S).xcresult"
log_file="$(mktemp -t pushgo-macos-ui.XXXXXX.log)"
echo "==> macOS App-owned UI journeys (zero retry)"
set +e
xcodebuild "${common_args[@]}" -resultBundlePath "$result_bundle" test-without-building 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e

if [[ $status -eq 0 ]]; then
  rm -f "$log_file"
  echo "status=PASSED"
  echo "result_bundle=$result_bundle"
  exit 0
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
