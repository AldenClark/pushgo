#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-watchOS}"
app_bundle_identifier="${APP_BUNDLE_IDENTIFIER:-io.ethan.pushgo.watchkitapp}"
test_scopes="${TEST_SCOPES:-${TEST_SCOPE:-}}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.deriveddata-watch-ui-tests}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/watchos}"
runner_status_file="${QUALITY_RUNNER_STATUS_FILE:-}"
runner_issue_file="${QUALITY_RUNNER_ISSUE_FILE:-}"

if [[ -n "$runner_status_file" && ! -f "$runner_status_file" ]]; then
  mkdir -p "$(dirname "$runner_status_file")"
  printf 'PASSED\n' > "$runner_status_file"
fi

block() {
  local reason="$1"
  if [[ -n "$runner_status_file" ]]; then
    printf 'BLOCKED\n' > "$runner_status_file"
  fi
  echo "status=BLOCKED"
  echo "reason=$reason"
  exit 2
}

record_classification() {
  local classification="$1"
  local issue_ids
  printf '%s\n' "$classification"
  issue_ids="$(printf '%s\n' "$classification" | sed -n 's/^classification_issue_ids=//p')"
  if [[ -n "$runner_issue_file" && -n "$issue_ids" ]]; then
    printf '%s\n' "$issue_ids" | tr ',' '\n' >>"$runner_issue_file"
  fi
}

"$repo_root/scripts/require_unlocked_apple_ui_console.sh" watchos_simulator
command -v xcodebuild >/dev/null 2>&1 || block "xcodebuild_not_found"
command -v xcrun >/dev/null 2>&1 || block "xcrun_not_found"
command -v python3 >/dev/null 2>&1 || block "python3_not_found"
command -v rg >/dev/null 2>&1 || block "rg_not_found"
python3 "$repo_root/scripts/quality_test_system_issues.py" --check >/dev/null || block "invalid_or_expired_apple_test_system_issue_registry"
if ! xcodebuild -project "$project_path" -list 2>/dev/null | rg -q "^[[:space:]]+$scheme$"; then
  block "watchos_scheme_not_found:$scheme"
fi

target="${WATCH_SIMULATOR_ID:-}"
if [[ -z "$target" ]]; then
  target="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
payload = json.load(sys.stdin)
candidates = []
for runtime, devices in payload.get("devices", {}).items():
    if "watchOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable"):
            candidates.append((device.get("state") != "Booted", runtime, device.get("name", ""), device["udid"]))
if candidates:
    print(sorted(candidates)[0][3])
')"
fi
[[ -n "$target" ]] || block "no_available_watchos_simulator"

mkdir -p "$results_root"
xcrun simctl boot "$target" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$target" -b || block "watchos_simulator_boot_failed:$target"

common_args=(
  -project "$project_path"
  -scheme "$scheme"
  -configuration Debug
  -derivedDataPath "$derived_data_path"
  -destination "platform=watchOS Simulator,id=${target}"
  -onlyUsePackageVersionsFromResolvedFile
  -disableAutomaticPackageResolution
  -skipPackageUpdates
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -collect-test-diagnostics never
)

run_id="$(date +%Y%m%d-%H%M%S)-$$"
build_log="$results_root/build-$run_id.log"
log_file="$results_root/run-$run_id.log"
result_bundle="$results_root/run-$run_id.xcresult"

if [[ -n "$test_scopes" ]]; then
  IFS=',' read -r -a scope_list <<< "$test_scopes"
  for scope in "${scope_list[@]}"; do
    [[ -n "$scope" ]] && common_args+=("-only-testing:${scope}")
  done
fi

echo "==> watchOS build-for-testing"
set +e
xcodebuild "${common_args[@]}" build-for-testing 2>&1 | tee "$build_log"
build_status=${PIPESTATUS[0]}
set -e
if [[ $build_status -ne 0 ]]; then
  echo "status=FAILED"
  echo "reason=watchos_test_build_failed"
  echo "log=$build_log"
  exit 1
fi

watch_app_path="$derived_data_path/Build/Products/Debug-watchsimulator/PushGoWatch.app"
if ! "$repo_root/scripts/prepare_ios_ui_test_app.sh" \
  "$target" \
  "$watch_app_path" \
  "$app_bundle_identifier"; then
  [[ -z "$runner_status_file" ]] || printf 'BLOCKED\n' > "$runner_status_file"
  exit 2
fi

xcrun simctl terminate "$target" "$app_bundle_identifier" >/dev/null 2>&1 || true
echo "==> watchOS test-without-building"
set +e
xcodebuild "${common_args[@]}" -resultBundlePath "$result_bundle" test-without-building 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e

if [[ $status -eq 0 ]]; then
  if ! python3 "$repo_root/scripts/verify_apple_test_execution.py" --result-bundle "$result_bundle"; then
    [[ -z "$runner_status_file" ]] || printf 'FAILED\n' > "$runner_status_file"
    echo "status=FAILED_TEST_SYSTEM"
    echo "reason=selected_watchos_ui_scope_executed_zero_tests"
    echo "result_bundle=$result_bundle"
    exit 3
  fi
  echo "status=PASSED"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 0
fi

if classification="$(python3 "$repo_root/scripts/quality_test_system_issues.py" --match-file "$log_file" --reject-if-matches "Test Case '-\\[")"; then
  record_classification "$classification"
  if [[ -n "$runner_status_file" ]]; then
    printf 'BLOCKED\n' > "$runner_status_file"
  fi
  echo "status=BLOCKED"
  echo "reason=registered_watchos_test_system_failure"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 2
fi

if rg -q 'Simulator device failed to launch .*Application info provider .* returned nil' "$log_file"; then
  [[ -z "$runner_status_file" ]] || printf 'BLOCKED\n' > "$runner_status_file"
  echo "status=BLOCKED"
  echo "reason=watchos_app_install_launch_race"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 2
fi

if ! rg -q "Test Case '-\\[" "$log_file"; then
  if [[ -n "$runner_status_file" ]]; then
    printf 'BLOCKED\n' > "$runner_status_file"
  fi
  echo "status=BLOCKED"
  echo "reason=unclassified_watchos_runner_failure_before_product_execution"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 2
fi

echo "status=FAILED"
echo "log=$log_file"
echo "result_bundle=$result_bundle"
exit 1
