#!/usr/bin/env python3
"""Replay real historical tasks against the current quality-selection contract.

This tool validates deterministic facts only: task identity, changed paths, capability
selection, minimum lane, and required co-change path groups. The recorded semantic
review remains human/AI evidence and is deliberately not converted into a score.
"""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import os
import subprocess
import tarfile
import tempfile
from pathlib import Path
from typing import Any


SEMANTIC_REVIEW_FIELDS = (
    "reachable_entry",
    "user_action",
    "observable_outcomes",
    "error_or_recovery",
    "persistence_or_system_boundary",
    "negative_control",
    "weak_oracle_rejected",
    "evidence",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", default="config/quality-ai-task-history.json")
    parser.add_argument("--impact-manifest", default="config/quality-impact.json")
    parser.add_argument("--output", default="build/quality-results/apple-ai-history-audit.json")
    parser.add_argument("--blind-output")
    parser.add_argument("--materialize-task")
    parser.add_argument("--snapshot-output")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location("quality_impact_for_ai_history", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load quality impact module: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_git(repo: Path, *args: str) -> str:
    process = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode != 0:
        detail = process.stderr.strip() or process.stdout.strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {detail}")
    return process.stdout.strip()


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, path)


def require_nonempty_string(value: Any, label: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be a non-empty string")


def validate_corpus(corpus: dict[str, Any], manifest: dict[str, Any]) -> None:
    if corpus.get("schema_version") != 1:
        raise ValueError("AI history corpus schema_version must be 1")
    if corpus.get("platform") != manifest.get("platform"):
        raise ValueError("AI history corpus platform must match impact manifest")
    tasks = corpus.get("tasks")
    if not isinstance(tasks, list) or len(tasks) < 10:
        raise ValueError("AI history corpus must contain at least 10 real tasks")
    seen: set[str] = set()
    lanes = set(manifest["lane_order"])
    for index, task in enumerate(tasks):
        prefix = f"tasks[{index}]"
        for key in ("id", "commit", "task_prompt", "user_outcome", "credible_counterexample"):
            require_nonempty_string(task.get(key), f"{prefix}.{key}")
        if task["id"] in seen:
            raise ValueError(f"duplicate task id: {task['id']}")
        seen.add(task["id"])
        if task.get("minimum_lane") not in lanes:
            raise ValueError(f"{prefix}.minimum_lane is unsupported")
        capabilities = task.get("required_capabilities")
        if not isinstance(capabilities, list) or not capabilities or any(not isinstance(v, str) or not v for v in capabilities):
            raise ValueError(f"{prefix}.required_capabilities must be non-empty strings")
        groups = task.get("required_changed_path_groups")
        if not isinstance(groups, list) or not groups:
            raise ValueError(f"{prefix}.required_changed_path_groups must be non-empty")
        for group_index, group in enumerate(groups):
            require_nonempty_string(group.get("description"), f"{prefix}.groups[{group_index}].description")
            patterns = group.get("patterns")
            if not isinstance(patterns, list) or not patterns or any(not isinstance(v, str) or not v for v in patterns):
                raise ValueError(f"{prefix}.groups[{group_index}].patterns must be non-empty strings")
        review = task.get("semantic_review")
        if not isinstance(review, dict):
            raise ValueError(f"{prefix}.semantic_review must be an object")
        for key in SEMANTIC_REVIEW_FIELDS:
            value = review.get(key)
            if key in {"observable_outcomes", "evidence"}:
                if not isinstance(value, list) or not value or any(not isinstance(v, str) or not v.strip() for v in value):
                    raise ValueError(f"{prefix}.semantic_review.{key} must be non-empty strings")
            else:
                require_nonempty_string(value, f"{prefix}.semantic_review.{key}")


def changed_paths(repo: Path, commit: str) -> tuple[str, list[str], str]:
    full_commit = run_git(repo, "rev-parse", "--verify", f"{commit}^{{commit}}")
    parent = run_git(repo, "rev-parse", f"{full_commit}^")
    paths = run_git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", full_commit).splitlines()
    return full_commit, [path for path in paths if path], parent


def evaluate_corpus(
    repo: Path,
    corpus: dict[str, Any],
    manifest: dict[str, Any],
    quality_impact: Any,
) -> dict[str, Any]:
    validate_corpus(corpus, manifest)
    lane_rank = {lane: index for index, lane in enumerate(manifest["lane_order"])}
    results: list[dict[str, Any]] = []
    seen_commits: set[str] = set()
    for task in corpus["tasks"]:
        full_commit, paths, parent = changed_paths(repo, task["commit"])
        if full_commit in seen_commits:
            raise ValueError(f"duplicate historical commit: {full_commit}")
        seen_commits.add(full_commit)
        plan = quality_impact.build_plan(paths, manifest, f"historical-task:{task['id']}")
        failures: list[str] = []
        if plan["plan_status"] != "READY":
            failures.append(f"selector plan status is {plan['plan_status']}")
        if lane_rank[plan["recommended_lane"]] < lane_rank[task["minimum_lane"]]:
            failures.append(
                f"recommended lane {plan['recommended_lane']} is below {task['minimum_lane']}"
            )
        missing_capabilities = sorted(set(task["required_capabilities"]) - set(plan["impacted_capabilities"]))
        if missing_capabilities:
            failures.append(f"missing capabilities: {','.join(missing_capabilities)}")
        missing_groups: list[str] = []
        for group in task["required_changed_path_groups"]:
            if not any(
                fnmatch.fnmatchcase(path, pattern)
                for path in paths
                for pattern in group["patterns"]
            ):
                missing_groups.append(group["description"])
        if missing_groups:
            failures.append(f"missing co-change path groups: {','.join(missing_groups)}")
        results.append(
            {
                "id": task["id"],
                "commit": full_commit,
                "base_commit": parent,
                "changed_paths": paths,
                "selector_contract_status": "PASSED" if not failures else "FAILED",
                "selector_failures": failures,
                "recommended_lane": plan["recommended_lane"],
                "required_minimum_lane": task["minimum_lane"],
                "impacted_capabilities": plan["impacted_capabilities"],
                "required_capabilities": task["required_capabilities"],
                "semantic_review_status": "RECORDED_NOT_AUTOMATICALLY_VERIFIED",
                "semantic_review": task["semantic_review"],
            }
        )
    failures = [result["id"] for result in results if result["selector_contract_status"] == "FAILED"]
    return {
        "schema_version": 1,
        "platform": corpus["platform"],
        "status": "FAILED" if failures else "READY_FOR_RECORDED_SEMANTIC_REVIEW",
        "task_count": len(results),
        "failed_task_ids": failures,
        "tasks": results,
        "scope_notice": (
            "Selector replay and co-change checks are deterministic lower-bound evidence only. "
            "Recorded semantic reviews must still be challenged against the diff and product behavior; "
            "this report is not a product pass or an AI quality score."
        ),
    }


def blind_packets(repo: Path, corpus: dict[str, Any]) -> dict[str, Any]:
    packets = []
    for task in corpus["tasks"]:
        _, _, parent = changed_paths(repo, task["commit"])
        packets.append(
            {
                "id": task["id"],
                "base_commit": parent,
                "task_prompt": task["task_prompt"],
                "required_response": [
                    "user purpose and protected behavior",
                    "caller/state/data/platform impact trace",
                    "credible counterexample",
                    "minimum sufficient tests and product-level oracles",
                    "focused and minimum lane commands",
                    "BLOCKED/NOT RUN boundaries",
                ],
                "materialize_command": (
                    "python3 scripts/quality_ai_history.py "
                    f"--materialize-task {task['id']} --snapshot-output <new-directory>"
                ),
            }
        )
    return {
        "schema_version": 1,
        "platform": corpus["platform"],
        "packets": packets,
        "scope_notice": "Packets intentionally omit target commits and expected answers; materialize a history-free base snapshot before evaluation.",
    }


def materialize_history_free_snapshot(
    repo: Path,
    corpus: dict[str, Any],
    task_id: str,
    output: Path,
) -> None:
    task = next((item for item in corpus["tasks"] if item["id"] == task_id), None)
    if task is None:
        raise ValueError(f"unknown historical task id: {task_id}")
    if output.exists():
        raise ValueError(f"snapshot output must not already exist: {output}")
    _, _, parent = changed_paths(repo, task["commit"])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary_root:
        temporary = Path(temporary_root)
        archive = temporary / "snapshot.tar"
        export = temporary / "export"
        export.mkdir()
        run_git(repo, "archive", "--format=tar", f"--output={archive}", parent)
        with tarfile.open(archive, "r") as handle:
            handle.extractall(export, filter="data")
        os.replace(export, output)


def main() -> int:
    args = parse_args()
    if bool(args.materialize_task) != bool(args.snapshot_output):
        raise ValueError("--materialize-task and --snapshot-output must be provided together")
    repo = Path(__file__).resolve().parent.parent
    corpus_path = repo / args.corpus
    manifest_path = repo / args.impact_manifest
    corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
    quality_impact = load_module(repo / "scripts/quality_impact.py")
    manifest = quality_impact.load_manifest(manifest_path)
    report = evaluate_corpus(repo, corpus, manifest, quality_impact)
    output = repo / args.output
    write_json(output, report)
    if args.blind_output:
        write_json(repo / args.blind_output, blind_packets(repo, corpus))
    if args.materialize_task:
        snapshot_output = Path(args.snapshot_output)
        if not snapshot_output.is_absolute():
            snapshot_output = repo / snapshot_output
        materialize_history_free_snapshot(repo, corpus, args.materialize_task, snapshot_output)
        print(f"history_free_snapshot={snapshot_output}")
    print(f"ai_history_report={output}")
    print(f"status={report['status']}")
    print(f"task_count={report['task_count']}")
    if report["failed_task_ids"]:
        print(f"failed_task_ids={','.join(report['failed_task_ids'])}")
    return 1 if args.check and report["failed_task_ids"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
