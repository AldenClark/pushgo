#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/create_pretty_dmg.sh [options]

Options:
  --app PATH             Use an existing PushGo.app instead of building locally.
  --background PATH      DMG Finder background image.
                         Default: scripts/assets/dmg/pushgo_dmg_bg_680pt_2x.jpg
  --output-dir PATH      Directory for generated artifacts. Default: artifacts/local-dmg
  --output-name NAME     DMG filename stem and volume name. Default: PushGo-macOS-local
  --output PATH          Final DMG path. Overrides --output-dir for the output file.
  --display-version VER  Set PUSHGO_DISPLAY_VERSION for the local build.
  --no-build             Require --app and skip xcodebuild.
  -h, --help             Show this help.

This is a local visual-debug DMG builder. It mirrors the release DMG staging
shape, but intentionally skips Developer ID signing, notarization, and Sparkle
appcast generation.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="${repo_root}/pushgo.xcodeproj"
scheme="${APP_MACOS_DMG_SCHEME:-PushGo-macOS-DMG}"
sparkle_xcconfig="${APP_MACOS_DMG_XCCONFIG:-${repo_root}/config/PushGo-macOS-DMG-Sparkle.xcconfig}"
background_path="${repo_root}/scripts/assets/dmg/pushgo_dmg_bg_680pt_2x.jpg"
output_dir="${repo_root}/artifacts/local-dmg"
output_name="PushGo-macOS-local"
final_dmg_override=""
display_version="${PUSHGO_DISPLAY_VERSION:-}"
app_path=""
skip_build="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      app_path="${2:-}"
      shift 2
      ;;
    --background)
      background_path="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --output-name)
      output_name="${2:-}"
      shift 2
      ;;
    --output)
      final_dmg_override="${2:-}"
      shift 2
      ;;
    --display-version)
      display_version="${2:-}"
      shift 2
      ;;
    --no-build)
      skip_build="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$background_path" ]]; then
  echo "Background image not found: $background_path" >&2
  exit 1
fi

if [[ "$skip_build" == "true" && -z "$app_path" ]]; then
  echo "--no-build requires --app PATH" >&2
  exit 1
fi

if [[ ! -f "$sparkle_xcconfig" ]]; then
  echo "Sparkle xcconfig not found: $sparkle_xcconfig" >&2
  exit 1
fi

required_tools=(hdiutil osascript sips iconutil SetFile Rez DeRez)
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool not found: $tool" >&2
    echo "Install Xcode command line tools and ensure /usr/bin is on PATH." >&2
    exit 1
  fi
done

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pushgo-pretty-dmg.XXXXXX")"
rw_dmg="${work_dir}/${output_name}.rw.dmg"
staging_dir="${work_dir}/staging"
iconset_dir="${work_dir}/PushGo.iconset"
volume_icon="${work_dir}/VolumeIcon.icns"
dmg_file_icon_png="${work_dir}/DmgFileIcon.png"
icon_resource="${work_dir}/DmgFileIcon.rsrc"
finder_background="${work_dir}/pushgo_dmg_bg_680pt_2x.png"
if [[ -n "$final_dmg_override" ]]; then
  mkdir -p "$(dirname "$final_dmg_override")"
  final_dmg="$(cd "$(dirname "$final_dmg_override")" && pwd)/$(basename "$final_dmg_override")"
else
  final_dmg="${output_dir}/${output_name}.dmg"
fi
mounted_volume=""

