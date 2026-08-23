#!/usr/bin/env python3
"""Generate deterministic dependency and artifact evidence without external tooling."""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import pathlib
import re
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCKS = (
    ROOT / "Package.resolved",
    ROOT / "pushgo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def spdx_id(identity: str) -> str:
    return "SPDXRef-Package-" + re.sub(r"[^A-Za-z0-9.-]", "-", identity)


def load_packages() -> list[dict[str, object]]:
    packages: dict[tuple[str, str], dict[str, object]] = {}
    for lock in LOCKS:
        payload = json.loads(lock.read_text(encoding="utf-8"))
        for pin in payload.get("pins", []):
            state = pin.get("state", {})
            identity = str(pin["identity"])
            revision = str(state["revision"])
            key = (identity, revision)
            packages[key] = {
                "SPDXID": spdx_id(f"{identity}-{revision[:12]}"),
                "name": identity,
                "versionInfo": str(state.get("version", revision)),
                "downloadLocation": str(pin.get("location", "NOASSERTION")),
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "externalRefs": [
                    {
                        "referenceCategory": "OTHER",
                        "referenceType": "vcs",
                        "referenceLocator": f"git+{pin.get('location')}@{revision}",
                    }
                ],
            }
    return [packages[key] for key in sorted(packages)]


def git_output(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--subject-pattern", action="append", default=[])
    args = parser.parse_args()

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    subjects = sorted(
        {
            pathlib.Path(match).resolve()
            for pattern in args.subject_pattern
            for match in glob.glob(pattern)
            if pathlib.Path(match).is_file()
        }
    )
    if not subjects:
        raise SystemExit("no release artifacts matched --subject-pattern")

    packages = load_packages()
    lock_digest = hashlib.sha256(
        b"".join(lock.read_bytes() for lock in LOCKS)
    ).hexdigest()
    created = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    document_id = f"SPDXRef-DOCUMENT-{lock_digest[:16]}"
    sbom = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": document_id,
        "name": "PushGo-Apple-dependencies",
        "documentNamespace": f"https://github.com/{os.getenv('GITHUB_REPOSITORY', 'pushgo/local')}/spdx/{lock_digest}",
        "creationInfo": {
            "created": created,
            "creators": ["Tool: PushGo-generate_apple_release_evidence.py"],
        },
        "packages": packages,
        "relationships": [
            {
                "spdxElementId": document_id,
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": package["SPDXID"],
            }
            for package in packages
        ],
    }
    (output_dir / "apple-dependencies.spdx.json").write_text(
        json.dumps(sbom, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    artifact_entries = [
        {
            "name": path.name,
            "path": str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else path.name,
            "sha256": sha256(path),
            "size": path.stat().st_size,
        }
        for path in subjects
    ]
    manifest = {
        "schema": "pushgo.apple.release-evidence.v1",
        "source": {
            "commit": os.getenv("GITHUB_SHA") or git_output("rev-parse", "HEAD"),
            "repository": os.getenv("GITHUB_REPOSITORY", "local"),
            "run_id": os.getenv("GITHUB_RUN_ID"),
            "ref": os.getenv("GITHUB_REF"),
        },
        "generated_at": created,
        "dependency_lock_sha256": lock_digest,
        "artifacts": artifact_entries,
    }
    (output_dir / "release-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "SHA256SUMS").write_text(
        "".join(f"{entry['sha256']}  {entry['name']}\n" for entry in artifact_entries),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
