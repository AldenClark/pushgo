#!/usr/bin/env python3
"""Fail closed on mutable Actions and job-wide release credentials."""

from __future__ import annotations

import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.y*ml"))
IMMUTABLE_ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")
SENSITIVE_JOB_KEYS = {
    "APPLE_TEAM_ID",
    "ASC_KEY_ID",
    "ASC_ISSUER_ID",
    "ASC_KEY_P8",
    "PUSHGO_SPARKLE_BASE_URL",
}


def main() -> int:
    errors: list[str] = []
    for workflow in WORKFLOWS:
        lines = workflow.read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(lines, start=1):
            stripped = line.strip()
            if stripped.startswith("uses:"):
                value = stripped.removeprefix("uses:").split("#", 1)[0].strip()
                if value.startswith("./"):
                    continue
                if not IMMUTABLE_ACTION.fullmatch(value):
                    errors.append(f"{workflow}:{number}: mutable or malformed action reference: {value}")

            match = re.match(r"^ {6}([A-Z0-9_]+):", line)
            if match and match.group(1) in SENSITIVE_JOB_KEYS:
                errors.append(
                    f"{workflow}:{number}: {match.group(1)} must be scoped to the exact consuming step"
                )

    release_workflow = ROOT / ".github/workflows/apple-release.yml"
    release_text = release_workflow.read_text(encoding="utf-8")
    store_gate_markers = (
        "- name: Build signed store artifacts",
        "- name: Generate store SBOM and artifact manifest",
        "- name: Attest store artifacts",
        "- name: Upload attested store artifacts",
    )
    positions = [release_text.find(marker) for marker in store_gate_markers]
    if any(position < 0 for position in positions):
        errors.append(
            f"{release_workflow}: signed-build, evidence, attestation, and upload gates must all exist"
        )
    elif positions != sorted(positions) or len(set(positions)) != len(positions):
        errors.append(
            f"{release_workflow}: store upload must occur only after evidence generation and attestation"
        )

    fastfile = (ROOT / "fastlane/Fastfile").read_text(encoding="utf-8")
    for lane in ("lane :store_build", "lane :beta_upload_prebuilt", "lane :release_upload_prebuilt"):
        if lane not in fastfile:
            errors.append(f"fastlane/Fastfile: missing gated release lane {lane}")

    if errors:
        raise SystemExit("\n".join(errors))
    print("release workflow action pins and credential scopes verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
