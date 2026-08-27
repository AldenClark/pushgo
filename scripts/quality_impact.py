#!/usr/bin/env python3
"""Select the deterministic minimum quality lane for changed repository paths.

Path rules are a lower bound, not a substitute for caller/data/platform impact
analysis. Unknown product paths are blocked so a new capability cannot silently
fall outside the quality system.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import subprocess
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="config/quality-impact.json")
    parser.add_argument("--output", required=True)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--changed-file", action="append", default=[])
    parser.add_argument("--audit-product-tree", action="store_true")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def normalize_path(raw: str) -> str:
    value = raw.strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts:
        raise ValueError(f"unsupported repository path: {raw!r}")
    return str(path)


def unique(values: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(values))


def matches_any(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def git_lines(repo: Path, args: list[str]) -> list[str]:
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
    return [line for line in process.stdout.splitlines() if line.strip()]


def changed_files(args: argparse.Namespace, repo: Path) -> tuple[list[str], str]:
    if args.changed_file:
        return unique(normalize_path(path) for path in args.changed_file), "explicit"
    if args.audit_product_tree:
        files = git_lines(repo, ["ls-files"])
        return unique(normalize_path(path) for path in files), "tracked-product-tree-audit"
    if args.base:
        for revision in (args.base, args.head):
            git_lines(repo, ["rev-parse", "--verify", f"{revision}^{{commit}}"])
        files = git_lines(
            repo,
            ["diff", "--name-only", "--diff-filter=ACDMRTUXB", f"{args.base}...{args.head}", "--"],
        )
        return unique(normalize_path(path) for path in files), f"git:{args.base}...{args.head}"
    tracked = git_lines(repo, ["diff", "--name-only", "--diff-filter=ACDMRTUXB", "HEAD", "--"])
    untracked = git_lines(repo, ["ls-files", "--others", "--exclude-standard"])
    return unique(normalize_path(path) for path in [*tracked, *untracked]), "working-tree"


def load_manifest(path: Path) -> dict[str, Any]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1:
        raise ValueError("quality impact manifest schema_version must be 1")
    lane_order = manifest.get("lane_order")
    if not isinstance(lane_order, list) or not lane_order or lane_order[0] != "not-run":
        raise ValueError("lane_order must be a non-empty list beginning with not-run")
    seen: set[str] = set()
    for rule in manifest.get("rules", []):
        rule_id = rule.get("id")
        if not isinstance(rule_id, str) or not rule_id or rule_id in seen:
            raise ValueError(f"invalid or duplicate rule id: {rule_id!r}")
        seen.add(rule_id)
        if rule.get("lane") not in lane_order:
            raise ValueError(f"rule {rule_id} uses unsupported lane {rule.get('lane')!r}")
        for key in ("paths", "capabilities", "minimum_evidence"):
            if not isinstance(rule.get(key), list) or not rule[key]:
                raise ValueError(f"rule {rule_id} requires a non-empty {key} list")
        if "required_checks" in rule:
            checks = rule["required_checks"]
            if not isinstance(checks, list) or any(not isinstance(item, str) or not item for item in checks):
                raise ValueError(f"rule {rule_id} required_checks must be a list of non-empty strings")
    return manifest


def build_plan(files: list[str], manifest: dict[str, Any], source: str) -> dict[str, Any]:
    lane_order = manifest["lane_order"]
    lane_rank = {lane: index for index, lane in enumerate(lane_order)}
    rules = manifest["rules"]
    product_patterns = manifest["product_paths"]
    path_matches: dict[str, list[str]] = {}
    changed_product_paths: list[str] = []
    ignored_paths: list[str] = []
    unmapped_product_paths: list[str] = []
    matched_rules: dict[str, dict[str, Any]] = {}

    for path in files:
        matching = [rule for rule in rules if matches_any(path, rule["paths"])]
        path_matches[path] = [rule["id"] for rule in matching]
        for rule in matching:
            matched_rules[rule["id"]] = rule
        if matches_any(path, product_patterns):
            changed_product_paths.append(path)
            if not matching:
                unmapped_product_paths.append(path)
        elif not matching:
            ignored_paths.append(path)

    selected = list(matched_rules.values())
    recommended_lane = max(
        (rule["lane"] for rule in selected),
        key=lambda lane: lane_rank[lane],
        default="not-run",
    )
    plan_status = "BLOCKED" if unmapped_product_paths else ("NOT_RUN" if not selected else "READY")
    return {
        "schema_version": 1,
        "platform": manifest["platform"],
        "plan_status": plan_status,
        "change_source": source,
        "changed_files": files,
        "changed_product_paths": changed_product_paths,
        "path_matches": path_matches,
        "selected_rule_ids": sorted(matched_rules),
        "impacted_capabilities": sorted({item for rule in selected for item in rule["capabilities"]}),
        "minimum_evidence": sorted({item for rule in selected for item in rule["minimum_evidence"]}),
        "required_checks": sorted({item for rule in selected for item in rule.get("required_checks", [])}),
        "recommended_lane": recommended_lane,
        "known_evidence_gaps": sorted({item for rule in selected for item in rule.get("known_evidence_gaps", [])}),
        "escalation_reasons": sorted({item for rule in selected for item in rule.get("escalation_reasons", [])}),
        "unmapped_product_paths": unmapped_product_paths,
        "ignored_paths": ignored_paths,
        "manual_impact_review_required": bool(changed_product_paths),
        "manual_impact_questions": manifest["manual_impact_questions"] if changed_product_paths else [],
        "scope_notice": (
            "This plan is a deterministic lower bound. A human or AI must still trace callers, "
            "state/data owners, errors, configuration, generated artifacts, and platform consumers. "
            "A READY plan is not evidence that a product capability passed."
        ),
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, path)


def main() -> int:
    args = parse_args()
    repo = Path(__file__).resolve().parent.parent
    manifest_path = Path(args.manifest)
    if not manifest_path.is_absolute():
        manifest_path = repo / manifest_path
    manifest = load_manifest(manifest_path)
    files, source = changed_files(args, repo)
    plan = build_plan(files, manifest, source)
    output = Path(args.output)
    if not output.is_absolute():
        output = repo / output
    write_json(output, plan)
    print(f"impact_plan={output}")
    print(f"plan_status={plan['plan_status']}")
    print(f"recommended_lane={plan['recommended_lane']}")
    if plan["impacted_capabilities"]:
        print(f"impacted_capabilities={','.join(plan['impacted_capabilities'])}")
    if plan["known_evidence_gaps"]:
        print(f"known_evidence_gaps={'; '.join(plan['known_evidence_gaps'])}")
    if plan["unmapped_product_paths"]:
        print(f"unmapped_product_paths={','.join(plan['unmapped_product_paths'])}")
    return 2 if args.check and plan["plan_status"] == "BLOCKED" else 0


if __name__ == "__main__":
    raise SystemExit(main())
