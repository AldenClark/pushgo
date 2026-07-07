#!/usr/bin/env python3
import argparse
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional


PROFILE_EXTENSIONS = ("mobileprovision", "provisionprofile")
APS_KEYS = ("aps-environment", "com.apple.developer.aps-environment")
PROFILE_MANAGED_BOOLEAN_KEYS = (
    "com.apple.developer.usernotifications.time-sensitive",
)


def decode_profile(path: Path) -> dict:
    with tempfile.NamedTemporaryFile() as decoded:
        subprocess.run(
            ["security", "cms", "-D", "-i", str(path), "-o", decoded.name],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        with open(decoded.name, "rb") as handle:
            return plistlib.load(handle)


def load_plist(path: Path) -> dict:
    with open(path, "rb") as handle:
        return plistlib.load(handle)


def find_profile(profile_dir: Path, uuid: str) -> Optional[Path]:
    for extension in PROFILE_EXTENSIONS:
        candidate = profile_dir / f"{uuid}.{extension}"
        if candidate.exists():
            return candidate
    return None


def bundle_id_from_profile(profile: dict) -> str:
    entitlements = profile.get("Entitlements", {})
    app_identifier = (
        entitlements.get("application-identifier")
        or entitlements.get("com.apple.application-identifier")
        or ""
    )
    return app_identifier.split(".", 1)[1] if "." in app_identifier else ""


def has_aps(entitlements: dict) -> bool:
    return any(key in entitlements for key in APS_KEYS)


def group_is_authorized(required_group: str, profile_group: str) -> bool:
    if profile_group == required_group:
        return True
    if profile_group == "*":
        return True
    if profile_group.endswith(".*"):
        return required_group.startswith(profile_group[:-1])
    return False


def validate_profile(
    *,
    label: str,
    uuid: str,
    expected_bundle_id: str,
    entitlements_path: Path,
    profile_dir: Path,
) -> list[str]:
    errors: list[str] = []
    profile_path = find_profile(profile_dir, uuid)
    if profile_path is None:
        return [
            f"{label}: profile {uuid} was not installed under {profile_dir}"
        ]

    profile = decode_profile(profile_path)
    profile_entitlements = profile.get("Entitlements", {})
    target_entitlements = load_plist(entitlements_path)

    actual_bundle_id = bundle_id_from_profile(profile)
    if actual_bundle_id != expected_bundle_id:
        errors.append(
            f"{label}: bundle id mismatch, expected {expected_bundle_id}, got {actual_bundle_id or '<missing>'}"
        )

    if has_aps(target_entitlements) and not has_aps(profile_entitlements):
        errors.append(
            f"{label}: profile {profile.get('Name', uuid)} ({uuid}) does not include the Push Notifications capability / aps-environment entitlement"
        )

    required_groups = target_entitlements.get("com.apple.security.application-groups", [])
    profile_groups = profile_entitlements.get("com.apple.security.application-groups", [])
    for required_group in required_groups:
        if not any(group_is_authorized(required_group, group) for group in profile_groups):
            errors.append(
                f"{label}: profile does not authorize app group {required_group}"
            )

    for key in PROFILE_MANAGED_BOOLEAN_KEYS:
        if target_entitlements.get(key) is True and profile_entitlements.get(key) is not True:
            errors.append(
                f"{label}: profile does not include entitlement {key}"
            )

    return errors


def parse_profile_argument(raw: str) -> tuple[str, str, str, Path]:
    parts = raw.split(":", 3)
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(
            "--profile must use label:uuid:bundle_id:entitlements_path"
        )
    label, uuid, bundle_id, entitlements_path = parts
    return label, uuid, bundle_id, Path(entitlements_path)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate release provisioning profiles against target entitlements."
    )
    parser.add_argument(
        "--profiles-dir",
        default=str(Path.home() / "Library/MobileDevice/Provisioning Profiles"),
    )
    parser.add_argument(
        "--profile",
        action="append",
        type=parse_profile_argument,
        required=True,
        help="Profile tuple as label:uuid:bundle_id:entitlements_path",
    )
    args = parser.parse_args()

    profile_dir = Path(args.profiles_dir)
    errors: list[str] = []

    for label, uuid, bundle_id, entitlements_path in args.profile:
        errors.extend(
            validate_profile(
                label=label,
                uuid=uuid,
                expected_bundle_id=bundle_id,
                entitlements_path=entitlements_path,
                profile_dir=profile_dir,
            )
        )

    if errors:
        print("Release provisioning profile validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Validated {len(args.profile)} release provisioning profiles.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
