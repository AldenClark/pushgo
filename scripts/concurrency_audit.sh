#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOWLIST="$ROOT/config/concurrency_allowlist.txt"

if [[ ! -f "$ALLOWLIST" ]]; then
  echo "missing allowlist: $ALLOWLIST" >&2
  exit 1
fi

read_lines() {
  local __target="$1"
  shift
  local __line
  local -a __items=()
  while IFS= read -r __line; do
    __items+=("$__line")
  done < <("$@" || true)

  eval "$__target=()"
  if [[ ${#__items[@]} -eq 0 ]]; then
    return 0
  fi

  local __quoted=""
  local __item
  for __item in "${__items[@]}"; do
    printf -v __quoted '%s %q' "$__quoted" "$__item"
  done
  eval "$__target=(${__quoted# })"
}

read_lines ALLOWED_KEYS awk -F'|' 'NF>=2 && $1 !~ /^#/ { print $1 "|" $2 }' "$ALLOWLIST"

is_allowed() {
  local key="$1"
  for allowed in "${ALLOWED_KEYS[@]}"; do
    if [[ "$allowed" == "$key" ]]; then
      return 0
    fi
  done
  return 1
}

find_matches() {
  local pattern="@unchecked[[:space:]]+Sendable|nonisolated\\(unsafe\\)|@preconcurrency|Task\\.detached|DispatchQueue\\.global\\(|Unsafe(Mutable)?(Pointer|RawPointer)|Unmanaged<|MainActor\\.assumeIsolated"
  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$ROOT" --glob '*.swift'
    return
  fi

  grep -R -n -E \
    --include='*.swift' \
    --exclude-dir='.build' \
    --exclude-dir='build' \
    --exclude-dir='.git' \
    --exclude-dir='.deriveddata-concurrency' \
    "$pattern" \
    "$ROOT"
}

read_lines MATCHES find_matches

if [[ ${#MATCHES[@]} -eq 0 ]]; then
  echo "concurrency audit: no risky patterns found"
  exit 0
fi

declare -a VIOLATIONS=()
declare -a OBSERVED_KEYS=()

token_for() {
  local text="$1"
  if [[ "$text" =~ nonisolated\(unsafe\) ]]; then
    echo "nonisolated_unsafe"
  elif [[ "$text" =~ @unchecked[[:space:]]+Sendable ]]; then
    echo "unchecked_sendable"
  elif [[ "$text" =~ Task\.detached ]]; then
    echo "task_detached"
  elif [[ "$text" =~ MainActor\.assumeIsolated ]]; then
    echo "mainactor_assumeisolated"
  elif [[ "$text" =~ DispatchQueue\.global\( ]]; then
    echo "dispatch_global"
  elif [[ "$text" =~ @preconcurrency ]]; then
    if [[ "$text" =~ UNUserNotificationCenterDelegate ]]; then
      echo "preconcurrency_delegate"
    else
      echo "preconcurrency"
    fi
  elif [[ "$text" =~ Unmanaged\< ]]; then
    echo "unmanaged"
  elif [[ "$text" =~ UnsafeMutablePointer|UnsafePointer|UnsafeMutableRawPointer|UnsafeRawPointer ]]; then
    echo "unsafe_raw_pointer"
  else
    echo "unknown"
  fi
}

for row in "${MATCHES[@]}"; do
  file="${row%%:*}"
  rest="${row#*:}"
  line="${rest%%:*}"
  text="${rest#*:}"

  rel="${file#$ROOT/}"
  token="$(token_for "$text")"
  key="$rel|$token"
  OBSERVED_KEYS+=("$key")

  if [[ "$token" == "nonisolated_unsafe" || "$token" == "unchecked_sendable" || "$token" == "mainactor_assumeisolated" || "$token" == "task_detached" || "$token" == "dispatch_global" ]]; then
    VIOLATIONS+=("$rel:$line | $token | $text")
    continue
  fi

  if ! is_allowed "$key"; then
    VIOLATIONS+=("$rel:$line | $token | $text")
  fi
done

for allowed in "${ALLOWED_KEYS[@]}"; do
  found=0
  for observed in "${OBSERVED_KEYS[@]}"; do
    if [[ "$observed" == "$allowed" ]]; then
      found=1
      break
    fi
  done
  if [[ $found -eq 0 ]]; then
    VIOLATIONS+=("allowlist stale entry | $allowed | no matching source pattern")
  fi
done

if [[ ${#VIOLATIONS[@]} -gt 0 ]]; then
  echo "concurrency audit failed: unapproved risky patterns found"
  printf '%s\n' "${VIOLATIONS[@]}"
  exit 2
fi

echo "concurrency audit passed with allowlist controls"
