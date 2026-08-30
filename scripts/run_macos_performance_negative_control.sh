#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
performance_scope="PushGo-macOSUITests/PushGo_macOSUITests/testSlowLargeMessageLoadTripsAccurateContentBudget"
result_file="$repo_root/build/quality-results/apple-performance-macos-slow-load-negative-control.json"
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/pushgo-macos-performance-negative.XXXXXX")"
runner_log="$run_dir/runner.log"
runner_status_file="$run_dir/runner-status.txt"

cleanup() {
  rm -rf "$run_dir"
}
trap cleanup EXIT

blocked() {
  printf 'status=BLOCKED\nreason=%s\n' "$1" >&2
  exit 2
}

failed_test_system() {
  printf 'status=FAILED_TEST_SYSTEM\nreason=%s\n' "$1" >&2
  exit 4
}

set +e
QUALITY_REUSE_BUILT_TESTS="${QUALITY_REUSE_BUILT_TESTS:-1}" \
  QUALITY_ALLOW_EXPECTED_FAILURES=1 \
  TEST_SCOPES="$performance_scope" \
  MAX_RETRIES=0 \
  RESULTS_ROOT="$repo_root/build/quality-results/macos-performance-negative" \
  QUALITY_RUNNER_STATUS_FILE="$runner_status_file" \
  "$repo_root/scripts/run_macos_ui_tests.sh" >"$runner_log" 2>&1
runner_exit=$?
set -e

if (( runner_exit == 2 || runner_exit == 3 )); then
  tail -n 80 "$runner_log" >&2
  blocked "macOS UI infrastructure failed before the slow-load product interval could be judged"
fi
if (( runner_exit != 0 )); then
  tail -n 80 "$runner_log" >&2
  failed_test_system "macOS slow-load sensitivity control did not complete its strict expected-failure contract"
fi

failure_line="$(rg -o 'macOS slow-load negative control: launch-to-accurate-content took [0-9]+ms; budget=8000ms' "$runner_log" | head -n 1 || true)"
[[ -n "$failure_line" ]] || {
  tail -n 80 "$runner_log" >&2
  failed_test_system "macOS slow-load run completed without the exact launch-to-accurate-content budget oracle"
}

result_bundle="$(rg -o 'result_bundle=.*' "$runner_log" | tail -n 1 | cut -d= -f2- || true)"
[[ -n "$result_bundle" && -d "$result_bundle" ]] ||
  failed_test_system "macOS slow-load run did not expose its native result bundle"
summary_file="$run_dir/xcresult-summary.json"
if ! xcrun xcresulttool get test-results summary \
  --path "$result_bundle" \
  --format json >"$summary_file"; then
  failed_test_system "macOS slow-load native result summary could not be read"
fi

mkdir -p "$(dirname "$result_file")"
python3 - "$result_file" "$failure_line" "$summary_file" "$result_bundle" <<'PY'
import json
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

output, failure, summary_path, result_bundle = sys.argv[1:]
match = re.fullmatch(
    r"macOS slow-load negative control: launch-to-accurate-content took (\d+)ms; budget=(\d+)ms",
    failure,
)
if match is None:
    raise SystemExit("unexpected macOS slow-load failure format")
summary = json.loads(Path(summary_path).read_text(encoding="utf-8"))
counts = {
    name: summary.get(name, 0)
    for name in ("passedTests", "failedTests", "expectedFailures")
}
if counts != {"passedTests": 0, "failedTests": 0, "expectedFailures": 1}:
    raise SystemExit(f"unexpected macOS slow-load native test counts: {counts}")
payload = {
    "schema_version": 1,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
    "platform": "apple-macos",
    "environment": {"kind": "controlled-local-host"},
    "workload": {"fixture": "messages.large", "canonical_rows": 1000},
    "interval": "cold process start -> exact canonical row visible",
    "injected_message_load_delay_ms": 8000,
    "budget_ms": int(match.group(2)),
    "observed_ms": int(match.group(1)),
    "product_status": "NOT_RUN",
    "test_system_status": "PASSED",
    "status_reason": "the deliberately over-budget load was rejected only after exact content became visible",
    "native_result_bundle": result_bundle,
    "native_test_counts": counts,
}
target = Path(output)
with tempfile.NamedTemporaryFile("w", dir=target.parent, delete=False, encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    temporary = Path(handle.name)
temporary.replace(target)
PY

printf 'status=PASSED\n'
printf 'claim=macOS slow 1k canonical load trips launch-to-accurate-content budget\n'
printf 'evidence=%s\n' "$result_file"
