#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-iOS}"
device_id="${IOS_PERFORMANCE_DEVICE_ID:-}"
expected_title="${PUSHGO_PHYSICAL_EXPECTED_TITLE:-}"
expected_body="${PUSHGO_PHYSICAL_EXPECTED_BODY:-}"
maximum_seconds="${PUSHGO_PHYSICAL_MAX_SECONDS:-}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/ios-physical-performance}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.deriveddata-ios-physical-performance}"
timestamp="$(date +%Y%m%d-%H%M%S)"
log_file="$results_root/run-$timestamp.log"
result_bundle="$results_root/run-$timestamp.xcresult"

for command_name in xcodebuild xcrun rg python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "status=BLOCKED"
    echo "reason=missing_command:$command_name"
    exit 2
  }
done

if [[ -z "$device_id" || -z "$expected_title" || -z "$expected_body" || -z "$maximum_seconds" ]]; then
  echo "status=BLOCKED"
  echo "reason=physical_reference_device_contract_incomplete"
  exit 2
fi

if ! python3 - "$maximum_seconds" <<'PY'
import math
import sys

try:
    value = float(sys.argv[1])
except ValueError as error:
    raise SystemExit("PUSHGO_PHYSICAL_MAX_SECONDS must be numeric") from error
if not math.isfinite(value) or value <= 0:
    raise SystemExit("PUSHGO_PHYSICAL_MAX_SECONDS must be finite and positive")
PY
then
  echo "status=BLOCKED"
  echo "reason=invalid_physical_reference_device_budget"
  exit 2
fi

if ! xcrun xctrace list devices 2>/dev/null | rg -F -q -- "$device_id"; then
  echo "status=BLOCKED"
  echo "reason=physical_reference_device_unavailable:$device_id"
  exit 2
fi

mkdir -p "$results_root"

set +e
PUSHGO_PHYSICAL_EXPECTED_TITLE="$expected_title" \
PUSHGO_PHYSICAL_EXPECTED_BODY="$expected_body" \
PUSHGO_PHYSICAL_MAX_SECONDS="$maximum_seconds" \
xcodebuild \
  -project "$project_path" \
  -scheme "$scheme" \
  -configuration Release \
  -derivedDataPath "$derived_data_path" \
  -destination "platform=iOS,id=$device_id" \
  -destination-timeout 30 \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -collect-test-diagnostics never \
  -only-testing:PushGo-iOSUITests/PushGo_iOSUITests/testPhysicalReferenceDeviceColdLaunchReachesExpectedContent \
  -resultBundlePath "$result_bundle" \
  test 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e

if [[ $status -eq 0 ]]; then
  if ! python3 "$repo_root/scripts/verify_apple_test_execution.py" --result-bundle "$result_bundle"; then
    echo "status=FAILED_TEST_SYSTEM"
    echo "reason=selected_ios_physical_performance_scope_executed_zero_tests"
    echo "result_bundle=$result_bundle"
    exit 3
  fi
  echo "status=PASSED"
  echo "result_bundle=$result_bundle"
  echo "log=$log_file"
  exit 0
fi

if rg -q \
  "No devices are available|Unable to find a destination|Device is locked|Developer Mode|requires a provisioning profile|CodeSign error|Failed to install|Failed to launch.*xctrunner" \
  "$log_file"; then
  echo "status=BLOCKED"
  echo "reason=physical_device_or_signing_precondition_failed"
  echo "result_bundle=$result_bundle"
  echo "log=$log_file"
  exit 2
fi

echo "status=FAILED"
echo "reason=physical_release_product_oracle_failed"
echo "result_bundle=$result_bundle"
echo "log=$log_file"
exit 1
