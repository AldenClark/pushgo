#!/usr/bin/env python3
"""Write one truthful, machine-readable quality-lane result.

The artifact reports only the claims actually exercised by the lane.  It is not
a capability oracle and must never be interpreted as whole-product coverage.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path

try:
    from scripts import quality_test_system_issues
except ModuleNotFoundError:
    import quality_test_system_issues


STATUSES = {"PASSED", "FAILED", "FLAKY", "BLOCKED", "NOT_RUN", "WAIVED"}


def git_value(*arguments: str, allow_empty: bool = False) -> str | None:
    try:
        process = subprocess.run(
            ["git", *arguments],
            cwd=Path(__file__).resolve().parent.parent,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError:
        return None
    value = process.stdout.strip()
    return value if process.returncode == 0 and (value or allow_empty) else None


def source_provenance() -> tuple[str | None, bool | None, str | None]:
    revision = os.environ.get("QUALITY_SOURCE_REVISION") or os.environ.get("GITHUB_SHA")
    if not revision:
        revision = git_value("rev-parse", "HEAD")

    explicit_dirty = os.environ.get("QUALITY_SOURCE_DIRTY")
    if explicit_dirty is not None:
        normalized = explicit_dirty.strip().lower()
        if normalized not in {"0", "1", "false", "true"}:
            raise SystemExit("QUALITY_SOURCE_DIRTY must be true/false or 1/0")
        dirty: bool | None = normalized in {"1", "true"}
    else:
        status = git_value(
            "status", "--porcelain", "--untracked-files=normal", allow_empty=True
        )
        dirty = None if status is None else bool(status)

    run_identity = os.environ.get("QUALITY_RUN_ID")
    if not run_identity and os.environ.get("GITHUB_RUN_ID"):
        run_identity = "github:{run}:{attempt}:{job}".format(
            run=os.environ["GITHUB_RUN_ID"],
            attempt=os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
            job=os.environ.get("GITHUB_JOB", "unknown"),
        )
    return revision, dirty, run_identity


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--lane", required=True)
    parser.add_argument("--product-status", required=True, choices=sorted(STATUSES))
    parser.add_argument("--test-system-status", required=True, choices=sorted(STATUSES))
    parser.add_argument("--selected-claim", action="append", default=[])
    parser.add_argument("--claim", action="append", default=[])
    parser.add_argument("--not-run", action="append", default=[])
    parser.add_argument("--test-system-issue-id", action="append", default=[])
    parser.add_argument("--reason")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source_revision, source_dirty, run_identity = source_provenance()
    issue_ids = list(dict.fromkeys(args.test_system_issue_id))
    if args.test_system_status == "PASSED" and issue_ids:
        raise SystemExit("PASSED test-system status cannot carry test-system issue ids")
    if args.test_system_status == "FLAKY" and not issue_ids:
        raise SystemExit("FLAKY test-system status requires an active registered issue id")
    if issue_ids:
        registry_path = Path(__file__).resolve().parent.parent / "config/quality-test-system-issues.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        quality_test_system_issues.validate_registry(registry, date.today())
        active_issues = {
            issue["id"]: issue
            for issue in registry.get("issues", [])
            if issue.get("status") == "active"
        }
        active_ids = set(active_issues)
        unknown_ids = sorted(set(issue_ids) - active_ids)
        if unknown_ids:
            raise SystemExit(f"unknown or inactive test-system issue ids: {','.join(unknown_ids)}")
        if args.test_system_status == "FLAKY":
            non_flake_ids = sorted(
                issue_id for issue_id in issue_ids if active_issues[issue_id].get("kind") != "flake"
            )
            if non_flake_ids:
                raise SystemExit(
                    "FLAKY test-system status requires active flake issue ids: "
                    + ",".join(non_flake_ids)
                )
    incomplete_selected_claims = [
        claim for claim in args.selected_claim if claim not in args.claim
    ]
    if args.product_status == "PASSED" and (
        not args.selected_claim or incomplete_selected_claims
    ):
        raise SystemExit(
            "PASSED requires at least one selected claim and every selected claim "
            "to be present in executed claims"
        )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": 2,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "source_revision": source_revision,
        "source_dirty": source_dirty,
        "run_identity": run_identity,
        "platform": args.platform,
        "lane": args.lane,
        "product_capability_status": args.product_status,
        "test_system_status": args.test_system_status,
        "selected_claims": args.selected_claim,
        "executed_claims": args.claim,
        "incomplete_selected_claims": incomplete_selected_claims,
        "not_run": args.not_run,
        "test_system_issue_ids": issue_ids,
        "reason": args.reason,
        "scope_notice": "PASSED applies only to executed_claims. Selected claims absent from executed_claims failed or were blocked; this is not whole-product coverage.",
    }
    with tempfile.NamedTemporaryFile("w", dir=output.parent, delete=False) as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, output)


if __name__ == "__main__":
    main()
