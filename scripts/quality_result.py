#!/usr/bin/env python3
"""Write one truthful, machine-readable quality-lane result.

The artifact reports only the claims actually exercised by the lane.  It is not
a capability oracle and must never be interpreted as whole-product coverage.
"""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path

try:
    from scripts import quality_test_system_issues
except ModuleNotFoundError:
    import quality_test_system_issues


STATUSES = {"PASSED", "FAILED", "FLAKY", "BLOCKED", "NOT_RUN", "WAIVED"}


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
        "schema_version": 1,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
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
