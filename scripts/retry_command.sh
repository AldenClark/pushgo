#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/retry_command.sh [--attempts N] [--base-sleep SECONDS] [--always] -- <command> [args...]

Examples:
  scripts/retry_command.sh --always -- bundle install
  scripts/retry_command.sh --attempts 3 -- ssh host "mkdir -p /tmp/demo"

Notes:
  - By default, retries happen only when stderr/stdout looks like a transient network failure.
  - Use --always for commands that are network-bound and safe to retry wholesale.
EOF
}

attempts="${NETWORK_MAX_ATTEMPTS:-3}"
base_sleep="${NETWORK_RETRY_BASE_SECONDS:-20}"
always_retry="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --attempts)
      attempts="${2:-}"
      shift 2
      ;;
    --base-sleep)
      base_sleep="${2:-}"
      shift 2
      ;;
    --always)
      always_retry="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

if ! [[ "$attempts" =~ ^[0-9]+$ ]] || (( attempts < 1 )); then
  echo "Error: --attempts must be a positive integer, got: $attempts" >&2
  exit 1
fi

if ! [[ "$base_sleep" =~ ^[0-9]+$ ]] || (( base_sleep < 1 )); then
  echo "Error: --base-sleep must be a positive integer, got: $base_sleep" >&2
  exit 1
fi

is_transient_network_log() {
  local log_file="$1"

  if [[ "$always_retry" == "true" ]]; then
    return 0
  fi

  /usr/bin/python3 - "$log_file" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
patterns = [
    r"timed?\s*out",
    r"network\s+is\s+unreachable",
    r"temporary\s+failure",
    r"temporar(?:y|ily)\s+unavailable",
    r"connection\s+(?:was\s+)?lost",
    r"connection\s+reset",
    r"connection\s+closed",
    r"remote\s+end\s+hung\s+up",
    r"broken\s+pipe",
    r"could\s+not\s+connect",
    r"could\s+not\s+resolve\s+host",
    r"name\s+or\s+service\s+not\s+known",
    r"no\s+route\s+to\s+host",
    r"operation\s+timed\s+out",
    r"TLS",
    r"SSL",
    r"HTTP(?:/\d\.\d)?\s+50[0-9]\b",
    r"\b502\b",
    r"\b503\b",
    r"\b504\b",
    r"Net::OpenTimeout",
    r"Net::ReadTimeout",
    r"fetcherror",
    r"unable\s+to\s+access",
    r"failed\s+to\s+connect",
    r"kex_exchange_identification",
    r"subsystem\s+request\s+failed",
    r"RPC\s+failed",
]

for pattern in patterns:
    if re.search(pattern, text, re.IGNORECASE):
        sys.exit(0)
sys.exit(1)
PY
}

attempt=1
while true; do
  log_file="$(mktemp "${TMPDIR:-/tmp}/pushgo-retry-command.XXXXXX")"
  if "$@" >"$log_file" 2>&1; then
    cat "$log_file"
    rm -f "$log_file"
    exit 0
  fi

  exit_code=$?
  cat "$log_file" >&2

  if (( attempt >= attempts )) || ! is_transient_network_log "$log_file"; then
    rm -f "$log_file"
    exit "$exit_code"
  fi

  sleep_seconds=$(( base_sleep * (2 ** (attempt - 1)) ))
  echo "Transient network failure detected for: $*" >&2
  echo "Retrying in ${sleep_seconds}s (attempt ${attempt}/${attempts})..." >&2
  rm -f "$log_file"
  sleep "$sleep_seconds"
  attempt=$((attempt + 1))
done
