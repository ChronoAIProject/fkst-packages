#!/usr/bin/env python3
"""Tests for the R9 refactor-phase behavior-oracle checker."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import check_repo_intent_bounded_replay as checker
from intent_bounded_replay.normalize import canonical_artifact_hash_v1, canonical_json
from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256


HEADER = "# R9 intent-bounded-replay: zero behavior-change intent-diffs during refactor.\n"
ZERO_HASH = "0" * 64


def write(root: Path, relative_path: str, content: str) -> Path:
    path = root / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def commit(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def manifest(pr_number: int = 123, self_hash: str | None = None) -> dict[str, object]:
    artifact: dict[str, object] = {
        "schema": "fkst.intent-diff.v2",
        "intent": "behavior-change",
        "pr_number": pr_number,
        "base_sha": "1" * 40,
        "semantic_tree_sha256": ZERO_HASH,
        "semantic_diff_sha256": ZERO_HASH,
        "changed_row_ids": [],
        "changed_edge_ids": [],
        "changed_policy_ids": [],
        "old_trace_sha256": ZERO_HASH,
        "new_trace_sha256": ZERO_HASH,
        "behavior_diff_sha256": ZERO_HASH,
        "cause": "bounded test change",
        "review_reference": "review:test",
        "one_use_identity": "123/base/semantic-hashes",
        "manifest_sha256": "",
    }
    artifact["manifest_sha256"] = self_hash or canonical_artifact_hash_v1(artifact)
    return artifact


def write_json(root: Path, relative_path: str, artifact: dict[str, object]) -> Path:
    return write(root, relative_path, json.dumps(artifact, sort_keys=True) + "\n")


class IntentBoundedReplayCheckerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        for relative_path in checker.PROTECTED_MODULES:
            write(self.root, relative_path, "# protected fixture\n")
        write(self.root, checker.ALLOWLIST, HEADER)
        write(self.root, f"{checker.INTENT_DIFF_DIR}/.gitkeep", "")

    def allow(self, relative_path: str) -> None:
        write(self.root, checker.ALLOWLIST, HEADER + relative_path + "\n")

    def test_clean_refactor_state_passes(self) -> None:
        self.assertEqual(checker.repository_messages(self.root), [])

    def test_stray_non_allowlisted_intent_diff_fails(self) -> None:
        relative_path = f"{checker.INTENT_DIFF_DIR}/123.json"
        write_json(self.root, relative_path, manifest())
        messages = checker.repository_messages(self.root)
        self.assertTrue(any("not listed" in message and relative_path in message for message in messages))

    def test_allowlisted_manifest_with_bad_self_hash_fails(self) -> None:
        relative_path = f"{checker.INTENT_DIFF_DIR}/123.json"
        self.allow(relative_path)
        write_json(self.root, relative_path, manifest(self_hash="f" * 64))
        messages = checker.repository_messages(self.root)
        self.assertTrue(any("manifest_sha256 mismatch" in message for message in messages))

    def test_allowlisted_manifest_with_valid_self_hash_passes(self) -> None:
        relative_path = f"{checker.INTENT_DIFF_DIR}/123.json"
        self.allow(relative_path)
        write_json(self.root, relative_path, manifest())
        self.assertEqual(checker.repository_messages(self.root), [])

    def test_allowlist_growth_relative_to_protected_base_fails(self) -> None:
        relative_path = f"{checker.INTENT_DIFF_DIR}/123.json"
        self.allow(relative_path)
        write_json(self.root, relative_path, manifest())

        with mock.patch.object(checker.ratchet_base, "file_at_base", return_value=("present", HEADER)):
            messages = checker.repository_messages(self.root, enforce_base=True)

        self.assertTrue(any("grows" in message and relative_path in message for message in messages))

    def test_attestation_with_mismatched_semantic_tree_fails(self) -> None:
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "r9-checker@example.invalid")
        git(self.root, "config", "user.name", "R9 Checker Test")
        write(self.root, "tracked.txt", "base\n")
        base_sha = commit(self.root, "base")

        relative_manifest = f"{checker.INTENT_DIFF_DIR}/123.json"
        self.allow(relative_manifest)
        artifact = manifest()
        artifact["base_sha"] = base_sha
        artifact["manifest_sha256"] = canonical_artifact_hash_v1(artifact)
        manifest_path = write_json(self.root, relative_manifest, artifact)
        head_sha = commit(self.root, "intent manifest")

        attestation: dict[str, object] = {
            "schema": "fkst.intent-diff-attestation.v1",
            "pr_number": 123,
            "base_sha": base_sha,
            "head_sha": head_sha,
            "manifest_path": relative_manifest,
            "manifest_blob_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            "manifest_sha256": artifact["manifest_sha256"],
            "semantic_tree_sha256": "f" * 64,
            "semantic_diff_sha256": semantic_diff_sha256(self.root, base_sha),
            "old_trace_sha256": ZERO_HASH,
            "new_trace_sha256": ZERO_HASH,
            "behavior_diff_sha256": ZERO_HASH,
            "result": "approved",
            "attestation_sha256": "",
        }
        attestation_body = dict(attestation)
        del attestation_body["attestation_sha256"]
        attestation["attestation_sha256"] = hashlib.sha256(
            canonical_json(attestation_body)
        ).hexdigest()
        write_json(self.root, f"{checker.INTENT_DIFF_DIR}/123-attestation.json", attestation)

        messages = checker.repository_messages(self.root)

        expected = semantic_tree_sha256(self.root)
        self.assertTrue(
            any(
                "semantic_tree_sha256 mismatch" in message and expected in message
                for message in messages
            )
        )


if __name__ == "__main__":
    unittest.main()
