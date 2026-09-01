#!/usr/bin/env python3
"""Reject Apple test runs whose native xcresult contains no executed tests."""

from __future__ import annotations

import argparse
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


def read_native_summary(result_bundle: Path) -> dict[str, object]:
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
                [
                    "xcrun",
                    "xcresulttool",
                    "get",
                    "test-results",
                    "summary",
                    "--path",
                    str(result_bundle),
                    "--format",
                    "json",
                ],
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
