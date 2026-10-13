#!/usr/bin/env python3
"""Run the paired iOS/watchOS Simulator provisioning acceptance smoke."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any


class SmokeError(RuntimeError):
    pass


def run(argv: list[str], *, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(argv, check=False, capture_output=True, text=True, env=env)
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip()
        raise SmokeError(f"command failed ({completed.returncode}): {' '.join(argv)}\n{detail}")
    return completed.stdout.strip()


def device_udid(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("udid", "UDID", "deviceUDID", "device_udid", "id"):
            candidate = value.get(key)
            if isinstance(candidate, str):
                return candidate
    return None


def parse_pairs(payload: str) -> set[tuple[str, str]]:
    try:
        root = json.loads(payload)
    except json.JSONDecodeError as error:
        raise SmokeError(f"simctl list pairs did not return JSON: {error}") from error
    pairs: set[tuple[str, str]] = set()

    def visit(node: Any) -> None:
        if isinstance(node, dict):
            phone = next((device_udid(node[key]) for key in ("phone", "phoneUDID", "phone_udid", "phoneDevice") if key in node), None)
            watch = next((device_udid(node[key]) for key in ("watch", "watchUDID", "watch_udid", "watchDevice") if key in node), None)
            if phone and watch:
                pairs.add((phone.lower(), watch.lower()))
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(root)
    if not pairs:
        raise SmokeError("unsupported simctl pair JSON shape; expected phone/watch UDIDs")
    return pairs


def bundle_id(app: Path) -> str:
    try:
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise SmokeError(f"cannot read app Info.plist at {app}: {error}") from error
    value = info.get("CFBundleIdentifier")
    if not isinstance(value, str) or not value:
        raise SmokeError(f"missing CFBundleIdentifier in {app}/Info.plist")
    return value


def simctl(*args: str, env: dict[str, str] | None = None) -> str:
    return run(["xcrun", "simctl", *args], env=env)


def app_container(device: str, app_id: str) -> Path:
    return Path(simctl("get_app_container", device, app_id, "data"))


def launch(device: str, app_id: str, role_root: Path, request: dict[str, Any] | None) -> Path:
    state_dir = role_root / "Documents" / "watch-provisioning-smoke"
    state_dir.mkdir(parents=True, exist_ok=True)
    response = state_dir / "response.json"
    state = state_dir / "state.json"
    # Stop the previous writer before removing observations. Deleting first
    # lets an in-flight old-process enrichment recreate an accepted snapshot.
    try:
        simctl("terminate", device, app_id)
    except SmokeError as error:
        if "found nothing to terminate" not in str(error):
            raise
    response.unlink(missing_ok=True)
    # Require a new process observation after relaunch; an old state file may
    # already contain the expected generation/window before the app restarts.
    state.unlink(missing_ok=True)
    env = dict(os.environ)
    env.update({
        "SIMCTL_CHILD_PUSHGO_AUTOMATION_STORAGE_ROOT": f"sandbox-tmp:watch-provisioning-smoke/{role_root.name}",
        "SIMCTL_CHILD_PUSHGO_AUTOMATION_RESPONSE_PATH": str(response),
        "SIMCTL_CHILD_PUSHGO_AUTOMATION_STATE_PATH": str(state),
        "SIMCTL_CHILD_PUSHGO_AUTOMATION_EVENTS_PATH": str(state_dir / "events.jsonl"),
        "SIMCTL_CHILD_PUSHGO_AUTOMATION_TRACE_PATH": str(state_dir / "trace.jsonl"),
    })
    if request is not None:
        env["SIMCTL_CHILD_PUSHGO_AUTOMATION_REQUEST"] = json.dumps(request, separators=(",", ":"))
    else:
        env.pop("SIMCTL_CHILD_PUSHGO_AUTOMATION_REQUEST", None)
    simctl("launch", device, app_id, env=env)
    return state


def wait_json(path: Path, timeout: float, predicate) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_error = "file not written"
    while time.monotonic() < deadline:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if predicate(value):
                return value
            last_error = "content did not match acceptance predicate"
        except (OSError, json.JSONDecodeError) as error:
            last_error = str(error)
        time.sleep(0.1)
    raise SmokeError(f"timed out waiting for {path}: {last_error}")


def run_request(phone_id: str, phone_bundle: str, root: Path, name: str, args: dict[str, str], timeout: float) -> dict[str, Any]:
    request_id = str(uuid.uuid4())
    state_path = launch(phone_id, phone_bundle, root, {"id": request_id, "name": name, "args": args})
    response_path = state_path.parent / "response.json"
    response = wait_json(response_path, timeout, lambda item: item.get("id") == request_id)
    if response.get("ok") is not True:
        raise SmokeError(f"iOS automation command {name} failed: {response.get('error')}")
    return response


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phone-id", required=True, help="UDID of the paired iOS Simulator")
    parser.add_argument("--watch-id", required=True, help="UDID of the paired watchOS Simulator")
    parser.add_argument("--ios-app", type=Path, required=True, help="Built iOS .app")
    parser.add_argument("--watch-app", type=Path, required=True, help="Built watchOS .app")
    parser.add_argument("--results-dir", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--alert-window-minutes", type=int, choices=(5, 15, 30, 60), help="Provision and verify this Watch alert window")
    parser.add_argument("--updated-alert-window-minutes", type=int, choices=(5, 15, 30, 60), help="Provision a second different window and verify a new generation/digest")
    args = parser.parse_args()
    if args.updated_alert_window_minutes is not None and (args.alert_window_minutes is None or args.updated_alert_window_minutes == args.alert_window_minutes):
        parser.error("--updated-alert-window-minutes requires a different --alert-window-minutes")

    try:
        if not args.ios_app.is_dir() or not args.watch_app.is_dir():
            raise SmokeError("both built .app bundles must exist")
        pairs = parse_pairs(simctl("list", "pairs", "-j"))
        if (args.phone_id.lower(), args.watch_id.lower()) not in pairs:
            raise SmokeError("the supplied iOS and watchOS Simulator UDIDs are not a paired device pair")
        phone_bundle = bundle_id(args.ios_app)
        watch_bundle = bundle_id(args.watch_app)
        simctl("install", args.phone_id, str(args.ios_app))
        simctl("install", args.watch_id, str(args.watch_app))
        phone_root = app_container(args.phone_id, phone_bundle)
        watch_root = app_container(args.watch_id, watch_bundle)
        run_id = uuid.uuid4().hex
        phone_session_root = phone_root / "tmp" / "pushgo-watch-provision-smoke" / f"phone-{run_id}"
        watch_session_root = watch_root / "tmp" / "pushgo-watch-provision-smoke" / f"watch-{run_id}"
        phone_session_root.mkdir(parents=True, exist_ok=True)
        watch_session_root.mkdir(parents=True, exist_ok=True)

        watch_state_path = launch(args.watch_id, watch_bundle, watch_session_root, None)
        wait_json(watch_state_path, args.timeout, lambda item: item.get("platform") == "watchos")

        run_request(args.phone_id, phone_bundle, phone_session_root, "gateway.set_server", {
            "base_url": "https://pushgo.example.test",
            "token": "c" * 64,
        }, args.timeout)
        run_request(args.phone_id, phone_bundle, phone_session_root, "settings.set_decryption_key", {
            "key": "MDEyMzQ1Njc4OWFiY2RlZg==",
            "encoding": "base64",
        }, args.timeout)
        fixture = Path(__file__).resolve().parents[1] / "Tests/Fixtures/p2/seed-subscriptions.json"
        run_request(args.phone_id, phone_bundle, phone_session_root, "fixture.seed_subscriptions", {
            "path": str(fixture),
        }, args.timeout)
        windows = [args.alert_window_minutes]
        if args.updated_alert_window_minutes is not None:
            windows.append(args.updated_alert_window_minutes)
        window_checks = []
        previous_generation = None
        previous_digest = None
        expected_channels = ["p2", "p2-secondary"]
        for window in windows:
            request_args = {} if window is None else {"value": str(window)}
            acceptance = run_request(args.phone_id, phone_bundle, phone_session_root, "watch.provisioning_acceptance", request_args, args.timeout)
            phone_state = acceptance.get("state") or {}
            generation = phone_state.get("watch_provisioning_generation")
            digest = phone_state.get("watch_provisioning_digest")
            if not isinstance(generation, int) or generation <= 0 or not isinstance(digest, str) or not digest:
                raise SmokeError("iOS acceptance response omitted the published generation/digest")
            if phone_state.get("watch_provisioning_ack_generation") != generation or phone_state.get("watch_provisioning_ack_digest") != digest:
                raise SmokeError("iOS did not observe a matching Watch ACK")
            if previous_generation is not None and (generation <= previous_generation or digest == previous_digest):
                raise SmokeError("changed Watch alert window did not publish a new generation and content digest")

            # Ordinary process relaunch retains the same sandbox Store. The
            # enriched state reads the persisted Watch value, not phone input.
            watch_state_path = launch(args.watch_id, watch_bundle, watch_session_root, None)
            watch_state = wait_json(watch_state_path, args.timeout, lambda item:
                item.get("watch_provisioning_generation") == generation
                and item.get("watch_provisioning_digest") == digest
                and item.get("watch_provisioning_gateway_base_url") == "https://pushgo.example.test"
                and item.get("watch_provisioning_token_present") is True
                and item.get("watch_provisioning_channel_ids") == expected_channels
                and (window is None or item.get("watch_alert_window_minutes") == window)
            )
            if window is not None:
                window_checks.append({
                    "requested_minutes": window,
                    "persisted_watch_minutes_after_relaunch": watch_state["watch_alert_window_minutes"],
                    "generation": generation,
                    "content_digest": digest,
                    "ack_generation": phone_state["watch_provisioning_ack_generation"],
                    "ack_digest": phone_state["watch_provisioning_ack_digest"],
                })
            previous_generation, previous_digest = generation, digest
        args.results_dir.mkdir(parents=True, exist_ok=True)
        receipt = {
            "schema_version": 1,
            "result": "PASS",
            "scope": "paired_simulator_inline_application_context_standalone_provisioning",
            "phone_id": args.phone_id,
            "watch_id": args.watch_id,
            "generation": generation,
            "content_digest": digest,
            "ack_generation": phone_state["watch_provisioning_ack_generation"],
            "ack_digest": phone_state["watch_provisioning_ack_digest"],
            "persisted_watch_gateway_base_url": watch_state["watch_provisioning_gateway_base_url"],
            "persisted_watch_channel_ids": watch_state["watch_provisioning_channel_ids"],
            "transport": "WCSession.updateApplicationContext",
            "generated_at_epoch": int(time.time()),
        }
        if window_checks:
            receipt["alert_window_checks"] = window_checks
        (args.results_dir / "watch-provisioning-smoke.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(receipt, indent=2))
        return 0
    except (SmokeError, OSError) as error:
        args.results_dir.mkdir(parents=True, exist_ok=True)
        (args.results_dir / "watch-provisioning-smoke.json").write_text(json.dumps({
            "schema_version": 1,
            "result": "FAIL",
            "scope": "paired_simulator_inline_application_context_standalone_provisioning",
            "phone_id": args.phone_id,
            "watch_id": args.watch_id,
            "reason": str(error),
            "generated_at_epoch": int(time.time()),
        }, indent=2) + "\n", encoding="utf-8")
        print(f"WATCH_PROVISIONING_SMOKE: FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
