#!/usr/bin/env bash
set -euo pipefail

system_reporter_pattern='^/System/Library/CoreServices/Problem Reporter\.app/Contents/MacOS/Problem Reporter($| )'
pattern="$system_reporter_pattern"

if [[ "${1:-}" == "--pattern" ]]; then
  [[ -n "${2:-}" ]] || {
    echo "usage: $0 [--pattern process-regex]" >&2
    exit 2
  }
  pattern="$2"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--pattern process-regex]" >&2
  exit 2
fi

reporter_pids=()
while IFS= read -r reporter_pid; do
  [[ -z "$reporter_pid" ]] || reporter_pids+=("$reporter_pid")
done < <(pgrep -f "$pattern" || true)

if [[ ${#reporter_pids[@]} -eq 0 ]]; then
  exit 0
fi

pid_is_live() {
  local pid="$1"
  local process_state
  process_state="$(ps -p "$pid" -o state= 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$process_state" && "$process_state" != Z* ]]
}

kill "${reporter_pids[@]}" >/dev/null 2>&1 || true

remaining_pids=()
for _ in {1..20}; do
  remaining_pids=()
  for reporter_pid in "${reporter_pids[@]}"; do
    pid_is_live "$reporter_pid" && remaining_pids+=("$reporter_pid")
  done
  [[ ${#remaining_pids[@]} -eq 0 ]] && break
  sleep 0.1
done

if [[ ${#remaining_pids[@]} -gt 0 ]]; then
  kill -KILL "${remaining_pids[@]}" >/dev/null 2>&1 || true
  for _ in {1..10}; do
    killed_pids_still_live=()
    for reporter_pid in "${remaining_pids[@]}"; do
      pid_is_live "$reporter_pid" && killed_pids_still_live+=("$reporter_pid")
    done
    [[ ${#killed_pids_still_live[@]} -eq 0 ]] && break
    sleep 0.05
  done
fi

for reporter_pid in "${reporter_pids[@]}"; do
  if pid_is_live "$reporter_pid"; then
    echo "status=BLOCKED" >&2
    echo "reason=macos_problem_reporter_could_not_be_closed:$reporter_pid" >&2
    exit 2
  fi
done

echo "problem_reporter_closed=${#reporter_pids[@]}"
