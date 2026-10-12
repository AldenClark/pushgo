#!/usr/bin/env python3
"""Summarize real quality receipts without turning observation into product proof."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from scripts import quality_result
except ModuleNotFoundError:
    import quality_result


REQUIRED_FIELDS = {
    "recorded_at",
    "lane",
    "product_capability_status",
    "test_system_status",
}
VALID_STATUSES = quality_result.STATUSES


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", action="append", required=True, dest="inputs")
    parser.add_argument("--output", required=True)
    parser.add_argument("--required-lane", action="append", default=[])
    parser.add_argument("--minimum-calendar-days", type=int, default=14)
    parser.add_argument("--maximum-missing-days", type=int, default=0)
    parser.add_argument("--require-ready", action="store_true")
    return parser.parse_args()


def parse_recorded_at(value: Any, source: Path) -> datetime:
    if not isinstance(value, str):
        raise ValueError(f"{source}: recorded_at must be a string")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ValueError(f"{source}: invalid recorded_at: {value}") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{source}: recorded_at must include a timezone")
    return parsed.astimezone(timezone.utc)


def string_list(payload: dict[str, Any], key: str, source: Path) -> list[str]:
    value = payload.get(key, [])
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{source}: {key} must be a string array")
    return value


def receipt_files(inputs: list[str], output: Path) -> list[Path]:
    files: set[Path] = set()
    output = output.resolve()
    for raw in inputs:
        candidate = Path(raw)
        if not candidate.exists():
            raise ValueError(f"observation input does not exist: {candidate}")
        discovered = candidate.rglob("*.json") if candidate.is_dir() else [candidate]
        for item in discovered:
            if item.is_file() and item.resolve() != output:
                files.add(item.resolve())
    return sorted(files)


def load_receipts(inputs: list[str], output: Path) -> list[dict[str, Any]]:
    receipts: list[dict[str, Any]] = []
    for source in receipt_files(inputs, output):
        formal_candidate = source.name.endswith("-summary.json")
        try:
            payload = json.loads(source.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            if formal_candidate:
                raise ValueError(f"{source}: unreadable formal quality receipt") from error
            continue
        if not isinstance(payload, dict):
            if formal_candidate:
                raise ValueError(f"{source}: formal quality receipt must be an object")
            continue
        present_required_fields = REQUIRED_FIELDS.intersection(payload)
        if formal_candidate and present_required_fields and not REQUIRED_FIELDS.issubset(payload):
            missing = sorted(REQUIRED_FIELDS - set(payload))
            raise ValueError(f"{source}: incomplete quality receipt; missing {','.join(missing)}")
        if not REQUIRED_FIELDS.issubset(payload):
            if formal_candidate:
                raise ValueError(f"{source}: formal quality receipt is missing required fields")
            continue
        recorded_at = parse_recorded_at(payload["recorded_at"], source)
        try:
            quality_result.validate_receipt_payload(payload, as_of=recorded_at.date())
        except (OSError, json.JSONDecodeError, ValueError) as error:
            raise ValueError(f"{source}: invalid receipt contract: {error}") from error
        lane = payload["lane"]
        product_status = payload["product_capability_status"]
        test_system_status = payload["test_system_status"]
        selected = string_list(payload, "selected_claims", source)
        executed = string_list(payload, "executed_claims", source)
        incomplete = string_list(payload, "incomplete_selected_claims", source)
        issues = string_list(payload, "test_system_issue_ids", source)
        source_revision = payload.get("source_revision")
        source_dirty = payload.get("source_dirty")
        run_identity = payload.get("run_identity")
        if source_revision is not None and not isinstance(source_revision, str):
            raise ValueError(f"{source}: source_revision must be a string or null")
        if source_dirty is not None and not isinstance(source_dirty, bool):
            raise ValueError(f"{source}: source_dirty must be a boolean or null")
        if run_identity is not None and not isinstance(run_identity, str):
            raise ValueError(f"{source}: run_identity must be a string or null")
        receipts.append(
            {
                "source": str(source),
                "recorded_at": recorded_at,
                "lane": lane,
                "product_status": product_status,
                "test_system_status": test_system_status,
                "selected_claims": selected,
                "executed_claims": executed,
                "incomplete_claims": sorted(set(incomplete) | (set(selected) - set(executed))),
                "issue_ids": issues,
                "source_revision": source_revision,
                "source_dirty": source_dirty,
                "run_identity": run_identity,
            }
        )
    return sorted(receipts, key=lambda item: (item["recorded_at"], item["source"]))


def build_report(receipts: list[dict[str, Any]], required_lanes: list[str], minimum_days: int, maximum_missing: int) -> dict[str, Any]:
    if minimum_days < 1:
        raise ValueError("minimum-calendar-days must be positive")
    if maximum_missing < 0:
        raise ValueError("maximum-missing-days cannot be negative")

    blockers: list[str] = []
    observation_receipts = [
        item for item in receipts if not required_lanes or item["lane"] in required_lanes
    ]
    dates = sorted({item["recorded_at"].date() for item in observation_receipts})
    if dates:
        span_days = (dates[-1] - dates[0]).days + 1
        missing_between = max(
            ((right - left).days - 1 for left, right in zip(dates, dates[1:])),
            default=0,
        )
    else:
        span_days = 0
        missing_between = 0
        blockers.append("no_quality_receipts")

    if span_days < minimum_days:
        blockers.append(f"observation_span_days:{span_days}<{minimum_days}")
    if missing_between > maximum_missing:
        blockers.append(f"maximum_missing_days:{missing_between}>{maximum_missing}")

    observed_lanes = sorted({item["lane"] for item in receipts})
    missing_lanes = sorted(set(required_lanes) - set(observed_lanes))
    if missing_lanes:
        blockers.append("missing_required_lanes:" + ",".join(missing_lanes))

    missing_provenance = [
        item for item in observation_receipts
        if not item["source_revision"] or item["source_dirty"] is None or not item["run_identity"]
    ]
    dirty_receipts = [item for item in observation_receipts if item["source_dirty"] is True]
    run_identity_counts = Counter(
        item["run_identity"] for item in observation_receipts if item["run_identity"]
    )
    duplicate_run_identities = sorted(
        identity for identity, count in run_identity_counts.items() if count > 1
    )
    if missing_provenance:
        blockers.append(f"missing_receipt_provenance:{len(missing_provenance)}")
    if dirty_receipts:
        blockers.append(f"dirty_source_receipts:{len(dirty_receipts)}")
    if duplicate_run_identities:
        blockers.append("duplicate_run_identities:" + ",".join(duplicate_run_identities))

    latest_by_lane: dict[str, dict[str, Any]] = {}
    for item in receipts:
        latest_by_lane[item["lane"]] = item
    latest_required: dict[str, Any] = {}
    for lane in required_lanes:
        item = latest_by_lane.get(lane)
        if item is None:
            continue
        ready = (
            item["product_status"] == "PASSED"
            and item["test_system_status"] == "PASSED"
            and not item["incomplete_claims"]
            and not item["issue_ids"]
        )
        latest_required[lane] = {
            "recorded_at": item["recorded_at"].isoformat(),
            "product_capability_status": item["product_status"],
            "test_system_status": item["test_system_status"],
            "incomplete_selected_claims": item["incomplete_claims"],
            "test_system_issue_ids": item["issue_ids"],
            "ready_for_review": ready,
            "source": item["source"],
        }
        if not ready:
            blockers.append(f"latest_required_lane_not_clean:{lane}")

    lane_counts = Counter(item["lane"] for item in receipts)
    product_counts = Counter(item["product_status"] for item in receipts)
    test_system_counts = Counter(item["test_system_status"] for item in receipts)
    issue_counts = Counter(issue for item in receipts for issue in item["issue_ids"])
    incomplete_receipts = [
        {
            "recorded_at": item["recorded_at"].isoformat(),
            "lane": item["lane"],
            "claims": item["incomplete_claims"],
            "source": item["source"],
        }
        for item in receipts
        if item["incomplete_claims"]
    ]
    non_clean_required_receipts = [
        {
            "recorded_at": item["recorded_at"].isoformat(),
            "lane": item["lane"],
            "product_capability_status": item["product_status"],
            "test_system_status": item["test_system_status"],
            "test_system_issue_ids": item["issue_ids"],
            "source": item["source"],
        }
        for item in observation_receipts
        if item["product_status"] != "PASSED" or item["test_system_status"] != "PASSED"
    ]

    return {
        "schema_version": 1,
        "assessment_status": "READY_FOR_RECORDED_REVIEW" if not blockers else "INSUFFICIENT_EVIDENCE",
        "claim_limit": (
            "This report summarizes retained receipts. READY_FOR_RECORDED_REVIEW is not product PASSED, "
            "does not identify P0 semantics by itself, and does not replace independent review."
        ),
        "receipt_count": len(receipts),
        "observation_receipt_count": len(observation_receipts),
        "earliest_recorded_at": receipts[0]["recorded_at"].isoformat() if receipts else None,
        "latest_recorded_at": receipts[-1]["recorded_at"].isoformat() if receipts else None,
        "calendar_day_count": len(dates),
        "observation_span_days": span_days,
        "maximum_missing_days": missing_between,
        "required_lanes": required_lanes,
        "observed_lane_counts": dict(sorted(lane_counts.items())),
        "product_status_counts": dict(sorted(product_counts.items())),
        "test_system_status_counts": dict(sorted(test_system_counts.items())),
        "test_system_issue_counts": dict(sorted(issue_counts.items())),
        "missing_provenance_receipt_count": len(missing_provenance),
        "dirty_source_receipt_count": len(dirty_receipts),
        "duplicate_run_identities": duplicate_run_identities,
        "latest_required_lanes": latest_required,
        "non_clean_required_receipts": non_clean_required_receipts,
        "incomplete_receipts": incomplete_receipts,
        "blockers": blockers,
    }


def main() -> int:
    args = parse_args()
    output = Path(args.output)
    try:
        receipts = load_receipts(args.inputs, output)
        report = build_report(
            receipts,
            list(dict.fromkeys(args.required_lane)),
            args.minimum_calendar_days,
            args.maximum_missing_days,
        )
    except ValueError as error:
        print(f"status=BLOCKED\nreason={error}")
        return 2
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"observation_report={output.resolve()}")
    print(f"assessment_status={report['assessment_status']}")
    print(f"receipt_count={report['receipt_count']}")
    print(f"observation_span_days={report['observation_span_days']}")
    if args.require_ready and report["assessment_status"] != "READY_FOR_RECORDED_REVIEW":
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
