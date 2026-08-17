#!/usr/bin/env python3
"""The supervise contract must refuse a binary that is not the declared engine revision.

The receipt records the digest in the publisher's canonical `sha256-<hex>` form, so these
fixtures write that exact form; comparing a bare hex digest against it never matches.

The helper cases drive the real `host_run_require_expected_engine_revision` from
`scripts/host_run.sh`; the entrypoint cases execute `scripts/run.sh supervise` so parser
drift or reordered restart/claim effects fail here rather than only on a live machine.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

from host_run_fixture import HostRunHarness, kill_if_alive, start_orphan_sleep

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SHA_A = "a" * 40
SHA_B = "b" * 40


def _drive(binary: pathlib.Path, expected: str) -> subprocess.CompletedProcess:
    script = (
        f'set -euo pipefail\n'
        f'. "{REPO_ROOT}/scripts/host_run.sh"\n'
        f'BIN="{binary}"\n'
        f'HOST_RUN_EXPECTED_ENGINE_REVISION="{expected}"\n'
        f'host_run_require_expected_engine_revision\n'
    )
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True)


def _publish(directory: pathlib.Path, revision: str, body: bytes, digest: str | None = None):
    binary = directory / f"engine-binary-{revision}"
    binary.write_bytes(body)
    binary.chmod(0o755)
    receipt = directory / f".{binary.name}.build-receipt.json"
    receipt.write_text(
        json.dumps({"binary_sha256": digest or "sha256-" + hashlib.sha256(body).hexdigest()}),
        encoding="ascii",
    )
    return binary


def _run_supervise(harness: HostRunHarness, binary: pathlib.Path, expected: str, *, restart: bool = False):
    args = [
        "/bin/bash",
        str(REPO_ROOT / "scripts" / "run.sh"),
        "supervise",
        "--project-root",
        str(harness.packages_host),
        "--platform-root",
        str(harness.packages_host),
        "--platform-packages",
        "github-proxy",
        "--expected-engine-revision",
        expected,
        "--durable-root",
        str(harness.durable),
        "--runtime-root",
        str(harness.runtime),
    ]
    if restart:
        args.append("--restart")
    environment = os.environ.copy()
    environment["BIN"] = str(binary)
    environment["FKST_NO_AUTOBUILD"] = "1"
    return subprocess.run(
        args,
        cwd=REPO_ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def main() -> int:
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        directory = pathlib.Path(raw)

        binary = _publish(directory, SHA_A, b"engine-bytes")
        if _drive(binary, SHA_A).returncode != 0:
            failures.append("a matching revision and receipt must be accepted")

        # A revision the operator did not declare must not launch, however healthy it is.
        if _drive(binary, SHA_B).returncode == 0:
            failures.append("a binary for another revision must be refused")

        # Bytes that no longer match the receipt are a corrupt or partial publication.
        tampered = _publish(directory, SHA_B, b"engine-bytes", digest="sha256-" + hashlib.sha256(b"other").hexdigest())
        if _drive(tampered, SHA_B).returncode == 0:
            failures.append("bytes that do not match the receipt must be refused")

        # An absent receipt cannot attest anything.
        (directory / f".{tampered.name}.build-receipt.json").unlink()
        if _drive(tampered, SHA_B).returncode == 0:
            failures.append("a missing receipt must be refused")

        # A malformed expectation is an operator error, not something to launch through.
        if _drive(binary, "not-a-sha").returncode == 0:
            failures.append("a malformed expected revision must be refused")

        # No expectation declared means there is nothing to verify.
        if _drive(binary, "").returncode != 0:
            failures.append("an absent expectation must not block launch")

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    print("PASS: expected-engine-revision contract" if not failures else "FAILED")
    return 1 if failures else 0


def test_real_supervise_entrypoint_rejects_before_restart_or_claim() -> None:
    harness = HostRunHarness()
    prior_pid = start_orphan_sleep()
    try:
        harness.write_workspace_manifest(root=harness.packages_host, workspace_units=["packages/*"])
        binary = _publish(harness.root, SHA_B, b"#!/bin/sh\nexit 0\n")
        harness.durable.mkdir(parents=True, exist_ok=True)
        pid_file = harness.durable / ".fkst-supervise.pid"
        pid_file.write_text(f"{prior_pid}\n", encoding="ascii")

        result = _run_supervise(harness, binary, SHA_A, restart=True)

        assert result.returncode != 0, result.stdout + result.stderr
        assert "ENGINE_REVISION_MISMATCH" in result.stderr, result.stderr
        assert "unknown supervise option" not in result.stderr, result.stderr
        assert "killing prior supervise pid" not in result.stderr, result.stderr
        assert prior_pid_is_alive(prior_pid), "the pre-existing supervisor must not be restarted"
        assert pid_file.read_text(encoding="ascii") == f"{prior_pid}\n"
    finally:
        kill_if_alive(prior_pid)
        harness.close()


def test_real_supervise_entrypoint_accepts_expected_revision_option() -> None:
    harness = HostRunHarness()
    try:
        harness.write_workspace_manifest(root=harness.packages_host, workspace_units=["packages/*"])
        binary = _publish(harness.root, SHA_A, b"#!/bin/sh\nexit 0\n")

        result = _run_supervise(harness, binary, SHA_A)

        assert result.returncode == 0, result.stdout + result.stderr
        assert "unknown supervise option" not in result.stderr, result.stderr
        assert "ENGINE_REVISION_MISMATCH" not in result.stderr, result.stderr
    finally:
        harness.close()


def prior_pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


if __name__ == "__main__":
    status = main()
    if status:
        raise SystemExit(status)
    test_real_supervise_entrypoint_rejects_before_restart_or_claim()
    test_real_supervise_entrypoint_accepts_expected_revision_option()
