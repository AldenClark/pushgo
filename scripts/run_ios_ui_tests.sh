#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-iOS}"
test_scopes="${TEST_SCOPES:-${TEST_SCOPE:-}}"
max_retries="${MAX_RETRIES:-1}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.deriveddata-ui-tests}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/ios}"

doctor_output="$("$repo_root/scripts/quality_doctor.sh")"
printf '%s\n' "$doctor_output"
target="$(printf '%s\n' "$doctor_output" | awk -F= '$1 == "simulator_id" { print $2; exit }')"
if [[ -z "$target" ]]; then
  echo "status=BLOCKED"
  echo "reason=no_available_ios_simulator"
  exit 2
fi

mkdir -p "$results_root"

common_args=(
  -project "$project_path"
  -scheme "$scheme"
  -configuration Debug
  -derivedDataPath "$derived_data_path"
  -destination "platform=iOS Simulator,id=${target}"
  -onlyUsePackageVersionsFromResolvedFile
  -disableAutomaticPackageResolution
  -skipPackageUpdates
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -collect-test-diagnostics never
)

if [[ -n "$test_scopes" ]]; then
  IFS=',' read -r -a scope_list <<< "$test_scopes"
  for scope in "${scope_list[@]}"; do
    [[ -n "$scope" ]] && common_args+=("-only-testing:${scope}")
  done
fi

xcrun simctl shutdown "$target" >/dev/null 2>&1 || true
xcrun simctl boot "$target" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$target" -b

echo "==> build-for-testing"
xcodebuild "${common_args[@]}" build-for-testing

run_test_once() {
  local logfile="$1"
  local result_bundle="$2"
  set +e
  xcodebuild "${common_args[@]}" -resultBundlePath "$result_bundle" test-without-building 2>&1 | tee "$logfile"
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

is_transient_runner_failure() {
  local logfile="$1"
  rg -q \
    "Failed to launch app with identifier: .*xctrunner|RequestDenied|timed out waiting for simulator|Unable to boot the Simulator" \
    "$logfile"
}

attempt=1
until [[ $attempt -gt $((max_retries + 1)) ]]; do
  log_file="$(mktemp -t pushgo-ui-tests.XXXXXX.log)"
  result_bundle="$results_root/run-${attempt}-$(date +%Y%m%d-%H%M%S).xcresult"
  echo "==> test-without-building (attempt ${attempt}/$((max_retries + 1)))"

  if run_test_once "$log_file" "$result_bundle"; then
    rm -f "$log_file"
    echo "status=PASSED"
    echo "result_bundle=$result_bundle"
    exit 0
  fi

  if [[ $attempt -le $max_retries ]] && is_transient_runner_failure "$log_file"; then
    echo "classification=BLOCKED_TRANSIENT_RUNNER"
    xcrun simctl shutdown "$target" >/dev/null 2>&1 || true
    xcrun simctl boot "$target" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$target" -b
    rm -f "$log_file"
    attempt=$((attempt + 1))
    continue
  fi

  echo "status=FAILED"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 1
done
