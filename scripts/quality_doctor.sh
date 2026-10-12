#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$repo_root/pushgo.xcodeproj"
scheme="${PUSHGO_QUALITY_SCHEME:-PushGo-iOS}"
host_only=false

if [[ "${1:-}" == "--host-only" ]]; then
  host_only=true
elif [[ $# -gt 0 ]]; then
  printf 'status=BLOCKED\nreason=unsupported_doctor_argument:%s\n' "$1"
  exit 2
fi

fail() {
  printf 'status=BLOCKED\nreason=%s\n' "$1"
  exit 2
}

command -v swift >/dev/null 2>&1 || fail "swift_not_found"
[[ -f "$repo_root/Package.swift" ]] || fail "swift_package_missing"

if [[ "$host_only" == true ]]; then
  printf 'status=READY\n'
  printf 'platform=apple\n'
  printf 'execution_target=host\n'
  printf 'storage_contract=app-owned-temporary-store\n'
  printf 'release_runtime=not_applicable\n'
  exit 0
fi

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild_not_found"
command -v xcrun >/dev/null 2>&1 || fail "xcrun_not_found"
[[ -d "$project_path" ]] || fail "xcode_project_missing"

if ! xcodebuild -project "$project_path" -list 2>/dev/null | rg -q "^[[:space:]]+$scheme$"; then
  fail "scheme_not_found:$scheme"
fi

simulator_line="$(
  xcrun simctl list devices available \
    | sed -E 's/[[:space:]]+$//' \
    | awk '
        /^-- iOS / { in_ios = 1; next }
        /^-- / { in_ios = 0 }
        in_ios && /\([0-9A-F-]{36}\) \((Booted|Shutdown)\)$/ {
          if ($0 ~ /PushGo Quality iPhone/) { print; exit }
          if ($0 ~ /\(Booted\)$/ && booted == "") { booted = $0 }
          if (fallback == "") { fallback = $0 }
        }
        END {
          if (booted != "") print booted
          else if (fallback != "") print fallback
        }
      ' \
    | head -1
)"
[[ -n "$simulator_line" ]] || fail "no_available_ios_simulator"
simulator_id="$(printf '%s\n' "$simulator_line" | sed -E 's/.*\(([0-9A-F-]{36})\) \((Booted|Shutdown)\)$/\1/')"
simulator_name="$(printf '%s\n' "$simulator_line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+\([0-9A-F-]{36}\) \((Booted|Shutdown)\)$//')"

printf 'status=READY\n'
printf 'platform=apple\n'
printf 'scheme=%s\n' "$scheme"
printf 'simulator_name=%s\n' "$simulator_name"
printf 'simulator_id=%s\n' "$simulator_id"
printf 'fixture_empty=empty.clean\n'
printf 'fixture_standard=messages.standard\n'
printf 'storage_contract=app-owned\n'
printf 'release_runtime=disabled\n'
