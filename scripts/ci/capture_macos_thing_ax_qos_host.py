#!/usr/bin/env python3
"""Bounded host-side stacks for one App-owned macOS Thing AX query.

Only the exact Runner/App PIDs emitted by the selected XCTest method are
examined. A sampler failure is a diagnostic precondition, never a clean run.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


MARKER = re.compile(
    r"PUSHGO_AX_QOS_HOST_BEGIN run=(\d+) runner=(\d+) app=(\d+) control=(\S+)"
)
MAX_REPORT_BYTES = 12 * 1024 * 1024


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def command_name(pid: int) -> str:
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "comm="],
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
    )
    return Path(result.stdout.strip()).name


def verify_target(pid: int, executable: str) -> None:
    if pid <= 0:
        raise ValueError("nonpositive target PID")
    os.kill(pid, 0)
    observed = command_name(pid)
    if observed != executable:
        raise ValueError(f"target PID executable mismatch: expected {executable}, got {observed}")


def sample_start(report: Path) -> dt.datetime:
    for line in report.read_text(errors="replace").splitlines():
        if line.startswith("Date/Time:"):
            value = line.partition(":")[2].strip()
            return dt.datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f %z")
    raise ValueError(f"sample report has no Date/Time: {report.name}")


def query_interval(path: Path, runner: int, app: int) -> tuple[float, float]:
    fields = dict(
        line.split("=", 1) for line in path.read_text().splitlines() if "=" in line
    )
    if int(fields.get("runner_pid", "0")) != runner or int(fields.get("app_pid", "0")) != app:
        raise ValueError("query timing PID identity mismatch")
    start = float(fields["query_start_epoch"])
    end = float(fields["query_end_epoch"])
    if not (start > 0 and start <= end and end - start < 10):
        raise ValueError("invalid AX query interval")
    return start, end


def bounded_command(args: list[str], output: Path, timeout: int) -> None:
    with output.open("wb") as sink:
        result = subprocess.run(
            args, stdout=sink, stderr=subprocess.PIPE, timeout=timeout, check=False
        )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"{Path(args[2]).name} exited {result.returncode}: {detail}")
    if not output.is_file() or not (0 < output.stat().st_size <= MAX_REPORT_BYTES):
        raise ValueError(f"invalid or oversized {output.name}")


def capture(marker: re.Match[str], expected_run: str, output: Path) -> dict:
    run_id, runner_raw, app_raw, control_raw = marker.groups()
    if run_id != expected_run:
        raise ValueError("run marker does not match selected CI run")
    runner, app = int(runner_raw), int(app_raw)
    if runner == app:
        raise ValueError("Runner and App PIDs are identical")
    control = Path(control_raw)
    if (
        control.is_symlink()
        or control.parent.is_symlink()
        or not control.is_dir()
        or control.parent.name != "PushGoAXQoSHostSamples"
        or re.fullmatch(r"macos-thing-relations-[a-f0-9-]+", control.name) is None
        or control.stat().st_uid != os.getuid()
    ):
        raise ValueError("invalid Runner-owned control directory")
    summary = {
        "schema_version": 1,
        "run_id": run_id,
        "status": "BLOCKED",
        "runner_pid": runner,
        "app_pid": app,
        "control_directory": str(control),
        "sampled_roles": ["runner", "app"],
    }
    jobs: list[tuple[str, int, subprocess.Popen, Path]] = []
    try:
        verify_target(runner, "PushGo-macOSUITests-Runner")
        verify_target(app, "PushGo")
        for role, pid in (("runner", runner), ("app", app)):
            bounded_command(
                ["/usr/bin/sudo", "-n", "/usr/bin/vmmap", "-wide", str(pid)],
                output / f"{role}-vmmap.txt",
                timeout=12,
            )
        for role, pid in (("runner", runner), ("app", app)):
            report = output / f"{role}-sample.txt"
            process = subprocess.Popen(
                ["/usr/bin/sudo", "-n", "/usr/bin/sample", str(pid), "3", "1", "-file", str(report)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            jobs.append((role, pid, process, report))
        time.sleep(0.2)
        if any(process.poll() is not None for _, _, process, _ in jobs):
            raise RuntimeError("sample process exited before AX query")
        verify_target(runner, "PushGo-macOSUITests-Runner")
        verify_target(app, "PushGo")
        (control / "host-ready").write_text("ready\n")
        timing = control / "query-timing.txt"
        deadline = time.monotonic() + 15
        while not timing.is_file() and time.monotonic() < deadline:
            time.sleep(0.05)
        if not timing.is_file():
            raise TimeoutError("AX query timing receipt was not emitted")
        started, ended = query_interval(timing, runner, app)
        (output / "query-timing.txt").write_bytes(timing.read_bytes())
        for role, pid, process, report in jobs:
            _, stderr = process.communicate(timeout=10)
            if process.returncode != 0:
                raise RuntimeError(
                    f"{role} sample exited {process.returncode}: "
                    + stderr.decode("utf-8", errors="replace")[:500]
                )
            if not report.is_file() or not (0 < report.stat().st_size <= MAX_REPORT_BYTES):
                raise ValueError(f"invalid or oversized {role} sample")
            content = report.read_text(errors="replace")
            if f"(pid {pid})" not in content or "Call graph:" not in content:
                raise ValueError(f"{role} sample does not identify the selected PID and call graph")
            sample_epoch = sample_start(report).timestamp()
            if not (sample_epoch <= started <= ended <= sample_epoch + 3):
                raise ValueError(f"{role} sample did not bracket the exact AX query")
        summary.update({
            "status": "CAPTURED",
            "query_start_epoch": started,
            "query_end_epoch": ended,
            "reports": [
                "runner-vmmap.txt", "app-vmmap.txt", "runner-sample.txt", "app-sample.txt",
                "query-timing.txt",
            ],
        })
    except Exception as error:
        summary["reason"] = f"{type(error).__name__}: {error}"[:700]
        blocked = control / "host-blocked"
        if not blocked.exists():
            blocked.write_text(summary["reason"] + "\n")
    finally:
        for _, _, process, _ in jobs:
            if process.poll() is None:
                try:
                    process.communicate(timeout=7)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except PermissionError:
                        process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except PermissionError:
                            process.kill()
                        process.wait()
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native-log", type=Path, required=True)
    parser.add_argument("--done-marker", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    status_file = args.output / "host-sample-summary.json"
    offset = 0
    previous_tail = ""
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        if args.native_log.is_file():
            with args.native_log.open(errors="replace") as log:
                log.seek(offset)
                chunk = log.read()
                offset = log.tell()
            marker = MARKER.search(previous_tail + chunk)
            previous_tail = (previous_tail + chunk)[-1024:]
            if marker:
                try:
                    summary = capture(marker, args.run_id, args.output)
                except Exception as error:
                    summary = {
                        "schema_version": 1,
                        "status": "BLOCKED",
                        "reason": f"{type(error).__name__}: {error}"[:700],
                    }
                write_json(status_file, summary)
                print(f"host_ax_qos_sample_status={summary['status']}", flush=True)
                return 0 if summary["status"] == "CAPTURED" else 2
        if args.done_marker.is_file():
            write_json(status_file, {"schema_version": 1, "status": "NOT_REACHED"})
            print("host_ax_qos_sample_status=NOT_REACHED", flush=True)
            return 2
        time.sleep(0.1)
    write_json(status_file, {"schema_version": 1, "status": "BLOCKED", "reason": "marker timeout"})
    print("host_ax_qos_sample_status=BLOCKED", flush=True)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
