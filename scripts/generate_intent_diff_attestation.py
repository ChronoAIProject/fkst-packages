#!/usr/bin/env python3
"""Generate a verifier-owned SPEC 9.6 intent-diff attestation."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable

import check_repo_intent_bounded_replay as checker
from intent_bounded_replay.attestation import (
    AttestationError,
    TRACE_HASH_FIELDS,
    TRACE_PAIRS,
    TracePair,
    canonical_attestation_sha256,
    recompute_trace_hashes,
)
from intent_bounded_replay.normalize import (
    canonical_json,
    loads_json,
)
from intent_bounded_replay.semantic_tree import (
    semantic_diff_sha256,
    semantic_tree_sha256,
)


MANIFEST_PATH_RE = re.compile(r"migration/intent-diffs/[1-9][0-9]*\.json")


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=root, check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.strip()
        raise AttestationError(f"git {' '.join(args)} failed ({result.returncode}): {detail}")
    return result.stdout.strip()


def _changed_manifest_paths(root: Path, base_sha: str, head_sha: str) -> list[str]:
    output = _git(
        root,
        "diff",
        "--name-only",
        "--diff-filter=ACDMRT",
        base_sha,
        head_sha,
        "--",
        checker.INTENT_DIFF_DIR,
    )
    return sorted(
        {
            line
            for line in output.splitlines()
            if MANIFEST_PATH_RE.fullmatch(line) is not None
        },
        key=lambda path: path.encode("utf-8"),
    )


def _load_manifest(path: Path, relative: str) -> dict[str, object]:
    if not path.is_file():
        raise AttestationError(f"missing intent-diff manifest: {relative}")
    try:
        artifact = loads_json(path.read_bytes())
    except Exception as error:
        raise AttestationError(f"cannot load intent-diff manifest {relative}: {error}") from error
    if not isinstance(artifact, dict):
        raise AttestationError(f"intent-diff manifest {relative} must contain an object")
    return artifact


def generate_attestation(
    *,
    root: Path,
    pr_number: int,
    base_ref: str,
    head_ref: str,
    output_dir: Path,
    trace_pairs: Iterable[TracePair] = TRACE_PAIRS,
) -> dict[str, object] | None:
    root = Path(root).resolve()
    if pr_number < 1:
        raise AttestationError("actual PR number must be positive")
    head_sha = _git(root, "rev-parse", "--verify", f"{head_ref}^{{commit}}").lower()
    checkout_sha = _git(root, "rev-parse", "--verify", "HEAD^{commit}").lower()
    if checkout_sha != head_sha:
        raise AttestationError(
            f"checked out commit {checkout_sha} does not match attested head {head_sha}"
        )
    base_sha = _git(root, "merge-base", head_sha, base_ref).lower()
    expected_manifest = f"{checker.INTENT_DIFF_DIR}/{pr_number}.json"
    changed_manifests = _changed_manifest_paths(root, base_sha, head_sha)
    output_path = Path(output_dir) / f"{pr_number}.json"
    trace_hashes = recompute_trace_hashes(root, trace_pairs, old_ref=base_sha)
    if not changed_manifests:
        if output_path.is_file():
            output_path.unlink()
        return None
    if changed_manifests != [expected_manifest]:
        shown = ", ".join(changed_manifests)
        raise AttestationError(
            f"changed intent-diff manifest must be {expected_manifest} for actual PR {pr_number}; "
            f"found: {shown}"
        )

    manifest_path = root / expected_manifest
    manifest = _load_manifest(manifest_path, expected_manifest)
    manifest_messages = checker._bound_manifest_messages(
        root, manifest, expected_manifest, base_sha, head_sha
    )
    if manifest_messages:
        raise AttestationError("; ".join(manifest_messages))

    for field in TRACE_HASH_FIELDS:
        if manifest.get(field) != trace_hashes[field]:
            raise AttestationError(
                f"{expected_manifest} {field} mismatch: "
                f"declared {manifest.get(field)}, computed {trace_hashes[field]}"
            )

    actual_tree = semantic_tree_sha256(root, head_sha)
    actual_diff = semantic_diff_sha256(root, base_sha, head_sha)
    artifact: dict[str, object] = {
        "schema": "fkst.intent-diff-attestation.v1",
        "pr_number": pr_number,
        "base_sha": base_sha,
        "head_sha": head_sha,
        "manifest_path": expected_manifest,
        "manifest_blob_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "manifest_sha256": manifest["manifest_sha256"],
        "semantic_tree_sha256": actual_tree,
        "semantic_diff_sha256": actual_diff,
        **trace_hashes,
        "result": "approved",
        "attestation_sha256": "",
    }
    artifact["attestation_sha256"] = canonical_attestation_sha256(artifact)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(canonical_json(artifact) + b"\n")
    return artifact


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr-number", required=True, type=int)
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--head-ref", required=True)
    parser.add_argument(
        "--output-dir",
        default=".fkst/run/intent-diff-attestations",
        type=Path,
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    try:
        artifact = generate_attestation(
            root=root,
            pr_number=args.pr_number,
            base_ref=args.base_ref,
            head_ref=args.head_ref,
            output_dir=(root / args.output_dir),
        )
    except AttestationError as error:
        print(f"R9-INTENT-DIFF-ATTESTATION: {error}", file=sys.stderr)
        return 1
    if artifact is None:
        print(f"OK: PR {args.pr_number} has no changed intent-diff manifest to attest")
    else:
        print(
            "OK: generated verifier-owned intent-diff attestation "
            f"for PR {args.pr_number} at {args.output_dir}/{args.pr_number}.json"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
