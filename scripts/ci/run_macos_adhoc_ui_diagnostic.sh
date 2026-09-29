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

test_scope='PushGo-macOSUITests/PushGo_macOSUITests/testThingRelationsOpenAccurateDetailsAndSurviveRelaunch'
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
    "$result_bundle" "$runner_exit" "$command_status" "$test_scope" <<'PY'
import json
import sys
from pathlib import Path

(
    output, classification, source_sha, trial, first_run_id, product_status,
    test_system_status, reason, result_bundle, runner_exit, command_status,
    test_scope,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "kind": "direct_native_macos_adhoc_ui_diagnostic",
    "quality_gate_status": "NOT_RUN",
    "source_sha": source_sha,
    "trial": int(trial) if trial in {"1", "2"} else trial,
    "first_clean_run_id": first_run_id or None,
    "selected_test": test_scope,
    "signing_mode": "temporary_sandboxed_ad_hoc_with_xctest_exceptions",
    "product_status": product_status,
    "test_system_status": test_system_status,
    "reason": reason,
    "result_bundle": result_bundle or None,
    "runner_exit_code": int(runner_exit) if runner_exit else None,
    "script_exit_code": int(command_status),
    "claim_limit": "One App-owned macOS Thing journey only; no quality gate, real APNs, keychain, cross-process App Group, Release, or distribution claim.",
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
  "-only-testing:$test_scope" \
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
reason=native_thing_ui_not_executed
mkdir -p "$results_root/native"
if QUALITY_REUSE_BUILT_TESTS=1 \
    DERIVED_DATA_PATH="$derived_data_path" \
    RESULTS_ROOT="$results_root/native" \
    TEST_SCOPES="$test_scope" \
    QUALITY_EXPECTED_TEST_COUNT=1 \
    MAX_RETRIES=0 \
    QUALITY_RUNNER_STATUS_FILE="$results_root/runner-status.txt" \
    "$repo_root/scripts/run_macos_ui_tests.sh" \
    > "$results_root/native-test.log" 2>&1; then
  runner_exit=0
else
  runner_exit=$?
fi

result_count="$(find "$results_root/native" -maxdepth 1 -name '*.xcresult' -print | wc -l | tr -d ' ')"
if [[ "$result_count" != '1' ]]; then
  reason=native_xcresult_missing_or_ambiguous
  exit 3
fi
result_bundle="$(find "$results_root/native" -maxdepth 1 -name '*.xcresult' -print | head -n 1)"

if PYTHONPATH="$repo_root" python3 - "$result_bundle" "$results_root/native-test.log" \
    "$results_root/runner-status.txt" "$runner_exit" "$classification_file" <<'PY'; then
import json
import sys
from pathlib import Path

from scripts.verify_apple_test_execution import read_native_summary, runtime_warning_messages

result_path, log_path, runner_status_path, runner_exit, output_path = sys.argv[1:]
classification = {
    "product_status": "NOT_RUN",
    "test_system_status": "FAILED_TEST_SYSTEM",
    "reason": "native_result_unreadable",
}
try:
    summary = read_native_summary(Path(result_path))
    warnings = runtime_warning_messages(summary)
    counts = {
        name: summary.get(name, 0)
        for name in ("passedTests", "failedTests", "skippedTests", "expectedFailures")
    }
    if any(isinstance(value, bool) or not isinstance(value, int) for value in counts.values()):
        raise ValueError("noninteger native test counts")
    classification["native_counts"] = counts
    classification["runtime_warning_count"] = len(warnings)
    runner_status_file = Path(runner_status_path)
    runner_status = runner_status_file.read_text().strip() if runner_status_file.exists() else "missing"
    classification["runner_status"] = runner_status
    executed = counts["passedTests"] + counts["failedTests"] + counts["expectedFailures"]
    log = Path(log_path).read_text(errors="replace")
    if executed != 1 or counts["skippedTests"] or counts["expectedFailures"]:
        classification["reason"] = "selected_native_test_not_exactly_executed"
    elif counts["passedTests"] == 1:
        classification["product_status"] = "PASSED"
        if runner_exit == "0" and runner_status == "PASSED" and not warnings:
            classification["test_system_status"] = "PASSED"
            classification["reason"] = "one_clean_native_thing_journey"
        else:
            classification["reason"] = "product_oracle_passed_but_native_test_system_not_clean"
    elif "QUALITY_PRECONDITION:" in log:
        classification["test_system_status"] = "BLOCKED"
        classification["reason"] = "app_owned_quality_precondition_failed"
    else:
        classification["product_status"] = "FAILED"
        classification["test_system_status"] = "FAILED_TEST_SYSTEM" if warnings else "PASSED"
        classification["reason"] = "native_thing_product_oracle_failed"
except Exception as error:
    classification["reason"] = f"native_result_unreadable:{type(error).__name__}"

Path(output_path).write_text(json.dumps(classification, indent=2, sort_keys=True) + "\n")
print(json.dumps(classification, sort_keys=True))
raise SystemExit(0 if classification["product_status"] == "PASSED" and classification["test_system_status"] == "PASSED" else 1)
PY
  exit 0
else
  exit 1
fi
