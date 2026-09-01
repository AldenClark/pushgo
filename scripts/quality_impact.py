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
import re
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


def git_text(repo: Path, args: list[str], *, allow_missing: bool = False) -> str | None:
    process = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode == 0:
        return process.stdout
    if allow_missing:
        return None
    detail = process.stderr.strip() or process.stdout.strip()
    raise RuntimeError(f"git {' '.join(args)} failed: {detail}")


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


UI_TEST_SUITES = {
    "Tests/PushGo-iOSUITests/PushGo_iOSUITests.swift": (
        "ios",
        "PushGo-iOSUITests",
    ),
    "Tests/PushGo-macOSUITests/PushGo_macOSUITests.swift": (
        "macos",
        "PushGo-macOSUITests",
    ),
    "Tests/PushGo-watchOSUITests/PushGo_watchOSUITests.swift": (
        "watchos",
        "PushGo-watchOSUITests",
    ),
}
SWIFT_XCTEST_CLASS_PATTERN = re.compile(
    r"^\s*(?:@[A-Za-z_][\w.]*(?:\([^\n]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|open|final)\s+)*"
    r"class\s+([A-Za-z_]\w*)\s*:\s*XCTestCase\b",
    re.MULTILINE,
)
SWIFT_TEST_METHOD_PATTERN = re.compile(
    r"^(?P<indent>\s*)"
    r"(?:(?:public|internal|private|fileprivate|open|final|static|class|nonisolated|override)\s+)*"
    r"func\s+(?P<name>test[A-Za-z0-9_]*)\s*\("
)
SWIFT_MEMBER_PATTERN = re.compile(
    r"^(?:(?:public|internal|private|fileprivate|open|final|static|class|nonisolated|override)\s+)*"
    r"(?:func|var|let|init|deinit|subscript)\b"
)
HUNK_PATTERN = re.compile(r"^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@")
SPECIAL_UI_TEST_PROFILES = {
    (
        "ios",
        "testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation",
    ): "accessibility",
    (
        "macos",
        "testDeniedNotificationSettingsCardRecoversAfterSystemEnable",
    ): "system",
    (
        "macos",
        "testSystemNotificationClickPersistsAccurateMessageAndSurvivesRelaunch",
    ): "system",
}


def swift_ui_test_class_scope(source: str, path: str) -> tuple[str, str] | None:
    suite = UI_TEST_SUITES.get(path)
    if not suite:
        return None
    matches = SWIFT_XCTEST_CLASS_PATTERN.findall(source)
    if len(matches) != 1:
        return None
    platform, target = suite
    return platform, f"{target}/{matches[0]}"


def swift_test_method_ranges(source: str) -> dict[str, tuple[int, int]] | None:
    lines = source.splitlines()
    methods: dict[str, tuple[int, int]] = {}
    for index, line in enumerate(lines):
        match = SWIFT_TEST_METHOD_PATTERN.match(line)
        if not match:
            continue
        name = match.group("name")
        if name in methods:
            return None
        indent = len(match.group("indent").replace("\t", "    "))
        end_line = len(lines)
        for candidate_index in range(index + 1, len(lines)):
            candidate = lines[candidate_index]
            stripped = candidate.strip()
            if not stripped:
                continue
            candidate_indent = len(candidate) - len(candidate.lstrip(" \t"))
            if candidate_indent < indent:
                end_line = candidate_index
                break
            if candidate_indent == indent and (
                stripped == "}" or SWIFT_MEMBER_PATTERN.match(stripped)
            ):
                end_line = candidate_index + (1 if stripped == "}" else 0)
                break
        methods[name] = (index + 1, end_line)
    return methods if methods else None


