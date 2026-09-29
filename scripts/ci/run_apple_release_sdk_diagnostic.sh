#!/usr/bin/env bash
set -euo pipefail

# A direct, host-only Release SDK diagnostic. It does not run the expired
# quality-test-system/P1 gates, launch an App, sign for distribution, or publish.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

run_id="${GITHUB_RUN_ID:-}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
source_sha="$(git rev-parse HEAD)"
expected_sha="${EXPECTED_SHA:-}"
results_root="$repo_root/build/quality-results/apple-release-sdk-diagnostic/run-${run_id:-local}-${run_attempt}"
mkdir -p "$results_root"

ios_build_status=NOT_RUN
watch_build_status=NOT_RUN
ios_settings_status=NOT_RUN
watch_settings_status=NOT_RUN
release_isolation_status=NOT_RUN
reason=diagnostic_not_started

write_summary() {
  local command_status=$?
  trap - EXIT
  python3 - "$results_root/diagnostic-summary.json" "$source_sha" "$expected_sha" \
    "$ios_build_status" "$watch_build_status" "$ios_settings_status" \
    "$watch_settings_status" "$release_isolation_status" "$reason" "$command_status" <<'PY'
import json
import sys
from pathlib import Path

(
    output, source_sha, expected_sha, ios_build, watch_build, ios_settings,
    watch_settings, release_isolation, reason, exit_code,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "kind": "direct_apple_release_sdk_diagnostic",
    "source_sha": source_sha,
    "requested_sha": expected_sha or None,
    "ios_simulator_release_build_status": ios_build,
    "watchos_simulator_release_build_status": watch_build,
    "ios_release_settings_status": ios_settings,
    "watchos_release_settings_status": watch_settings,
    "release_isolation_contract_status": release_isolation,
    "quality_gate_status": "NOT_RUN",
    "product_runtime_status": "NOT_RUN",
    "distribution_signing_status": "NOT_RUN",
    "reason": reason,
    "script_exit_code": int(exit_code),
    "claim_limit": "Simulator Release SDK products and compile-time Quality Runtime isolation only; no App launch, physical device, signer, distribution, or complete Release gate.",
}
Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(f"diagnostic_summary={output}")
print(f"release_isolation_contract_status={release_isolation}")
print("quality_gate_status=NOT_RUN")
PY
  exit "$command_status"
}
trap write_summary EXIT

if [[ -z "$run_id" || ! "$expected_sha" =~ ^[0-9a-f]{40}$ || "$source_sha" != "$expected_sha" ]]; then
  reason=github_runner_or_exact_source_sha_precondition_failed
  exit 2
fi

temporary_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pushgo-release-sdk.XXXXXX")"
ios_derived_data="$temporary_root/derived-data/ios"
watch_derived_data="$temporary_root/derived-data/watch"
mkdir -p "$temporary_root/build-logs"
xcodebuild -version > "$results_root/xcode-version.log" 2>&1
sw_vers -productVersion > "$results_root/macos-version.log" 2>&1
df -h "$repo_root" > "$results_root/disk-before-build.log" 2>&1

# Keep the same schemes, Release configuration, simulator destinations, package
# lock flags and signing choices as quality_test.sh:run_release_isolation_checks.
run_product_build() {
  local label="$1" scheme="$2" destination="$3" derived_data="$4"
  shift 4
  local full_log="$temporary_root/build-logs/$label.full.log"
  local -a args=(
    -project "$repo_root/pushgo.xcodeproj"
    -scheme "$scheme"
    -configuration Release
    -destination "$destination"
    -derivedDataPath "$derived_data"
    -onlyUsePackageVersionsFromResolvedFile
    -disableAutomaticPackageResolution
    -skipPackageUpdates
  )
  if xcodebuild "${args[@]}" "$@" build > "$full_log" 2>&1; then
    tail -n 80 "$full_log" > "$results_root/$label-build-tail.log"
    printf '%s_build=PASSED\n' "$label"
  else
    tail -n 200 "$full_log" > "$results_root/$label-build-tail.log"
    cat "$results_root/$label-build-tail.log"
    return 1
  fi
}

run_product_settings() {
  local label="$1" scheme="$2" destination="$3" derived_data="$4"
  shift 4
  xcodebuild \
    -project "$repo_root/pushgo.xcodeproj" \
    -scheme "$scheme" \
    -configuration Release \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    -skipPackageUpdates \
    "$@" -showBuildSettings > "$results_root/$label-release-settings.log" 2>&1
}

reason=ios_simulator_release_build_failed
if ! run_product_build ios PushGo-iOS 'generic/platform=iOS Simulator' "$ios_derived_data"; then
  ios_build_status=FAILED
  exit 3
fi
ios_build_status=PASSED

reason=ios_release_settings_failed
if ! run_product_settings ios PushGo-iOS 'generic/platform=iOS Simulator' "$ios_derived_data"; then
  ios_settings_status=FAILED
  exit 3
fi
ios_settings_status=PASSED

reason=watchos_simulator_release_build_failed
if ! run_product_build watchos PushGo-watchOS 'generic/platform=watchOS Simulator' "$watch_derived_data" CODE_SIGNING_ALLOWED=NO; then
  watch_build_status=FAILED
  exit 3
fi
watch_build_status=PASSED

reason=watchos_release_settings_failed
if ! run_product_settings watchos PushGo-watchOS 'generic/platform=watchOS Simulator' "$watch_derived_data" CODE_SIGNING_ALLOWED=NO; then
  watch_settings_status=FAILED
  exit 3
fi
watch_settings_status=PASSED

reason=release_isolation_contract_failed
release_isolation_status=FAILED
if ! python3 "$repo_root/scripts/verify_apple_release_isolation.py" \
  --source-root "$repo_root" \
  --ios-derived-data "$ios_derived_data" \
  --watch-derived-data "$watch_derived_data" \
  --ios-build-settings "$results_root/ios-release-settings.log" \
  --watch-build-settings "$results_root/watchos-release-settings.log" \
  --output "$results_root/apple-release-isolation.json" \
  > "$results_root/release-isolation-verifier.log" 2>&1; then
  cat "$results_root/release-isolation-verifier.log"
  exit 1
fi

shasum -a 256 \
  "$ios_derived_data/Build/Products/Release-iphonesimulator/PushGo.app/PushGo" \
  "$watch_derived_data/Build/Products/Release-watchsimulator/PushGoWatch.app/PushGoWatch" \
  > "$results_root/product-executable-sha256.log"
df -h "$repo_root" > "$results_root/disk-after-build.log" 2>&1
release_isolation_status=PASSED
reason=simulator_release_sdk_isolation_verified
