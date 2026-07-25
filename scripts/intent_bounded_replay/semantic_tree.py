#!/usr/bin/env python3
"""Deterministic git-tree hashing for the R9 semantic oracle.

Every field is encoded as an unsigned 64-bit big-endian byte length followed by
that field's exact bytes. Paths are Git's raw path bytes, modes are Git's ASCII
modes, and blob hashes are raw 32-byte SHA-256 digests of blob content. Tree
records sort by path bytes. Diff records sort lexicographically by the tuple
(status, old_path, new_path, old_mode, new_mode, old_blob_hash,
new_blob_hash), comparing each component as bytes; an absent side is b"".
Statuses are Git's single-byte A, D, M, and T codes; renames become D plus A.

The fixed tracked-tree exclusion is a numbered behavior-change manifest at
migration/intent-diffs/<actual-pr-number>.json. Generated CI attestations are
outside the tracked tree, so tracked-tree enumeration excludes them by
construction.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Sequence
import hashlib
import os
from pathlib import Path
import re
import struct
import subprocess
from typing import TypeAlias

TREE_DOMAIN = b"fkst-semantic-tree-v1"
DIFF_DOMAIN = b"fkst-semantic-diff-v1"
PathExclusion: TypeAlias = Callable[[bytes], bool]


def _is_numbered_intent_diff_manifest(path: bytes) -> bool:
    return re.fullmatch(rb"migration/intent-diffs/[1-9][0-9]*\.json", path) is not None


FIXED: tuple[PathExclusion, ...] = (_is_numbered_intent_diff_manifest,)


def _git(repo_root: Path, *args: str, input_bytes: bytes | None = None) -> bytes:
    result = subprocess.run(
        ["git", *args],
        cwd=os.fspath(repo_root),
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git {' '.join(args)} failed ({result.returncode}): {detail}")
    return result.stdout


def _resolve(repo_root: Path, ref: str, object_type: str) -> bytes:
    resolved = _git(
        repo_root,
        "rev-parse",
        "--verify",
        "--end-of-options",
        f"{ref}^{{{object_type}}}",
    ).strip()
    if not re.fullmatch(rb"[0-9a-fA-F]+", resolved):
        raise RuntimeError(f"git resolved {ref!r} to an invalid object id")
    return resolved.lower()


def _ls_tree_entries(repo_root: Path, tree_oid: bytes) -> list[tuple[bytes, bytes, bytes]]:
    output = _git(
        repo_root,
        "ls-tree",
        "-r",
        "-z",
        "--full-tree",
        tree_oid.decode("ascii"),
        "--",
    )
    entries: list[tuple[bytes, bytes, bytes]] = []
    for raw_entry in output.split(b"\0"):
        if not raw_entry:
            continue
        try:
            metadata, path = raw_entry.split(b"\t", 1)
            mode, object_type, object_id = metadata.split(b" ", 2)
        except ValueError as error:
            raise RuntimeError("git ls-tree returned a malformed entry") from error
        if object_type != b"blob":
            raise RuntimeError(
                f"tracked path {path!r} has unsupported object type {object_type!r}; "
                "semantic records require blobs"
            )
        entries.append((path, mode, object_id.lower()))
    return entries


def _read_blobs(repo_root: Path, object_ids: Iterable[bytes]) -> dict[bytes, bytes]:
    requested = sorted(set(object_ids))
    if not requested:
        return {}
    output = _git(repo_root, "cat-file", "--batch", input_bytes=b"\n".join(requested) + b"\n")
    cursor = 0
    blobs: dict[bytes, bytes] = {}
    for expected_id in requested:
        header_end = output.find(b"\n", cursor)
        if header_end < 0:
            raise RuntimeError("git cat-file --batch omitted an object header")
        header = output[cursor:header_end]
        cursor = header_end + 1
        parts = header.split(b" ")
        if len(parts) != 3:
            raise RuntimeError(f"git cat-file returned malformed header {header!r}")
        object_id, object_type, size_bytes = parts
        if object_id.lower() != expected_id or object_type != b"blob":
            raise RuntimeError(f"git cat-file returned unexpected object header {header!r}")
        try:
            size = int(size_bytes)
        except ValueError as error:
            raise RuntimeError(f"git cat-file returned invalid blob size {size_bytes!r}") from error
        end = cursor + size
        if end >= len(output) or output[end : end + 1] != b"\n":
            raise RuntimeError("git cat-file returned a truncated blob")
        blobs[expected_id] = output[cursor:end]
        cursor = end + 1
    if cursor != len(output):
        raise RuntimeError("git cat-file returned unexpected trailing bytes")
    return blobs


def _frame_fields(fields: Sequence[bytes]) -> bytes:
    """Encode fields as u64-be length followed by exact bytes."""
    framed = bytearray()
    for field in fields:
        framed.extend(struct.pack(">Q", len(field)))
        framed.extend(field)
    return bytes(framed)


def _excluded(path: bytes, exclusions: Iterable[PathExclusion]) -> bool:
    return any(exclusion(path) for exclusion in exclusions)


def semantic_tree_sha256(
    repo_root: str | os.PathLike[str],
    head_ref: str = "HEAD",
    exclusions: Iterable[PathExclusion] = FIXED,
) -> str:
    """Hash the canonical tracked tree at ``head_ref`` and return lowercase hex."""
    root = Path(repo_root)
    tree_oid = _resolve(root, head_ref, "tree")
    exclusion_rules = tuple(exclusions)
    entries = [
        entry
        for entry in _ls_tree_entries(root, tree_oid)
        if not _excluded(entry[0], exclusion_rules)
    ]
    blobs = _read_blobs(root, (object_id for _, _, object_id in entries))
    records = [
        (
            path,
            _frame_fields((path, mode, hashlib.sha256(blobs[object_id]).digest())),
        )
        for path, mode, object_id in entries
    ]
    records.sort(key=lambda record: record[0])
    stream = TREE_DOMAIN + b"".join(record for _, record in records)
    return hashlib.sha256(stream).hexdigest()


def _git_mode_type(mode: bytes) -> int:
    try:
        return int(mode, 8) & 0o170000
    except ValueError as error:
        raise RuntimeError(f"git ls-tree returned invalid mode {mode!r}") from error


def _tree_diff_entries(
    repo_root: Path,
    base_tree_oid: bytes,
    head_tree_oid: bytes,
    exclusions: Iterable[PathExclusion],
) -> list[tuple[bytes, bytes, bytes, bytes, bytes, bytes, bytes]]:
    exclusion_rules = tuple(exclusions)
    base_entries = {
        path: (mode, object_id)
        for path, mode, object_id in _ls_tree_entries(repo_root, base_tree_oid)
        if not _excluded(path, exclusion_rules)
    }
    head_entries = {
        path: (mode, object_id)
        for path, mode, object_id in _ls_tree_entries(repo_root, head_tree_oid)
        if not _excluded(path, exclusion_rules)
    }
    entries = []
    for path in base_entries.keys() | head_entries.keys():
        old = base_entries.get(path)
        new = head_entries.get(path)
        if old is None:
            new_mode, new_id = new
            entries.append((b"A", b"", path, b"", new_mode, b"", new_id))
        elif new is None:
            old_mode, old_id = old
            entries.append((b"D", path, b"", old_mode, b"", old_id, b""))
        elif old != new:
            old_mode, old_id = old
            new_mode, new_id = new
            status = b"T" if _git_mode_type(old_mode) != _git_mode_type(new_mode) else b"M"
            entries.append((status, path, path, old_mode, new_mode, old_id, new_id))
    return entries


def semantic_diff_sha256(
    repo_root: str | os.PathLike[str],
    base_sha: str,
    head_ref: str = "HEAD",
    exclusions: Iterable[PathExclusion] = FIXED,
) -> str:
    """Hash canonical tracked changes from ``base_sha`` to ``head_ref``.

    Rename detection is disabled in Git, which canonically represents every
    rename as one DELETE record and one ADD record.
    """
    root = Path(repo_root)
    base_oid = _resolve(root, base_sha, "commit")
    head_oid = _resolve(root, head_ref, "commit")
    base_tree_oid = _resolve(root, base_oid.decode("ascii"), "tree")
    head_tree_oid = _resolve(root, head_oid.decode("ascii"), "tree")
    entries = _tree_diff_entries(root, base_tree_oid, head_tree_oid, exclusions)

    object_ids = [
        object_id
        for entry in entries
        for object_id in (entry[5], entry[6])
        if object_id
    ]
    blobs = _read_blobs(root, object_ids)
    records = []
    for status, old_path, new_path, old_mode, new_mode, old_id, new_id in entries:
        old_hash = hashlib.sha256(blobs[old_id]).digest() if old_id else b""
        new_hash = hashlib.sha256(blobs[new_id]).digest() if new_id else b""
        record = (status, old_path, new_path, old_mode, new_mode, old_hash, new_hash)
        records.append(record)
    records.sort()
    stream = DIFF_DOMAIN + b"".join(_frame_fields(record) for record in records)
    return hashlib.sha256(stream).hexdigest()
