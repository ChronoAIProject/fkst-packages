#!/usr/bin/env python3
"""The supervise contract must refuse a binary that is not the declared engine revision.

The receipt records the digest in the publisher's canonical `sha256-<hex>` form, so these
fixtures write that exact form; comparing a bare hex digest against it never matches.

Each case drives the real `host_run_require_expected_engine_revision` from
`scripts/host_run.sh`, so a regression in that function fails here rather than only on
a live machine.
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

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


if __name__ == "__main__":
    raise SystemExit(main())
