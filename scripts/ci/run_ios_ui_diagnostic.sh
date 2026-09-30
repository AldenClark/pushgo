#!/usr/bin/env bash
set -euo pipefail

# Direct native Simulator diagnostic. The formal quality runner retains its
# expired issue registry and full lane rules; this job makes no gate claim.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
results_root="$repo_root/build/quality-results/apple-ios-ui-diagnostic/run-${run_id}-${run_attempt}"
mkdir -p "$results_root"
source_sha="$(git rev-parse HEAD)"
summary_file="$results_root/diagnostic-summary.json"
classification_file="$results_root/native-classification.json"
test_scopes=()
expected_test_count=0
product_status=NOT_RUN
test_system_status=BLOCKED
reason=diagnostic_not_started
simulator_id=''
runtime_version=''
result_bundle=''
runner_exit=''
verify_exit=''

stage() {
  printf '[%s] diagnostic_stage=%s status=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" "$2"
}

write_summary() {
  local command_status=$?
  trap - EXIT
  python3 - "$summary_file" "$classification_file" "$source_sha" \
    "$product_status" "$test_system_status" "$reason" "$simulator_id" \
    "$runtime_version" "$result_bundle" "$runner_exit" "$verify_exit" \
    "$command_status" "$expected_test_count" "${test_scopes[@]}" <<'PY'
import json
import sys
from pathlib import Path

(
    output, classification, source_sha, product_status, test_system_status,
    reason, simulator_id, runtime_version, result_bundle, runner_exit,
    verify_exit, command_status, expected_test_count, *scopes,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "kind": "direct_native_ios_app_owned_ui_diagnostic",
    "quality_gate_status": "NOT_RUN",
    "source_sha": source_sha,
    "selected_tests": scopes,
    "expected_test_count": int(expected_test_count),
    "max_retries": 0,
    "signing_mode": "unsigned_simulator_test_build_only",
    "simulator_udid": simulator_id or None,
    "ios_runtime_version": runtime_version or None,
    "product_status": product_status,
    "test_system_status": test_system_status,
    "reason": reason,
    "result_bundle": result_bundle or None,
    "runner_exit_code": int(runner_exit) if runner_exit else None,
    "strict_verifier_exit_code": int(verify_exit) if verify_exit else None,
    "script_exit_code": int(command_status),
    "claim_limit": "Only the selected App-owned message journeys on iOS Simulator; no formal quality gate, physical device, provider delivery, Release, or distribution claim.",
}
path = Path(classification)
if path.exists():
    payload.update(json.loads(path.read_text()))
Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(f"diagnostic_summary={output}")
print(f"product_status={payload['product_status']}")
print(f"test_system_status={payload['test_system_status']}")
PY
  exit "$command_status"
}
trap write_summary EXIT

case "${DIAGNOSTIC_IOS_SCOPE:-message-three}" in
  message-three)
    test_scopes=(
      'PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions'
      'PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail'
      'PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch'
    )
    expected_test_count=3
    ;;
  message-workflow)
    test_scopes=(
      'PushGo-iOSUITests/PushGo_iOSUITests/testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions'
    )
    expected_test_count=1
    ;;
  message-list)
    test_scopes=(
      'PushGo-iOSUITests/PushGo_iOSUITests/testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist'
      'PushGo-iOSUITests/PushGo_iOSUITests/testHistoryCleanupRemovesOnlyOldMessagesAndPersistsAcrossRelaunch'
    )
    expected_test_count=2
    ;;
  message-history-cleanup)
    test_scopes=(
      'PushGo-iOSUITests/PushGo_iOSUITests/testHistoryCleanupRemovesOnlyOldMessagesAndPersistsAcrossRelaunch'
    )
    expected_test_count=1
    ;;
  message-facets)
    test_scopes=(
      'PushGo-iOSUITests/PushGo_iOSUITests/testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist'
    )
    expected_test_count=1
    ;;
  *)
    reason=unsupported_ios_diagnostic_scope
    exit 2
    ;;
esac

if [[ "$run_id" == local || "${MAX_RETRIES:-0}" != 0 ]]; then
  reason=diagnostic_requires_isolated_runner_and_zero_retries
  exit 2
