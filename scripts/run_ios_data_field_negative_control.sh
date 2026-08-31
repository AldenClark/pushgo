#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
control_scope="PushGo-iOSUITests/PushGo_iOSUITests/testLargeMessageDataFieldOracleRejectsWrongCanonicalBody"
results_root="${QUALITY_RESULTS_ROOT:-$repo_root/build/quality-results}"
result_file="$results_root/apple-data-field-negative-control.json"
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/pushgo-ios-data-field-negative.XXXXXX")"
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
  TEST_SCOPES="$control_scope" \
  MAX_RETRIES=0 \
  RESULTS_ROOT="$results_root/ios-data-field-negative" \
  QUALITY_RUNNER_STATUS_FILE="$runner_status_file" \
  "$repo_root/scripts/run_ios_ui_tests.sh" >"$runner_log" 2>&1
runner_exit=$?
set -e

if (( runner_exit == 2 || runner_exit == 3 )); then
  tail -n 80 "$runner_log" >&2
  blocked "iOS UI infrastructure failed before the visible data field could be judged"
fi
if (( runner_exit != 0 )); then
  tail -n 80 "$runner_log" >&2
  failed_test_system "iOS data-field sensitivity control did not complete its strict expected-failure contract"
fi

failure_line="$(rg -o 'data-field negative control: accepted an intentionally wrong canonical body' "$runner_log" | head -n 1 || true)"
[[ -n "$failure_line" ]] || {
  tail -n 80 "$runner_log" >&2
  failed_test_system "iOS data-field run completed without the exact wrong-body oracle"
}

mkdir -p "$(dirname "$result_file")"
python3 - "$result_file" <<'PY'
import json
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

target = Path(sys.argv[1])
payload = {
    "schema_version": 1,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
    "platform": "apple-ios",
    "environment": {"kind": "controlled-simulator"},
    "workload": {
        "fixture": "messages.large",
        "canonical_row": "Quality message 999",
        "field": "message.body",
    },
    "product_status": "NOT_RUN",
    "test_system_status": "PASSED",
    "status_reason": "the exact visible-field oracle rejected a fixed wrong canonical body after proving the real title and body",
}
with tempfile.NamedTemporaryFile("w", dir=target.parent, delete=False, encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    temporary = Path(handle.name)
temporary.replace(target)
PY

printf 'status=PASSED\n'
printf 'claim=iOS exact visible message-body oracle rejects a fixed wrong canonical field\n'
printf 'evidence=%s\n' "$result_file"
