#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-/Users/ethan/Repo/PushGo/pushgo/pushgo.xcodeproj}"
PACKAGE_PATH="${PACKAGE_PATH:-/Users/ethan/Repo/PushGo/pushgo}"
WATCH_SMOKE_SCRIPT="${WATCH_SMOKE_SCRIPT:-/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-watchOSAutomation/watchos_automation_smoke.sh}"
MACOS_SMOKE_SCRIPT="${MACOS_SMOKE_SCRIPT:-/Users/ethan/Repo/PushGo/pushgo/Tests/PushGo-macOSAutomation/macos_automation_smoke.sh}"

IOS_DEVICE_NAME="${IOS_DEVICE_NAME:-iPhone Air}"
IOS_DEVICE_OS="${IOS_DEVICE_OS:-26.2}"
IOS_DERIVED_DATA="${IOS_DERIVED_DATA:-/tmp/pushgo-ios-uitests-serial}"
MACOS_DERIVED_DATA="${MACOS_DERIVED_DATA:-/tmp/pushgo-macos-uitests-serial}"

RUN_CORE_TESTS="${RUN_CORE_TESTS:-1}"
RUN_MACOS_UI="${RUN_MACOS_UI:-1}"
RUN_MACOS_SMOKE="${RUN_MACOS_SMOKE:-1}"
RUN_WATCHOS_SMOKE="${RUN_WATCHOS_SMOKE:-1}"
RUN_IOS_UI="${RUN_IOS_UI:-1}"
NO_INTERACTIVE_SIGNING="${NO_INTERACTIVE_SIGNING:-1}"
PUSHGO_AUTOMATION_MACOS_BRIDGE_ROOT="${PUSHGO_AUTOMATION_MACOS_BRIDGE_ROOT:-/tmp/pushgo-macos-automation-bridge}"

LOG_ROOT="${LOG_ROOT:-/tmp/pushgo-apple-automation-logs}"
mkdir -p "$LOG_ROOT"

XCODE_NO_SIGN_FLAGS=()
if [[ "$NO_INTERACTIVE_SIGNING" == "1" ]]; then
  XCODE_NO_SIGN_FLAGS+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=
  )
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd xcodebuild
need_cmd xcrun
need_cmd swift
need_cmd bash

shutdown_simulators() {
  xcrun simctl shutdown all >/dev/null 2>&1 || true
}

run_step() {
  local name="$1"
  shift
  local log_file="${LOG_ROOT}/${name}.log"
  echo "[apple-serial] step=${name}"
  if "$@" >"$log_file" 2>&1; then
    echo "[apple-serial] step=${name} status=ok log=${log_file}"
    return 0
  fi
  echo "[apple-serial] step=${name} status=failed log=${log_file}" >&2
  tail -n 120 "$log_file" >&2 || true
  return 1
}

run_step_with_retry() {
  local name="$1"
  local retry_count="$2"
  shift 2
  local attempt=1
  while (( attempt <= retry_count )); do
    if run_step "$name" "$@"; then
      return 0
    fi
    if (( attempt == retry_count )); then
      return 1
    fi
    echo "[apple-serial] step=${name} retry=${attempt}/${retry_count}" >&2
    sleep 3
    attempt=$((attempt + 1))
  done
}

run_core_tests() {
  run_step \
    "apple_core_tests" \
    swift test --package-path "$PACKAGE_PATH" --filter PushGoAppleCoreTests
}

run_macos_ui_tests() {
  shutdown_simulators
  run_step_with_retry \
    "macos_ui_tests" \
    2 \
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme PushGo-macOS \
      -destination "platform=macOS" \
      -derivedDataPath "$MACOS_DERIVED_DATA" \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=YES \
      "${XCODE_NO_SIGN_FLAGS[@]}" \
      test \
      -only-testing:PushGo-macOSUITests
}

run_watch_smoke_tests() {
  shutdown_simulators
  run_step \
    "watchos_smoke" \
    env NO_INTERACTIVE_SIGNING="$NO_INTERACTIVE_SIGNING" bash "$WATCH_SMOKE_SCRIPT"
  shutdown_simulators
}

run_macos_smoke_tests() {
  shutdown_simulators
  run_step \
    "macos_smoke" \
    env NO_INTERACTIVE_SIGNING="$NO_INTERACTIVE_SIGNING" \
      PUSHGO_AUTOMATION_MACOS_BRIDGE_ROOT="$PUSHGO_AUTOMATION_MACOS_BRIDGE_ROOT" \
      bash "$MACOS_SMOKE_SCRIPT"
  shutdown_simulators
}

run_ios_ui_tests() {
  shutdown_simulators
  run_step \
    "ios_ui_build_for_testing" \
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme PushGo-iOS \
      -destination "platform=iOS Simulator,name=${IOS_DEVICE_NAME},OS=${IOS_DEVICE_OS}" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=YES \
      EXCLUDED_ARCHS__EFFECTIVE_PLATFORM_SUFFIX_iphonesimulator=x86_64 \
      EXCLUDED_ARCHS__EFFECTIVE_PLATFORM_SUFFIX_watchsimulator=x86_64 \
      "${XCODE_NO_SIGN_FLAGS[@]}" \
      build-for-testing

  run_step_with_retry \
    "ios_ui_test_without_building" \
    2 \
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme PushGo-iOS \
      -destination "platform=iOS Simulator,name=${IOS_DEVICE_NAME},OS=${IOS_DEVICE_OS}" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=YES \
      EXCLUDED_ARCHS__EFFECTIVE_PLATFORM_SUFFIX_iphonesimulator=x86_64 \
      EXCLUDED_ARCHS__EFFECTIVE_PLATFORM_SUFFIX_watchsimulator=x86_64 \
      "${XCODE_NO_SIGN_FLAGS[@]}" \
      test-without-building \
      -only-testing:PushGo-iOSUITests
  shutdown_simulators
}

if [[ "$RUN_CORE_TESTS" == "1" ]]; then
  run_core_tests
fi
if [[ "$RUN_MACOS_UI" == "1" ]]; then
  run_macos_ui_tests
fi
if [[ "$RUN_MACOS_SMOKE" == "1" ]]; then
  run_macos_smoke_tests
fi
if [[ "$RUN_WATCHOS_SMOKE" == "1" ]]; then
  run_watch_smoke_tests
fi
if [[ "$RUN_IOS_UI" == "1" ]]; then
  run_ios_ui_tests
fi

echo "[apple-serial] all enabled steps passed"
echo "[apple-serial] logs=${LOG_ROOT}"
