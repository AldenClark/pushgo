#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 || -z "$1" || -z "$2" || -z "$3" ]]; then
  echo "usage: $0 simulator-id app-bundle-path app-bundle-identifier" >&2
  exit 2
fi

target="$1"
app_bundle="$2"
app_bundle_identifier="$3"

if [[ ! -d "$app_bundle" ]]; then
  echo "status=BLOCKED" >&2
  echo "reason=ios_built_app_bundle_missing:$app_bundle" >&2
  exit 2
fi

# test-without-building can otherwise ask CoreSimulator to launch before Xcode's
# asynchronous placeholder installation has completed. Install and verify the
# exact built App as an explicit, observable preparation boundary.
if ! xcrun simctl install "$target" "$app_bundle"; then
  echo "status=BLOCKED" >&2
  echo "reason=ios_ui_app_preinstall_failed:$target" >&2
  exit 2
fi

installed_container="$(xcrun simctl get_app_container "$target" "$app_bundle_identifier" app 2>/dev/null || true)"
if [[ -z "$installed_container" || ! -d "$installed_container" ]]; then
  echo "status=BLOCKED" >&2
  echo "reason=ios_ui_app_install_not_observable:$target:$app_bundle_identifier" >&2
  exit 2
fi

echo "ios_ui_app_preinstalled=$installed_container"
