#!/usr/bin/env bash
set -euo pipefail

# Direct native diagnostic only. This does not run quality_test.sh, close its
# expired registry/ledger gates, or validate production signing capabilities.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

trial="${DIAGNOSTIC_TRIAL:-1}"
first_run_id="${DIAGNOSTIC_FIRST_RUN_ID:-}"
run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
results_root="$repo_root/build/quality-results/apple-macos-adhoc-ui-diagnostic/trial-${trial}-run-${run_id}-${run_attempt}"
mkdir -p "$results_root"

test_scopes=()
expected_test_count=1
sample_capture_mode=0
host_sample_capture_mode=0
source_sha="$(git rev-parse HEAD)"
product_status=NOT_RUN
test_system_status=BLOCKED
reason=diagnostic_not_started
result_bundle=''
runner_exit=''
classification_file="$results_root/native-classification.json"
summary_file="$results_root/diagnostic-summary.json"

write_summary() {
  local command_status=$?
  trap - EXIT
  python3 - "$summary_file" "$classification_file" "$source_sha" "$trial" \
    "$first_run_id" "$product_status" "$test_system_status" "$reason" \
    "$result_bundle" "$runner_exit" "$command_status" "$expected_test_count" \
    "$sample_capture_mode" "$host_sample_capture_mode" "${test_scopes[@]}" <<'PY'
import json
import sys
from pathlib import Path

(
    output, classification, source_sha, trial, first_run_id, product_status,
    test_system_status, reason, result_bundle, runner_exit, command_status,
    expected_test_count, sample_capture_mode, host_sample_capture_mode, *test_scopes,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "kind": ("direct_native_macos_thing_ax_qos_host_sample_diagnostic"
             if host_sample_capture_mode == "1" else
             "direct_native_macos_thing_ax_qos_sample_diagnostic"
             if sample_capture_mode == "1" else
             "direct_native_macos_adhoc_ui_diagnostic"),
    "quality_gate_status": "NOT_RUN",
    "source_sha": source_sha,
    "trial": int(trial) if trial in {"1", "2"} else trial,
    "first_clean_run_id": first_run_id or None,
    "selected_test": test_scopes[0] if len(test_scopes) == 1 else None,
    "selected_tests": test_scopes,
    "expected_test_count": int(expected_test_count),
    "max_retries": 0,
    "sample_capture_mode": sample_capture_mode == "1",
    "host_sample_capture_mode": host_sample_capture_mode == "1",
    "signing_mode": "temporary_sandboxed_ad_hoc_with_xctest_exceptions",
    "product_status": product_status,
    "test_system_status": test_system_status,
    "reason": reason,
    "result_bundle": result_bundle or None,
    "runner_exit_code": int(runner_exit) if runner_exit else None,
    "script_exit_code": int(command_status),
    "claim_limit": ("Host-side stacks and binary maps for only the App and UI Runner around one Thing AX query; sampling changes scheduling and cannot close the QoS issue or qualify the product. No formal quality gate."
                    if host_sample_capture_mode == "1" else
                    "Diagnostic stacks and timing around one sampled Thing query only; sampling changes scheduling and cannot close the QoS issue or qualify the product. No formal quality gate."
                    if sample_capture_mode == "1" else
                    "Only the selected App-owned macOS UI journeys; no quality gate, real APNs, keychain, cross-process App Group, Release, or distribution claim."),
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

case "${DIAGNOSTIC_MACOS_SCOPE:-thing-relations}" in
  thing-ax-qos-host-sample)
    test_scopes=('PushGo-macOSUITests/PushGo_macOSUITests/testThingRelationsOpenAccurateDetailsAndSurviveRelaunch')
    host_sample_capture_mode=1
    ;;
  thing-ax-qos-sample)
    test_scopes=('PushGo-macOSUITests/PushGo_macOSUITests/testThingRelationsOpenAccurateDetailsAndSurviveRelaunch')
    sample_capture_mode=1
    ;;
  thing-relations)
    test_scopes=('PushGo-macOSUITests/PushGo_macOSUITests/testThingRelationsOpenAccurateDetailsAndSurviveRelaunch')
    ;;
  message-deletion-route)
    test_scopes=('PushGo-macOSUITests/PushGo_macOSUITests/testMessageDeletionRestoresThenCommitsAccurateCanonicalStateAcrossRelaunch')
    ;;
  message-list)
    test_scopes=(
      'PushGo-macOSUITests/PushGo_macOSUITests/testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist'
      'PushGo-macOSUITests/PushGo_macOSUITests/testHistoryCleanupRemovesOnlyOldMessagesAndPersistsAcrossRelaunch'
    )
    expected_test_count=2
    ;;
  message-refresh-failure)
    test_scopes=('PushGo-macOSUITests/PushGo_macOSUITests/testMessageRefreshFailureKeepsSnapshotAndRetryPersistsAccurateResult')
    ;;
  *)
    reason=unsupported_macos_diagnostic_scope
    exit 2
    ;;
