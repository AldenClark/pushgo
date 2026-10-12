#!/usr/bin/env python3
"""Record hashes for signed Apple artifacts accepted by the build workflow."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


VALIDATIONS = {
    "app-store": {"profile-entitlements", "fastlane-archive-export"},
    "dmg": {"direct-profile-entitlements", "developer-id-signing", "notarization-stapling"},
}
FORBIDDEN_SUFFIXES = {".p12", ".p8", ".mobileprovision", ".provisionprofile", ".key", ".pem"}


def describe_artifact(path: Path) -> dict[str, int | str]:
    if not path.is_file():
        raise ValueError(f"signed artifact is missing: {path}")
    if path.suffix.lower() in FORBIDDEN_SUFFIXES:
        raise ValueError(f"refusing to retain signing material: {path.name}")
    digest = hashlib.sha256()
    with path.open("rb") as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"name": path.name, "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def build_receipt(target: str, version: str, artifacts: list[Path], validations: set[str]) -> dict:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("acceptance version must be stable X.Y.Z")
    if validations != VALIDATIONS[target]:
        raise ValueError(f"{target} acceptance must include exactly: {', '.join(sorted(VALIDATIONS[target]))}")
    descriptions = [describe_artifact(path) for path in sorted(artifacts)]
    required_extensions = {".ipa", ".pkg"} if target == "app-store" else {".dmg"}
    if len(artifacts) != len(required_extensions) or {path.suffix.lower() for path in artifacts} != required_extensions:
        raise ValueError(f"{target} acceptance artifact set must be {', '.join(sorted(required_extensions))}")
    return {
        "schema_version": 1,
        "target": target,
        "candidate_version": version,
        "status": "PASSED",
        "publication": "NOT_PERFORMED",
        "product_acceptance": "NOT_CERTIFIED",
        "validated_gates": sorted(validations),
        "artifacts": descriptions,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=sorted(VALIDATIONS))
    parser.add_argument("--version", required=True)
    parser.add_argument("--artifact", action="append", type=Path, required=True)
    parser.add_argument("--validation", action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    receipt = build_receipt(args.target, args.version, args.artifact, set(args.validation))
    receipt["source_revision"] = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True
    ).strip()
    receipt["source_dirty"] = bool(subprocess.check_output(
        ["git", "status", "--porcelain"], text=True
    ).strip())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"signing_acceptance={args.target}:PASSED publication=NOT_PERFORMED product_acceptance=NOT_CERTIFIED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
