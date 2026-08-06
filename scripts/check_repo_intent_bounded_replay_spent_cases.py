"""Focused spent-manifest cases for the intent-bounded-replay checker suite."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import check_repo_intent_bounded_replay as checker
from intent_bounded_replay.normalize import canonical_artifact_hash_v1
from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256


HEADER = "# R9 intent-bounded-replay: zero behavior-change intent-diffs during refactor.\n"
ZERO_HASH = "0" * 64
PR_NUMBER = 123
MANIFEST_PATH = f"{checker.INTENT_DIFF_DIR}/{PR_NUMBER}.json"


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


def write(root: Path, relative: str, content: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def manifest(base_sha: str) -> dict[str, object]:
    artifact: dict[str, object] = {
        "schema": "fkst.intent-diff.v2",
        "intent": "behavior-change",
        "pr_number": PR_NUMBER,
        "base_sha": base_sha,
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
        "one_use_identity": f"{PR_NUMBER}/{base_sha}/{ZERO_HASH}/{ZERO_HASH}",
        "manifest_sha256": "",
    }
    artifact["manifest_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


class IntentBoundedReplaySpentTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "r9-spent@example.invalid")
        git(self.root, "config", "user.name", "R9 Spent Test")
        for relative in checker.PROTECTED_MODULES:
            write(self.root, relative, "# protected fixture\n")
        write(self.root, checker.ALLOWLIST, HEADER)
        write(self.root, f"{checker.INTENT_DIFF_DIR}/.gitkeep", "")
        self.protected_base = commit(self.root, "protected base")

    def allow(self, artifact: dict[str, object]) -> None:
        write(self.root, checker.ALLOWLIST, HEADER + MANIFEST_PATH + "\n")
        write(self.root, MANIFEST_PATH, json.dumps(artifact, sort_keys=True) + "\n")

    def messages(self) -> list[str]:
        with (
            mock.patch.object(checker, "_admission_trace_messages", return_value=[]),
            mock.patch.object(checker, "_protected_base_sha", return_value=self.protected_base),
        ):
            return checker.repository_messages(self.root, enforce_base=True)

    def test_spent_manifest_contained_in_protected_base_produces_no_messages(self) -> None:
        artifact = manifest(self.protected_base)
        self.allow(artifact)
        commit(self.root, f"land behavior change (#{PR_NUMBER})")
        (self.root / MANIFEST_PATH).unlink()
        write(self.root, checker.ALLOWLIST, HEADER)
        self.protected_base = commit(self.root, "retire spent manifest")
        self.allow(artifact)

        self.assertEqual(self.messages(), [])

    def test_live_manifest_with_mismatched_base_keeps_exact_failures(self) -> None:
        artifact = manifest("1" * 40)
        self.allow(artifact)
        actual_tree = semantic_tree_sha256(self.root)
        actual_diff = semantic_diff_sha256(self.root, self.protected_base)

        self.assertEqual(
            self.messages(),
            [
                f"{MANIFEST_PATH} base_sha must equal protected merge-base {self.protected_base}",
                f"{MANIFEST_PATH} semantic_tree_sha256 mismatch: declared {ZERO_HASH}, computed {actual_tree}",
                f"{MANIFEST_PATH} semantic_diff_sha256 mismatch: declared {ZERO_HASH}, computed {actual_diff}",
                f"{MANIFEST_PATH} grows {checker.ALLOWLIST} relative to the protected base",
            ],
        )

    def test_live_manifest_with_mismatched_hashes_still_fails(self) -> None:
        artifact = manifest(self.protected_base)
        self.allow(artifact)
        actual_tree = semantic_tree_sha256(self.root)
        actual_diff = semantic_diff_sha256(self.root, self.protected_base)

        self.assertEqual(
            self.messages(),
            [
                f"{MANIFEST_PATH} semantic_tree_sha256 mismatch: declared {ZERO_HASH}, computed {actual_tree}",
                f"{MANIFEST_PATH} semantic_diff_sha256 mismatch: declared {ZERO_HASH}, computed {actual_diff}",
                f"{MANIFEST_PATH} grows {checker.ALLOWLIST} relative to the protected base",
            ],
        )