esac
only_testing_args=()
for scope in "${test_scopes[@]}"; do
  only_testing_args+=("-only-testing:$scope")
done
test_scopes_csv="$(IFS=,; printf '%s' "${test_scopes[*]}")"

if [[ "$trial" != '1' && "$trial" != '2' ]]; then
  reason=invalid_diagnostic_trial
  exit 2
fi
if [[ "$trial" == '2' && ! "$first_run_id" =~ ^[0-9]+$ ]]; then
  reason=trial_two_requires_reviewed_clean_trial_one_run_id
  exit 2
fi
if [[ "$run_id" == 'local' ]]; then
  reason=diagnostic_requires_isolated_github_runner
  exit 2
fi

reason=macos_console_locked_or_unavailable
if ! "$repo_root/scripts/require_unlocked_apple_ui_console.sh" macos \
  > "$results_root/console-preflight.log" 2>&1; then
  exit 2
fi
printf 'console_status=unlocked\n' > "$results_root/console-preflight.log"
xcodebuild -version > "$results_root/xcode-version.log" 2>&1

temporary_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pushgo-macos-adhoc-ui.XXXXXX")"
derived_data_path="$temporary_root/derived-data"
entitlements_file="$temporary_root/sandbox-only.entitlements"
cat > "$entitlements_file" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.get-task-allow</key><true/>
</dict>
</plist>
PLIST
cp "$entitlements_file" "$results_root/sandbox-only.entitlements"
plutil -lint "$entitlements_file" > "$results_root/entitlements-lint.log" 2>&1

reason=adhoc_build_for_testing_failed
test_system_status=FAILED_TEST_SYSTEM
if ! xcodebuild \
  -project "$repo_root/pushgo.xcodeproj" \
  -scheme PushGo-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -collect-test-diagnostics never \
  -jobs 2 \
  "${only_testing_args[@]}" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  PROVISIONING_PROFILE= \
  "CODE_SIGN_ENTITLEMENTS=$entitlements_file" \
  build-for-testing > "$results_root/build-for-testing.log" 2>&1; then
  tail -n 50 "$results_root/build-for-testing.log"
  exit 3
fi

app_bundle="$derived_data_path/Build/Products/Debug/PushGo.app"
test_runner="$derived_data_path/Build/Products/Debug/PushGo-macOSUITests-Runner.app"
test_bundle="$test_runner/Contents/PlugIns/PushGo-macOSUITests.xctest"
xctestrun_count="$(find "$derived_data_path/Build/Products" -maxdepth 1 -name 'PushGo-macOS_*.xctestrun' -print | wc -l | tr -d ' ')"
if [[ ! -d "$app_bundle" || ! -d "$test_runner" || ! -d "$test_bundle" || "$xctestrun_count" != '1' ]]; then
  reason=adhoc_build_missing_exact_native_products
  exit 3
