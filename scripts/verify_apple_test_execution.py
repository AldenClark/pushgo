#!/usr/bin/env python3
"""Reject Apple test runs whose native xcresult contains no executed tests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


def executed_test_count(
    summary: dict[str, object], *, allow_expected_failures: bool = False
) -> int:
    values = [
        summary.get(name, 0)
        for name in ("passedTests", "failedTests", "expectedFailures")
    ]
    if any(isinstance(value, bool) or not isinstance(value, int) for value in values):
        raise ValueError("xcresult passedTests/failedTests/expectedFailures are not integers")
    if values[2] > 0 and not allow_expected_failures:
        raise ValueError("xcresult contains expected failures outside an authorized sensitivity control")
    return sum(values)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", required=True, type=Path)
    parser.add_argument("--allow-expected-failures", action="store_true")
    args = parser.parse_args()

    try:
        completed = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "summary",
                "--path",
                str(args.result_bundle),
                "--format",
                "json",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        count = executed_test_count(
            json.loads(completed.stdout),
            allow_expected_failures=args.allow_expected_failures,
        )
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print("status=FAILED_TEST_SYSTEM")
        print(f"reason=invalid_apple_test_result:{error}")
        return 1

    if count <= 0:
        print("status=FAILED_TEST_SYSTEM")
        print("reason=selected_apple_tests_executed_zero_tests")
        return 1

    print("status=EXECUTED")
    print(f"executed_test_count={count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
