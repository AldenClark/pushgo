#!/usr/bin/env python3
"""Download retained compact quality receipts for longitudinal review."""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Any


MAX_ARCHIVE_BYTES = 8 * 1024 * 1024
MAX_RECEIPT_BYTES = 1024 * 1024
MAX_RECEIPT_ARTIFACT_AGE = timedelta(hours=24)
MAX_RECEIPT_FUTURE_SKEW = timedelta(minutes=15)
GITHUB_RUN_IDENTITY = re.compile(
    r"github:(?P<run_id>[1-9][0-9]*):(?P<attempt>[1-9][0-9]*):(?P<job>[A-Za-z0-9_.-]+)"
)


class CollectionError(ValueError):
    pass


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        redirected = super().redirect_request(
            request, file_pointer, code, message, headers, new_url
        )
        if redirected is None:
            return None
        old_host = urllib.parse.urlsplit(request.full_url).netloc
        new_host = urllib.parse.urlsplit(new_url).netloc
        if old_host.lower() != new_host.lower():
            redirected.remove_header("Authorization")
        return redirected


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True, help="GitHub owner/repository")
    parser.add_argument("--workflow", required=True, help="Trusted workflow file name")
    parser.add_argument("--artifact-name-prefix", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--lookback-days", type=int, default=21)
    parser.add_argument("--token-env", default="QUALITY_GITHUB_TOKEN")
    parser.add_argument("--api-url", default="https://api.github.com")
    return parser.parse_args()


def parse_github_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise CollectionError("artifact created_at must be a string")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise CollectionError(f"invalid artifact created_at: {value}") from error
    if parsed.tzinfo is None:
        raise CollectionError("artifact created_at must include a timezone")
    return parsed.astimezone(timezone.utc)


def select_artifacts(
    artifacts: list[dict[str, Any]],
    prefix: str,
    cutoff: datetime,
    allowed_run_ids: set[int],
) -> list[dict[str, Any]]:
    selected: dict[int, dict[str, Any]] = {}
    for artifact in artifacts:
        artifact_id = artifact.get("id")
        name = artifact.get("name")
        if not isinstance(artifact_id, int) or not isinstance(name, str):
            raise CollectionError("artifact id/name has an invalid type")
        workflow_run = artifact.get("workflow_run")
        workflow_run_id = workflow_run.get("id") if isinstance(workflow_run, dict) else None
        if not isinstance(workflow_run_id, int):
            raise CollectionError("artifact has no workflow run identity")
        if workflow_run_id not in allowed_run_ids:
            continue
        if artifact.get("expired") is True or not name.startswith(prefix):
            continue
        if parse_github_time(artifact.get("created_at")) < cutoff:
            continue
        selected[artifact_id] = artifact
    return sorted(selected.values(), key=lambda item: (item["created_at"], item["id"]))


def request_bytes(url: str, token: str, *, accept: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": accept,
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2026-03-10",
            "User-Agent": "pushgo-quality-observation",
        },
    )
    try:
        opener = urllib.request.build_opener(SafeRedirectHandler())
        with opener.open(request, timeout=30) as response:
            declared = response.headers.get("Content-Length")
            if declared:
                try:
                    declared_size = int(declared)
                except ValueError as error:
                    raise CollectionError("artifact response has an invalid content length") from error
                if declared_size > MAX_ARCHIVE_BYTES:
                    raise CollectionError(f"artifact response exceeds {MAX_ARCHIVE_BYTES} bytes")
            payload = response.read(MAX_ARCHIVE_BYTES + 1)
    except (OSError, urllib.error.HTTPError, urllib.error.URLError) as error:
        raise CollectionError(f"GitHub artifact request failed: {error}") from error
    if len(payload) > MAX_ARCHIVE_BYTES:
        raise CollectionError(f"artifact response exceeds {MAX_ARCHIVE_BYTES} bytes")
    return payload