fi
xctestrun="$(find "$derived_data_path/Build/Products" -maxdepth 1 -name 'PushGo-macOS_*.xctestrun' -print | head -n 1)"
cp "$xctestrun" "$results_root/$(basename "$xctestrun")"
sample_xctestrun=''
if [[ "$sample_capture_mode" == '1' || "$host_sample_capture_mode" == '1' ]]; then
  reason=ax_qos_sample_xctestrun_injection_failed
  diagnostic_env_key=PUSHGO_AX_QOS_SAMPLE_DIAGNOSTIC
  if [[ "$host_sample_capture_mode" == '1' ]]; then
    diagnostic_env_key=PUSHGO_AX_QOS_HOST_SAMPLE_DIAGNOSTIC
  fi
  sample_xctestrun="$derived_data_path/Build/Products/PushGo-macOS_AXQoSSample.xctestrun"
  python3 - "$xctestrun" "$sample_xctestrun" "$diagnostic_env_key" "$run_id" <<'PY'
import plistlib
import sys
from pathlib import Path

source, output = map(Path, sys.argv[1:3])
key, run_id = sys.argv[3:]
specification = plistlib.loads(source.read_bytes())
targets = [
    target
    for configuration in specification.get("TestConfigurations", [])
    for target in configuration.get("TestTargets", [])
    if target.get("BlueprintName") == "PushGo-macOSUITests"
]
if len(targets) != 1 or not isinstance(targets[0].get("TestingEnvironmentVariables"), dict):
    raise SystemExit("expected exactly one macOS UI Runner environment")
environment = targets[0]["TestingEnvironmentVariables"]
if key in environment:
    raise SystemExit("sample switch already set in the build product")
environment[key] = "1"
if key == "PUSHGO_AX_QOS_HOST_SAMPLE_DIAGNOSTIC":
    environment["PUSHGO_AX_QOS_HOST_RUN_ID"] = run_id
output.write_bytes(plistlib.dumps(specification, fmt=plistlib.FMT_XML))
reloaded = plistlib.loads(output.read_bytes())
reloaded_targets = [
    target
    for configuration in reloaded["TestConfigurations"]
    for target in configuration["TestTargets"]
    if target.get("BlueprintName") == "PushGo-macOSUITests"
]
if len(reloaded_targets) != 1 or reloaded_targets[0]["TestingEnvironmentVariables"].get(key) != "1":
    raise SystemExit("sample switch did not survive xctestrun round-trip")
if key == "PUSHGO_AX_QOS_HOST_SAMPLE_DIAGNOSTIC" and reloaded_targets[0]["TestingEnvironmentVariables"].get("PUSHGO_AX_QOS_HOST_RUN_ID") != run_id:
    raise SystemExit("host run identity did not survive xctestrun round-trip")
print("ax_qos_sample_xctestrun_environment=verified")
PY
  plutil -lint "$sample_xctestrun" > "$results_root/sample-xctestrun-lint.log" 2>&1
  cp "$sample_xctestrun" "$results_root/$(basename "$sample_xctestrun")"
fi

reason=adhoc_signature_or_sandbox_entitlements_invalid
if ! {
  codesign --verify --deep --strict --verbose=2 "$app_bundle" &&
    codesign --verify --strict --verbose=2 "$test_runner" &&
    codesign --verify --strict --verbose=2 "$test_bundle" &&
    codesign -dvv "$app_bundle" &&
    codesign -dvv "$test_runner" &&
    codesign -dvv "$test_bundle"
} > "$results_root/signature-verification.log" 2>&1; then
  exit 3
fi
if ! python3 - "$app_bundle" "$results_root/app-entitlements.json" \
  > "$results_root/entitlements-verification.log" 2>&1 <<'PY'; then
import json
import plistlib
import subprocess
import sys
from pathlib import Path

app, output = sys.argv[1:]
process = subprocess.run(
    ["codesign", "-d", "--entitlements", "-", "--xml", app],
    capture_output=True,
    check=True,
)
entitlements = plistlib.loads(process.stdout)
Path(output).write_text(json.dumps(entitlements, indent=2, sort_keys=True) + "\n")
allowed = {
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.get-task-allow",
    # Xcode adds these to the ad-hoc UI test host on macOS 26.4; their values
    # remain checked below. App Group, keychain and other production rights fail.
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.temporary-exception.files.absolute-path.read-only",
    "com.apple.security.temporary-exception.mach-lookup.global-name",
}
if entitlements.get("com.apple.security.app-sandbox") is not True:
    raise SystemExit("the ad-hoc App lost its required sandbox container")