def changed_hunk_ranges(patch: str) -> tuple[list[tuple[int, int]], list[tuple[int, int]]] | None:
    old_ranges: list[tuple[int, int]] = []
    new_ranges: list[tuple[int, int]] = []
    for line in patch.splitlines():
        if not line.startswith("@@"):
            continue
        match = HUNK_PATTERN.match(line)
        if not match:
            return None
        old_start, old_count, new_start, new_count = (
            int(match.group(1)),
            int(match.group(2) or "1"),
            int(match.group(3)),
            int(match.group(4) or "1"),
        )
        if old_count:
            old_ranges.append((old_start, old_start + old_count - 1))
        if new_count:
            new_ranges.append((new_start, new_start + new_count - 1))
    return (old_ranges, new_ranges) if old_ranges or new_ranges else None


def methods_covering_changes(
    methods: dict[str, tuple[int, int]], changed_ranges: list[tuple[int, int]]
) -> tuple[set[str], bool]:
    selected: set[str] = set()
    has_unowned_change = False
    for changed_start, changed_end in changed_ranges:
        covering = {
            name
            for name, (method_start, method_end) in methods.items()
            if changed_start <= method_end and changed_end >= method_start
        }
        if len(covering) > 1:
            return set(), True
        if not covering:
            has_unowned_change = True
        selected.update(covering)
    return selected, has_unowned_change


def profiled_method_scopes(
    platform: str, class_scope: str, method_names: set[str]
) -> dict[str, list[str]]:
    profiles: dict[str, list[str]] = {}
    for name in sorted(method_names):
        profile = SPECIAL_UI_TEST_PROFILES.get((platform, name), "default")
        profiles.setdefault(profile, []).append(f"{class_scope}/{name}")
    return profiles


def resolve_swift_ui_test_change(
    path: str,
    old_source: str | None,
    new_source: str | None,
    patch: str | None,
) -> dict[str, Any]:
    suite = UI_TEST_SUITES[path]
    platform = suite[0]
    if new_source is None:
        return {
            "platform": platform,
            "selection": "blocked",
            "scopes": [],
            "blocker": f"changed UI test source was deleted: {path}",
        }
    new_class = swift_ui_test_class_scope(new_source, path)
    new_methods = swift_test_method_ranges(new_source)
    if not new_class or not new_methods:
        return {
            "platform": platform,
            "selection": "blocked",
            "scopes": [],
            "blocker": f"unable to resolve a runnable XCTestCase in changed UI test source: {path}",
        }
    class_scope = new_class[1]
    if old_source is None:
        profile_scopes = profiled_method_scopes(platform, class_scope, set(new_methods))
        return {
            "platform": platform,
            "selection": "changed-class",
            "scopes": sorted(scope for scopes in profile_scopes.values() for scope in scopes),
            "profile_scopes": profile_scopes,
            "expected_test_count": len(new_methods),
            "blocker": None,
        }
    old_class = swift_ui_test_class_scope(old_source, path)
    old_methods = swift_test_method_ranges(old_source)
    ranges = changed_hunk_ranges(patch or "")
    if not old_class or old_class != new_class or not old_methods or not ranges:
        return {
            "platform": platform,
            "selection": "blocked",
            "scopes": [],
            "blocker": f"unable to attribute changed UI test source safely: {path}",
        }

    old_selected, old_unowned = methods_covering_changes(old_methods, ranges[0])
    new_selected, new_unowned = methods_covering_changes(new_methods, ranges[1])
    removed_methods = old_selected - set(new_methods)
    if removed_methods:
        return {
            "platform": platform,
            "selection": "blocked",
            "scopes": [],
            "blocker": (
                f"changed UI test method was removed or renamed in {path}: "
                f"{','.join(sorted(removed_methods))}"
            ),
        }
    added_methods_only = (
        not old_selected
        and bool(new_selected)
        and not new_unowned
        and all(name not in old_methods for name in new_selected)
    )
    same_existing_methods = (
        bool(new_selected)
        and old_selected == new_selected
        and not old_unowned
        and not new_unowned
    )
    existing_plus_added_methods = (
        bool(old_selected)
        and old_selected < new_selected
        and not old_unowned
        and not new_unowned
        and all(name in new_methods for name in old_selected)
        and all(name not in old_methods for name in new_selected - old_selected)
    )
    one_sided_existing_method_change = (
        (
            bool(new_selected)
            and not old_selected
            and not new_unowned
            and all(name in old_methods for name in new_selected)
        )
        or (
            bool(old_selected)
            and not new_selected
            and not old_unowned
            and all(name in new_methods for name in old_selected)
        )
    )
    if (
        added_methods_only
        or same_existing_methods
        or existing_plus_added_methods
        or one_sided_existing_method_change
    ):
        selected_methods = new_selected or old_selected
        profile_scopes = profiled_method_scopes(platform, class_scope, selected_methods)
        return {
            "platform": platform,
            "selection": "exact-method",
            "scopes": [f"{class_scope}/{name}" for name in sorted(selected_methods)],
            "profile_scopes": profile_scopes,
            "expected_test_count": len(selected_methods),
            "blocker": None,
        }
    if (
        old_selected != new_selected
        and (old_selected or new_selected)
        and not (old_unowned or new_unowned)
    ):
        return {
            "platform": platform,
            "selection": "blocked",
            "scopes": [],
            "blocker": f"changed UI test methods could not be matched across the diff: {path}",
        }
    profile_scopes = profiled_method_scopes(platform, class_scope, set(new_methods))
    return {
        "platform": platform,
        "selection": "changed-class",
        "scopes": sorted(scope for scopes in profile_scopes.values() for scope in scopes),
        "profile_scopes": profile_scopes,
        "expected_test_count": len(new_methods),
        "blocker": None,
    }


