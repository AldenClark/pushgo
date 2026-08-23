#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <derived-data-root>" >&2
  exit 2
fi

DERIVED_ROOT="$1"
if [[ ! -d "$DERIVED_ROOT" ]]; then
  echo "derived data root does not exist: $DERIVED_ROOT" >&2
  exit 1
fi

bundle_count=0
missing=()
while IFS= read -r -d '' bundle; do
  bundle_count=$((bundle_count + 1))
  if [[ ! -f "$bundle/PrivacyInfo.xcprivacy" \
        && ! -f "$bundle/Contents/Resources/PrivacyInfo.xcprivacy" ]]; then
    missing+=("$bundle")
  fi
done < <(
  find "$DERIVED_ROOT" -path '*/Build/Products/*' -type d \
    \( -name '*.app' -o -name '*.appex' \) -print0
)

if [[ $bundle_count -eq 0 ]]; then
  echo "no built application or extension bundles found under $DERIVED_ROOT" >&2
  exit 1
fi
if (( ${#missing[@]} > 0 )); then
  printf 'PrivacyInfo.xcprivacy missing from built bundle: %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "privacy manifest embedded in ${bundle_count} built application/extension bundles"