for key in ("com.apple.security.network.client", "com.apple.security.get-task-allow"):
    if entitlements.get(key) is not True:
        raise SystemExit(f"the ad-hoc App lost required test entitlement: {key}")
production_rights = {
    "com.apple.security.application-groups",
    "keychain-access-groups",
    "aps-environment",
    "com.apple.developer.aps-environment",
}
if set(entitlements) & production_rights:
    raise SystemExit(f"production entitlement in ad-hoc App: {sorted(set(entitlements) & production_rights)}")
unexpected = sorted(set(entitlements) - allowed)
if unexpected:
    raise SystemExit(f"unexpected entitlement claims: {unexpected}")
if entitlements.get("com.apple.security.files.user-selected.read-write") not in (None, True):
    raise SystemExit("unexpected user-selected file entitlement value")
read_only_paths = entitlements.get("com.apple.security.temporary-exception.files.absolute-path.read-only")
if read_only_paths is not None and read_only_paths != ["/"]:
    raise SystemExit(f"unexpected XCTest read-only path exception: {read_only_paths!r}")
mach_services = entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name")
test_services = {
    "com.apple.testmanagerd",
    "com.apple.dt.testmanagerd.runner",
    "com.apple.coresymbolicationd",
    "com.apple.coredevice.version",
    "com.apple.coredevice.service",
    "com.apple.remoted",
}
if mach_services is not None and (not isinstance(mach_services, list) or not set(mach_services) <= test_services):
    raise SystemExit(f"unexpected XCTest mach lookup exception: {mach_services!r}")
print("sandboxed_adhoc_test_entitlements=verified")
PY
  exit 3
fi

# Reuse the exact signed products. The established runner owns zero-retry native
# execution, the unlocked-console precondition, and strict xcresult verification.
reason=native_selected_ui_not_executed
mkdir -p "$results_root/native"
host_sample_dir="$results_root/host-sample"
host_sampler_done="$results_root/host-sampler-native-done"
host_sampler_pid=''
host_sampler_exit=''
if [[ "$host_sample_capture_mode" == '1' ]]; then
  touch "$results_root/native-test.log"
  python3 "$repo_root/scripts/ci/capture_macos_thing_ax_qos_host.py" \
    --native-log "$results_root/native-test.log" \
    --done-marker "$host_sampler_done" \
    --output "$host_sample_dir" \
    --run-id "$run_id" \
    > "$results_root/host-sampler.log" 2>&1 &
  host_sampler_pid=$!
fi
if QUALITY_REUSE_BUILT_TESTS=1 \
    QUALITY_XCTESTRUN_PATH="$sample_xctestrun" \
    DERIVED_DATA_PATH="$derived_data_path" \
    RESULTS_ROOT="$results_root/native" \
    TEST_SCOPES="$test_scopes_csv" \
    QUALITY_EXPECTED_TEST_COUNT="$expected_test_count" \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$results_root/runner-status.txt" \
    "$repo_root/scripts/run_macos_ui_tests.sh" \
    > "$results_root/native-test.log" 2>&1; then
  runner_exit=0
else
  runner_exit=$?
fi
if [[ "$host_sample_capture_mode" == '1' ]]; then
  touch "$host_sampler_done"
  if wait "$host_sampler_pid"; then
    host_sampler_exit=0
  else
    host_sampler_exit=$?
  fi
  printf 'host_sampler_exit=%s\n' "$host_sampler_exit" > "$results_root/host-sampler-exit.txt"
fi

result_count="$(find "$results_root/native" -maxdepth 1 -name '*.xcresult' -print | wc -l | tr -d ' ')"
if [[ "$result_count" != '1' ]]; then
  reason=native_xcresult_missing_or_ambiguous
  exit 3