fi
if [[ ! "${EXPECTED_SHA:-}" =~ ^[0-9a-f]{40}$ || "$source_sha" != "$EXPECTED_SHA" ]]; then
  reason=checked_out_sha_does_not_match_requested_source
  exit 2
fi

reason=ios_simulator_console_locked_or_unavailable
if ! "$repo_root/scripts/require_unlocked_apple_ui_console.sh" ios_simulator \
  > "$results_root/console-preflight.log" 2>&1; then
  exit 2
fi
printf 'console_status=unlocked\n' > "$results_root/console-preflight.log"
xcodebuild -version > "$results_root/xcode-version.log" 2>&1
sw_vers > "$results_root/macos-version.log" 2>&1
xcrun simctl list -j runtimes > "$results_root/simulator-runtimes.json"
xcrun simctl list -j devicetypes > "$results_root/simulator-device-types.json"

# A dedicated device on the exact installed iOS 26.4 runtime avoids fallback
# to a different iOS release or a previously used Simulator.
reason=ios_26_4_iphone_17_runtime_unavailable
if ! python3 - "$results_root/simulator-runtimes.json" \
  "$results_root/simulator-device-types.json" "$results_root/simulator-selection.json" <<'PY'; then
import json
import sys
from pathlib import Path

runtimes = json.loads(Path(sys.argv[1]).read_text()).get("runtimes", [])
types = json.loads(Path(sys.argv[2]).read_text()).get("devicetypes", [])
matches = [
    item for item in runtimes
    if item.get("identifier") == "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
    and item.get("version", "").startswith("26.4")
    and item.get("isAvailable") is True
]
device = next(
    (item for item in types if item.get("identifier") == "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    None,
)
if len(matches) != 1 or device is None:
    raise SystemExit("exact iOS 26.4 runtime or iPhone 17 device type unavailable")
Path(sys.argv[3]).write_text(json.dumps({
    "runtime_identifier": matches[0]["identifier"],
    "runtime_version": matches[0]["version"],
    "device_type_identifier": device["identifier"],
}, indent=2, sort_keys=True) + "\n")
PY
  exit 2
fi
runtime_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtime_version"])' "$results_root/simulator-selection.json")"
runtime_identifier="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtime_identifier"])' "$results_root/simulator-selection.json")"
simulator_id="$(xcrun simctl create 'PushGo Quality iPhone' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime_identifier")"
printf '%s\n' "$simulator_id" > "$results_root/simulator-udid.txt"
reason=ios_simulator_boot_failed
stage simulator_boot started
if ! { xcrun simctl boot "$simulator_id" && xcrun simctl bootstatus "$simulator_id" -b; } \
  > "$results_root/simulator-boot.log" 2>&1; then
  exit 2
fi
stage simulator_boot completed
xcrun simctl list devices > "$results_root/simulator-devices-after-boot.log"

temporary_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pushgo-ios-ui.XXXXXX")"
derived_data_path="$temporary_root/derived-data"
common_args=(
  -project "$repo_root/pushgo.xcodeproj"
  -scheme PushGo-iOS
  -configuration Debug
  -derivedDataPath "$derived_data_path"
  -destination "platform=iOS Simulator,id=${simulator_id}"
  -onlyUsePackageVersionsFromResolvedFile
  -disableAutomaticPackageResolution
  -skipPackageUpdates
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -collect-test-diagnostics never
  -jobs 2
)
for scope in "${test_scopes[@]}"; do
  common_args+=("-only-testing:$scope")
done

reason=ios_build_for_testing_failed
test_system_status=FAILED_TEST_SYSTEM
stage build_for_testing started
if ! xcodebuild "${common_args[@]}" CODE_SIGNING_ALLOWED=NO \
  build-for-testing > "$results_root/build-for-testing.log" 2>&1; then
  tail -n 50 "$results_root/build-for-testing.log"
  exit 3
fi
stage build_for_testing completed
app_bundle="$derived_data_path/Build/Products/Debug-iphonesimulator/PushGo.app"
test_runner="$derived_data_path/Build/Products/Debug-iphonesimulator/PushGo-iOSUITests-Runner.app"
if [[ ! -d "$app_bundle" || ! -d "$test_runner" ]]; then
  reason=ios_build_missing_exact_native_products
  exit 3
