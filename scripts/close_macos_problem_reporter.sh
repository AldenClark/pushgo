#!/usr/bin/env bash
set -euo pipefail

system_reporter_pattern='^/System/Library/CoreServices/Problem Reporter\.app/Contents/MacOS/Problem Reporter($| )'
pattern="$system_reporter_pattern"
watch_pid=""
poll_interval="0.2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern)
      [[ -n "${2:-}" ]] || {
        echo "usage: $0 [--pattern process-regex] [--watch-pid pid] [--poll-interval seconds]" >&2
        exit 2
      }
      pattern="$2"
      shift 2
      ;;
    --watch-pid)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || {
        echo "usage: $0 [--pattern process-regex] [--watch-pid pid] [--poll-interval seconds]" >&2
        exit 2
      }
      watch_pid="$2"
      shift 2
      ;;
    --poll-interval)
      [[ "${2:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        echo "usage: $0 [--pattern process-regex] [--watch-pid pid] [--poll-interval seconds]" >&2
        exit 2
      }
      poll_interval="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--pattern process-regex] [--watch-pid pid] [--poll-interval seconds]" >&2
      exit 2
      ;;
  esac
done

pid_is_live() {
  local pid="$1"
  local process_state
  process_state="$(ps -p "$pid" -o state= 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$process_state" && "$process_state" != Z* ]]
}

close_matching_reporters() {
  local reporter_pid
  local -a reporter_pids=()
  local -a remaining_pids=()
  local -a killed_pids_still_live=()

  while IFS= read -r reporter_pid; do
    [[ -z "$reporter_pid" ]] || reporter_pids+=("$reporter_pid")
  done < <(pgrep -f "$pattern" || true)

  [[ ${#reporter_pids[@]} -gt 0 ]] || return 0

  kill "${reporter_pids[@]}" >/dev/null 2>&1 || true

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
      return 2
    fi
  done

  echo "problem_reporter_closed=${#reporter_pids[@]}"
}

close_matching_reporters

if [[ -n "$watch_pid" ]]; then
  while kill -0 "$watch_pid" >/dev/null 2>&1; do
    sleep "$poll_interval"
    close_matching_reporters
  done
  # Cover a reporter created in the narrow race between the last poll and the
  # watched process exiting.
  close_matching_reporters
fi