def list_artifacts(api_url: str, repository: str, token: str) -> list[dict[str, Any]]:
    encoded_repository = urllib.parse.quote(repository, safe="/")
    artifacts: list[dict[str, Any]] = []
    for page in range(1, 101):
        url = f"{api_url.rstrip('/')}/repos/{encoded_repository}/actions/artifacts?per_page=100&page={page}"
        raw = request_bytes(url, token, accept="application/vnd.github+json")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise CollectionError("GitHub artifacts response is not JSON") from error
        page_artifacts = payload.get("artifacts") if isinstance(payload, dict) else None
        if not isinstance(page_artifacts, list) or not all(
            isinstance(item, dict) for item in page_artifacts
        ):
            raise CollectionError("GitHub artifacts response has no artifact array")
        artifacts.extend(page_artifacts)
        if len(page_artifacts) < 100:
            return artifacts
    raise CollectionError("GitHub artifact pagination exceeded 100 pages")


def list_workflow_run_ids(
    api_url: str,
    repository: str,
    workflow: str,
    token: str,
    cutoff: datetime,
) -> set[int]:
    encoded_repository = urllib.parse.quote(repository, safe="/")
    encoded_workflow = urllib.parse.quote(workflow, safe="")
    created = ">=" + cutoff.isoformat().replace("+00:00", "Z")
    run_ids: set[int] = set()
    for page in range(1, 101):
        query = urllib.parse.urlencode({"per_page": 100, "page": page, "created": created})
        url = (
            f"{api_url.rstrip('/')}/repos/{encoded_repository}/actions/workflows/"
            f"{encoded_workflow}/runs?{query}"
        )
        raw = request_bytes(url, token, accept="application/vnd.github+json")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise CollectionError("GitHub workflow runs response is not JSON") from error
        runs = payload.get("workflow_runs") if isinstance(payload, dict) else None
        if not isinstance(runs, list) or not all(isinstance(item, dict) for item in runs):
            raise CollectionError("GitHub workflow runs response has no run array")
        for run in runs:
            run_id = run.get("id")
            if not isinstance(run_id, int):
                raise CollectionError("workflow run id has an invalid type")
            run_ids.add(run_id)
        if len(runs) < 100:
            return run_ids
    raise CollectionError("GitHub workflow run pagination exceeded 100 pages")


def validate_receipt_artifact_binding(
    content: bytes,
    artifact_id: int,
    workflow_run_id: int,
    workflow_source_revision: str,
    artifact_created_at: datetime,
) -> None:
    try:
        payload = json.loads(content)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return
    if not isinstance(payload, dict):
        return

    run_identity = payload.get("run_identity")
    if run_identity is not None:
        if not isinstance(run_identity, str):
            raise CollectionError(f"artifact {artifact_id} receipt run identity has an invalid type")
        match = GITHUB_RUN_IDENTITY.fullmatch(run_identity)
        if not match:
            raise CollectionError(f"artifact {artifact_id} receipt has a non-GitHub run identity")
        if int(match.group("run_id")) != workflow_run_id:
            raise CollectionError(
                f"artifact {artifact_id} receipt run identity does not match its workflow run"
            )

    source_revision = payload.get("source_revision")
    if source_revision is not None:
        if not isinstance(source_revision, str):
            raise CollectionError(f"artifact {artifact_id} receipt source revision has an invalid type")
        if source_revision != workflow_source_revision:
            raise CollectionError(
                f"artifact {artifact_id} receipt source revision does not match its workflow run"
            )

    recorded_at = payload.get("recorded_at")
    if recorded_at is not None:
        try:
            receipt_time = parse_github_time(recorded_at)
        except CollectionError as error:
            raise CollectionError(f"artifact {artifact_id} receipt has an invalid recorded_at") from error
        if receipt_time < artifact_created_at - MAX_RECEIPT_ARTIFACT_AGE:
            raise CollectionError(f"artifact {artifact_id} receipt predates its artifact window")
        if receipt_time > artifact_created_at + MAX_RECEIPT_FUTURE_SKEW:
            raise CollectionError(f"artifact {artifact_id} receipt postdates its artifact window")


