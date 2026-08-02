"""Verify immutable intent-diff subjects against reachable Git history."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
from typing import Any, Mapping

from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256


GIT_SHA_RE = re.compile(r"[0-9a-f]{40,64}")


def _identity_messages(artifact: Mapping[str, Any], relative: str) -> list[str]:
    expected_identity = "/".join((
        str(int(artifact["pr_number"])),
        artifact["base_sha"],
        artifact["semantic_tree_sha256"],
        artifact["semantic_diff_sha256"],
    ))
    if artifact["one_use_identity"] == expected_identity:
        return []
    return [f"{relative} one_use_identity is not bound to pr/base/semantic hashes"]


def manifest_subject_commit(
    root: Path,
    artifact: Mapping[str, Any],
    relative: str,
    head_ref: str = "HEAD",
    manifest_blob: bytes | None = None,
) -> str | None:
    """Return a manifest-bearing ancestor matching the declared semantic subject."""
    history = subprocess.run(
        ["git", "rev-list", "--full-history", head_ref, "--", relative],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if history.returncode != 0:
        detail = history.stderr.strip()
        raise RuntimeError(f"git rev-list failed ({history.returncode}): {detail}")

    expected_blob = (
        manifest_blob if manifest_blob is not None else (root / relative).read_bytes()
    )
    for commit in history.stdout.splitlines():
        if GIT_SHA_RE.fullmatch(commit) is None:
            raise RuntimeError(f"git rev-list returned invalid object ID {commit!r}")
        historical_blob = subprocess.run(
            ["git", "show", f"{commit}:{relative}"],
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if historical_blob.returncode != 0 or historical_blob.stdout != expected_blob:
            continue
        ancestry = subprocess.run(
            ["git", "merge-base", "--is-ancestor", artifact["base_sha"], commit],
            cwd=root,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        if ancestry.returncode == 1:
            continue
        if ancestry.returncode != 0:
            detail = ancestry.stderr.strip()
            raise RuntimeError(
                f"git merge-base --is-ancestor failed ({ancestry.returncode}): {detail}"
            )
        if (
            artifact["semantic_tree_sha256"] == semantic_tree_sha256(root, commit)
            and artifact["semantic_diff_sha256"]
            == semantic_diff_sha256(root, artifact["base_sha"], commit)
        ):
            return commit
    return None


def bound_subject_messages(
    root: Path,
    artifact: Mapping[str, Any],
    relative: str,
    base_sha: str,
    head_ref: str = "HEAD",
) -> list[str]:
    """Validate a live candidate against its explicit protected base and head."""
    messages = _identity_messages(artifact, relative)
    if artifact["base_sha"] != base_sha:
        messages.append(f"{relative} base_sha must equal protected merge-base {base_sha}")
    try:
        actual_tree = semantic_tree_sha256(root, head_ref)
        actual_diff = semantic_diff_sha256(root, base_sha, head_ref)
    except Exception as error:
        return messages + [f"{relative} cannot recompute semantic hashes: {error}"]
    for field, actual in (
        ("semantic_tree_sha256", actual_tree),
        ("semantic_diff_sha256", actual_diff),
    ):
        if artifact[field] != actual:
            messages.append(
                f"{relative} {field} mismatch: declared {artifact[field]}, computed {actual}"
            )
    return messages


def included_subject_messages(
    root: Path,
    artifact: Mapping[str, Any],
    relative: str,
    head_ref: str = "HEAD",
    manifest_blob: bytes | None = None,
) -> list[str]:
    """Validate that an immutable manifest subject is included in head history."""
    messages = _identity_messages(artifact, relative)
    try:
        subject_commit = manifest_subject_commit(
            root,
            artifact,
            relative,
            head_ref,
            manifest_blob=manifest_blob,
        )
    except Exception as error:
        return messages + [f"{relative} cannot verify immutable subject inclusion: {error}"]
    if subject_commit is None:
        messages.append(f"{relative} immutable subject is not present in {head_ref} ancestry")
    return messages
