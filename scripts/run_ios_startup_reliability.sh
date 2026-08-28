#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-iOS}"
app_bundle_identifier="${APP_BUNDLE_IDENTIFIER:-io.ethan.pushgo}"
iterations="${ITERATIONS:-50}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.deriveddata-ui-tests}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/ios-startup-reliability}"
test_scope="${TEST_SCOPE:-PushGo-iOSUITests/PushGo_iOSUITests/testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState}"

if [[ ! "$iterations" =~ ^[0-9]+$ ]] || (( iterations < 1 || iterations > 100 )); then
  echo "status=BLOCKED"
  echo "reason=iterations_must_be_between_1_and_100:$iterations"
  exit 2
fi

python3 "$repo_root/scripts/quality_test_system_issues.py" --check

doctor_output="$("$repo_root/scripts/quality_doctor.sh")"
printf '%s\n' "$doctor_output"
target="$(printf '%s\n' "$doctor_output" | awk -F= '$1 == "simulator_id" { print $2; exit }')"
if [[ -z "$target" ]]; then
  echo "status=BLOCKED"
  echo "reason=no_available_ios_simulator"
  exit 2
fi

campaign_id="$(date +%Y%m%d-%H%M%S)"
campaign_root="$results_root/$campaign_id"
mkdir -p "$campaign_root"

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
  "-only-testing:${test_scope}"
)

xcrun simctl shutdown "$target" >/dev/null 2>&1 || true
xcrun simctl boot "$target" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$target" -b
echo "==> build startup reliability test once"
xcodebuild "${common_args[@]}" build-for-testing

log_file="$campaign_root/campaign.log"
result_bundle="$campaign_root/campaign.xcresult"
xcrun simctl terminate "$target" "$app_bundle_identifier" >/dev/null 2>&1 || true
started_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
set +e
xcodebuild "${common_args[@]}" \
  -test-iterations "$iterations" \
  -test-repetition-relaunch-enabled YES \
  -resultBundlePath "$result_bundle" \
  test-without-building >"$log_file" 2>&1
command_status=$?
set -e
finished_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
elapsed_ms=$(((finished_ns - started_ns) / 1000000))
classification="$(python3 "$repo_root/scripts/quality_test_system_issues.py" --match-file "$log_file" 2>/dev/null || true)"
issue_ids="$(printf '%s\n' "$classification" | sed -n 's/^classification_issue_ids=//p')"

report="$campaign_root/summary.json"
python3 - "$log_file" "$report" "$iterations" "$target" "$test_scope" "$command_status" "$issue_ids" "$elapsed_ms" "$result_bundle" <<'PY'
import json, math, os, re, statistics, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path

log_path, report_path, requested, target, test_scope, command_status, issue_ids_raw, elapsed_ms, result_bundle = sys.argv[1:]
text = Path(log_path).read_text(encoding="utf-8", errors="replace")
method = test_scope.rsplit("/", 1)[-1]
escaped = re.escape(method)
started = len(re.findall(rf"Test Case .*{escaped}.* started\.", text))
passed = len(re.findall(rf"Test Case .*{escaped}.* passed \(", text))
failed = len(re.findall(rf"Test Case .*{escaped}.* failed \(", text))
durations = [
    float(value)
    for value in re.findall(rf"Test Case .*{escaped}.* passed \(([0-9.]+) seconds\)", text)
]
total = int(requested)
minimum = math.ceil(total * 0.98)
def percentile(values, ratio):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * ratio) - 1)] if ordered else None
issue_ids = sorted({item for item in issue_ids_raw.split(",") if item})
precondition = "apple-quality-precondition" in issue_ids
runner_flake = "apple-simulator-xctest-runner-launch" in issue_ids and failed == 0
product_failures = failed if not precondition else 0
product_status = "FAILED" if product_failures else ("PASSED" if passed >= minimum else "NOT_RUN")
if precondition:
    test_system_status = "BLOCKED"
elif runner_flake:
    test_system_status = "FLAKY" if passed >= minimum else "FAILED"
elif int(command_status) != 0 or started != total or passed != total:
    test_system_status = "PASSED" if product_failures else "BLOCKED"
else:
    test_system_status = "PASSED"
payload = {
    "schema_version": 1,
    "platform": "apple-ios-simulator",
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "device_id": target,
    "test_scope": test_scope,
    "requested_iterations": total,
    "started_iterations": started,
    "passed_iterations": passed,
    "failed_iterations": failed,
    "minimum_successes_for_98_percent": minimum,
    "success_rate": passed / total,
    "elapsed_ms": int(elapsed_ms),
    "iteration_duration_seconds": {
        "sample_count": len(durations),
        "p50": statistics.median(durations) if durations else None,
        "p95": percentile(durations, 0.95),
        "max": max(durations) if durations else None,
        "scope_notice": "Observed UI-test journey duration; no physical-device product SLO is inferred.",
    },
    "product_status": product_status,
    "test_system_status": test_system_status,
    "test_system_issue_ids": issue_ids,
    "startup_reliability_exit_criteria_met": passed == total and not issue_ids,
    "resolved_runner_flake_exit_evidence_reproduced": passed == total and not issue_ids,
    "oracle": "XCTest repetitions relaunch the test process; each repetition launches a fresh App-owned empty.clean session and requires the functional empty state in an isolated database. No retry-on-failure is enabled.",
    "log": str(Path(log_path).resolve()),
    "result_bundle": str(Path(result_bundle).resolve()),
}
path = Path(report_path)
with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    temporary = handle.name
os.replace(temporary, path)
print(json.dumps(payload, ensure_ascii=False, indent=2))
if product_status != "PASSED" or test_system_status != "PASSED":
    raise SystemExit(2 if test_system_status in {"BLOCKED", "FLAKY", "FAILED"} else 1)
PY

echo "summary=$report"
