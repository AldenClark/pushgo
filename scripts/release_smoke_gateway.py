"""Own a disposable loopback Gateway for the Apple client integration profile."""
from contextlib import contextmanager
import hashlib
from pathlib import Path
import socket
import subprocess
import time
import urllib.request
import uuid


@contextmanager
def isolated_gateway(binary, result, env, receipt, expected_revision):
    binary = Path(binary).resolve(strict=True)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    auth = str(uuid.uuid4())
    env.update(PUSHGO_SMOKE_GATEWAY_URL=base, PUSHGO_SMOKE_GATEWAY_AUTH=auth)
    receipt["gateway_binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt["gateway_binary"] = str(binary)
    # These identify the paired sources; they do not certify an arbitrary
    # prebuilt binary. CI builds this binary from its explicit checkout first.
    repo = next((p for p in binary.parents if (p / "Cargo.toml").is_file()), None)
    if repo is not None:
        receipt["gateway_source_sha"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        receipt["gateway_source_dirty"] = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True))
    if receipt.get("gateway_source_sha") != expected_revision:
        raise ValueError("candidate Gateway checkout differs from the paired revision; update the explicit pair before running")
    with (result / "gateway.log").open("w") as log:
        child = subprocess.Popen([
            str(binary), "--http-addr", f"127.0.0.1:{port}",
            "--db-url", f"sqlite://{result.resolve() / 'gateway.sqlite'}?mode=rwc",
            "--token", auth, "--token-service-url", "http://127.0.0.1:1",
            "--private-transports", "none",
        ], stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 20
            while True:
                if child.poll() is not None:
                    raise ValueError("isolated Gateway exited before readiness; inspect gateway.log")
                try:
                    request = urllib.request.Request(base + "/", headers={"Authorization": f"Bearer {auth}"})
                    with urllib.request.urlopen(request, timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise ValueError("isolated Gateway readiness timed out; inspect gateway.log")
                    time.sleep(0.1)
            yield
        finally:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
