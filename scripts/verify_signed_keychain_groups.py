#!/usr/bin/env python3
"""Reject signed bundles whose runtime Keychain group differs from their entitlement."""

import argparse
from pathlib import Path
import plistlib
import subprocess


def verify_metadata(info, entitlements):
    group = info.get("PushGoKeychainAccessGroup")
    if group is None:
        if info.get("CFBundleIdentifier") in {"io.ethan.pushgo", "io.ethan.pushgo.NotificationServiceExtension"}:
            raise ValueError("runtime Keychain access group is missing")
        return False  # Bundle does not configure this runtime Keychain client.
    if not isinstance(group, str) or "$" in group or group not in entitlements.get("keychain-access-groups", []):
        raise ValueError(f"runtime Keychain access group is not signed: {info.get('CFBundleIdentifier')}")
    return True


def verify(app):
    checked = 0
    for bundle in [app, *sorted(app.rglob("*.appex"))]:
        path = bundle / "Contents/Info.plist"
        if not path.exists():
            path = bundle / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        if "PushGoKeychainAccessGroup" not in info:
            verify_metadata(info, {})
            continue
        signed = subprocess.run(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
            capture_output=True, check=True, timeout=20,
        ).stdout
        checked += verify_metadata(info, plistlib.loads(signed))
    if checked == 0:
        raise ValueError("no runtime Keychain access groups were checked")
    print(f"signed_runtime_keychain_groups=PASSED bundles={checked}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    verify(parser.parse_args().app)
