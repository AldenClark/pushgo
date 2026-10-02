#!/usr/bin/env python3
"""Read configured signing inputs in memory; emit only contract booleans."""

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from validate_release_profiles import bundle_id_from_profile, group_is_authorized, has_aps

CERTIFICATES = {
    "APPLE_DISTRIBUTION": "Apple Distribution:",
    "MAC_INSTALLER_DISTRIBUTION": "3rd Party Mac Developer Installer:",
    "DEVELOPER_ID_APPLICATION": "Developer ID Application:",
}
PROFILES = {
    "APP_STORE_PROFILE_IOS_WIDGET": ("io.ethan.pushgo.widgets", "iOS", "PushGoWidgets.entitlements", "APPLE_DISTRIBUTION", False),
    "APP_STORE_PROFILE_WATCH_WIDGET": ("io.ethan.pushgo.watchkitapp.widgets", "iOS", "PushGoWidgets-watchOS.entitlements", "APPLE_DISTRIBUTION", False),
    "DEVELOPER_ID_PROFILE_MACOS_WIDGET": ("io.ethan.pushgo.widgets.mac", "OSX", "PushGoWidgets-macOS.entitlements", "DEVELOPER_ID_APPLICATION", True),
}


def openssl(arguments, payload, environment=None):
    # Raw stdout/stderr remain private to this process, including on failure.
    result = subprocess.run(
        ["/usr/bin/openssl", *arguments], input=payload, capture_output=True,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **(environment or {})}, timeout=20,
    )
    if result.returncode:
        raise ValueError("metadata_decoder_failed")
    return result.stdout, result.stderr


def decode_input(name):
    return base64.b64decode(os.environ[name + "_BASE64"], validate=True)


def certificate_metadata(name, family, team, now):
    password_name = name + "_P12_PASSWORD"
    pem, diagnostic = openssl(
        ["pkcs12", "-nokeys", "-clcerts", "-info", "-passin", "env:" + password_name],
        decode_input(name + "_P12"), {password_name: os.environ[password_name]},
    )
    info, _ = openssl(["x509", "-noout", "-subject", "-dates", "-nameopt", "RFC2253"], pem)
    der, _ = openssl(["x509", "-outform", "DER"], pem)
    text = info.decode()
    date = lambda label: dt.datetime.strptime(re.search(r"^" + label + r"=(.+)$", text, re.M)[1], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
    checks = {
        "decoded": True,
        "purpose_matches": "CN=" + family in text,
        "team_matches": bool(team) and bool(re.search(r"(?:^|,)OU=" + re.escape(team) + r"(?:,|$)", text)),
        "currently_valid": date("notBefore") <= now < date("notAfter"),
        "private_component_present": b"Shrouded Keybag" in diagnostic or b"Shrouded Key Bag" in diagnostic or b"Key bag" in diagnostic,
    }
    return checks, hashlib.sha256(der).digest()


def profile_checks(profile, contract, team, certificate_hash, now, entitlements):
    bundle, platform, _, _, direct = contract
    granted = profile.get("Entitlements", {})
    expiry = profile.get("ExpirationDate")
    created = profile.get("CreationDate")
    def current(value, before):
        return isinstance(value, dt.datetime) and (value.replace(tzinfo=dt.timezone.utc) <= now if before else now < value.replace(tzinfo=dt.timezone.utc))
    required_groups = entitlements.get("com.apple.security.application-groups", [])
    granted_groups = granted.get("com.apple.security.application-groups", [])
    return {
        "decoded_and_cms_signature_checked": True,
        "bundle_matches": bundle_id_from_profile(profile) == bundle,
        "platform_matches": platform in profile.get("Platform", []),
        "team_matches": bool(team) and team in profile.get("TeamIdentifier", []),
        "currently_valid": current(created, True) and current(expiry, False),
        "distribution_matches": granted.get("get-task-allow") is False and not profile.get("ProvisionedDevices") and bool(profile.get("ProvisionsAllDevices")) == direct,
        "certificate_matches": certificate_hash is not None and certificate_hash in [hashlib.sha256(c).digest() for c in profile.get("DeveloperCertificates", [])],
        "app_groups_match": all(any(group_is_authorized(g, permitted) for permitted in granted_groups) for g in required_groups),
        "production_push_matches": not has_aps(entitlements) or any(granted.get(k) == "production" for k in ("aps-environment", "com.apple.developer.aps-environment")),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    now = dt.datetime.now(dt.timezone.utc)
    team = os.environ.get("APPLE_TEAM_ID", "")
    assets, certificates = {}, {}
    for name, family in CERTIFICATES.items():
        try:
            assets[name], certificates[name] = certificate_metadata(name, family, team, now)
        except Exception:
            assets[name] = {"decoded": False}
    for name, contract in PROFILES.items():
        try:
            decoded, _ = openssl(["cms", "-verify", "-inform", "DER", "-noverify", "-binary"], decode_input(name))
            entitlements = plistlib.loads((ROOT / "Extensions/PushGoWidgets" / contract[2]).read_bytes())
            assets[name] = profile_checks(plistlib.loads(decoded), contract, team, certificates.get(contract[3]), now, entitlements)
        except Exception:
            assets[name] = {"decoded_and_cms_signature_checked": False}
    passed = all(all(checks.values()) for checks in assets.values())
    report = {
        "schema_version": 1, "source_revision": os.environ.get("GITHUB_SHA", ""),
        "metadata_status": "PASSED" if passed else "BLOCKED", "assets": assets,
        "actual_signing": "NOT_RUN", "publication": "NOT_RUN",
        "limitations": ["No key import or profile installation", "No trust-chain, archive/export, notarization or ASC API permission qualification", "Only the three explicitly supplied widget profiles; automatic profiles for other targets are not qualified"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0 if passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
