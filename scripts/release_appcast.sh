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
  --ed-key-file <path>                Sparkle Ed25519 private key file (preferred in CI)
  --expected-version <version>        Only process DMG files matching this version token (for example: v1.2.0-beta.3)
  --download-url-prefix <url>         Update file base URL (default: https://update.pushgo.cn/macos/)
  --release-notes-url-prefix <url>    Release notes base URL (default: same as download prefix)
  --output <path>                     Additional output copy path after updating release/appcast.xml
  --tool <path>                       Explicit generate_appcast path
  -h, --help                          Show this help

Notes:
  - stable: generates default channel items (no sparkle:channel tag)
  - beta:   generates sparkle:channel=beta items
  - per-version notes are sourced from release/update-notes/vX.Y.Z(.beta.N).json
  - persistent appcast state lives at release/appcast.xml
  - each branch in the feed keeps only its latest version
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
ed_key_file=""
expected_version=""
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
    --ed-key-file)
      ed_key_file="${2:-}"
      shift 2
      ;;
    --expected-version)
      expected_version="${2:-}"
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
  output_path=""
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

if [[ -n "$ed_key_file" && ! -f "$ed_key_file" ]]; then
  echo "Error: --ed-key-file not found: $ed_key_file" >&2
  exit 1
fi

if [[ -z "$account" && -z "$ed_key_file" ]]; then
  echo "Error: either --account or --ed-key-file must be provided for Sparkle signing" >&2
  exit 1
fi

