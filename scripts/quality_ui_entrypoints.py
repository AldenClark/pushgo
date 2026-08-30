#!/usr/bin/env python3
"""Report stable production UI contracts that need semantic test review.

This is a discovery aid, not a coverage metric or a product gate. A matching
identifier in product and test source proves only that a reference exists; it
does not prove that a reachable user action or its business result was tested.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Iterable


ENTRYPOINT_LITERAL = re.compile(
    r'["\']((?:action|screen|tab|toggle|button|row|banner)\.'
    r'[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?)["\']'
)
ENTRYPOINT_TOKEN = re.compile(
    r'(?<![A-Za-z0-9_.-])'
    r'((?:action|screen|tab|toggle|button|row|banner)\.'
    r'[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?)'
    r'(?![A-Za-z0-9_.-])'
)
PRODUCT_ENTRYPOINT_LITERAL = re.compile(
    r'(?:accessibilityIdentifier|[A-Za-z0-9]*[Tt]estTag)\s*(?:\(\s*|=\s*)'
    r'["\']((?:action|screen|tab|toggle|button|row|banner)\.[A-Za-z0-9_.-]+)["\']'
)
SOURCE_SUFFIXES = {".swift", ".kt", ".kts", ".sh"}
EXCLUDED_DIRECTORIES = {
    ".build",
    ".deriveddata-ui-tests",
    ".git",
    ".gradle",
    "build",
    "DerivedData",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True)
    parser.add_argument("--product-root", action="append", required=True)
    parser.add_argument("--test-root", action="append", required=True)
    parser.add_argument("--base-root", default=".")
    parser.add_argument("--output", required=True)
    parser.add_argument("--dispositions")
    return parser.parse_args()


def source_files(roots: Iterable[Path]) -> list[Path]:
    files: set[Path] = set()
    for root in roots:
        if root.is_file() and root.suffix in SOURCE_SUFFIXES:
            files.add(root.resolve())
            continue
        if not root.is_dir():
            raise ValueError(f"source root does not exist: {root}")
        for candidate in root.rglob("*"):
            if (
                candidate.is_file()
                and candidate.suffix in SOURCE_SUFFIXES
                and not EXCLUDED_DIRECTORIES.intersection(candidate.parts)
            ):
                files.add(candidate.resolve())
    return sorted(files)


def without_comments(source: str) -> str:
    """Remove // and /* */ comments while preserving strings and line numbers."""

    output: list[str] = []
    index = 0
    state = "code"
    quote = ""
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "line-comment":
            if current == "\n":
                output.append(current)
                state = "code"
            else:
                output.append(" ")
            index += 1
            continue
        if state == "block-comment":
            if current == "*" and following == "/":
                output.extend((" ", " "))
                state = "code"
                index += 2
            else:
                output.append("\n" if current == "\n" else " ")
                index += 1
            continue
        if state == "string":
            output.append(current)
            if current == "\\" and index + 1 < len(source):
                output.append(source[index + 1])
                index += 2
                continue
            if current == quote:
                state = "code"
            index += 1
            continue
        if current == "/" and following == "/":
            output.extend((" ", " "))
            state = "line-comment"
            index += 2
            continue
        if current == "/" and following == "*":
            output.extend((" ", " "))
            state = "block-comment"
            index += 2
            continue
        output.append(current)
        if current in {'"', "'"}:
            state = "string"
            quote = current
        index += 1
    return "".join(output)


def without_shell_comments(source: str) -> str:
    """Remove shell # comments while preserving quoted stable identifiers."""

    output: list[str] = []
    index = 0
    quote = ""
    while index < len(source):
        current = source[index]
        if quote:
            output.append(current)
            if current == "\\" and quote == '"' and index + 1 < len(source):
                output.append(source[index + 1])
                index += 2
                continue
            if current == quote:
                quote = ""
            index += 1
            continue
        if current in {'"', "'"}:
            quote = current
            output.append(current)
            index += 1
            continue
        if current == "#":
            while index < len(source) and source[index] != "\n":
                output.append(" ")
                index += 1
            continue
        output.append(current)
        index += 1
    return "".join(output)


