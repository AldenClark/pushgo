#!/usr/bin/env python3
"""Persist purpose-level iOS Simulator performance evidence from an xcresult.

The XCTest pass itself proves the user flow, but its metrics otherwise remain
buried in the result bundle.  This extractor requires both the five measured
metrics and the test-authored "accurate content" samples before writing a
small, reviewable receipt.  It deliberately labels every value Simulator-only.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


TEST_IDENTIFIER = "PushGo_iOSUITests/testPreparedLargeMessageStoreColdLaunchReachesAccurateContent()"
ACCURATE_CONTENT_PREFIX = "simulator_launch_to_accurate_content_seconds="
REQUIRED_METRICS = {
    "Clock Monotonic Time": "clock_monotonic_seconds",
    "Duration (ApplicationFirstFramePresentationResponsive)": "first_frame_responsive_seconds",
    "CPU Time (pushgo)": "cpu_time_seconds",
    "Memory Peak Physical (pushgo)": "peak_physical_memory_kb",
}


def xcresult_json(bundle: Path, *arguments: str) -> Any:
    process = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", *arguments, "--path", str(bundle)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise ValueError(process.stderr.strip() or "xcresulttool failed")
    try:
        return json.loads(process.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("xcresulttool did not return JSON") from error


def activities(nodes: Iterable[dict[str, Any]]) -> Iterable[dict[str, Any]]:
    for node in nodes:
        yield node
        children = node.get("childActivities", [])
        if isinstance(children, list):
            yield from activities(child for child in children if isinstance(child, dict))


def samples(values: Any, label: str) -> list[float]:
    if not isinstance(values, list) or len(values) != 5:
        raise ValueError(f"{label} must contain exactly five samples")
    parsed = [float(value) for value in values]
    if any(value <= 0 for value in parsed):
        raise ValueError(f"{label} must contain positive samples")
    return parsed


def summarize(values: list[float]) -> dict[str, Any]:
    return {
        "samples": values,
        "median": statistics.median(values),
        "max": max(values),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--max-accurate-content-seconds", type=float, default=8.0)
    parser.add_argument("--max-clock-seconds", type=float, default=8.0)
    args = parser.parse_args()

    if not args.result_bundle.is_dir() or not (args.result_bundle / "Info.plist").is_file():
        raise SystemExit("result bundle is incomplete or missing")
    if args.max_accurate_content_seconds <= 0 or args.max_clock_seconds <= 0:
        raise SystemExit("performance ceilings must be positive")

    raw_metrics = xcresult_json(args.result_bundle, "metrics", "--test-id", TEST_IDENTIFIER)
    if not isinstance(raw_metrics, list) or len(raw_metrics) != 1:
        raise SystemExit("expected one performance test metric payload")
    test_runs = raw_metrics[0].get("testRuns", [])
    if not isinstance(test_runs, list) or len(test_runs) != 1:
        raise SystemExit("expected one performance test run")
    run = test_runs[0]
    raw_by_name = {
        item.get("displayName"): item.get("measurements")
        for item in run.get("metrics", [])
        if isinstance(item, dict)
    }
    metric_summary = {
        output_name: summarize(samples(raw_by_name.get(display_name), display_name))
        for display_name, output_name in REQUIRED_METRICS.items()
    }

    raw_activities = xcresult_json(
        args.result_bundle,
        "activities",
        "--test-id",
        "test://com.apple.xcode/pushgo/PushGo-iOSUITests/PushGo_iOSUITests/testPreparedLargeMessageStoreColdLaunchReachesAccurateContent",
    )
    test_activity_runs = raw_activities.get("testRuns", []) if isinstance(raw_activities, dict) else []
    if not isinstance(test_activity_runs, list) or len(test_activity_runs) != 1:
        raise SystemExit("expected one performance test activity run")
    titles = [
        node.get("title", "")
        for node in activities(test_activity_runs[0].get("activities", []))
        if isinstance(node.get("title"), str)
        and node["title"].startswith(ACCURATE_CONTENT_PREFIX)
    ]
    if len(titles) != 1:
        raise SystemExit("expected one accurate-content activity summary")
    match = re.search(r"=\[([^]]+)\]", titles[0])
    if not match:
        raise SystemExit("accurate-content activity samples are missing")
    all_accurate_samples = [float(value.strip()) for value in match.group(1).split(",")]
    if len(all_accurate_samples) not in {5, 6}:
        raise SystemExit("accurate-content activity must contain five measured samples plus optional warm-up")
    accurate_summary = summarize(samples(all_accurate_samples[-5:], "accurate-content"))
    if accurate_summary["max"] > args.max_accurate_content_seconds:
        raise SystemExit("accurate-content sample exceeded the Simulator gross-regression ceiling")
    if metric_summary["clock_monotonic_seconds"]["max"] > args.max_clock_seconds:
        raise SystemExit("clock sample exceeded the Simulator gross-regression ceiling")

    device = run.get("device", {})
    receipt = {
        "schema_version": 1,
        "status": "PASSED",
        "scope": "iOS Simulator Debug App-owned 1,000-message cold launch to accurate visible content and matching detail",
        "result_bundle": str(args.result_bundle),
        "test_identifier": TEST_IDENTIFIER,
        "device": device,
        "simulator_only": True,
        "physical_release_baseline": "NOT_RUN",
        "ceilings": {
            "accurate_content_seconds": args.max_accurate_content_seconds,
            "clock_seconds": args.max_clock_seconds,
        },
        "accurate_content_seconds": accurate_summary,
        "metrics": metric_summary,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"performance_evidence={args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"performance_evidence_error={error}", file=sys.stderr)
        raise SystemExit(2)