def swift_ui_test_impacts(
    args: argparse.Namespace,
    repo: Path,
    files: list[str],
    source: str,
) -> dict[str, dict[str, Any]] | None:
    paths = [path for path in files if path in UI_TEST_SUITES]
    if source == "tracked-product-tree-audit":
        return None
    impacts: dict[str, dict[str, Any]] = {}
    merge_base: str | None = None
    if source.startswith("git:") and args.base:
        merge_base_lines = git_lines(repo, ["merge-base", args.base, args.head])
        merge_base = merge_base_lines[0] if merge_base_lines else args.base
    name_status: str | None = None
    if source == "working-tree":
        name_status = git_text(repo, ["diff", "--name-status", "-M", "HEAD", "--"])
    elif merge_base:
        name_status = git_text(
            repo,
            ["diff", "--name-status", "-M", f"{args.base}...{args.head}", "--"],
        )
    for line in (name_status or "").splitlines():
        fields = line.split("\t")
        if len(fields) != 3 or not fields[0].startswith("R"):
            continue
        old_path, new_path = map(normalize_path, fields[1:])
        if old_path not in UI_TEST_SUITES and new_path not in UI_TEST_SUITES:
            continue
        managed_path = old_path if old_path in UI_TEST_SUITES else new_path
        platform = UI_TEST_SUITES[managed_path][0]
        impacts[managed_path] = {
            "platform": platform,
            "selection": "blocked",
            "scopes": [],
            "blocker": (
                "managed UI test source was renamed and requires an explicit selector "
                f"mapping update: {old_path} -> {new_path}"
            ),
        }
    if not paths and not impacts:
        return None
    for path in paths:
        if path in impacts:
            continue
        current_path = repo / path
        new_source = current_path.read_text(encoding="utf-8") if current_path.is_file() else None
        old_source: str | None = None
        patch: str | None = None
        if source == "working-tree":
            old_source = git_text(repo, ["show", f"HEAD:{path}"], allow_missing=True)
            patch = git_text(repo, ["diff", "--unified=0", "HEAD", "--", path])
        elif merge_base:
            old_source = git_text(repo, ["show", f"{merge_base}:{path}"], allow_missing=True)
            new_source = git_text(repo, ["show", f"{args.head}:{path}"], allow_missing=True)
            patch = git_text(repo, ["diff", "--unified=0", f"{args.base}...{args.head}", "--", path])
        impacts[path] = resolve_swift_ui_test_change(path, old_source, new_source, patch)
    return impacts


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
        if "exclude_paths" in rule:
            exclusions = rule["exclude_paths"]
            if not isinstance(exclusions, list) or any(
                not isinstance(item, str) or not item for item in exclusions
            ):
                raise ValueError(f"rule {rule_id} exclude_paths must be a list of non-empty strings")
        if "required_checks" in rule:
            checks = rule["required_checks"]
            if not isinstance(checks, list) or any(not isinstance(item, str) or not item for item in checks):
                raise ValueError(f"rule {rule_id} required_checks must be a list of non-empty strings")
    return manifest


