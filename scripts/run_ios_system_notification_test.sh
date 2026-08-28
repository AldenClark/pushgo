#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="${PROJECT_PATH:-$repo_root/pushgo.xcodeproj}"
scheme="${SCHEME:-PushGo-iOS}"
app_bundle_identifier="${APP_BUNDLE_IDENTIFIER:-io.ethan.pushgo}"
runner_bundle_identifier="${UI_TEST_RUNNER_BUNDLE_IDENTIFIER:-io.ethan.pushgo.uitests.xctrunner}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.deriveddata-ui-tests}"
results_root="${RESULTS_ROOT:-$repo_root/build/quality-results/ios-system-notification}"
runner_status_file="${QUALITY_RUNNER_STATUS_FILE:-}"
runner_issue_file="${QUALITY_RUNNER_ISSUE_FILE:-}"
test_scope="PushGo-iOSUITests/PushGo_iOSSystemNotificationTests/testSystemNotificationTapOpensAccurateReadDetailAndPersists"
readiness_filename="pushgo-system-notification-ready"

set_runner_status() {
  [[ -z "$runner_status_file" ]] || printf '%s\n' "$1" >"$runner_status_file"
}

record_classification() {
  local classification="$1"
  local issue_ids
  printf '%s\n' "$classification"
  issue_ids="$(printf '%s\n' "$classification" | sed -n 's/^classification_issue_ids=//p')"
  if [[ -n "$runner_issue_file" && -n "$issue_ids" ]]; then
    printf '%s\n' "$issue_ids" | tr ',' '\n' >>"$runner_issue_file"
  fi
}

classify_test_system_log() {
  local log_file="$1"
  local classification
  classification="$(python3 "$repo_root/scripts/quality_test_system_issues.py" --match-file "$log_file")" || return 1
  record_classification "$classification"
}

python3 "$repo_root/scripts/quality_test_system_issues.py" --check >/dev/null

doctor_output="$("$repo_root/scripts/quality_doctor.sh")"
printf '%s\n' "$doctor_output"
target="$(printf '%s\n' "$doctor_output" | awk -F= '$1 == "simulator_id" { print $2; exit }')"
if [[ -z "$target" ]]; then
  set_runner_status BLOCKED
  echo "status=BLOCKED"
  echo "reason=no_available_ios_simulator"
  exit 2
fi

mkdir -p "$results_root"
xcrun simctl shutdown "$target" >/dev/null 2>&1 || true
xcrun simctl boot "$target" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$target" -b

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

echo "==> build-for-testing system notification journey"
xcodebuild "${common_args[@]}" build-for-testing

# A clean install makes the OS authorization state deterministic. The product requests permission
# through its normal launch path, and the UI test accepts the real system prompt when XCTest has
# not already handled it. No notification database or preference is mutated by the harness.
xcrun simctl uninstall "$target" "$app_bundle_identifier" >/dev/null 2>&1 || true
xcrun simctl uninstall "$target" "$runner_bundle_identifier" >/dev/null 2>&1 || true

run_id="$(date +%Y%m%d-%H%M%S)"
log_file="$results_root/system-notification-$run_id.log"
result_bundle="$results_root/system-notification-$run_id.xcresult"
echo "==> test-without-building and wait for App-owned background readiness"
xcodebuild "${common_args[@]}" \
  -resultBundlePath "$result_bundle" \
  test-without-building >"$log_file" 2>&1 &
xcode_pid=$!

terminate_xcodebuild() {
  if kill -0 "$xcode_pid" >/dev/null 2>&1; then
    kill "$xcode_pid" >/dev/null 2>&1 || true
    wait "$xcode_pid" >/dev/null 2>&1 || true
  fi
}
trap terminate_xcodebuild EXIT

deadline=$((SECONDS + 75))
readiness_path=""
while (( SECONDS < deadline )); do
  if ! kill -0 "$xcode_pid" >/dev/null 2>&1; then
    set +e
    wait "$xcode_pid"
    test_status=$?
    set -e
    trap - EXIT
    tail -80 "$log_file" || true
    if classify_test_system_log "$log_file"; then
      set_runner_status BLOCKED
      echo "status=BLOCKED"
      echo "reason=registered_test_system_failure_before_notification_readiness"
      echo "log=$log_file"
      echo "result_bundle=$result_bundle"
      exit 2
    fi
    echo "status=FAILED"
    echo "reason=ui_test_exited_before_notification_readiness"
    echo "xcode_status=$test_status"
    echo "log=$log_file"
    echo "result_bundle=$result_bundle"
    exit 1
  fi

  runner_container="$(xcrun simctl get_app_container "$target" "$runner_bundle_identifier" data 2>/dev/null || true)"
  if [[ -n "$runner_container" ]]; then
    readiness_path="$runner_container/tmp/$readiness_filename"
    if [[ -s "$readiness_path" ]]; then
      break
    fi
  fi
  sleep 0.2
done

if [[ -z "$readiness_path" || ! -f "$readiness_path" ]]; then
  set_runner_status BLOCKED
  echo "status=BLOCKED"
  echo "reason=system_notification_readiness_timeout"
  echo "log=$log_file"
  exit 2
fi

if ! payload="$(python3 - "$readiness_path" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for key in ("title", "body", "message_id"):
    if not isinstance(contract.get(key), str) or not contract[key]:
        raise SystemExit(f"invalid readiness field: {key}")
payload = {
    "aps": {
        "alert": {"title": contract["title"], "body": contract["body"]},
        "sound": "default",
        "badge": 1,
    },
    "entity_type": "message",
    "entity_id": contract["message_id"],
    "message_id": contract["message_id"],
    "title": contract["title"],
    "body": contract["body"],
    "channel_id": "quality-system-route",
    "severity": "normal",
    "sent_at": "1787918400000",
}
print(json.dumps(payload, separators=(",", ":")))
PY
)"; then
  set_runner_status BLOCKED
  echo "status=BLOCKED"
  echo "reason=invalid_system_notification_readiness_contract"
  echo "log=$log_file"
  exit 2
fi
if ! push_output="$(printf '%s' "$payload" | xcrun simctl push "$target" "$app_bundle_identifier" - 2>&1)"; then
  set_runner_status BLOCKED
  echo "status=BLOCKED"
  echo "reason=simctl_push_failed"
  echo "detail=$push_output"
  echo "log=$log_file"
  exit 2
fi
printf '%s\n' "$push_output"

set +e
wait "$xcode_pid"
test_status=$?
set -e
trap - EXIT
tail -80 "$log_file" || true
if [[ $test_status -ne 0 ]]; then
  echo "status=FAILED"
  echo "reason=system_notification_product_oracle_failed"
  echo "log=$log_file"
  echo "result_bundle=$result_bundle"
  exit 1
fi

set_runner_status PASSED
echo "status=PASSED"
echo "result_bundle=$result_bundle"
echo "log=$log_file"
