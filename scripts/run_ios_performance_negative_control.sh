#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
performance_scope="PushGo-iOSUITests/PushGo_iOSUITests/testSlowLargeMessageLoadTripsAccurateContentBudget"
result_file="$repo_root/build/quality-results/apple-performance-slow-load-negative-control.json"
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/pushgo-ios-performance-negative.XXXXXX")"
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
  RESULTS_ROOT="$repo_root/build/quality-results/ios-performance-negative" \
  QUALITY_RUNNER_STATUS_FILE="$runner_status_file" \
  "$repo_root/scripts/run_ios_ui_tests.sh" >"$runner_log" 2>&1
runner_exit=$?
set -e

if (( runner_exit == 2 || runner_exit == 3 )); then
  tail -n 80 "$runner_log" >&2
  blocked "iOS UI infrastructure failed before the slow-load product interval could be judged"
fi
if (( runner_exit != 0 )); then
  tail -n 80 "$runner_log" >&2
  failed_test_system "iOS slow-load sensitivity control did not complete its strict expected-failure contract"
fi

failure_line="$(rg -o 'slow-load negative control: launch-to-accurate-content took [0-9]+ms; budget=8000ms' "$runner_log" | head -n 1 || true)"
[[ -n "$failure_line" ]] || {
  tail -n 80 "$runner_log" >&2
  failed_test_system "iOS slow-load run failed without the exact launch-to-accurate-content budget oracle"
}

mkdir -p "$(dirname "$result_file")"
python3 - "$result_file" "$failure_line" <<'PY'
import json
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

output, failure = sys.argv[1:]
match = re.fullmatch(
    r"slow-load negative control: launch-to-accurate-content took (\d+)ms; budget=(\d+)ms",
    failure,
)
if match is None:
    raise SystemExit("unexpected iOS slow-load failure format")
payload = {
    "schema_version": 1,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
    "platform": "apple-ios",
    "environment": {"kind": "controlled-simulator"},
    "workload": {"fixture": "messages.large", "canonical_rows": 1000},
    "interval": "cold process start -> exact canonical title visible",
    "injected_message_load_delay_ms": 8000,
    "budget_ms": int(match.group(2)),
    "observed_ms": int(match.group(1)),
    "product_status": "NOT_RUN",
    "test_system_status": "PASSED",
    "status_reason": "the deliberately over-budget load was rejected only after exact content became visible",
}
target = Path(output)
with tempfile.NamedTemporaryFile("w", dir=target.parent, delete=False, encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    temporary = Path(handle.name)
temporary.replace(target)
PY

printf 'status=PASSED\n'
printf 'claim=iOS slow 1k canonical load trips launch-to-accurate-content budget\n'
printf 'evidence=%s\n' "$result_file"
