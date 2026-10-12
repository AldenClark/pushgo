#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-macOS}"
iterations="${ITERATIONS:-50}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/build/.deriveddata-macos-ui}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/macos-startup-reliability}"
test_scope="${TEST_SCOPE:-PushGo-macOSUITests/PushGo_macOSUITests/testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState}"
problem_reporter_cleaner="$repo_root/scripts/close_macos_problem_reporter.sh"
test_app_executable="$derived_data_path/Build/Products/Debug/PushGo.app/Contents/MacOS/PushGo"
test_runner_executable="$derived_data_path/Build/Products/Debug/PushGo-macOSUITests-Runner.app/Contents/MacOS/PushGo-macOSUITests-Runner"
caffeinate_pid=""
problem_reporter_monitor_pid=""
problem_reporter_monitor_log=""

if [[ ! "$iterations" =~ ^[0-9]+$ ]] || (( iterations < 1 || iterations > 100 )); then
  echo "status=BLOCKED"
  echo "reason=iterations_must_be_between_1_and_100:$iterations"
  exit 2
fi

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

python3 "$repo_root/scripts/quality_test_system_issues.py" --check
"$repo_root/scripts/require_unlocked_apple_ui_console.sh" macos

/usr/bin/caffeinate -dimsu -w $$ &
caffeinate_pid=$!
"$problem_reporter_cleaner"
close_stale_test_processes

campaign_id="$(date +%Y%m%d-%H%M%S)"
campaign_root="$results_root/$campaign_id"
mkdir -p "$campaign_root"
problem_reporter_monitor_log="$campaign_root/problem-reporter-monitor.log"
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
  "-only-testing:${test_scope}"
)

echo "==> build macOS startup reliability test once"
xcodebuild "${common_args[@]}" build-for-testing

log_file="$campaign_root/campaign.log"
: >"$log_file"
started_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
command_status=0
for (( iteration = 1; iteration <= iterations; iteration++ )); do
  result_bundle="$campaign_root/iteration-$(printf '%03d' "$iteration").xcresult"
  printf '==> startup iteration %d/%d\n' "$iteration" "$iterations" >>"$log_file"
  set +e
  xcodebuild "${common_args[@]}" \
    -resultBundlePath "$result_bundle" \
    test-without-building >>"$log_file" 2>&1
  iteration_status=$?
  set -e
  if (( iteration_status != 0 )); then
    command_status=$iteration_status
  fi
  "$problem_reporter_cleaner"
done
finished_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
elapsed_ms=$(((finished_ns - started_ns) / 1000000))

"$problem_reporter_cleaner"
if ! kill -0 "$problem_reporter_monitor_pid" >/dev/null 2>&1; then
  wait "$problem_reporter_monitor_pid" || monitor_status=$?
  echo "status=BLOCKED"
  echo "reason=macos_problem_reporter_cleanup_failed:${monitor_status:-unknown}"
  echo "monitor_log=$problem_reporter_monitor_log"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 2
fi

classification="$(python3 "$repo_root/scripts/quality_test_system_issues.py" --match-file "$log_file" 2>/dev/null || true)"
issue_ids="$(printf '%s\n' "$classification" | sed -n 's/^classification_issue_ids=//p')"
report="$campaign_root/summary.json"

python3 - "$log_file" "$report" "$iterations" "$test_scope" "$command_status" "$issue_ids" "$elapsed_ms" "$campaign_root" "$problem_reporter_monitor_log" <<'PY'
import json, math, os, re, statistics, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path

(log_path, report_path, requested, test_scope, command_status, issue_ids_raw,
 elapsed_ms, campaign_root, monitor_log) = sys.argv[1:]
text = Path(log_path).read_text(encoding="utf-8", errors="replace")
method = test_scope.rsplit("/", 1)[-1]
escaped = re.escape(method)
started = len(re.findall(rf"Test Case .*{escaped}.* started\.", text))
passed_matches = re.findall(rf"Test Case .*{escaped}.* passed \(([0-9.]+) seconds\)", text)
failed_matches = re.findall(rf"Test Case .*{escaped}.* failed \(([0-9.]+) seconds\)", text)
ordered_results = re.findall(
    rf"Test Case .*{escaped}.* (passed|failed) \(([0-9.]+) seconds\)",
    text,
)
passed = len(passed_matches)
failed = len(failed_matches)
total = int(requested)
minimum = math.ceil(total * 0.98)
issue_ids = sorted({item for item in issue_ids_raw.split(",") if item})
precondition = "apple-quality-precondition" in issue_ids
activation_failures = len(re.findall(r"error: .*Failed to activate application .*current state: Running Background", text))

if precondition:
    product_status = "NOT_RUN"
    test_system_status = "BLOCKED"
elif failed and activation_failures == failed:
    product_status = "NOT_RUN"
    test_system_status = "FLAKY"
elif failed:
    product_status = "FAILED"
    test_system_status = "PASSED"
elif int(command_status) != 0 or started != total or passed != total:
    product_status = "NOT_RUN"
    test_system_status = "BLOCKED"
else:
    product_status = "PASSED"
    test_system_status = "PASSED"

durations = [float(value) for value in passed_matches + failed_matches]
def percentile(values, ratio):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * ratio) - 1)] if ordered else None

monitor_text = Path(monitor_log).read_text(encoding="utf-8", errors="replace")
closed_dialogs = sum(int(value) for value in re.findall(r"problem_reporter_closed=([0-9]+)", monitor_text))
iterations = [
    {"index": index + 1, "status": status.upper(), "duration_seconds": float(value)}
    for index, (status, value) in enumerate(ordered_results)
]

payload = {
    "schema_version": 1,
    "platform": "apple-macos-host",
    "generated_at": datetime.now(timezone.utc).isoformat(),
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
        "scope_notice": "Observed host UI-test journey duration; no physical-device product SLO is inferred.",
    },
    "iterations": iterations,
    "problem_reporter_dialogs_closed": closed_dialogs,
    "business_retries": 0,
    "product_status": product_status,
    "test_system_status": test_system_status,
    "test_system_issue_ids": issue_ids,
    "xctest_activation_failures_before_business_oracle": activation_failures,
    "calibration_only": total != 50,
    "startup_reliability_exit_criteria_met": total == 50 and passed == total and not issue_ids,
    "oracle": "Every independently planned XCTest invocation creates a fresh App-owned empty.clean Store, reaches the accurate Messages empty state, performs a real Settings-to-Messages navigation round trip, and ends in the same accurate empty state. The test bundle is built once; product retries are forbidden.",
    "log": str(Path(log_path).resolve()),
    "result_bundles": [str(path.resolve()) for path in sorted(Path(campaign_root).glob("iteration-*.xcresult"))],
    "problem_reporter_monitor_log": str(Path(monitor_log).resolve()),
}
path = Path(report_path)
with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    temporary = handle.name
os.replace(temporary, path)
print(json.dumps(payload, ensure_ascii=False, indent=2))
if product_status != "PASSED" or test_system_status != "PASSED":
    raise SystemExit(1 if product_status == "FAILED" else 2)
PY

echo "summary=$report"