fi

reason=ios_built_app_preinstall_failed
stage app_install started
if ! "$repo_root/scripts/prepare_ios_ui_test_app.sh" "$simulator_id" \
  "$app_bundle" io.ethan.pushgo > "$results_root/app-install.log" 2>&1; then
  exit 2
fi
stage app_install completed
xcrun simctl terminate "$simulator_id" io.ethan.pushgo >/dev/null 2>&1 || true

result_bundle="$results_root/message-journeys.xcresult"
reason=native_ios_message_tests_not_clean
stage test_without_building started
touch "$results_root/test-start-stamp"
if xcodebuild "${common_args[@]}" -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO test-without-building \
  > "$results_root/native-test.log" 2>&1; then
  runner_exit=0
else
  runner_exit=$?
fi
stage test_without_building completed

# Keep the app's own Simulator crash report when a user journey terminates it.
# XCTest's assertion can otherwise appear to be only a missing UI element.
if [[ "$runner_exit" != 0 ]]; then
  app_executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app_bundle/Info.plist")"
  printf 'bundle_executable=%s\n' "$app_executable" > "$results_root/app-crash-report-inventory.txt"
  report_sources=(
    "$HOME/Library/Logs/DiagnosticReports"
    "$HOME/Library/Developer/CoreSimulator/Devices/$simulator_id/data/Library/Logs/DiagnosticReports"
    "/Library/Logs/DiagnosticReports"
  )
  # A per-device diagnose can retain reports even when the usual host and
  # device crash-report directories have not surfaced an .ips file yet.
  diagnostic_root="$temporary_root/simulator-diagnose"
  mkdir -p "$diagnostic_root"
  if xcrun simctl diagnose -b --udid "$simulator_id" --no-archive \
    --timeout=45 --output "$diagnostic_root" \
    > "$results_root/simulator-diagnose.log" 2>&1; then
    report_sources+=("$diagnostic_root")
  fi
  for report_index in "${!report_sources[@]}"; do
    report_source="${report_sources[$report_index]}"
    [[ -d "$report_source" ]] || continue
    report_destination="$results_root/app-crash-reports/source-$report_index"
    while IFS= read -r -d '' report; do
      basename_report="$(basename "$report")"
      printf 'source=%s name=%s\n' "$report_index" "$basename_report" \
        >> "$results_root/app-crash-report-inventory.txt"
      if [[ "$basename_report" == *"$app_executable"* ]]; then
        mkdir -p "$report_destination"
        cp -p "$report" "$report_destination/"
      fi
    done < <(find "$report_source" -type f \
      \( -name '*.ips' -o -name '*.crash' \) \
      -newer "$results_root/test-start-stamp" -print0)
  done
fi
if [[ ! -d "$result_bundle" ]]; then
  reason=native_ios_xcresult_missing
  exit 3
fi

capture_xcresult_json() {
  local output="$1"
  shift
  local attempt
  for attempt in 1 2 3 4; do
    if xcrun xcresulttool get "$@" --path "$result_bundle" --format json \
      > "$output" 2> "$output.stderr"; then
      return 0
    fi
    [[ "$attempt" == 4 ]] || sleep 1
  done
  return 1
}

reason=native_ios_xcresult_raw_receipts_unreadable
stage native_receipt started
if ! capture_xcresult_json "$results_root/native-summary-raw.json" test-results summary ||
   ! capture_xcresult_json "$results_root/native-legacy-object-raw.json" object --legacy; then
  exit 3
fi
stage native_receipt completed

if python3 "$repo_root/scripts/verify_apple_test_execution.py" \
  --result-bundle "$result_bundle" --expected-test-count "$expected_test_count" \
  --reject-runtime-warnings > "$results_root/strict-verifier.log" 2>&1; then
  verify_exit=0
else
  verify_exit=$?
fi

if PYTHONPATH="$repo_root" python3 - "$results_root/native-summary-raw.json" \
  "$results_root/native-legacy-object-raw.json" \
  "$runner_exit" "$verify_exit" "$expected_test_count" \
  "$classification_file" <<'PY'; then
import json
import sys
from pathlib import Path

