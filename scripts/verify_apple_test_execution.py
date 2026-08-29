#!/usr/bin/env python3
"""Reject Apple test runs whose native xcresult contains no executed tests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


def executed_test_count(summary: dict[str, object]) -> int:
    values = [summary.get(name, 0) for name in ("passedTests", "failedTests")]
    if any(isinstance(value, bool) or not isinstance(value, int) for value in values):
        raise ValueError("xcresult passedTests/failedTests are not integers")
    return sum(values)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", required=True, type=Path)
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
        count = executed_test_count(json.loads(completed.stdout))
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
