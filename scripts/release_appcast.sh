#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/release_appcast.sh <stable|beta> <archives_dir> [options]

Examples:
  scripts/release_appcast.sh stable artifacts/sparkle
  scripts/release_appcast.sh beta artifacts/sparkle --account pushgo

Options:
  --account <name>                    Sparkle keychain account (default: pushgo)
  --download-url-prefix <url>         Update file base URL (default: https://update.pushgo.cn/macos/)
  --release-notes-url-prefix <url>    Release notes base URL (default: same as download prefix)
  --output <path>                     Output appcast path (passed to generate_appcast -o)
  --tool <path>                       Explicit generate_appcast path
  -h, --help                          Show this help

Notes:
  - stable: generates default channel items (no sparkle:channel tag)
  - beta:   generates sparkle:channel=beta items
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

track="$1"
archives_dir="$2"
shift 2

if [[ "$track" != "stable" && "$track" != "beta" ]]; then
  echo "Error: track must be 'stable' or 'beta', got: $track" >&2
  exit 1
fi

if [[ ! -d "$archives_dir" ]]; then
  echo "Error: archives directory does not exist: $archives_dir" >&2
  exit 1
fi

account="pushgo"
download_url_prefix="https://update.pushgo.cn/macos/"
release_notes_url_prefix=""
output_path=""
tool_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account)
      account="${2:-}"
      shift 2
      ;;
    --download-url-prefix)
      download_url_prefix="${2:-}"
      shift 2
      ;;
    --release-notes-url-prefix)
      release_notes_url_prefix="${2:-}"
      shift 2
      ;;
    --output)
      output_path="${2:-}"
      shift 2
      ;;
    --tool)
      tool_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$release_notes_url_prefix" ]]; then
  release_notes_url_prefix="$download_url_prefix"
fi

if [[ -z "$output_path" ]]; then
  output_path="${archives_dir%/}/appcast.xml"
fi

if [[ -z "$tool_path" ]]; then
  if [[ -n "${SPARKLE_BIN:-}" && -x "${SPARKLE_BIN}/generate_appcast" ]]; then
    tool_path="${SPARKLE_BIN}/generate_appcast"
  else
    tool_path="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
      -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
      -print 2>/dev/null | head -n 1 || true)"
  fi
fi

if [[ -z "$tool_path" && -n "$(command -v generate_appcast || true)" ]]; then
  tool_path="$(command -v generate_appcast)"
fi

if [[ -z "$tool_path" || ! -x "$tool_path" ]]; then
  echo "Error: generate_appcast not found. Pass --tool <path> or set SPARKLE_BIN." >&2
  exit 1
fi

if [[ ! "$download_url_prefix" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "Error: --download-url-prefix must be http(s) URL: $download_url_prefix" >&2
  exit 1
fi

if [[ ! "$release_notes_url_prefix" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "Error: --release-notes-url-prefix must be http(s) URL: $release_notes_url_prefix" >&2
  exit 1
fi

cmd=(
  "$tool_path"
  --account "$account"
  --download-url-prefix "$download_url_prefix"
  --release-notes-url-prefix "$release_notes_url_prefix"
)

if [[ "$track" == "beta" ]]; then
  cmd+=(--channel beta)
fi

cmd+=(-o "$output_path")

cmd+=("$archives_dir")

echo "Running: ${cmd[*]}"
"${cmd[@]}"

appcast_path="${output_path}"
if [[ ! -f "$appcast_path" ]]; then
  echo "Error: appcast file was not generated: $appcast_path" >&2
  exit 1
fi

if ! xmllint --noout "$appcast_path" 2>/dev/null; then
  echo "Error: generated appcast is not valid XML: $appcast_path" >&2
  exit 1
fi

enclosure_count="$(xmllint --xpath 'count(//*[local-name()="enclosure"])' "$appcast_path" 2>/dev/null || echo 0)"
unsigned_count="$(xmllint --xpath 'count(//*[local-name()="enclosure"][not(@*[local-name()="edSignature"])])' "$appcast_path" 2>/dev/null || echo 0)"
if [[ "$enclosure_count" == "0" ]]; then
  echo "Error: generated appcast contains no enclosure items: $appcast_path" >&2
  exit 1
fi
if [[ "$unsigned_count" != "0" ]]; then
  echo "Error: generated appcast has ${unsigned_count} enclosure item(s) without sparkle:edSignature: $appcast_path" >&2
  echo "Hint: verify --account matches your keychain key, or use --ed-key-file in generate_appcast flow." >&2
  exit 1
fi

if [[ "$track" == "beta" ]]; then
  beta_item_count="$(xmllint --xpath 'count(//*[local-name()="item"][.//*[local-name()="channel" and normalize-space(text())="beta"]])' "$appcast_path" 2>/dev/null || echo 0)"
  if [[ "$beta_item_count" == "0" ]]; then
    echo "Error: beta track was requested but no sparkle:channel=beta item was found in appcast: $appcast_path" >&2
    exit 1
  fi
fi

echo "Done: appcast generated for track=${track}, archives_dir=${archives_dir}, appcast=${appcast_path}"
