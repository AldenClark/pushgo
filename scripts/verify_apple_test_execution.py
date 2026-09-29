#!/usr/bin/env python3
"""Reject Apple test runs whose native xcresult contains no executed tests."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import time


RESULT_READ_ATTEMPTS = 4
RESULT_READ_RETRY_SECONDS = 1


def executed_test_count(
    summary: dict[str, object], *, allow_expected_failures: bool = False
) -> int:
    values = [
        summary.get(name, 0)
        for name in ("passedTests", "failedTests", "expectedFailures")
    ]
    if any(isinstance(value, bool) or not isinstance(value, int) for value in values):
        raise ValueError("xcresult passedTests/failedTests/expectedFailures are not integers")
    passed, failed, expected_failures = values
    if failed > 0:
        raise ValueError("xcresult contains failed tests; it cannot establish executed evidence")
    if expected_failures > 0 and not allow_expected_failures:
        raise ValueError("xcresult contains expected failures outside an authorized sensitivity control")
    return passed + expected_failures


def test_count_matches_selection(count: int, expected: int | None) -> bool:
    return expected is None or count == expected


def runtime_warning_messages(summary: dict[str, object]) -> list[str]:
    warnings = summary.get("runtimeWarnings", [])
    if not isinstance(warnings, list):
        raise ValueError("xcresult runtimeWarnings is not a list")
    messages: list[str] = []
    for warning in warnings:
        if not isinstance(warning, dict) or not isinstance(warning.get("message"), str):
            raise ValueError("xcresult runtime warning has no message")
        messages.append(warning["message"])
    return messages


def legacy_test_warning_messages(result: dict[str, object]) -> list[str]:
    """Read warnings stored in the xcresult's action issue summaries.

    Xcode 26.4's summary view can omit a warning that is present in the
    underlying TestIssueSummary. Xcode 27 surfaces that same issue as a
    runtimeWarning. Both views must agree before a native run is clean.
    """
    actions = result.get("actions")
    if (not isinstance(actions, dict) or not isinstance(actions.get("_values"), list)
            or not actions["_values"]):
        raise ValueError("xcresult legacy object has no action issue records")
    messages: list[str] = []
    for action in actions["_values"]:
        if not isinstance(action, dict) or not isinstance(action.get("actionResult"), dict):
            raise ValueError("xcresult legacy action result is malformed")
        issues = action["actionResult"].get("issues")
        if not isinstance(issues, dict):
            raise ValueError("xcresult legacy action issues are malformed")
        warnings = issues.get("testWarningSummaries")
        if warnings is None:
            continue
        if not isinstance(warnings, dict) or not isinstance(warnings.get("_values"), list):
            raise ValueError("xcresult test warning summaries are malformed")
        for issue in warnings["_values"]:
            if not isinstance(issue, dict):
                raise ValueError("xcresult test warning issue is malformed")
            message = issue.get("message")
            if not isinstance(message, dict) or not isinstance(message.get("_value"), str):
                raise ValueError("xcresult test warning issue has no message")
            messages.append(message["_value"])
    return messages


def combined_warning_messages(summary: dict[str, object], legacy: dict[str, object]) -> list[str]:
    # Both API views can expose the same issue. Retain repeated occurrences
    # from distinct tests while avoiding double-counting the two views.
    return list((Counter(runtime_warning_messages(summary)) |
                 Counter(legacy_test_warning_messages(legacy))).elements())


def _read_native_json(result_bundle: Path, command: list[str]) -> dict[str, object]:
    """Read an xcresult only after its file-backed store has stabilized.

    Xcode can return from `test-without-building` before `xcresulttool summary`
    can reopen a concurrently imported attachment. This retries only the
    read-side receipt operation; it never retries a product test or accepts an
    unreadable final bundle.
    """
    last_error: Exception | None = None
    for attempt in range(RESULT_READ_ATTEMPTS):
        try:
            completed = subprocess.run(
                ["xcrun", "xcresulttool", *command, "--path", str(result_bundle), "--format", "json"],
                check=True,
                capture_output=True,
                text=True,
            )
            loaded = json.loads(completed.stdout)
            if not isinstance(loaded, dict):
                raise ValueError("xcresult summary is not an object")
            return loaded
        except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
            last_error = error
            if attempt + 1 < RESULT_READ_ATTEMPTS:
                time.sleep(RESULT_READ_RETRY_SECONDS)
    assert last_error is not None
    raise last_error


def read_native_summary(result_bundle: Path) -> dict[str, object]:
    return _read_native_json(result_bundle, ["get", "test-results", "summary"])


def read_native_legacy_result(result_bundle: Path) -> dict[str, object]:
    return _read_native_json(result_bundle, ["get", "object", "--legacy"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", required=True, type=Path)
    parser.add_argument("--allow-expected-failures", action="store_true")
    parser.add_argument("--expected-test-count", type=int)
    parser.add_argument("--reject-runtime-warnings", action="store_true")
    args = parser.parse_args()

    try:
        summary = read_native_summary(args.result_bundle)
        count = executed_test_count(
            summary,
            allow_expected_failures=args.allow_expected_failures,
        )
        warnings = runtime_warning_messages(summary)
        if args.reject_runtime_warnings:
            legacy = read_native_legacy_result(args.result_bundle)
            warnings = combined_warning_messages(summary, legacy)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print("status=FAILED_TEST_SYSTEM")
        print(f"reason=invalid_apple_test_result:{error}")
        return 1

    if count <= 0:
        print("status=FAILED_TEST_SYSTEM")
        print("reason=selected_apple_tests_executed_zero_tests")
        return 1
    if not test_count_matches_selection(count, args.expected_test_count):
        print("status=FAILED_TEST_SYSTEM")
        print(
            "reason=selected_apple_test_count_mismatch:"
            f"expected={args.expected_test_count}:executed={count}"
        )
        return 1
    if args.reject_runtime_warnings and warnings:
        print("status=FAILED_TEST_SYSTEM")
        print("reason=apple_test_result_contains_runtime_warnings")
        for warning in warnings:
            print(f"runtime_warning={warning}")
        return 1

    print("status=EXECUTED")
    print(f"executed_test_count={count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