fi
result_bundle="$(find "$results_root/native" -maxdepth 1 -name '*.xcresult' -print | head -n 1)"

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

# Retain the exact output of both Xcode receipt views. The 26.4 summary view
# omitted a test warning present in actionResult.issues.testWarningSummaries;
# the legacy object is therefore mandatory evidence, not an optional fallback.
reason=native_xcresult_raw_receipts_unreadable
if ! capture_xcresult_json "$results_root/native-summary-raw.json" test-results summary ||
   ! capture_xcresult_json "$results_root/native-legacy-object-raw.json" object --legacy; then
  exit 3
fi

if PYTHONPATH="$repo_root" python3 - "$results_root/native-summary-raw.json" \
    "$results_root/native-legacy-object-raw.json" "$results_root/native-test.log" \
    "$results_root/runner-status.txt" "$runner_exit" "$expected_test_count" \
    "$classification_file" "$sample_capture_mode" "$host_sample_capture_mode" \
    "$host_sample_dir/host-sample-summary.json" "$result_bundle" <<'PY'; then
import json
import subprocess
import sys
from pathlib import Path

from scripts.verify_apple_test_execution import combined_warning_messages

summary_path, legacy_path, log_path, runner_status_path, runner_exit, expected_count, output_path, sample_capture_mode, host_sample_capture_mode, host_sample_summary_path, result_bundle = sys.argv[1:]
expected_count = int(expected_count)
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
        raise ValueError("noninteger native test counts")
    classification["native_counts"] = counts
    classification["runtime_warning_count"] = len(warnings)
    runner_status_file = Path(runner_status_path)
    runner_status = runner_status_file.read_text().strip() if runner_status_file.exists() else "missing"
    classification["runner_status"] = runner_status
    executed = counts["passedTests"] + counts["failedTests"] + counts["expectedFailures"]
    log = Path(log_path).read_text(errors="replace")
    if executed != expected_count or counts["skippedTests"] or counts["expectedFailures"]:
        classification["reason"] = "selected_native_test_not_exactly_executed"
    elif host_sample_capture_mode == "1":
        failures = summary.get("testFailures", [])
        if not isinstance(failures, list) or any(
            not isinstance(item, dict) or not isinstance(item.get("testName"), str)
            or not isinstance(item.get("failureText"), str)
            for item in failures
        ):
            raise ValueError("host-sampled method failure details unreadable")
        if len({item["testName"] for item in failures}) != counts["failedTests"]:
            raise ValueError("host-sampled method failures do not match native counts")
        classification["native_failures"] = failures
        host_summary_file = Path(host_sample_summary_path)
        host_summary = json.loads(host_summary_file.read_text()) if host_summary_file.exists() else {}
        classification["host_sample_status"] = host_summary.get("status", "MISSING")
        classification["host_sample_reason"] = host_summary.get("reason")
        if counts["failedTests"]:
            if all("QUALITY_PRECONDITION: AX_QOS_HOST_SAMPLE_BLOCKED" in item["failureText"] for item in failures):
                classification["test_system_status"] = "BLOCKED"
                classification["reason"] = "two_owned_pid_host_sample_precondition_blocked"
            else:
                classification["product_status"] = "FAILED"
                classification["reason"] = "host_sampled_native_method_failed"
        elif counts["passedTests"] == expected_count:
            if host_summary.get("status") != "CAPTURED":
                classification["test_system_status"] = "BLOCKED"
                classification["reason"] = "two_owned_pid_host_sample_incomplete"
            elif warnings:
                classification["sample_capture_status"] = "PASSED"
                classification["reason"] = "two_owned_pid_host_sample_captured_with_runtime_warning"
            elif runner_exit == "0" and runner_status == "PASSED":
                classification["sample_capture_status"] = "PASSED"
                classification["test_system_status"] = "PASSED"
                classification["reason"] = "two_owned_pid_host_sample_captured"
            else:
                classification["sample_capture_status"] = "PASSED"
                classification["reason"] = "two_owned_pid_host_sample_captured_but_runner_not_clean"
    elif sample_capture_mode == "1":
        failures = summary.get("testFailures", [])
        if not isinstance(failures, list) or any(
            not isinstance(item, dict) or not isinstance(item.get("testName"), str)
            or not isinstance(item.get("failureText"), str)
            for item in failures
        ):
            raise ValueError("sampled method failure details unreadable")
        if len({item["testName"] for item in failures}) != counts["failedTests"]:
            raise ValueError("sampled method failures do not match native counts")
        classification["native_failures"] = failures
        if counts["failedTests"]:
            if all("QUALITY_PRECONDITION: AX_QOS_SAMPLE_BLOCKED" in item["failureText"] for item in failures):
                classification["test_system_status"] = "BLOCKED"
                classification["reason"] = "three_pid_sample_precondition_blocked"
            else:
                classification["product_status"] = "FAILED"
                classification["reason"] = "sampled_native_method_failed"
        elif counts["passedTests"] == expected_count:
            test_id = "PushGo_macOSUITests/testThingRelationsOpenAccurateDetailsAndSurviveRelaunch()"
            activities = subprocess.run(
                ["xcrun", "xcresulttool", "get", "test-results", "activities",
                 "--path", result_bundle, "--test-id", test_id],
                capture_output=True, text=True, check=True,
            )
            Path(output_path).with_name("native-activities-raw.json").write_text(activities.stdout)
            names = set()
            def collect_attachments(value):
                if isinstance(value, dict):
                    for item in value.get("attachments", []):
                        if isinstance(item, dict) and isinstance(item.get("name"), str):
                            names.add(item["name"])
                    for child in value.values():
                        collect_attachments(child)
                elif isinstance(value, list):
                    for child in value:
                        collect_attachments(child)
            collect_attachments(json.loads(activities.stdout))
            required = {
                "thing-ax-qos-query-timing",
                "thing-ax-qos-runner-sample",
                "thing-ax-qos-app-sample",
                "thing-ax-qos-theme-widget-sample",
            }
            classification["sample_attachment_names"] = sorted(names & required)
            if not required <= names:
                classification["reason"] = "three_pid_sample_attachments_missing"
            elif warnings:
                classification["sample_capture_status"] = "PASSED"
                classification["reason"] = "three_pid_sample_captured_with_runtime_warning"
            elif runner_exit == "0" and runner_status == "PASSED":
                classification["sample_capture_status"] = "PASSED"
                classification["test_system_status"] = "PASSED"
                classification["reason"] = "three_pid_sample_captured"
            else:
                classification["sample_capture_status"] = "PASSED"
                classification["reason"] = "three_pid_sample_captured_but_runner_not_clean"
    elif counts["passedTests"] == expected_count:
        classification["product_status"] = "PASSED"
        if runner_exit == "0" and runner_status == "PASSED" and not warnings:
            classification["test_system_status"] = "PASSED"
            classification["reason"] = "clean_native_selected_journeys"
        else:
            classification["reason"] = "product_oracle_passed_but_native_test_system_not_clean"
    elif "QUALITY_PRECONDITION:" in log:
        classification["test_system_status"] = "BLOCKED"
        classification["reason"] = "app_owned_quality_precondition_failed"
    else:
        classification["product_status"] = "FAILED"
        classification["test_system_status"] = "FAILED_TEST_SYSTEM" if warnings else "PASSED"
        classification["reason"] = "native_selected_product_oracle_failed"
except Exception as error:
    classification["reason"] = f"native_result_unreadable:{type(error).__name__}"

Path(output_path).write_text(json.dumps(classification, indent=2, sort_keys=True) + "\n")
print(json.dumps(classification, sort_keys=True))
if sample_capture_mode == "1" or host_sample_capture_mode == "1":
    success = (classification.get("sample_capture_status") == "PASSED"
               and classification["test_system_status"] == "PASSED")
else:
    success = (classification["product_status"] == "PASSED"
               and classification["test_system_status"] == "PASSED")
raise SystemExit(0 if success else 1)
PY
  exit 0
else
  exit 1
fi
