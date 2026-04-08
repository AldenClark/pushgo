#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT/pushgo.xcodeproj}"
SCHEME="${SCHEME:-PushGo-iOS}"
SIM_NAME="${IOS_SIM_NAME:-iPhone 17e}"
SIM_OS="${IOS_SIM_OS:-26.4}"
TEST_SCOPE="${TEST_SCOPE:-}"
MAX_RETRIES="${MAX_RETRIES:-2}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/.deriveddata-ui-tests}"

RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-${SIM_OS//./-}"
SIM_UDID="$(
  xcrun simctl list devices available -j \
    | jq -r --arg runtime "$RUNTIME_ID" --arg name "$SIM_NAME" '.devices[$runtime][]? | select(.name == $name) | .udid' \
    | head -n 1
)"

if [[ -z "$SIM_UDID" ]]; then
  echo "Unable to find simulator: ${SIM_NAME} (iOS ${SIM_OS})"
  echo "Available iOS runtimes:"
  xcrun simctl list devices available | sed -n '/-- iOS /,/--/p'
  exit 2
fi

COMMON_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration Debug
  -derivedDataPath "$DERIVED_DATA_PATH"
  -destination "platform=iOS Simulator,id=${SIM_UDID}"
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
)

if [[ -n "$TEST_SCOPE" ]]; then
  COMMON_ARGS+=("-only-testing:${TEST_SCOPE}")
fi

echo "==> preboot simulator: ${SIM_NAME} (${SIM_OS}) [${SIM_UDID}]"
xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_UDID" -b

echo "==> build-for-testing"
xcodebuild "${COMMON_ARGS[@]}" build-for-testing

run_test_once() {
  local logfile="$1"
  set +e
  xcodebuild "${COMMON_ARGS[@]}" test-without-building 2>&1 | tee "$logfile"
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

is_transient_runner_failure() {
  local logfile="$1"
  rg -q \
    "Failed to launch app with identifier: .*xctrunner|RequestDenied|timed out waiting for simulator|Unable to boot the Simulator" \
    "$logfile"
}

attempt=1
until [[ $attempt -gt $((MAX_RETRIES + 1)) ]]; do
  echo "==> test-without-building (attempt ${attempt}/$((MAX_RETRIES + 1)))"
  log_file="$(mktemp -t pushgo-ui-tests.XXXXXX.log)"

  if run_test_once "$log_file"; then
    rm -f "$log_file"
    echo "iOS UI tests passed"
    exit 0
  fi

  if [[ $attempt -le $MAX_RETRIES ]] && is_transient_runner_failure "$log_file"; then
    echo "Transient runner launch failure detected, rebooting simulator and retrying..."
    xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
    xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$SIM_UDID" -b
    rm -f "$log_file"
    attempt=$((attempt + 1))
    continue
  fi

  echo "UI tests failed. Log retained at: $log_file"
  exit 1
done
