#!/usr/bin/env python3
"""Bounded release smoke using the existing SwiftPM/XCTest runners."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from contextlib import nullcontext

ROOT = Path(__file__).resolve().parents[1]


def validate_release_version(expected, versions):
    if versions != {expected}:
        raise ValueError("release smoke manifest/version waiver does not match product version")
    if os.environ.get("GITHUB_REF_TYPE") == "tag":
        tag = os.environ.get("GITHUB_REF_NAME", "")
        if not re.fullmatch(r"v" + re.escape(expected) + r"(-beta\.[1-9][0-9]*)?", tag):
            raise ValueError("smoke release version does not match selected tag")


def current_product_versions():
    project = json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(ROOT / "pushgo.xcodeproj/project.pbxproj")],
        text=True,
    ))["objects"]
    targets = [
        target for target in project.values()
        if target.get("isa") == "PBXNativeTarget"
        and target.get("name") in {"PushGo-iOS", "PushGo-macOS", "PushGo-watchOS"}
    ]
    if len(targets) != 3:
        raise ValueError("primary product version owners are missing or ambiguous")
    return {
        project[configuration]["buildSettings"].get("MARKETING_VERSION")
        for target in targets
        for configuration in project[target["buildConfigurationList"]]["buildConfigurations"]
    }


def active_governance_waiver_records(manifest=None, versions=None):
    """Return manifest waivers only for the checked-out product and selected tag."""
    manifest = manifest or json.loads((ROOT / "config/release-smoke.json").read_text())
    version = manifest["release_version"]
    requested_version = os.environ.get("PUSHGO_RELEASE_SMOKE_VERSION")
    if requested_version and requested_version != version:
        return {}
    validate_release_version(version, versions if versions is not None else current_product_versions())
    waivers = manifest.get("governance_waivers", [])
    return {
        waiver["id"]: waiver
        for waiver in waivers
        if isinstance(waiver, dict)
        and waiver.get("status") == "WAIVED"
        and waiver.get("release_version") == version
        and waiver.get("id")
        and waiver.get("scope")
    }


def active_governance_waivers(manifest=None, versions=None):
    return set(active_governance_waiver_records(manifest, versions))


def validate_profile(profile):
    if "gateway_repository" in profile or "gateway_revision" in profile:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", profile.get("gateway_repository", "")) or not re.fullmatch(r"[0-9a-f]{40}", profile.get("gateway_revision", "")):
            raise ValueError("paired Gateway must name a repository and immutable full revision")
    tests = profile.get("tests", [])
    if tests:
        if len(tests) != len(set(tests)):
            raise ValueError("duplicate smoke selector")
        source = (ROOT / profile["source"]).read_text()
        for test in tests:
            if not re.search(r"\bfunc\s+" + re.escape(test.split("/")[-1]) + r"\s*\(", source):
                raise ValueError(f"smoke method missing: {test}")
    else:
        suites = profile.get("suites", [])
        if not suites or len(suites) != len(set(suites)):
            raise ValueError("empty or duplicate core selection")
        for suite in suites:
            if not (ROOT / "Tests/PushGoAppleCoreTests" / f"{suite}.swift").is_file():
                raise ValueError(f"core smoke suite missing: {suite}")


def verify_core_events(path, suites):
    records = [json.loads(line) for line in path.read_text().splitlines()]
    if not records or any(r.get("version") != 0 for r in records):
        raise ValueError("missing or unsupported Swift Testing event stream")
    tests = {r["payload"]["id"]: r["payload"] for r in records if r["kind"] == "test"}
    events = [r["payload"] for r in records if r["kind"] == "event"]
    if any(e["kind"] in {"testSkipped", "issueRecorded"} for e in events):
        raise ValueError("core smoke has skips or issues")
    if sum(e["kind"] == "runEnded" for e in events) != 1:
        raise ValueError("incomplete Swift Testing run")
    started = [e["testID"] for e in events if e["kind"] == "testStarted"]
    ended = [e["testID"] for e in events if e["kind"] == "testEnded"]
    if not started or sorted(started) != sorted(ended) or set(started) != set(tests):
        raise ValueError("native test discovery/execution mismatch")
    actual_suites = {t["name"] for t in tests.values() if t["kind"] == "suite"}
    if actual_suites != set(suites):
        raise ValueError("core suite selection mismatch")
    count = sum(t["kind"] != "suite" for t in tests.values())
    if count == 0:
        raise ValueError("zero executed core tests")
    return count


def verify_ui_identities(tree, selected):
    leaves = []
    def visit(node):
        if node.get("nodeType") == "Test Case":
            leaves.append(node)
        for child in node.get("children", []):
            visit(child)
    for node in tree.get("testNodes", []):
        visit(node)
    expected = sorted("/".join(test.split("/")[1:]) for test in selected)
    actual = sorted(node.get("nodeIdentifier", "").removesuffix("()") for node in leaves)
    if actual != expected or any(node.get("result") != "Passed" for node in leaves):
        raise ValueError("UI native test identities/results do not match selection")


def verify_ui_bundle(bundle, selected):
    from verify_apple_test_execution import read_native_summary, read_native_legacy_result, combined_warning_messages, executed_test_count
    summary = read_native_summary(bundle)
    if executed_test_count(summary) != len(selected) or summary.get("skippedTests", 0):
        raise ValueError("UI test count mismatch or skipped tests")
    if combined_warning_messages(summary, read_native_legacy_result(bundle)):
        raise ValueError("UI native runtime warnings")
    tree = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)], text=True))
    verify_ui_identities(tree, selected)
    return len(selected)


def main():
    manifest = json.loads((ROOT / "config/release-smoke.json").read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=list(manifest["profiles"]))
    parser.add_argument("--check", action="store_true", help="Validate source selection without running product tests")
    parser.add_argument("--results-root", type=Path)
    parser.add_argument("--gateway-binary", type=Path, help="Actual candidate Gateway executable for gateway-integration")
    args = parser.parse_args()
    validate_release_version(manifest["release_version"], current_product_versions())
    profile = manifest["profiles"][args.profile]
    validate_profile(profile)
    if args.check:
        print("selection=VALIDATED; product=NOT_RUN")
        return 0
    from datetime import datetime, timezone
    result = args.results_root or ROOT / "build/quality-results/release-smoke" / (args.profile + "-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
    result.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env.update(PUSHGO_RELEASE_SMOKE_VERSION=manifest["release_version"], RESULTS_ROOT=str(result.resolve()), MAX_RETRIES="0", QUALITY_ALLOW_EXPECTED_FAILURES="0")
    is_core = "suites" in profile
    receipt = {"profile": args.profile, "source_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)), "selection": profile, "status": "NOT_RUN", "configuration": "SwiftPM host" if is_core else "Debug native UI", "governance_waivers": manifest["governance_waivers"], "not_proven": manifest["not_proven"], "retries": 0}
    if args.profile == "macos":
        receipt["signing_mode"] = "sandboxed ad-hoc XCTest; production capabilities not proven"
    try:
        gateway = nullcontext()
        if args.profile == "gateway-integration":
            if args.gateway_binary is None:
                raise ValueError("gateway-integration requires --gateway-binary; no mocked fallback")
            from release_smoke_gateway import isolated_gateway
            gateway = isolated_gateway(args.gateway_binary, result, env, receipt, profile["gateway_revision"])
        if is_core:
            suites = profile["suites"]
            pattern = "(" + "|".join(map(re.escape, suites)) + ")/"
            command = [str(ROOT / "scripts/run_apple_core_tests.sh"), "--jobs", "2", "--filter", pattern, "--experimental-event-stream-output", str(result.resolve() / "core.jsonl"), "--experimental-event-stream-version", "0"]
        else:
            tests = profile["tests"]
            env.update(TEST_SCOPES=",".join(tests), QUALITY_EXPECTED_TEST_COUNT=str(len(tests)))
            if args.profile == "ios-notification":
                env["SYSTEM_NOTIFICATION_TEST_SCOPE"] = tests[0]
                runner = "run_ios_system_notification_test.sh"
            elif args.profile == "macos":
                env["DIAGNOSTIC_MACOS_SCOPE"] = "release-smoke"
                runner = "ci/run_macos_adhoc_ui_diagnostic.sh"
            else:
                runner = f"run_{args.profile}_ui_tests.sh"
            command = ["bash", str(ROOT / "scripts" / runner)]
        with gateway, (result / "runner.log").open("w") as log:
            proc = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        receipt["runner_exit"] = proc.returncode
        if proc.returncode:
            receipt["status"] = "BLOCKED" if proc.returncode == 2 else "FAILED"
            diagnostic = result / "diagnostic-summary.json"
            if args.profile == "macos" and diagnostic.exists():
                native = json.loads(diagnostic.read_text())
                receipt["product_status"] = native.get("product_status", "NOT_RUN")
                receipt["test_system_status"] = native.get("test_system_status", "FAILED_TEST_SYSTEM")
                if receipt["test_system_status"] == "BLOCKED":
                    receipt["status"] = "BLOCKED"
            raise ValueError("native runner failed; inspect runner.log and xcresult")
        if is_core:
            count = verify_core_events(result / "core.jsonl", suites)
        else:
            bundles = list(result.rglob("*.xcresult"))
            if len(bundles) != 1:
                raise ValueError("expected exactly one native xcresult")
            count = verify_ui_bundle(bundles[0], tests)
            receipt["native_result"] = str(bundles[0])
        receipt.update(status="PASSED", executed_tests=count)
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if receipt["status"] == "NOT_RUN":
            receipt["status"] = "FAILED_TEST_SYSTEM"
        receipt["reason"] = str(error)
        print(str(error))
        return 1
    finally:
        (result / "summary.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        print(f"{receipt['status']}: {result / 'summary.json'}")


if __name__ == "__main__":
    raise SystemExit(main())
