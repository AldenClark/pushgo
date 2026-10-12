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
ALLOWED_STATUS_PAIRS = {
    ("PASSED", "PASSED"),
    ("PASSED", "FLAKY"),
    ("FAILED", "PASSED"),
    ("NOT_RUN", "PASSED"),
    ("NOT_RUN", "FAILED"),
    ("NOT_RUN", "BLOCKED"),
    ("NOT_RUN", "FLAKY"),
    ("NOT_RUN", "NOT_RUN"),
    ("WAIVED", "PASSED"),
    ("NOT_RUN", "WAIVED"),
}


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
    parser.add_argument("--waiver-id")
    parser.add_argument("--reason")
    return parser.parse_args()


def validate_status_pair(product_status: str, test_system_status: str) -> None:
    if (product_status, test_system_status) not in ALLOWED_STATUS_PAIRS:
        raise ValueError(
            "invalid product/test-system status pair: "
            f"{product_status}/{test_system_status}"
        )


def validate_waiver(
    waiver_id: str | None,
    *,
    product_status: str,
    test_system_status: str,
    platform: str,
    lane: str,
    selected_claims: list[str],
    as_of: date,
) -> str | None:
    waived_axis = (
        "product" if product_status == "WAIVED"
        else "test-system" if test_system_status == "WAIVED"
        else None
    )
    if waived_axis is None:
        if waiver_id:
            raise ValueError("waiver id is only valid when exactly one status is WAIVED")
        return None
    if not waiver_id:
        raise ValueError("WAIVED requires a version-controlled active waiver id")
    if not selected_claims:
        raise ValueError("WAIVED requires at least one selected claim")

    registry_path = Path(__file__).resolve().parent.parent / "config/quality-waivers.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    if registry.get("schema_version") != 1 or not isinstance(registry.get("waivers"), list):
        raise ValueError("quality waiver registry must use schema_version 1 and a waivers array")
    matches = [item for item in registry["waivers"] if item.get("id") == waiver_id]
    if len(matches) != 1:
        raise ValueError(f"unknown or duplicate quality waiver id: {waiver_id}")
    waiver = matches[0]
    required_text = ("owner", "rationale", "expires_on")
    if any(not isinstance(waiver.get(key), str) or not waiver[key] for key in required_text):
        raise ValueError(f"quality waiver {waiver_id} lacks owner, rationale, or expires_on")
    try:
        expires_on = date.fromisoformat(waiver["expires_on"])
    except ValueError as error:
        raise ValueError(f"quality waiver {waiver_id} has invalid expires_on") from error
    if waiver.get("status") != "active" or expires_on < as_of:
        raise ValueError(f"quality waiver {waiver_id} is inactive or expired")
    if waiver.get("axis") != waived_axis:
        raise ValueError(f"quality waiver {waiver_id} does not authorize {waived_axis}")
    for key, value in (("platforms", platform), ("lanes", lane)):
        allowed = waiver.get(key)
        if not isinstance(allowed, list) or value not in allowed:
            raise ValueError(f"quality waiver {waiver_id} does not authorize {key[:-1]} {value}")
    claims = waiver.get("claims")
    if not isinstance(claims, list) or not claims or not set(selected_claims).issubset(claims):
        raise ValueError(f"quality waiver {waiver_id} does not authorize every selected claim")
    return waiver_id


def _string_array(payload: dict[str, object], key: str) -> list[str]:
    value = payload.get(key)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{key} must be a string array")
    return value


def validate_receipt_payload(payload: dict[str, object], *, as_of: date) -> None:
    """Revalidate a persisted receipt before any downstream aggregation."""
    if payload.get("schema_version") != 2:
        raise ValueError("quality receipt must use schema_version 2")
    platform = payload.get("platform")
    lane = payload.get("lane")
    if not isinstance(platform, str) or not platform:
        raise ValueError("platform must be a non-empty string")
    if not isinstance(lane, str) or not lane:
        raise ValueError("lane must be a non-empty string")
    product_status = payload.get("product_capability_status")
    test_system_status = payload.get("test_system_status")
    if product_status not in STATUSES or test_system_status not in STATUSES:
        raise ValueError("receipt contains an invalid product or test-system status")
    validate_status_pair(product_status, test_system_status)

    selected = _string_array(payload, "selected_claims")
    executed = _string_array(payload, "executed_claims")
    incomplete = _string_array(payload, "incomplete_selected_claims")
    issue_ids = _string_array(payload, "test_system_issue_ids")
    expected_incomplete = [claim for claim in selected if claim not in executed]
    if incomplete != expected_incomplete:
        raise ValueError("incomplete_selected_claims does not match selected/executed claims")
    if product_status == "PASSED" and (not selected or expected_incomplete):
        raise ValueError(
            "PASSED requires at least one selected claim and every selected claim "
            "to be present in executed claims"
        )
    if test_system_status == "PASSED" and issue_ids:
        raise ValueError("PASSED test-system status cannot carry test-system issue ids")
    if test_system_status == "FLAKY" and not issue_ids:
        raise ValueError("FLAKY test-system status requires an active registered issue id")
    if issue_ids:
        registry_path = Path(__file__).resolve().parent.parent / "config/quality-test-system-issues.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        quality_test_system_issues.validate_registry(registry, as_of)
        active_issues = {
            issue["id"]: issue
            for issue in registry.get("issues", [])
            if issue.get("status") == "active"
        }
        unknown_ids = sorted(set(issue_ids) - set(active_issues))
        if unknown_ids:
            raise ValueError(f"unknown or inactive test-system issue ids: {','.join(unknown_ids)}")
        if test_system_status == "FLAKY":
            non_flake_ids = sorted(
                issue_id
                for issue_id in issue_ids
                if active_issues[issue_id].get("kind") != "flake"
            )
            if non_flake_ids:
                raise ValueError(
                    "FLAKY test-system status requires active flake issue ids: "
                    + ",".join(non_flake_ids)
                )
    raw_waiver_id = payload.get("waiver_id")
    if raw_waiver_id is not None and not isinstance(raw_waiver_id, str):
        raise ValueError("waiver_id must be a string or null")
    validate_waiver(
        raw_waiver_id,
        product_status=product_status,
        test_system_status=test_system_status,
        platform=platform,
        lane=lane,
        selected_claims=selected,
        as_of=as_of,
    )


def main() -> None:
    args = parse_args()
    try:
        validate_status_pair(args.product_status, args.test_system_status)
        waiver_id = validate_waiver(
            args.waiver_id,
            product_status=args.product_status,
            test_system_status=args.test_system_status,
            platform=args.platform,
            lane=args.lane,
            selected_claims=args.selected_claim,
            as_of=date.today(),
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise SystemExit(str(error)) from error
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
        "waiver_id": waiver_id,
        "reason": args.reason,
        "scope_notice": "PASSED applies only to executed_claims. Selected claims absent from executed_claims failed or were blocked; this is not whole-product coverage.",
    }
    try:
        validate_receipt_payload(payload, as_of=date.today())
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise SystemExit(str(error)) from error
    with tempfile.NamedTemporaryFile("w", dir=output.parent, delete=False) as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, output)


if __name__ == "__main__":
    main()
