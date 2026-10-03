#!/usr/bin/env python3
"""Validate repository-owned Sparkle and App Store update metadata."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlparse


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-beta\.[1-9][0-9]*)?$")
NOTE_LOCALES = {"en", "zh-CN", "zh-TW"}
APP_STORE_LOCALES = {"en-US", "zh-Hans", "zh-Hant"}
APP_STORE_FIELDS = {"promotional_text", "keywords", "description", "support_url"}
REPO_ROOT = Path(__file__).resolve().parents[1]


class ContractError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def require_https(value: str | None, label: str) -> None:
    parsed = urlparse(value or "")
    require(parsed.scheme == "https" and bool(parsed.netloc), f"{label} must be an HTTPS URL")


def validate_appcast(path: Path) -> None:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        raise ContractError(f"{path}: invalid XML: {error}") from error

    require(root.tag == "rss" and root.get("version") == "2.0", f"{path}: expected RSS 2.0 root")
    channel = root.find("channel")
    require(channel is not None, f"{path}: missing channel")
    items = channel.findall("item")
    require(bool(items), f"{path}: feed must contain at least one item")

    identities: set[tuple[str, int]] = set()
    for index, item in enumerate(items, start=1):
        label = f"{path}: item {index}"
        track = (item.findtext(f"{{{SPARKLE}}}channel") or "stable").strip()
        require(track in {"stable", "beta"}, f"{label}: unsupported channel {track!r}")
        build_text = (item.findtext(f"{{{SPARKLE}}}version") or "").strip()
        require(build_text.isdigit() and int(build_text) > 0, f"{label}: invalid build version")
        identity = (track, int(build_text))
        require(identity not in identities, f"{label}: duplicate channel/build {identity}")
        identities.add(identity)

        short_version = (item.findtext(f"{{{SPARKLE}}}shortVersionString") or "").strip()
        require(bool(VERSION_RE.fullmatch(short_version)), f"{label}: invalid short version")
        enclosure = item.find("enclosure")
        require(enclosure is not None, f"{label}: missing enclosure")
        require_https(enclosure.get("url"), f"{label} enclosure")
        require(enclosure.get("type") == "application/octet-stream", f"{label}: invalid enclosure type")
        length = enclosure.get("length") or ""
        require(length.isdigit() and int(length) > 0, f"{label}: invalid enclosure length")
        signature = enclosure.get(f"{{{SPARKLE}}}edSignature") or ""
        try:
            decoded_signature = base64.b64decode(signature, validate=True)
        except (binascii.Error, ValueError) as error:
            raise ContractError(f"{label}: malformed Ed25519 signature") from error
        require(len(decoded_signature) == 64, f"{label}: Ed25519 signature must be 64 bytes")

        links = item.findall(f"{{{SPARKLE}}}releaseNotesLink")
        require(bool(links), f"{label}: missing release notes link")
        for link in links:
            require_https(link.text, f"{label} release notes")


def validate_update_notes(directory: Path) -> None:
    files = sorted(directory.glob("v*.json"))
    require(bool(files), f"{directory}: no versioned update notes")
    for path in files:
        require(VERSION_RE.fullmatch(path.stem.removeprefix("v")) is not None, f"{path}: invalid version filename")
        payload = json.loads(path.read_text(encoding="utf-8"))
        require(isinstance(payload, dict), f"{path}: expected locale object")
        require(NOTE_LOCALES.issubset(payload), f"{path}: missing required locales")
        for locale in NOTE_LOCALES:
            value = payload[locale]
            require(isinstance(value, str) and bool(value.strip()), f"{path}: empty {locale} notes")


def validate_app_store(path: Path) -> None:
    payload = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(payload, dict), f"{path}: expected locale object")
    require(APP_STORE_LOCALES.issubset(payload), f"{path}: missing required locales")
    for locale in APP_STORE_LOCALES:
        metadata = payload[locale]
        require(isinstance(metadata, dict), f"{path}: {locale} must be an object")
        require(APP_STORE_FIELDS.issubset(metadata), f"{path}: {locale} missing required fields")
        for field in APP_STORE_FIELDS:
            value = metadata[field]
            require(isinstance(value, str) and bool(value.strip()), f"{path}: empty {locale}.{field}")
        require_https(metadata["support_url"], f"{path} {locale}.support_url")


def validate_macos_sparkle_install_integration(repo_root: Path) -> None:
    info_path = repo_root / "Apps/PushGo-macOS/PushGo-macOS-DMG-Info.plist"
    entitlements_path = repo_root / "Apps/PushGo-macOS/pushgomac-dmg.entitlements"
    project_path = repo_root / "pushgo.xcodeproj/project.pbxproj"
    config_path = repo_root / "config/PushGo-macOS-DMG-Sparkle.xcconfig"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    with entitlements_path.open("rb") as stream:
        entitlements = plistlib.load(stream)
    project = project_path.read_text(encoding="utf-8")
    config = config_path.read_text(encoding="utf-8")

    require(
        info.get("SUEnableInstallerLauncherService") is True,
        f"{info_path}: sandboxed Sparkle builds must enable the Installer Launcher service",
    )
    mach_services = entitlements.get(
        "com.apple.security.temporary-exception.mach-lookup.global-name"
    )
    require(
        isinstance(mach_services, list),
        f"{entitlements_path}: missing Sparkle installer mach service exceptions",
    )
    required_services = {
        "$(PRODUCT_BUNDLE_IDENTIFIER)-spks",
        "$(PRODUCT_BUNDLE_IDENTIFIER)-spki",
    }
    require(
        required_services.issubset(set(mach_services or [])),
        f"{entitlements_path}: incomplete Sparkle installer mach service exceptions",
    )
    require(
        project.count(
            'CODE_SIGN_ENTITLEMENTS = "Apps/PushGo-macOS/pushgomac-dmg.entitlements";'
        )
        == 2,
        f"{project_path}: Debug and Release DMG configurations must use the DMG entitlements",
    )
    public_key_match = re.search(
        r"^PUSHGO_SPARKLE_PUBLIC_ED_KEY\s*=\s*([^\s]+)\s*$",
        config,
        flags=re.MULTILINE,
    )
    require(public_key_match is not None, f"{config_path}: missing Sparkle public key")
    public_key = public_key_match.group(1) if public_key_match is not None else ""
    require(
        not public_key.startswith(('"', "'")),
        f"{config_path}: Sparkle public key must not contain literal xcconfig quotes",
    )
    try:
        decoded_public_key = base64.b64decode(public_key, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ContractError(f"{config_path}: malformed Sparkle public key") from error
    require(
        len(decoded_public_key) == 32,
        f"{config_path}: Sparkle public key must decode to 32 bytes",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", type=Path, default=Path("release/appcast.xml"))
    parser.add_argument("--app-store", type=Path, default=Path("release/appstore.json"))
    parser.add_argument("--update-notes", type=Path, default=Path("release/update-notes"))
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    validate_appcast(args.appcast)
    validate_app_store(args.app_store)
    validate_update_notes(args.update_notes)
    validate_macos_sparkle_install_integration(args.repo_root)
    print("Apple update distribution contract verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
