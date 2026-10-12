#!/usr/bin/env python3
import argparse
import os
import tempfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", type=Path, required=True)
    parser.add_argument("--minimum-free-bytes", type=int, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.minimum_free_bytes < 0:
        raise SystemExit("minimum free bytes must be non-negative")

    args.path.mkdir(parents=True, exist_ok=True)
    stats = os.statvfs(args.path)
    free_bytes = stats.f_bavail * stats.f_frsize
    if free_bytes < args.minimum_free_bytes:
        print("status=BLOCKED")
        print(
            "reason=insufficient_free_disk:"
            f"available_bytes={free_bytes}:required_bytes={args.minimum_free_bytes}"
        )
        return 2

    try:
        with tempfile.NamedTemporaryFile(dir=args.path, prefix=".quality-write-probe-", delete=True) as probe:
            probe.write(b"pushgo-quality-preflight")
            probe.flush()
            os.fsync(probe.fileno())
    except OSError as error:
        print("status=BLOCKED")
        print(f"reason=quality_results_not_writable:{error.errno}")
        return 2

    print("disk_preflight=READY")
    print(f"disk_available_bytes={free_bytes}")
    print(f"disk_required_bytes={args.minimum_free_bytes}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