if [[ -n "$expected_version" && ! "$expected_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]]; then
  echo "Error: --expected-version must look like vX.Y.Z or vX.Y.Z-beta.N, got: $expected_version" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
update_notes_dir="${repo_root}/release/update-notes"
state_appcast_path="${repo_root}/release/appcast.xml"

emit_release_notes_from_json() {
  local source_json_path="$1"
  local archive_output_base="$2"

  /usr/bin/python3 - "$source_json_path" "$archive_output_base" <<'PY'
import json
import pathlib
import sys

source_json = pathlib.Path(sys.argv[1])
output_base = pathlib.Path(sys.argv[2])
required_locales = ["en", "de", "es", "fr", "ja", "ko", "zh-CN", "zh-TW"]
direct_locale_map = {
    "en": "en",
    "de": "de",
    "es": "es",
    "fr": "fr",
    "ja": "ja",
    "ko": "ko",
}
managed_suffixes = [
    "txt",
    "en.txt",
    "de.txt",
    "es.txt",
    "fr.txt",
    "ja.txt",
    "ko.txt",
    "zh.txt",
]

try:
    payload = json.loads(source_json.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    print(f"Error: invalid JSON in {source_json}: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(payload, dict):
    print(f"Error: update notes JSON must be an object: {source_json}", file=sys.stderr)
    sys.exit(1)

missing = []
for locale in required_locales:
    value = payload.get(locale)
    if not isinstance(value, str) or not value.strip():
      missing.append(locale)

if missing:
    print(
        f"Error: missing required locale text in {source_json}: {', '.join(missing)}",
        file=sys.stderr,
    )
    sys.exit(1)

def write_note(suffix: str, content: str) -> None:
    output_path = pathlib.Path(f"{output_base}.{suffix}")
    output_path.write_text(content.rstrip() + "\n", encoding="utf-8")

for suffix in managed_suffixes:
    output_path = pathlib.Path(f"{output_base}.{suffix}")
    if output_path.exists():
        output_path.unlink()

write_note("txt", payload["en"])

for source_locale, target_locale in direct_locale_map.items():
    write_note(f"{target_locale}.txt", payload[source_locale])

zh_cn = payload["zh-CN"]
zh_tw = payload["zh-TW"]
write_note("zh.txt", zh_cn)

if zh_cn.rstrip() != zh_tw.rstrip():
    print(
        f"Warning: Sparkle localized release notes currently support only generic 'zh'; "
        f"using zh-CN for {output_base.name}.zh.txt while retaining zh-TW in {source_json.name}",
        file=sys.stderr,
    )
PY
}

prepare_release_notes_for_archives() {
  local archive_path archive_name archive_stem version source_notes_json_path
  local matched_release_notes
  local dmg_count=0

  if [[ ! -d "$update_notes_dir" ]]; then
    echo "Error: update notes directory does not exist: $update_notes_dir" >&2
    exit 1
  fi

  while IFS= read -r archive_path; do
    dmg_count=$((dmg_count + 1))
    archive_name="$(basename "$archive_path")"
    archive_stem="${archive_name%.*}"
    matched_release_notes=""

    if [[ "$archive_name" =~ (v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?) ]]; then
      version="${BASH_REMATCH[1]}"
      source_notes_json_path="${update_notes_dir}/${version}.json"
      if [[ -f "$source_notes_json_path" ]]; then
        emit_release_notes_from_json "$source_notes_json_path" "${archives_dir%/}/${archive_stem}"
        continue
      fi
    else
      version=""
      source_notes_json_path=""
    fi

    for candidate_ext in html md txt; do
      if [[ -f "${archives_dir%/}/${archive_stem}.${candidate_ext}" ]]; then
        matched_release_notes="${archives_dir%/}/${archive_stem}.${candidate_ext}"
        break
      fi
    done

    if [[ -n "$matched_release_notes" ]]; then
      continue
    fi

    if [[ -z "$version" ]]; then
      echo "Error: could not infer version from archive filename: $archive_name" >&2
      echo "Hint: use names like PushGo-macOS-v1.2.0.dmg or provide a same-basename .txt/.md/.html file." >&2
      exit 1
    fi

    if [[ ! -f "$source_notes_json_path" ]]; then
      echo "Error: missing update notes source for ${version}: $source_notes_json_path" >&2
      exit 1
    fi
  done < <(
    if [[ -n "$expected_version" ]]; then
      find "$archives_dir" -maxdepth 1 -type f -name "*${expected_version}*.dmg" -print | sort
    else
      find "$archives_dir" -maxdepth 1 -type f -name '*.dmg' -print | sort
    fi
  )

  if (( dmg_count == 0 )); then
    if [[ -n "$expected_version" ]]; then
      echo "Error: no DMG archives found in ${archives_dir} matching expected version ${expected_version}" >&2
    else
      echo "Error: no DMG archives found in ${archives_dir}" >&2
    fi
    exit 1
  fi
}

prepare_release_notes_for_archives

mkdir -p "$(dirname "$state_appcast_path")"

cmd=(
  "$tool_path"
  --download-url-prefix "$download_url_prefix"
  --release-notes-url-prefix "$release_notes_url_prefix"
  --maximum-versions 1
)

if [[ -n "$ed_key_file" ]]; then
  cmd+=(--ed-key-file "$ed_key_file")
fi

if [[ -n "$account" ]]; then
  cmd+=(--account "$account")
fi

if [[ "$track" == "beta" ]]; then
  cmd+=(--channel beta)
fi

cmd+=(-o "$state_appcast_path")

cmd+=("$archives_dir")

echo "Running: ${cmd[*]}"
"${cmd[@]}"

appcast_path="${state_appcast_path}"
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

invalid_url_count="$(xmllint --xpath "count(//*[local-name()='enclosure'][not(starts-with(@url, '${download_url_prefix}'))])" "$appcast_path" 2>/dev/null || echo 1)"
if [[ "$invalid_url_count" != "0" ]]; then
  echo "Error: generated appcast contains enclosure URL(s) outside --download-url-prefix=${download_url_prefix}" >&2
  exit 1
fi

if [[ -n "$output_path" ]]; then
  mkdir -p "$(dirname "$output_path")"
  cp "$appcast_path" "$output_path"
fi

echo "Done: appcast generated for track=${track}, archives_dir=${archives_dir}, appcast=${appcast_path}"
