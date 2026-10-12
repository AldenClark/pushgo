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
macos_build_status=NOT_RUN
ios_settings_status=NOT_RUN
watch_settings_status=NOT_RUN
macos_settings_status=NOT_RUN
macos_architecture_status=NOT_RUN
release_isolation_status=NOT_RUN
reason=diagnostic_not_started

write_summary() {
  local command_status=$?
  trap - EXIT
  python3 - "$results_root/diagnostic-summary.json" "$source_sha" "$expected_sha" \
    "$ios_build_status" "$watch_build_status" "$macos_build_status" \
    "$ios_settings_status" "$watch_settings_status" "$macos_settings_status" \
    "$macos_architecture_status" "$release_isolation_status" "$reason" \
    "$command_status" "$results_root/macos-architectures.json" <<'PY'
import json
import sys
from pathlib import Path

(
    output, source_sha, expected_sha, ios_build, watch_build, macos_build,
    ios_settings, watch_settings, macos_settings, macos_architecture,
    release_isolation, reason, exit_code, architecture_path,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "kind": "direct_apple_release_sdk_diagnostic",
    "source_sha": source_sha,
    "requested_sha": expected_sha or None,
    "ios_simulator_release_build_status": ios_build,
    "watchos_simulator_release_build_status": watch_build,
    "macos_unsigned_release_build_status": macos_build,
    "ios_release_settings_status": ios_settings,
    "watchos_release_settings_status": watch_settings,
    "macos_release_settings_status": macos_settings,
    "macos_release_architecture_status": macos_architecture,
    "release_isolation_contract_status": release_isolation,
    "quality_gate_status": "NOT_RUN",
    "product_runtime_status": "NOT_RUN",
    "distribution_signing_status": "NOT_RUN",
    "reason": reason,
    "script_exit_code": int(exit_code),
    "claim_limit": "iOS/watchOS Simulator and unsigned macOS Release SDK products for the recorded architectures, with compile-time Quality Runtime isolation only; no App launch, physical device, signer, distribution, or complete Release gate.",
}
architecture_file = Path(architecture_path)
if architecture_file.is_file():
    architecture_receipt = json.loads(architecture_file.read_text())
    payload["macos_release_architecture_scope"] = architecture_receipt.get("architecture_scope")
    payload["macos_embedded_extension_count"] = architecture_receipt.get("extension_count")
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
macos_derived_data="$temporary_root/derived-data/macos"
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

# A scheme's -showBuildSettings output only includes its primary target, even
# when the build embeds a dependent app extension. Capture that declared target
# separately so the architecture verifier can compare every shipped binary to
# its own effective Release ARCHS instead of inferring slices from the App.
run_macos_extension_settings() {
  local target output
  # Both targets are declared in the PushGo-macOS Embed Foundation Extensions
  # phase. A new embedded extension will fail bundle_record until its own
  # target settings are added here; no architecture is inferred from the App.
  for target in PushGoNSE-macOS PushGoWidgets-macOS; do
    output="$results_root/$target-release-settings.log"
    if ! xcodebuild \
      -project "$repo_root/pushgo.xcodeproj" \
      -target "$target" \
      -configuration Release \
      -sdk macosx \
      -onlyUsePackageVersionsFromResolvedFile \
      -disableAutomaticPackageResolution \
      -skipPackageUpdates \
      CODE_SIGNING_ALLOWED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
      PROVISIONING_PROFILE_SPECIFIER= PROVISIONING_PROFILE= \
      -showBuildSettings > "$output" 2>&1; then
      return 1
    fi
    cat "$output" >> "$results_root/macos-release-settings.log"
  done
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

reason=macos_unsigned_release_build_failed
if ! run_product_build macos PushGo-macOS 'generic/platform=macOS' "$macos_derived_data" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= PROVISIONING_PROFILE=; then
  macos_build_status=FAILED
  exit 3
fi
macos_build_status=PASSED

reason=macos_release_settings_failed
if ! run_product_settings macos PushGo-macOS 'generic/platform=macOS' "$macos_derived_data" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= PROVISIONING_PROFILE=; then
  macos_settings_status=FAILED
  exit 3
fi
if ! run_macos_extension_settings; then
  macos_settings_status=FAILED
  exit 3
fi
macos_settings_status=PASSED

reason=macos_release_architecture_verification_failed
if ! python3 "$repo_root/scripts/verify_macos_release_architectures.py" \
  --app "$macos_derived_data/Build/Products/Release/PushGo.app" \
  --build-settings "$results_root/macos-release-settings.log" \
  --output "$results_root/macos-architectures.json" \
  > "$results_root/macos-architecture-verifier.log" 2>&1; then
  cat "$results_root/macos-architecture-verifier.log"
  macos_architecture_status=FAILED
  exit 3
fi
macos_architecture_status=PASSED

reason=release_isolation_contract_failed
release_isolation_status=FAILED
if ! python3 "$repo_root/scripts/verify_apple_release_isolation.py" \
  --source-root "$repo_root" \
  --ios-derived-data "$ios_derived_data" \
  --watch-derived-data "$watch_derived_data" \
  --macos-derived-data "$macos_derived_data" \
  --ios-build-settings "$results_root/ios-release-settings.log" \
  --watch-build-settings "$results_root/watchos-release-settings.log" \
  --macos-build-settings "$results_root/macos-release-settings.log" \
  --output "$results_root/apple-release-isolation.json" \
  > "$results_root/release-isolation-verifier.log" 2>&1; then
  cat "$results_root/release-isolation-verifier.log"
  exit 1
fi

shasum -a 256 \
  "$ios_derived_data/Build/Products/Release-iphonesimulator/PushGo.app/PushGo" \
  "$watch_derived_data/Build/Products/Release-watchsimulator/PushGoWatch.app/PushGoWatch" \
  "$macos_derived_data/Build/Products/Release/PushGo.app/Contents/MacOS/PushGo" \
  > "$results_root/product-executable-sha256.log"
df -h "$repo_root" > "$results_root/disk-after-build.log" 2>&1
release_isolation_status=PASSED
reason=apple_release_sdk_isolation_verified
