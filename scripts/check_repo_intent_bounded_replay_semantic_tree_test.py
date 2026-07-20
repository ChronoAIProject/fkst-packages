#!/usr/bin/env python3
"""Tests for deterministic R9 semantic tree and diff hashing."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from intent_bounded_replay import semantic_tree
from intent_bounded_replay.semantic_tree import (
    semantic_diff_sha256,
    semantic_tree_sha256,
)


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def _write(repo: Path, relative_path: str, content: bytes) -> None:
    path = repo / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def _commit(repo: Path, message: str) -> str:
    _git(repo, "add", "-A")
    _git(repo, "commit", "-m", message)
    return _git(repo, "rev-parse", "HEAD")


def _new_repo(root: Path, name: str = "repo") -> Path:
    repo = root / name
    repo.mkdir()
    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "semantic-tree@example.invalid")
    _git(repo, "config", "user.name", "Semantic Tree Test")
    return repo


def _independent_frame(*fields: bytes) -> bytes:
    return b"".join(len(field).to_bytes(8, "big") + field for field in fields)


class SemanticTreeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.repo = _new_repo(self.root)
        _write(self.repo, "a.txt", b"alpha\n")
        self.base = _commit(self.repo, "base")

    def test_same_tree_is_deterministic_and_enumeration_order_independent(self) -> None:
        _write(self.repo, "z.txt", b"zulu\n")
        _commit(self.repo, "add z")
        expected = semantic_tree_sha256(self.repo)
        self.assertEqual(expected, semantic_tree_sha256(self.repo))
        original = semantic_tree._ls_tree_entries

        def reversed_entries(repo_root: Path, tree_oid: bytes):
            return list(reversed(original(repo_root, tree_oid)))

        with mock.patch.object(semantic_tree, "_ls_tree_entries", reversed_entries):
            self.assertEqual(expected, semantic_tree_sha256(self.repo))

    def test_commit_order_does_not_change_identical_tree(self) -> None:
        first = _new_repo(self.root, "first")
        _write(first, "a.txt", b"a")
        _commit(first, "a first")
        _write(first, "b.txt", b"b")
        _commit(first, "b second")
        second = _new_repo(self.root, "second")
        _write(second, "b.txt", b"b")
        _commit(second, "b first")
        _write(second, "a.txt", b"a")
        _commit(second, "a second")
        self.assertEqual(semantic_tree_sha256(first), semantic_tree_sha256(second))

    def test_add_content_and_mode_changes_each_change_tree_hash(self) -> None:
        baseline = semantic_tree_sha256(self.repo)
        _write(self.repo, "added.txt", b"new\n")
        added_hash = semantic_tree_sha256(self.repo, _commit(self.repo, "add file"))
        self.assertNotEqual(baseline, added_hash)
        _write(self.repo, "a.txt", b"Alpha\n")
        changed_hash = semantic_tree_sha256(self.repo, _commit(self.repo, "change byte"))
        self.assertNotEqual(added_hash, changed_hash)
        (self.repo / "a.txt").chmod(0o755)
        mode_head = _commit(self.repo, "change mode")
        self.assertNotEqual(changed_hash, semantic_tree_sha256(self.repo, mode_head))

    def test_records_are_sorted_by_path_bytes(self) -> None:
        _write(self.repo, "z", b"last")
        _write(self.repo, "aa", b"first")
        head = _commit(self.repo, "add byte-sort paths")
        records = []
        for path, content in ((b"a.txt", b"alpha\n"), (b"aa", b"first"), (b"z", b"last")):
            records.append(
                _independent_frame(path, b"100644", hashlib.sha256(content).digest())
            )
        expected = hashlib.sha256(b"fkst-semantic-tree-v1" + b"".join(records)).hexdigest()
        self.assertEqual(expected, semantic_tree_sha256(self.repo, head))

    def test_fixed_exclusions_ignore_manifest_and_untracked_attestation(self) -> None:
        baseline = semantic_tree_sha256(self.repo)
        _write(self.repo, "migration/intent-diffs/123.json", b"excluded\n")
        excluded_head = _commit(self.repo, "add excluded manifest")
        self.assertEqual(baseline, semantic_tree_sha256(self.repo, excluded_head))
        _write(self.repo, "generated/ci-attestation.json", b"untracked\n")
        self.assertEqual(baseline, semantic_tree_sha256(self.repo, excluded_head))
        _write(self.repo, "migration/intent-diffs/template.json", b"tracked\n")
        included_head = _commit(self.repo, "add non-numbered manifest")
        self.assertNotEqual(baseline, semantic_tree_sha256(self.repo, included_head))

    def test_length_frames_prevent_naive_path_blob_split_collision(self) -> None:
        left = semantic_tree._frame_fields((b"ab", b"c"))
        right = semantic_tree._frame_fields((b"a", b"bc"))
        self.assertEqual(b"ab" + b"c", b"a" + b"bc")
        self.assertNotEqual(left, right)
        self.assertEqual(left, _independent_frame(b"ab", b"c"))
        self.assertEqual(right, _independent_frame(b"a", b"bc"))
        self.assertNotEqual(hashlib.sha256(left).digest(), hashlib.sha256(right).digest())


class SemanticDiffTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.repo = _new_repo(self.root)
        _write(self.repo, "old.txt", b"same content\n")
        self.base = _commit(self.repo, "base")

    def test_rename_has_same_hash_as_explicit_delete_and_add(self) -> None:
        _git(self.repo, "checkout", "-q", "-b", "rename", self.base)
        _git(self.repo, "mv", "old.txt", "new.txt")
        rename_head = _commit(self.repo, "rename")
        _git(self.repo, "checkout", "-q", "-b", "explicit", self.base)
        (self.repo / "old.txt").unlink()
        _write(self.repo, "new.txt", b"same content\n")
        explicit_head = _commit(self.repo, "delete and add")
        self.assertEqual(
            semantic_diff_sha256(self.repo, self.base, rename_head),
            semantic_diff_sha256(self.repo, self.base, explicit_head),
        )

    def test_empty_diff_is_stable_and_change_is_sensitive(self) -> None:
        empty = semantic_diff_sha256(self.repo, self.base, self.base)
        self.assertEqual(empty, semantic_diff_sha256(self.repo, self.base, self.base))
        self.assertEqual(empty, hashlib.sha256(b"fkst-semantic-diff-v1").hexdigest())
        _write(self.repo, "old.txt", b"changed content\n")
        head = _commit(self.repo, "change")
        changed = semantic_diff_sha256(self.repo, self.base, head)
        self.assertNotEqual(empty, changed)
        self.assertEqual(changed, semantic_diff_sha256(self.repo, self.base, head))

    def test_excluded_manifest_does_not_affect_diff(self) -> None:
        _write(self.repo, "migration/intent-diffs/42.json", b"excluded\n")
        head = _commit(self.repo, "excluded only")
        self.assertEqual(
            semantic_diff_sha256(self.repo, self.base, self.base),
            semantic_diff_sha256(self.repo, self.base, head),
        )


if __name__ == "__main__":
    unittest.main()
