#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_BASE="${DERIVED_BASE:-$ROOT/.deriveddata-concurrency}"
PACKAGE_ARGS=(
  -onlyUsePackageVersionsFromResolvedFile
  -disableAutomaticPackageResolution
  -skipPackageUpdates
)

run_build() {
  local scheme="$1"
  local destination="$2"
  local derived="$DERIVED_BASE/$scheme"
  local -a signing_args=()

  # CI runners do not have local provisioning profiles; build without signing.
  if [[ "${CI:-}" == "true" ]]; then
    signing_args=(
      "CODE_SIGNING_ALLOWED=NO"
      "CODE_SIGNING_REQUIRED=NO"
      "CODE_SIGN_IDENTITY="
      "PROVISIONING_PROFILE_SPECIFIER="
      "DEVELOPMENT_TEAM="
    )
  fi

  echo "==> build $scheme ($destination)"
  if [[ ${#signing_args[@]} -gt 0 ]]; then
    xcodebuild \
      -project "$ROOT/pushgo.xcodeproj" \
      -scheme "$scheme" \
      -configuration Debug \
      -destination "$destination" \
      -derivedDataPath "$derived" \
      "${PACKAGE_ARGS[@]}" \
      "${signing_args[@]}" \
      build
  else
    xcodebuild \
      -project "$ROOT/pushgo.xcodeproj" \
      -scheme "$scheme" \
      -configuration Debug \
      -destination "$destination" \
      -derivedDataPath "$derived" \
      "${PACKAGE_ARGS[@]}" \
      build
  fi
}

"$ROOT/scripts/concurrency_audit.sh"
"$ROOT/scripts/verify_locked_packages.sh"
"$ROOT/scripts/verify_privacy_manifests.sh"
python3 "$ROOT/scripts/verify_release_workflow_security.py"
python3 "$ROOT/scripts/verify_release_distribution_contract.py"
"$ROOT/scripts/verify_rollback_compatibility.sh"

run_build "PushGo-macOS" "platform=macOS"
run_build "PushGo-watchOS" "generic/platform=watchOS"
run_build "PushGo-iOS" "generic/platform=iOS"
"$ROOT/scripts/verify_built_privacy_manifests.sh" "$DERIVED_BASE"

(
  cd "$ROOT"
  swift test --disable-automatic-resolution
)

echo "apple concurrency gate passed"