from scripts.verify_apple_test_execution import (
    combined_warning_messages,
)

summary_path, legacy_path, runner_exit, verify_exit, expected, output = sys.argv[1:]
classification = {
    "product_status": "NOT_RUN",
    "test_system_status": "FAILED_TEST_SYSTEM",
    "reason": "native_result_unreadable",
}
try:
    summary = json.loads(Path(summary_path).read_text())
    legacy = json.loads(Path(legacy_path).read_text())
    warnings = combined_warning_messages(summary, legacy)
    counts = {
        name: summary.get(name, 0)
        for name in ("passedTests", "failedTests", "skippedTests", "expectedFailures")
    }
    if any(isinstance(value, bool) or not isinstance(value, int) or value < 0 for value in counts.values()):
        raise ValueError("invalid native test counts")
    classification["native_counts"] = counts
    classification["runtime_warning_count"] = len(warnings)
    executed = counts["passedTests"] + counts["failedTests"] + counts["expectedFailures"]
    failures = summary.get("testFailures", [])
    if not isinstance(failures, list):
        raise ValueError("invalid native test failures")
    failure_details = []
    for failure in failures:
        if (not isinstance(failure, dict)
                or not isinstance(failure.get("testName"), str)
                or not isinstance(failure.get("failureText"), str)):
            raise ValueError("malformed native test failure")
        failure_text = failure["failureText"]
        if "QUALITY_PRECONDITION:" in failure_text:
            failure_kind = "quality_precondition"
        elif ("Failed to determine hittability" in failure_text
              and "Activation point invalid and no suggested hit points based on element frame" in failure_text):
            # This exact XCTest AX error interrupted the visible-point query
            # and left every attached element frame infinite/zero. It gives no
            # completed product oracle, but the failure remains explicit.
            failure_kind = "ax_actionability_unresolved"
        else:
            failure_kind = "non_precondition_failure"
        failure_details.append({
            "test_name": failure["testName"],
            "failure_text": failure_text,
            "failure_kind": failure_kind,
        })
    if counts["failedTests"] and len({item["test_name"] for item in failure_details}) != counts["failedTests"]:
        raise ValueError("native failure details do not cover every failed test")
    if not counts["failedTests"] and failure_details:
        raise ValueError("native failure details contradict the test counts")
    classification["native_failures"] = failure_details
    failure_kinds = {item["failure_kind"] for item in failure_details}
    if executed != int(expected) or counts["skippedTests"] or counts["expectedFailures"]:
        classification["reason"] = "selected_native_tests_not_exactly_executed"
    elif "non_precondition_failure" in failure_kinds:
        # A second method's precondition or AX error must not erase a real
        # product assertion failure already recorded by another method.
        classification["product_status"] = "FAILED"
        if failure_kinds - {"non_precondition_failure"} or warnings:
            classification["reason"] = "native_product_failure_with_test_system_failure"
        else:
            classification["test_system_status"] = "PASSED"
            classification["reason"] = "native_message_product_oracle_failed"
    elif "ax_actionability_unresolved" in failure_kinds:
        classification["reason"] = "native_ax_actionability_unresolved"
    elif "quality_precondition" in failure_kinds:
        classification["test_system_status"] = "BLOCKED"
        classification["reason"] = "app_owned_quality_precondition_failed"
    elif counts["passedTests"] == int(expected):
        classification["product_status"] = "PASSED"
        if runner_exit == "0" and verify_exit == "0" and not warnings:
            classification["test_system_status"] = "PASSED"
            classification["reason"] = "selected_native_app_owned_message_journeys_clean"
        else:
            classification["reason"] = "product_oracles_passed_but_native_test_system_not_clean"
except Exception as error:
    classification["reason"] = f"native_result_unreadable:{type(error).__name__}"

Path(output).write_text(json.dumps(classification, indent=2, sort_keys=True) + "\n")
print(json.dumps(classification, sort_keys=True))
raise SystemExit(0 if classification["product_status"] == "PASSED" and classification["test_system_status"] == "PASSED" else 1)
PY
  product_status=PASSED
  test_system_status=PASSED
  reason=selected_native_app_owned_message_journeys_clean
  exit 0
fi
reason=native_ios_message_tests_not_clean
exit 3
