"""Isolate branch-contract tests from the live expiry governance check.

These tests exercise receipt and preflight behavior with the exact production
scripts in a temporary tree. The canonical repository registry remains the
input to its separate, intentionally current-date validation test.
"""

import json
import shutil
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


def copy_quality_scripts_with_nonexpiring_registry(destination: Path) -> Path:
    scripts = destination / "scripts"
    config = destination / "config"
    scripts.mkdir(parents=True)
    config.mkdir(parents=True)
    for name in (
        "quality_test.sh",
        "quality_result.py",
        "quality_test_system_issues.py",
        "quality_disk_preflight.py",
    ):
        shutil.copy2(REPO / "scripts" / name, scripts / name)

    registry = json.loads(
        (REPO / "config/quality-test-system-issues.json").read_text(encoding="utf-8")
    )
    # Receipt branch tests need the permanent active precondition and resolved
    # runner issue. Active flakes have a live expiry gate, tested separately.
    registry["issues"] = [
        issue for issue in registry["issues"]
        if not (issue["kind"] == "flake" and issue["status"] == "active")
    ]
    (config / "quality-test-system-issues.json").write_text(
        json.dumps(registry, indent=2) + "\n", encoding="utf-8"
    )
    return destination
