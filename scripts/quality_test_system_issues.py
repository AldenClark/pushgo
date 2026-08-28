#!/usr/bin/env python3
"""Validate owned test-system exceptions and classify exact diagnostic text."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from datetime import date, timedelta
from pathlib import Path
from typing import Any


KINDS = {"flake", "precondition", "blocker"}
STATUSES = {"active", "resolved"}


def parse_date(value: Any, label: str) -> date:
    if not isinstance(value, str):
        raise ValueError(f"{label} must be an ISO date")
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise ValueError(f"{label} must be an ISO date") from error


def nonempty(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be a non-empty string")
    return value


def validate_registry(registry: dict[str, Any], today: date) -> None:
    if registry.get("schema_version") != 1:
        raise ValueError("test-system issue registry schema_version must be 1")
    if registry.get("platform") not in {"apple", "android"}:
        raise ValueError("test-system issue registry platform is unsupported")
    issues = registry.get("issues")
    if not isinstance(issues, list):
        raise ValueError("test-system issue registry issues must be a list")
    seen: set[str] = set()
    for index, issue in enumerate(issues):
        prefix = f"issues[{index}]"
        issue_id = nonempty(issue.get("id"), f"{prefix}.id")
        if issue_id in seen:
            raise ValueError(f"duplicate test-system issue id: {issue_id}")
        seen.add(issue_id)
        if issue.get("kind") not in KINDS:
            raise ValueError(f"{prefix}.kind is unsupported")
        if issue.get("status") not in STATUSES:
            raise ValueError(f"{prefix}.status is unsupported")
        for key in ("owner", "rationale", "exit_criteria"):
            nonempty(issue.get(key), f"{prefix}.{key}")
        opened = parse_date(issue.get("opened_on"), f"{prefix}.opened_on")
        last_seen = parse_date(issue.get("last_seen_on"), f"{prefix}.last_seen_on")
        if last_seen < opened:
            raise ValueError(f"{prefix}.last_seen_on precedes opened_on")
        for key in ("scope", "signatures", "evidence"):
            values = issue.get(key)
            if not isinstance(values, list) or not values or any(not isinstance(v, str) or not v.strip() for v in values):
                raise ValueError(f"{prefix}.{key} must contain non-empty strings")
        for signature in issue["signatures"]:
            try:
                re.compile(signature)
            except re.error as error:
                raise ValueError(f"{prefix}.signatures contains invalid regex: {signature}") from error
        retries = issue.get("allowed_retries")
        if not isinstance(retries, int) or isinstance(retries, bool) or retries not in {0, 1}:
            raise ValueError(f"{prefix}.allowed_retries must be 0 or 1")
        if not isinstance(issue.get("quarantined"), bool):
            raise ValueError(f"{prefix}.quarantined must be boolean")
        if issue["quarantined"] and not issue.get("replacement_evidence"):
            raise ValueError(f"{prefix} quarantine requires replacement_evidence")
        expires_raw = issue.get("expires_on")
        if issue["kind"] == "flake" and issue["status"] == "active":
            expires = parse_date(expires_raw, f"{prefix}.expires_on")
            if expires > last_seen + timedelta(days=14):
                raise ValueError(f"active flake {issue_id} expiry exceeds 14 days from last_seen_on")
            if expires < last_seen or expires < today:
                raise ValueError(f"active flake {issue_id} expired on {expires.isoformat()}")
        elif expires_raw is not None:
            parse_date(expires_raw, f"{prefix}.expires_on")
        if issue["status"] == "resolved":
            parse_date(issue.get("resolved_on"), f"{prefix}.resolved_on")


def active_matches(registry: dict[str, Any], text: str, retryable_only: bool = False) -> list[dict[str, Any]]:
    matches = []
    for issue in registry["issues"]:
        if issue["status"] != "active":
            continue
        if retryable_only and issue["allowed_retries"] == 0:
            continue
        if any(re.search(signature, text) for signature in issue["signatures"]):
            matches.append(issue)
    return matches


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", default="config/quality-test-system-issues.json")
    parser.add_argument("--today")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--require-id")
    parser.add_argument("--match-file")
    parser.add_argument("--reject-if-matches", action="append", default=[])
    parser.add_argument("--retryable-only", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    registry = json.loads((repo / args.registry).read_text(encoding="utf-8"))
    current_date = date.fromisoformat(args.today) if args.today else date.today()
    validate_registry(registry, current_date)
    active = [issue for issue in registry["issues"] if issue["status"] == "active"]
    if args.require_id and not any(issue["id"] == args.require_id for issue in active):
        raise ValueError(f"required active test-system issue is absent: {args.require_id}")
    matches: list[dict[str, Any]] = []
    if args.match_file:
        text = Path(args.match_file).read_text(encoding="utf-8", errors="replace")
        if any(re.search(pattern, text) for pattern in args.reject_if_matches):
            return 1
        matches = active_matches(registry, text, args.retryable_only)
        if not matches:
            return 1
        print(f"classification_issue_ids={','.join(sorted(issue['id'] for issue in matches))}")
        print(f"allowed_retries={min(issue['allowed_retries'] for issue in matches)}")
    report = {
        "schema_version": 1,
        "platform": registry["platform"],
        "status": "READY",
        "active_issue_ids": sorted(issue["id"] for issue in active),
        "matched_issue_ids": sorted(issue["id"] for issue in matches),
        "scope_notice": "Only exact active signatures may affect test-system attribution; they never waive a product assertion or create product PASSED.",
    }
    if args.output:
        write_json(repo / args.output, report)
    if args.check:
        print(f"test_system_issue_registry={registry['platform']}:READY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
