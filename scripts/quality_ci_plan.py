#!/usr/bin/env python3
"""Keep cumulative acceptance obligations separate from draft diagnostics.

Ready PRs always execute the cumulative plan. Draft synchronize events may
execute only the new patch, provided the previous tip is a verified ancestor.
No evidence is reused or promoted to final acceptance by this planner.
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


def execution_range(repo: Path, event: dict, base: str, head: str) -> tuple[str, str]:
    pr = event.get("pull_request", {})
    if not pr.get("draft"):
        return base, "cumulative-acceptance"
    previous = event.get("before", "")
    if event.get("action") == "synchronize" and previous and previous != "0" * 40:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", previous, head],
            cwd=repo, capture_output=True, check=False,
        )
        if result.returncode == 0:
            return previous, "draft-patch-diagnostic"
    # Open/reopen, force-push, missing history: retain all obligations.
    return base, "draft-cumulative-diagnostic"


def select_execution_lane(plan: dict, purpose: str) -> str:
    # Native-only test repair: run the resolved methods and their specialized
    # profiles, without repeating the fixed PR UI suite. Product/shared runner
    # rules are excluded and keep their conservative lane.
    safe_rules = {"quality-system", "ios-ui-test-source", "macos-ui-test-source", "watchos-ui-test-source"}
    if (purpose.startswith("draft-") and plan.get("platform") == "apple"
            and not plan.get("changed_product_paths")
            and set(plan.get("selected_rule_ids", [])).issubset(safe_rules)
            and any(plan.get("required_ui_test_scopes", {}).values())):
        return "changed-tests"
    return plan["recommended_lane"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    obligations = output.with_name(output.stem + "-obligations.json")
    receipt = output.with_name(output.stem + "-selection.json")
    event = json.loads(Path(args.event).read_text())
    selected_base, purpose = execution_range(repo, event, args.base, args.head)
    for base, target in ((args.base, obligations), (selected_base, output)):
        result = subprocess.run(
            ["python3", str(repo / "scripts/quality_impact.py"), "--base", base,
             "--head", args.head, "--output", str(target), "--check"], cwd=repo,
            check=False,
        )
        if result.returncode:
            return result.returncode
    execution = json.loads(output.read_text())
    execution["execution_purpose"] = purpose
    execution["execution_lane"] = select_execution_lane(execution, purpose)
    output.write_text(json.dumps(execution, indent=2) + "\n")
    receipt.write_text(json.dumps({
        "schema_version": 1,
        "head": args.head,
        "obligations_base": args.base,
        "execution_base": selected_base,
        "execution_purpose": purpose,
        "obligations_plan": str(obligations),
        "execution_plan": str(output),
        "acceptance_status": "NOT_RUN",
        "reused_evidence": [],
        "notice": "Planning is not execution. Draft diagnostics cannot close cumulative acceptance; ready_for_review reruns the cumulative plan.",
    }, indent=2) + "\n")
    print(f"execution_purpose={purpose}")
    print(f"cumulative_obligations={obligations}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