def display_path(path: Path, base_root: Path) -> str:
    try:
        return path.resolve().relative_to(base_root.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def collect_literals(
    roots: Iterable[Path],
    base_root: Path,
    *,
    product_source: bool = False,
) -> dict[str, list[dict[str, object]]]:
    occurrences: dict[str, list[dict[str, object]]] = {}
    for path in source_files(roots):
        raw_source = path.read_text(encoding="utf-8")
        source = without_shell_comments(raw_source) if path.suffix == ".sh" else without_comments(raw_source)
        pattern = (
            PRODUCT_ENTRYPOINT_LITERAL
            if product_source
            else ENTRYPOINT_TOKEN if path.suffix == ".sh" else ENTRYPOINT_LITERAL
        )
        for match in pattern.finditer(source):
            identifier = match.group(1)
            location = {
                "path": display_path(path, base_root),
                "line": source.count("\n", 0, match.start()) + 1,
            }
            occurrences.setdefault(identifier, []).append(location)
    return occurrences


def report_entries(
    identifiers: Iterable[str],
    product: dict[str, list[dict[str, object]]],
    tests: dict[str, list[dict[str, object]]],
    semantic_status: str,
) -> list[dict[str, object]]:
    return [
        {
            "identifier": identifier,
            "product_locations": product.get(identifier, []),
            "test_locations": tests.get(identifier, []),
            "semantic_evidence_status": semantic_status,
        }
        for identifier in sorted(identifiers)
    ]


def build_report(
    platform: str,
    product_roots: Iterable[Path],
    test_roots: Iterable[Path],
    base_root: Path,
) -> dict[str, object]:
    product = collect_literals(product_roots, base_root, product_source=True)
    tests = collect_literals(test_roots, base_root)
    product_ids = set(product)
    test_ids = set(tests)
    referenced = product_ids & test_ids
    unreferenced = product_ids - test_ids
    test_only = test_ids - product_ids
    return {
        "schema_version": 1,
        "platform": platform,
        "review_status": (
            "REVIEW_REQUIRED" if unreferenced or test_only else "READY_FOR_SEMANTIC_REVIEW"
        ),
        "product_identifier_count": len(product_ids),
        "test_reference_identifier_count": len(test_ids),
        "referenced_product_identifiers": report_entries(
            referenced,
            product,
            tests,
            "REFERENCE_FOUND_SEMANTIC_ORACLE_NOT_PROVEN",
        ),
        "unreferenced_product_identifiers": report_entries(
            unreferenced,
            product,
            tests,
            "REQUIRES_REACHABILITY_VALUE_AND_ORACLE_REVIEW",
        ),
        "test_only_identifiers": report_entries(
            test_only,
            product,
            tests,
            "REQUIRES_DYNAMIC_OR_REMOVED_PRODUCT_OWNER_REVIEW",
        ),
        "scope_notice": (
            "This report discovers stable UI-contract literals attached to production "
            "accessibilityIdentifier/testTag calls only; routing aliases and Automation state "
            "strings are diagnostics, not UI entrypoints. Identifier overlap is not "
            "product coverage, absence is not automatically a defect, and counts are not a score. "
            "A human or AI must trace reachability, user purpose, state/data ownership, the business "
            "terminal, and the lowest sufficient evidence before adding, deferring, or deleting a test."
        ),
    }


def apply_dispositions(
    report: dict[str, object],
    dispositions: dict[str, dict[str, dict[str, str]]],
) -> dict[str, object]:
    reviewed: dict[str, list[dict[str, object]]] = {}
    unresolved: dict[str, list[dict[str, object]]] = {}
    stale: list[dict[str, str]] = []
    categories = ("unreferenced_product_identifiers", "test_only_identifiers")

    for category in categories:
        configured = dispositions.get(category, {})
        current = {item["identifier"]: item for item in report[category]}
        reviewed_items = []
        for identifier, item in current.items():
            review = configured.get(identifier)
            if review is None:
                continue
            if not review.get("disposition") or len(review.get("reason", "")) < 20:
                raise ValueError(f"incomplete UI-entrypoint disposition: {category}:{identifier}")
            reviewed_items.append({**item, "review": review})
        reviewed[category] = reviewed_items
        unresolved[category] = [
            item for identifier, item in current.items() if identifier not in configured
        ]
        stale.extend(
            {"category": category, "identifier": identifier}
            for identifier in configured
            if identifier not in current
        )

    report["reviewed_unreferenced_product_identifiers"] = reviewed[
        "unreferenced_product_identifiers"
    ]
    report["reviewed_test_only_identifiers"] = reviewed["test_only_identifiers"]
    report["unresolved_unreferenced_product_identifiers"] = unresolved[
        "unreferenced_product_identifiers"
    ]
    report["unresolved_test_only_identifiers"] = unresolved["test_only_identifiers"]
    report["stale_dispositions"] = stale
    report["review_status"] = (
        "REVIEW_REQUIRED"
        if unresolved["unreferenced_product_identifiers"]
        or unresolved["test_only_identifiers"]
        or stale
        else "READY_FOR_SEMANTIC_REVIEW"
    )
    return report


def load_dispositions(path: Path, platform: str) -> dict[str, dict[str, dict[str, str]]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1:
        raise ValueError("unsupported UI-entrypoint disposition schema")
    platform_payload = payload.get("platforms", {}).get(platform)
    if not isinstance(platform_payload, dict):
        raise ValueError(f"missing UI-entrypoint dispositions for platform: {platform}")
    return platform_payload


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, path)


def main() -> int:
    args = parse_args()
    base_root = Path(args.base_root).resolve()
    product_roots = [Path(value).resolve() for value in args.product_root]
    test_roots = [Path(value).resolve() for value in args.test_root]
    report = build_report(args.platform, product_roots, test_roots, base_root)
    if args.dispositions:
        report = apply_dispositions(
            report,
            load_dispositions(Path(args.dispositions).resolve(), args.platform),
        )
    output = Path(args.output).resolve()
    write_json(output, report)
    print(f"ui_entrypoint_report={output}")
    print(f"review_status={report['review_status']}")
    print(f"product_identifier_count={report['product_identifier_count']}")
    print(
        "unreferenced_product_identifier_count="
        f"{len(report['unreferenced_product_identifiers'])}"
    )
    print(f"test_only_identifier_count={len(report['test_only_identifiers'])}")
    if args.dispositions:
        print(
            "unresolved_unreferenced_product_identifier_count="
            f"{len(report['unresolved_unreferenced_product_identifiers'])}"
        )
        print(
            "unresolved_test_only_identifier_count="
            f"{len(report['unresolved_test_only_identifiers'])}"
        )
        print(f"stale_disposition_count={len(report['stale_dispositions'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
