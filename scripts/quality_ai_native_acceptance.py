#!/usr/bin/env python3
"""Validate evidence for an independent AI-native delivery task.

The historical-task replay proves only deterministic selection contracts.  This
checker validates the separate evidence bundle for a real, answer-hidden task:
the target diff contains product and quality changes, the blind packet does not
contain the target answer, the native receipt is bound to that target, and an
independent semantic review is recorded.  It deliberately does not execute an
AI or assign a product-quality score.  A bundle without later calibration stays
``READY_FOR_LONGITUDINAL_CALIBRATION`` rather than becoming a false pass.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any


SCHEMA_VERSION = 1
SHA256 = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_ORACLE_FIELDS = (
    "reachable_entry",
    "user_action",
    "observable_outcomes",
    "persistence_or_system_boundary",
    "negative_control",
)
FORBIDDEN_PACKET_KEYS = {
    "base_commit",
    "commit",
    "expected_lane",
    "minimum_lane",
    "required_capabilities",
    "required_changed_path_groups",
    "recorded_answer",
    "semantic_review",
    "selector_contract_status",
    "target_commit",
    "target_diff",
}
VERDICTS = {"SUPPORTED", "PARTIAL", "REJECTED"}
AXES = ("purpose", "oracle", "lane", "execution", "boundaries")


class AcceptanceContractError(ValueError):
    """A bundle cannot be safely interpreted as independent evidence."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AcceptanceContractError(f"{label} must be a non-empty string")
    return value


def require_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise AcceptanceContractError(f"{label} must be a boolean")
    return value


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AcceptanceContractError(f"{label} must be an object")
    return value


def require_strings(value: Any, label: str, *, nonempty: bool = True) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise AcceptanceContractError(f"{label} must be a string array")
    if nonempty and (not value or any(not item.strip() for item in value)):
        raise AcceptanceContractError(f"{label} must contain non-empty strings")
    return value


def safe_relative_path(value: Any, label: str) -> Path:
    raw = require_string(value, label)
    if "\\" in raw:
        raise AcceptanceContractError(f"{label} must use POSIX relative paths")
    parsed = PurePosixPath(raw)
    if parsed.is_absolute() or not parsed.parts or "." in parsed.parts or ".." in parsed.parts:
        raise AcceptanceContractError(f"{label} must stay inside the repository")
    return Path(*parsed.parts)


def parse_time(value: Any, label: str) -> datetime:
    raw = require_string(value, label)
    normalized = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise AcceptanceContractError(f"{label} must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise AcceptanceContractError(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AcceptanceContractError(f"{label} is not readable JSON") from error
    return require_object(payload, label)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", dir=path.parent, delete=False, encoding="utf-8"
    ) as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.replace(path)


def run_git(repo: Path, *arguments: str) -> str:
    process = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        text=True,
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.strip() or process.stdout.strip()
        raise AcceptanceContractError(f"git {' '.join(arguments)} failed: {detail}")
    return process.stdout.strip()


def resolve_commit(repo: Path, value: Any, label: str) -> str:
    raw = require_string(value, label)
    resolved = run_git(repo, "rev-parse", "--verify", f"{raw}^{{commit}}")
    if not re.fullmatch(r"[0-9a-f]{40}", resolved):
        raise AcceptanceContractError(f"{label} did not resolve to a full commit")
    return resolved


def changed_paths(repo: Path, base: str, target: str) -> dict[str, str]:
    ancestry = subprocess.run(
        ["git", "merge-base", "--is-ancestor", base, target],
        cwd=repo,
        capture_output=True,
        check=False,
    )
    if ancestry.returncode != 0:
        raise AcceptanceContractError("base_commit must be an ancestor of target_commit")
    raw = run_git(repo, "diff", "--name-status", "--find-renames", base, target)
    statuses: dict[str, str] = {}
    for line in raw.splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            raise AcceptanceContractError("git diff returned an invalid name-status row")
        status = fields[0]
        if status.startswith("R") and len(fields) >= 3:
            statuses[fields[1]] = status
            statuses[fields[2]] = status
        else:
            statuses[fields[1]] = status
    return statuses


def quality_path(path: str, platform: str) -> bool:
    prefixes = ("Tests/", "scripts/", "config/", "docs/", "design/")
    if platform == "android":
        prefixes += ("app/src/test/", "app/src/androidTest/", "macrobenchmark/", "benchmark/")
    return path.startswith(prefixes)


