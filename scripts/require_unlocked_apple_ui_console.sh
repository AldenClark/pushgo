#!/usr/bin/env bash
set -euo pipefail

platform="${1:-apple_ui}"
if [[ $# -gt 1 || -z "$platform" ]]; then
  echo "usage: $0 [platform]" >&2
  exit 2
fi

runner_status_file="${QUALITY_RUNNER_STATUS_FILE:-}"
console_locked="$(/usr/sbin/ioreg -n Root -d1 | awk -F'= ' '/"IOConsoleLocked"/ { print $2 }')"
if [[ "$console_locked" == "No" ]]; then
  exit 0
fi

if [[ -n "$runner_status_file" ]]; then
  mkdir -p "$(dirname "$runner_status_file")"
  printf 'BLOCKED\n' > "$runner_status_file"
fi
echo "status=BLOCKED"
echo "reason=${platform}_console_must_be_unlocked:${console_locked:-unknown}"
exit 2
