#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/publish_update_artifacts.sh <artifacts_dir> <appcast_path> <remote_user_host> <remote_base_path> [stable|beta] [expected_version]

Example:
  scripts/publish_update_artifacts.sh artifacts/release release/appcast.xml deploy@update.pushgo.cn /var/www/update.pushgo.cn/macos beta v1.2.0-beta.3

Requirements:
  - ssh access configured (optionally via PUSHGO_UPDATE_DEPLOY_SSH_KEY_FILE)
  - tar
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 4 ]]; then
  usage
  exit 1
fi

artifacts_dir="$1"
appcast_path="$2"
remote_user_host="$3"
remote_base_path="$4"
track="${5:-stable}"
expected_version="${6:-}"

if [[ "$track" != "stable" && "$track" != "beta" ]]; then
  echo "Error: track must be stable or beta, got: $track" >&2
  exit 1
fi

if [[ -n "$expected_version" && ! "$expected_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]]; then
  echo "Error: expected_version must look like vX.Y.Z or vX.Y.Z-beta.N, got: $expected_version" >&2
  exit 1
fi

if [[ ! -d "$artifacts_dir" ]]; then
  echo "Error: artifacts directory not found: $artifacts_dir" >&2
  exit 1
fi

if [[ ! -f "$appcast_path" ]]; then
  echo "Error: appcast file not found: $appcast_path" >&2
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "Error: ssh is required" >&2
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "Error: tar is required" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
retry_cmd="${script_dir}/retry_command.sh"
if [[ ! -f "$retry_cmd" ]]; then
  echo "Error: retry helper not found: $retry_cmd" >&2
  exit 1
fi

ssh_opts=(
  -o BatchMode=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=6
)
if [[ -n "${PUSHGO_UPDATE_DEPLOY_SSH_KEY_FILE:-}" ]]; then
  if [[ ! -f "${PUSHGO_UPDATE_DEPLOY_SSH_KEY_FILE}" ]]; then
    echo "Error: PUSHGO_UPDATE_DEPLOY_SSH_KEY_FILE not found: ${PUSHGO_UPDATE_DEPLOY_SSH_KEY_FILE}" >&2
    exit 1
  fi
  ssh_opts+=(-i "${PUSHGO_UPDATE_DEPLOY_SSH_KEY_FILE}" -o IdentitiesOnly=yes)
fi

shopt -s nullglob
all_dmg_files=("${artifacts_dir%/}"/*.dmg)
shopt -u nullglob
if (( ${#all_dmg_files[@]} == 0 )); then
  echo "Error: no DMG artifact found under ${artifacts_dir}" >&2
  exit 1
fi

dmg_path="${all_dmg_files[0]}"
version=""
matching_count=0
for candidate in "${all_dmg_files[@]}"; do
  name="$(basename "$candidate")"
  if [[ "$name" =~ (v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?) ]]; then
    version_candidate="${BASH_REMATCH[1]}"
    if [[ -n "$expected_version" && "$version_candidate" != "$expected_version" ]]; then
      continue
    fi
    matching_count=$((matching_count + 1))
    dmg_path="$candidate"
    version="$version_candidate"
  fi
done

if [[ -z "$version" ]]; then
  if [[ -n "$expected_version" ]]; then
    echo "Error: no DMG artifact matches expected version ${expected_version} under ${artifacts_dir}" >&2
  else
    echo "Error: unable to infer version from DMG filename: $(basename "$dmg_path")" >&2
    echo "Hint: expected name like PushGo-macOS-vX.Y.Z(.beta.N).dmg" >&2
  fi
  exit 1
fi

if (( matching_count > 1 )); then
  echo "Error: multiple DMG artifacts match expected version ${version}; keep exactly one release DMG in ${artifacts_dir}" >&2
  exit 1
fi

release_dir="${remote_base_path%/}/${track}/${version}"
active_appcast_file="${remote_base_path%/}/appcast.xml"
dmg_name="$(basename "$dmg_path")"
staging_dir="$(mktemp -d -t pushgo-macos-deploy-XXXXXX)"
cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

cp "$dmg_path" "$staging_dir/$dmg_name"

dmg_stem="${dmg_name%.dmg}"
shopt -s nullglob
note_files=(
  "${artifacts_dir%/}/${dmg_stem}.txt"
  "${artifacts_dir%/}/${dmg_stem}."*.txt
)
shopt -u nullglob
for note_file in "${note_files[@]}"; do
  [[ -f "$note_file" ]] || continue
  cp "$note_file" "$staging_dir/$(basename "$note_file")"
done

(
  cd "$staging_dir"
  shasum -a 256 "$dmg_name" > SHA256SUMS.txt
)

bash "$retry_cmd" --always -- ssh "${ssh_opts[@]}" "$remote_user_host" \
  "rm -rf '$release_dir' && mkdir -p '$release_dir' '${remote_base_path%/}'"

(
  cd "$staging_dir"
  tar -cf - .
) | bash "$retry_cmd" --always -- ssh "${ssh_opts[@]}" "$remote_user_host" \
  "tar -xf - -C '$release_dir'"

bash "$retry_cmd" --always -- ssh "${ssh_opts[@]}" "$remote_user_host" \
  "cat > '$active_appcast_file'" < "$appcast_path"

echo "Published macOS update artifacts to ${remote_user_host}:${release_dir} and refreshed ${active_appcast_file}"