cleanup() {
  if [[ -n "$mounted_volume" && -d "$mounted_volume" ]]; then
    hdiutil detach "$mounted_volume" -quiet || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

build_app() {
  local derived_data="${output_dir}/${output_name}-DerivedData"
  rm -rf "$derived_data"

  xcodebuild \
    -project "$project_path" \
    -scheme "$scheme" \
    -xcconfig "$sparkle_xcconfig" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data" \
    build \
    "PUSHGO_DISPLAY_VERSION=${display_version}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    DEVELOPMENT_TEAM=''

  local built_app
  built_app="$(find "$derived_data/Build/Products/Release" -maxdepth 1 -type d -name "*.app" -print -quit)"
  if [[ -z "$built_app" ]]; then
    echo "No built .app found under $derived_data/Build/Products/Release" >&2
    exit 1
  fi
  app_path="$built_app"
}

make_volume_icon() {
  local source_png="${repo_root}/Resources/AppIcon.icon/Assets/6ccf56e120998a22217130365797a9727de3afd9d5b10cea358ad02e50c93886.png"
  if [[ ! -f "$source_png" ]]; then
    echo "PushGo source icon not found: $source_png" >&2
    exit 1
  fi

  mkdir -p "$iconset_dir"
  sips -z 16 16 "$source_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64 "$source_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$source_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
  cp "$source_png" "$iconset_dir/icon_512x512@2x.png"
  iconutil -c icns "$iconset_dir" -o "$volume_icon"
  cp "$source_png" "$dmg_file_icon_png"
}

prepare_custom_icon_resource() {
  sips -i "$dmg_file_icon_png" >/dev/null
  DeRez -only icns "$dmg_file_icon_png" > "$icon_resource"
}

apply_custom_file_icon() {
  local target_path="$1"

  Rez -append "$icon_resource" -o "$target_path"
  SetFile -a C "$target_path"
}

write_finder_icon_file() {
  local target_path="$1"

  : > "$target_path"
  Rez -append "$icon_resource" -o "$target_path"
  SetFile -a V "$target_path"
}

if [[ -z "$app_path" ]]; then
  build_app
fi

if [[ ! -d "$app_path" || "${app_path##*.}" != "app" ]]; then
  echo "App bundle not found or not a .app directory: $app_path" >&2
  exit 1
fi

make_volume_icon
prepare_custom_icon_resource
sips \
  -s format png \
  -s dpiWidth 144 \
  -s dpiHeight 144 \
  "$background_path" \
  --out "$finder_background" >/dev/null

rm -f "$final_dmg"
mkdir -p "$staging_dir/.background" "$staging_dir/.localized"
ditto "$app_path" "$staging_dir/PushGo.app"
applications_link_name=" "
ln -s /Applications "$staging_dir/${applications_link_name}"
cat > "$staging_dir/.localized/en.strings" <<'EOF'
"PushGo.app" = " ";
EOF
cp "$staging_dir/.localized/en.strings" "$staging_dir/.localized/zh_CN.strings"
cp "$staging_dir/.localized/en.strings" "$staging_dir/.localized/zh_Hans.strings"
cp "$staging_dir/.localized/en.strings" "$staging_dir/.localized/zh_TW.strings"
cp "$staging_dir/.localized/en.strings" "$staging_dir/.localized/zh_Hant.strings"
cp "$finder_background" "$staging_dir/.background/pushgo_dmg_bg_680pt_2x.png"
cp "$volume_icon" "$staging_dir/.VolumeIcon.icns"
SetFile -a V "$staging_dir/.background"
SetFile -a V "$staging_dir/.localized"
SetFile -a V "$staging_dir/.VolumeIcon.icns"
SetFile -a C "$staging_dir"

staging_size_mb="$(du -sm "$staging_dir" | awk '{print $1}')"
image_size_mb=$((staging_size_mb + 96))

hdiutil create \
  -volname "$output_name" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -ov \
  -size "${image_size_mb}m" \
  "$rw_dmg" >/dev/null

mounted_volume="$(
  hdiutil attach "$rw_dmg" \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "/Volumes/${output_name}" \
    | awk '/\/Volumes\// {print $3; exit}'
)"

if [[ -z "$mounted_volume" || ! -d "$mounted_volume" ]]; then
  echo "Failed to mount $rw_dmg" >&2
  exit 1
fi

ditto "$staging_dir" "$mounted_volume"
SetFile -a C "$mounted_volume"
cp "$volume_icon" "$mounted_volume/.VolumeIcon.icns"
SetFile -a V "$mounted_volume/.VolumeIcon.icns"
write_finder_icon_file "${mounted_volume}/Icon"$'\r'
SetFile -a C "$mounted_volume"

/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "${output_name}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {120, 120, 800, 630}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 160
    try
      set text size of theViewOptions to 1
    end try
    set label position of theViewOptions to bottom
    set background picture of theViewOptions to file ".background:pushgo_dmg_bg_680pt_2x.png"
    set position of item "PushGo.app" of container window to {170, 302}
    set position of item " " of container window to {512, 302}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$mounted_volume" -quiet
mounted_volume=""

hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$final_dmg" >/dev/null
rm -f "${final_dmg}.tmp"
apply_custom_file_icon "$final_dmg"

echo "Created DMG: $final_dmg"
echo "Open it with: open '$final_dmg'"