def extract_receipts(
    archive: bytes,
    destination: Path,
    artifact_id: int,
    workflow_run_id: int,
    workflow_source_revision: str,
    artifact_created_at: datetime,
) -> int:
    artifact_root = destination / str(artifact_id)
    receipt_count = 0
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            for member in bundle.infolist():
                member_path = PurePosixPath(member.filename)
                if member_path.is_absolute() or ".." in member_path.parts:
                    raise CollectionError(f"artifact {artifact_id} contains an unsafe path")
                if member.is_dir() or not member_path.name.endswith("-summary.json"):
                    continue
                if member.file_size > MAX_RECEIPT_BYTES:
                    raise CollectionError(f"artifact {artifact_id} contains an oversized receipt")
                target = artifact_root / member_path.name
                if target.exists():
                    raise CollectionError(f"artifact {artifact_id} contains duplicate receipt names")
                content = bundle.read(member)
                if len(content) > MAX_RECEIPT_BYTES:
                    raise CollectionError(f"artifact {artifact_id} contains an oversized receipt")
                validate_receipt_artifact_binding(
                    content,
                    artifact_id,
                    workflow_run_id,
                    workflow_source_revision,
                    artifact_created_at,
                )
                artifact_root.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
                receipt_count += 1
    except zipfile.BadZipFile as error:
        raise CollectionError(f"artifact {artifact_id} is not a valid zip archive") from error
    if receipt_count == 0:
        raise CollectionError(f"artifact {artifact_id} contains no formal quality receipt")
    return receipt_count


def main() -> int:
    args = parse_args()
    if args.lookback_days < 14:
        print("status=BLOCKED\nreason=lookback-days cannot be shorter than the 14-day gate")
        return 2
    repository_parts = args.repository.split("/")
    if len(repository_parts) != 2 or not all(repository_parts):
        print("status=BLOCKED\nreason=repository must be owner/repository")
        return 2
    api_endpoint = urllib.parse.urlsplit(args.api_url)
    if api_endpoint.scheme != "https" or not api_endpoint.netloc:
        print("status=BLOCKED\nreason=GitHub API URL must use HTTPS")
        return 2
    if not args.artifact_name_prefix:
        print("status=BLOCKED\nreason=artifact-name-prefix cannot be empty")
        return 2
    token = os.environ.get(args.token_env)
    if not token:
        print(f"status=BLOCKED\nreason=missing token environment: {args.token_env}")
        return 2
    output = Path(args.output)
    if output.exists() and not output.is_dir():
        print("status=BLOCKED\nreason=observation download output must be a directory")
        return 2
    if output.exists() and any(output.iterdir()):
        print("status=BLOCKED\nreason=observation download output must be empty")
        return 2
    output.mkdir(parents=True, exist_ok=True)
    cutoff = datetime.now(timezone.utc) - timedelta(days=args.lookback_days)
    try:
        candidates = select_artifacts(
            list_artifacts(args.api_url, args.repository, token),
            args.artifact_name_prefix,
            cutoff,
            list_workflow_run_ids(
                args.api_url,
                args.repository,
                args.workflow,
                token,
                cutoff,
            ),
        )
        receipt_count = 0
        encoded_repository = urllib.parse.quote(args.repository, safe="/")
        for artifact in candidates:
            workflow_run = artifact["workflow_run"]
            source_revision = workflow_run.get("head_sha")
            if not isinstance(source_revision, str) or not source_revision:
                raise CollectionError(
                    f"artifact {artifact['id']} has no workflow source revision"
                )
            archive_url = (
                f"{args.api_url.rstrip('/')}/repos/{encoded_repository}/actions/artifacts/"
                f"{artifact['id']}/zip"
            )
            archive = request_bytes(archive_url, token, accept="application/vnd.github+json")
            receipt_count += extract_receipts(
                archive,
                output,
                artifact["id"],
                workflow_run["id"],
                source_revision,
                parse_github_time(artifact["created_at"]),
            )
    except CollectionError as error:
        print(f"status=BLOCKED\nreason={error}")
        return 2
    print("status=PASSED")
    print(f"artifact_count={len(candidates)}")
    print(f"receipt_count={receipt_count}")
    print(f"output={output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
