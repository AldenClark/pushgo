#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_BASE="${DERIVED_BASE:-$ROOT/.deriveddata-concurrency}"

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
  xcodebuild \
    -project "$ROOT/pushgo.xcodeproj" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived" \
    "${signing_args[@]}" \
    build
}

"$ROOT/scripts/concurrency_audit.sh"

run_build "PushGo-macOS" "platform=macOS"
run_build "PushGo-watchOS" "generic/platform=watchOS"
run_build "PushGo-iOS" "generic/platform=iOS"

(
  cd "$ROOT"
  swift test
)

echo "apple concurrency gate passed"