def build_plan(
    files: list[str],
    manifest: dict[str, Any],
    source: str,
    ui_test_impacts: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
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
        matching = [
            rule
            for rule in rules
            if matches_any(path, rule["paths"])
            and not matches_any(path, rule.get("exclude_paths", []))
        ]
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
    selected_lanes = {rule["lane"] for rule in selected}
    non_infrastructure_lanes = {
        rule["lane"]
        for rule in selected
        if rule["id"] not in {"quality-system", "performance-system"}
    }
    if "performance" in selected_lanes and non_infrastructure_lanes:
        # Performance is intentionally not a functional superset of PR/nightly.
        # Release executes both families, so a mixed product + performance-system
        # change must be promoted instead of dropping either evidence family.
        recommended_lane = "release"
    changed_ui_test_paths = sorted(
        {
            *[path for path in files if path in UI_TEST_SUITES],
            *(ui_test_impacts or {}).keys(),
        }
    )
    dynamic_selection_requested = ui_test_impacts is not None and bool(changed_ui_test_paths)
    dynamic_impacts = ui_test_impacts or {}
    selection_blockers = [
        impact["blocker"]
        for path in changed_ui_test_paths
        if (impact := dynamic_impacts.get(path)) and impact.get("blocker")
    ]
    if dynamic_selection_requested:
        for path in changed_ui_test_paths:
            if path not in dynamic_impacts:
                selection_blockers.append(f"missing changed UI test attribution: {path}")
    required_ui_test_scopes = {"ios": [], "macos": [], "watchos": []}
    required_ui_test_profile_scopes = {"ios": {}, "macos": {}, "watchos": {}}
    if dynamic_selection_requested and not selection_blockers:
        for path in changed_ui_test_paths:
            impact = dynamic_impacts[path]
            required_ui_test_scopes[impact["platform"]].extend(impact["scopes"])
            profile_scopes = impact.get("profile_scopes") or {"default": impact["scopes"]}
            for profile, scopes in profile_scopes.items():
                required_ui_test_profile_scopes[impact["platform"]].setdefault(
                    profile, []
                ).extend(scopes)
        required_ui_test_scopes = {
            platform: sorted(set(scopes))
            for platform, scopes in required_ui_test_scopes.items()
        }
        required_ui_test_profile_scopes = {
            platform: {
                profile: sorted(set(scopes))
                for profile, scopes in sorted(profiles.items())
            }
            for platform, profiles in required_ui_test_profile_scopes.items()
        }
    selections = {
        impact["selection"]
        for path in changed_ui_test_paths
        if (impact := dynamic_impacts.get(path)) and not impact.get("blocker")
    }
    plan_status = (
        "BLOCKED"
        if unmapped_product_paths or selection_blockers
        else ("NOT_RUN" if recommended_lane == "not-run" else "READY")
    )
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
        "ui_test_scope_selection": (
            next(iter(selections))
            if len(selections) == 1
            else "mixed"
            if selections
            else "blocked"
            if selection_blockers
            else "not-applicable"
        ),
        "ui_test_impacts": {
            path: dynamic_impacts.get(path, {}) for path in changed_ui_test_paths
        },
        "required_ui_test_scopes": required_ui_test_scopes,
        "required_ui_test_profile_scopes": required_ui_test_profile_scopes,
        "selection_blockers": selection_blockers,
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
    impacts = swift_ui_test_impacts(args, repo, files, source)
    plan = build_plan(files, manifest, source, impacts)
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
    if plan["selection_blockers"]:
        print(f"selection_blockers={'; '.join(plan['selection_blockers'])}")
    return 2 if args.check and plan["plan_status"] == "BLOCKED" else 0


if __name__ == "__main__":
    raise SystemExit(main())