def reject_forbidden_packet_keys(value: Any, path: str = "packet") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in FORBIDDEN_PACKET_KEYS:
                raise AcceptanceContractError(f"blind packet leaks answer key {path}.{key}")
            reject_forbidden_packet_keys(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_forbidden_packet_keys(child, f"{path}[{index}]")


def validate_packet(repo: Path, bundle: dict[str, Any]) -> dict[str, Any]:
    packet_path = safe_relative_path(bundle.get("packet_path"), "packet_path")
    packet_file = repo / packet_path
    if not packet_file.is_file():
        raise AcceptanceContractError(f"packet_path does not exist: {packet_path}")
    content = packet_file.read_bytes()
    digest = require_string(bundle.get("packet_sha256"), "packet_sha256").lower()
    if not SHA256.fullmatch(digest):
        raise AcceptanceContractError("packet_sha256 must be a lowercase SHA-256 digest")
    if hashlib.sha256(content).hexdigest() != digest:
        raise AcceptanceContractError("packet_sha256 does not match packet bytes")
    packet = load_json(packet_file, "blind packet")
    reject_forbidden_packet_keys(packet)
    for key in ("task_prompt", "user_outcome", "credible_counterexample"):
        require_string(packet.get(key), f"blind packet.{key}")
    return packet


def validate_implementation(
    bundle: dict[str, Any],
    platform: str,
    statuses: dict[str, str],
) -> tuple[list[str], list[str]]:
    implementation = require_object(bundle.get("implementation"), "implementation")
    product_paths = require_strings(implementation.get("product_paths"), "implementation.product_paths")
    quality_paths = require_strings(implementation.get("quality_paths"), "implementation.quality_paths")
    overlap = sorted(set(product_paths) & set(quality_paths))
    if overlap:
        raise AcceptanceContractError("product_paths and quality_paths overlap: " + ",".join(overlap))
    for path in product_paths + quality_paths:
        safe_relative_path(path, "implementation path")
        if path not in statuses:
            raise AcceptanceContractError(f"implementation path is not in target diff: {path}")
        if statuses[path] == "D":
            raise AcceptanceContractError(f"implementation path was deleted in target diff: {path}")
    if any(quality_path(path, platform) for path in product_paths):
        raise AcceptanceContractError("product_paths must point to product code, not quality assets")
    if not all(quality_path(path, platform) for path in quality_paths):
        raise AcceptanceContractError("quality_paths must point to tests or quality contracts")
    require_string(implementation.get("user_purpose"), "implementation.user_purpose")
    oracle = require_object(implementation.get("oracle"), "implementation.oracle")
    for key in REQUIRED_ORACLE_FIELDS:
        value = oracle.get(key)
        if key == "observable_outcomes":
            require_strings(value, f"implementation.oracle.{key}")
        else:
            require_string(value, f"implementation.oracle.{key}")
    return product_paths, quality_paths


def validate_native_receipt(
    repo: Path,
    bundle: dict[str, Any],
    platform: str,
    target_commit: str,
) -> list[str]:
    native = require_object(bundle.get("native_execution"), "native_execution")
    receipt_path = safe_relative_path(native.get("receipt"), "native_execution.receipt")
    receipt_file = repo / receipt_path
    if not receipt_file.is_file():
        raise AcceptanceContractError(f"native receipt does not exist: {receipt_path}")
    receipt = load_json(receipt_file, "native receipt")
    recorded_at = parse_time(receipt.get("recorded_at"), "native receipt.recorded_at")
    sys.path.insert(0, str(repo))
    try:
        from scripts import quality_result
    except ModuleNotFoundError as error:
        raise AcceptanceContractError("cannot load repository quality_result contract") from error
    try:
        quality_result.validate_receipt_payload(receipt, as_of=recorded_at.date())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise AcceptanceContractError(f"native receipt contract failed: {error}") from error

    if receipt.get("platform") != platform:
        raise AcceptanceContractError("native receipt platform does not match bundle platform")
    resolved_receipt_revision = resolve_commit(repo, receipt.get("source_revision"), "native receipt.source_revision")
    if resolved_receipt_revision != target_commit:
        raise AcceptanceContractError("native receipt source_revision is not the target commit")
    if receipt.get("source_dirty") is not False:
        raise AcceptanceContractError("native receipt must have source_dirty=false")
    lane = require_string(native.get("lane"), "native_execution.lane")
    if receipt.get("lane") != lane:
        raise AcceptanceContractError("native_execution.lane does not match receipt lane")
    run_identity = require_string(native.get("run_identity"), "native_execution.run_identity")
    if receipt.get("run_identity") != run_identity:
        raise AcceptanceContractError("native_execution.run_identity does not match receipt")

    selected = receipt.get("selected_claims")
    executed = receipt.get("executed_claims")
    incomplete = receipt.get("incomplete_selected_claims")
    require_strings(selected, "native receipt.selected_claims")
    require_strings(executed, "native receipt.executed_claims", nonempty=False)
    require_strings(incomplete, "native receipt.incomplete_selected_claims", nonempty=False)
    findings: list[str] = []
    if selected != executed or incomplete:
        findings.append("native receipt selected claims were not all executed")
    if receipt.get("product_capability_status") != "PASSED":
        findings.append("native product status is " + str(receipt.get("product_capability_status")))
    if receipt.get("test_system_status") != "PASSED":
        findings.append("native test-system status is " + str(receipt.get("test_system_status")))
    if receipt.get("test_system_issue_ids"):
        findings.append("native receipt carries test-system issue ids")
    return findings


def validate_review(bundle: dict[str, Any], packet_digest: str) -> tuple[list[str], bool]:
    review = require_object(bundle.get("semantic_review"), "semantic_review")
    ai_actor = require_string(bundle.get("ai_actor_id"), "ai_actor_id")
    reviewer = require_string(review.get("reviewer_id"), "semantic_review.reviewer_id")
    if ai_actor == reviewer:
        raise AcceptanceContractError("AI actor and semantic reviewer must be different identities")
    if not require_bool(bundle.get("answer_hidden"), "answer_hidden"):
        raise AcceptanceContractError("answer_hidden must be true")
    if not require_bool(review.get("independent"), "semantic_review.independent"):
        raise AcceptanceContractError("semantic_review.independent must be true")
    if not require_bool(review.get("blind_before_target"), "semantic_review.blind_before_target"):
        raise AcceptanceContractError("semantic_review.blind_before_target must be true")
    if require_string(review.get("packet_sha256"), "semantic_review.packet_sha256") != packet_digest:
        raise AcceptanceContractError("semantic review is bound to a different blind packet")
    blind_completed = parse_time(review.get("blind_completed_at"), "semantic_review.blind_completed_at")
    target_revealed = parse_time(review.get("target_revealed_at"), "semantic_review.target_revealed_at")
    reviewed_at = parse_time(review.get("reviewed_at"), "semantic_review.reviewed_at")
    if target_revealed < blind_completed or reviewed_at < target_revealed:
        raise AcceptanceContractError("semantic review timestamps do not preserve blind-before-reveal order")
    verdict = require_string(review.get("verdict"), "semantic_review.verdict")
    if verdict not in VERDICTS:
        raise AcceptanceContractError("semantic_review.verdict is unsupported")
    findings: list[str] = []
    axis_values: dict[str, str] = {}
    for axis in AXES:
        axis_value = require_string(review.get(axis), f"semantic_review.{axis}")
        if axis_value not in VERDICTS:
            raise AcceptanceContractError(f"semantic_review.{axis} is unsupported")
        axis_values[axis] = axis_value
    require_string(review.get("notes"), "semantic_review.notes")
    if verdict == "SUPPORTED" and any(value != "SUPPORTED" for value in axis_values.values()):
        raise AcceptanceContractError("SUPPORTED semantic verdict requires every review axis to be SUPPORTED")
    if verdict != "SUPPORTED":
        findings.append("independent semantic review verdict is " + verdict)
    return findings, verdict == "SUPPORTED"


def validate_calibration(repo: Path, bundle: dict[str, Any], target_commit: str) -> list[str]:
    calibration = bundle.get("calibration")
    if calibration is None:
        return ["no later real-change calibration record"]
    if not isinstance(calibration, list) or not calibration:
        raise AcceptanceContractError("calibration must be a non-empty array when present")
    findings: list[str] = []
    for index, item in enumerate(calibration):
        entry = require_object(item, f"calibration[{index}]")
        task_id = require_string(entry.get("task_id"), f"calibration[{index}].task_id")
        base = resolve_commit(repo, entry.get("base_commit"), f"calibration[{index}].base_commit")
        if base != target_commit:
            raise AcceptanceContractError(
                f"calibration[{index}].base_commit must equal the accepted task target"
            )
        revision = resolve_commit(repo, entry.get("target_commit"), f"calibration[{index}].target_commit")
        if revision == target_commit:
            raise AcceptanceContractError(f"calibration[{index}] must be a later distinct commit")
        calibration_changes = changed_paths(repo, base, revision)
        selection_path = safe_relative_path(
            entry.get("selection_report"), f"calibration[{index}].selection_report"
        )
        selection = load_json(repo / selection_path, f"calibration[{index}] selection report")
        if selection.get("plan_status") != "READY":
            findings.append(f"calibration task {task_id} selection plan is not READY")
        change_source = selection.get("change_source")
        if not isinstance(change_source, str) or not change_source.startswith("git:"):
            findings.append(f"calibration task {task_id} selection is not commit-bound")
        selected_paths = selection.get("changed_files")
        if not isinstance(selected_paths, list) or not all(isinstance(path, str) for path in selected_paths):
            raise AcceptanceContractError(f"calibration[{index}].selection_report.changed_files must be a string array")
        if set(selected_paths) != set(calibration_changes):
            findings.append(f"calibration task {task_id} selection paths do not match its commit diff")
        if selection.get("selection_blockers") or selection.get("unmapped_product_paths"):
            findings.append(f"calibration task {task_id} selection has blockers or unmapped product paths")
        native_bundle = {
            "native_execution": {
                "receipt": entry.get("native_receipt"),
                "lane": entry.get("lane"),
                "run_identity": entry.get("run_identity"),
            }
        }
        findings.extend(validate_native_receipt(repo, native_bundle, bundle["platform"], revision))
        reviewer = require_string(entry.get("reviewer_id"), f"calibration[{index}].reviewer_id")
        if reviewer == require_string(bundle.get("ai_actor_id"), "ai_actor_id"):
            raise AcceptanceContractError(f"calibration[{index}] reviewer must differ from AI actor")
        parse_time(entry.get("reviewed_at"), f"calibration[{index}].reviewed_at")
        for key in ("selection_replayed", "native_executed", "user_purpose_verified", "oracle_verified"):
            if not require_bool(entry.get(key), f"calibration[{index}].{key}"):
                findings.append(f"calibration task {task_id} has {key}=false")
    return findings


def evaluate_bundle(repo: Path, bundle_path: Path) -> dict[str, Any]:
    bundle = load_json(bundle_path, "AI native acceptance bundle")
    if bundle.get("schema_version") != SCHEMA_VERSION:
        raise AcceptanceContractError("AI native acceptance bundle has unsupported schema_version")
    if bundle.get("objective") != "ai-native-delivery":
        raise AcceptanceContractError("objective must be ai-native-delivery")
    platform = require_string(bundle.get("platform"), "platform")
    if platform not in {"apple", "android"}:
        raise AcceptanceContractError("platform must be apple or android")
    task_id = require_string(bundle.get("task_id"), "task_id")
    packet = validate_packet(repo, bundle)
    if packet.get("id") != task_id:
        raise AcceptanceContractError("blind packet id does not match task_id")
    packet_digest = require_string(bundle.get("packet_sha256"), "packet_sha256").lower()
    base_commit = resolve_commit(repo, bundle.get("base_commit"), "base_commit")
    target_commit = resolve_commit(repo, bundle.get("target_commit"), "target_commit")
    if base_commit == target_commit:
        raise AcceptanceContractError("base_commit and target_commit must differ")
    statuses = changed_paths(repo, base_commit, target_commit)
    product_paths, quality_paths = validate_implementation(bundle, platform, statuses)
    native_findings = validate_native_receipt(repo, bundle, platform, target_commit)
    review_findings, review_supported = validate_review(bundle, packet_digest)
    calibration_findings = validate_calibration(repo, bundle, target_commit) if review_supported else [
        "calibration cannot be accepted before an independent semantic review is supported"
    ]
    findings = native_findings + review_findings + calibration_findings
    if native_findings or not review_supported:
        status = "PARTIAL"
    elif calibration_findings:
        status = "READY_FOR_LONGITUDINAL_CALIBRATION"
    else:
        status = "SUPPORTED"
    return {
        "schema_version": SCHEMA_VERSION,
        "assessment_status": status,
        "objective": "ai-native-delivery",
        "platform": platform,
        "task_id": task_id,
        "base_commit": base_commit,
        "target_commit": target_commit,
        "changed_path_count": len(statuses),
        "product_paths": product_paths,
        "quality_paths": quality_paths,
        "evidence": {
            "answer_hidden_packet": True,
            "implementation_diff": True,
            "native_execution": not native_findings,
            "independent_semantic_review": review_supported,
            "longitudinal_calibration": not calibration_findings,
        },
        "findings": findings,
        "scope_notice": (
            "This is an independent AI-delivery evidence assessment, not an App product pass. "
            "It does not execute AI, replace native product verification, or infer physical/provider coverage."
        ),
        "packet_summary": {
            "task_prompt": packet["task_prompt"],
            "user_outcome": packet["user_outcome"],
            "credible_counterexample": packet["credible_counterexample"],
        },
    }


def main() -> int:
    args = parse_args()
    repo = Path(__file__).resolve().parent.parent
    bundle_path = safe_relative_path(args.bundle, "--bundle")
    try:
        report = evaluate_bundle(repo, repo / bundle_path)
    except AcceptanceContractError as error:
        report = {
            "schema_version": SCHEMA_VERSION,
            "assessment_status": "FAILED",
            "objective": "ai-native-delivery",
            "error": str(error),
            "scope_notice": (
                "The bundle was rejected as untrustworthy evidence; this is not a product result."
            ),
        }
    output = Path(args.output)
    if not output.is_absolute():
        output = repo / output
    write_json(output, report)
    print(f"ai_native_acceptance_report={output}")
    print(f"assessment_status={report['assessment_status']}")
    if report.get("findings"):
        print("findings=" + " | ".join(report["findings"]))
    if args.check and report["assessment_status"] != "SUPPORTED":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
