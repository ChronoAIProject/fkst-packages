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
import check_repo_intent_bounded_replay_test as trace_fixtures
import check_repo_intent_bounded_replay_trace_catalog as trace_catalog
from check_repo_intent_bounded_replay_spent_cases import IntentBoundedReplaySpentTest
from intent_bounded_replay.normalize import canonical_artifact_hash_v1, canonical_json
from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256


HEADER = "# R9 intent-bounded-replay: zero behavior-change intent-diffs during refactor.\n"


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
        "semantic_tree_sha256": trace_fixtures.ZERO_HASH,
        "semantic_diff_sha256": trace_fixtures.ZERO_HASH,
        "changed_row_ids": [],
        "changed_edge_ids": [],
        "changed_policy_ids": [],
        "old_trace_sha256": trace_fixtures.ZERO_HASH,
        "new_trace_sha256": trace_fixtures.ZERO_HASH,
        "behavior_diff_sha256": trace_fixtures.ZERO_HASH,
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
        write_json(self.root, trace_catalog.THINKING_OLD_CORPUS, trace_fixtures.thinking_trace())
        write_json(self.root, trace_catalog.ISSUE_RECONCILE_OLD_CORPUS, trace_fixtures.issue_reconcile_trace())
        write_json(self.root, trace_catalog.LOOP_PLAIN_OLD_CORPUS, trace_fixtures.loop_plain_trace())
        write_json(self.root, trace_catalog.IMPLEMENT_ACTIVATION_OLD_CORPUS, trace_fixtures.implement_activation_trace())
        write_json(self.root, trace_catalog.AWAITING_PR_OLD_CORPUS, trace_fixtures.awaiting_pr_trace())
        write_json(self.root, trace_catalog.TIMEOUT_RECONCILE_OLD_CORPUS, trace_fixtures.timeout_reconcile_trace())

        write_json(
            self.root,
            trace_catalog.OBSERVE_ISSUE_ENTRY_OLD_CORPUS,
            trace_fixtures.observe_issue_entry_trace(),
        )
        write_json(
            self.root,
            trace_catalog.PR_REVIEW_RESULT_OLD_CORPUS,
            trace_fixtures.pr_review_result_trace(),
        )
        write_json(
            self.root,
            trace_catalog.PR_REVIEW_META_OLD_CORPUS,
            trace_fixtures.pr_review_meta_trace(),
        )
        write_json(self.root, trace_catalog.PR_FIX_OLD_CORPUS, trace_fixtures.pr_fix_trace())
        write_json(
            self.root,
            trace_catalog.PR_REVIEW_ACTIVATION_OLD_CORPUS,
            trace_fixtures.pr_review_activation_trace(),
        )
        write_json(
            self.root,
            trace_catalog.OBSERVE_PR_FIX_OLD_CORPUS,
            trace_fixtures.observe_pr_fix_trace(),
        )
        write_json(
            self.root,
            trace_catalog.PR_REVIEW_LOOP_OLD_CORPUS,
            trace_fixtures.pr_review_loop_trace(),
        )
        write_json(
            self.root,
            trace_catalog.PR_FIX_RECONCILE_OLD_CORPUS,
            trace_fixtures.pr_fix_reconcile_trace(),
        )
        write_json(
            self.root,
            trace_catalog.PR_MERGE_OLD_CORPUS,
            trace_fixtures.pr_merge_trace(),
        )

    def allow(self, relative_path: str) -> None:
        write(self.root, checker.ALLOWLIST, HEADER + relative_path + "\n")

    def test_clean_refactor_state_passes(self) -> None:
        self.assertEqual(checker.repository_messages(self.root), [])

    def test_explicit_empty_trace_root_fails_closed(self) -> None:
        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any("explicit R9 trace root contains no emitted traces" in message for message in messages))

    def test_missing_thinking_corpus_fails_closed(self) -> None:
        (self.root / trace_catalog.THINKING_OLD_CORPUS).unlink()

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("missing protected input" in message for message in messages))

    def test_ambient_runtime_trace_is_not_an_implicit_checker_input(self) -> None:
        changed = trace_fixtures.thinking_trace()
        changed["fixtures"][0]["cas_outcome"] = "poisoned-ambient-runtime-trace"  # type: ignore[index]
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.THINKING_NEW_TRACE, changed)

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_missing_issue_reconcile_corpus_fails_closed(self) -> None:
        (self.root / trace_catalog.ISSUE_RECONCILE_OLD_CORPUS).unlink()

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("missing protected input" in message for message in messages))

    def test_issue_reconcile_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.ISSUE_RECONCILE_NEW_TRACE,
            trace_fixtures.issue_reconcile_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_issue_reconcile_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.issue_reconcile_trace()
        changed["artifact_sha256"] = "f" * 64
        write_json(self.root / ".fkst/run", trace_catalog.ISSUE_RECONCILE_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any("artifact_sha256 mismatch" in message for message in messages))

    def test_loop_plain_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(self.root / ".fkst/run", trace_catalog.LOOP_PLAIN_NEW_TRACE, trace_fixtures.loop_plain_trace())

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_loop_plain_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.loop_plain_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.LOOP_PLAIN_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any("loop-plain trace canonical hash mismatch" in message for message in messages))

    def test_implement_activation_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.IMPLEMENT_ACTIVATION_NEW_TRACE,
            trace_fixtures.implement_activation_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_implement_activation_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.implement_activation_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(
            self.root / ".fkst/run",
            trace_catalog.IMPLEMENT_ACTIVATION_NEW_TRACE,
            changed,
        )

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(
            any("implement-activation trace canonical hash mismatch" in message for message in messages)
        )

    def test_awaiting_pr_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(self.root / ".fkst/run", trace_catalog.AWAITING_PR_NEW_TRACE, trace_fixtures.awaiting_pr_trace())

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_awaiting_pr_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.awaiting_pr_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.AWAITING_PR_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any("awaiting-pr trace canonical hash mismatch" in message for message in messages))

    def test_timeout_reconcile_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.TIMEOUT_RECONCILE_NEW_TRACE,
            trace_fixtures.timeout_reconcile_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_timeout_reconcile_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.timeout_reconcile_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.TIMEOUT_RECONCILE_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "timeout-reconcile trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_observe_issue_entry_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.OBSERVE_ISSUE_ENTRY_NEW_TRACE,
            trace_fixtures.observe_issue_entry_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_observe_issue_entry_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.observe_issue_entry_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.OBSERVE_ISSUE_ENTRY_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "observe-issue-entry trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_pr_review_result_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.PR_REVIEW_RESULT_NEW_TRACE,
            trace_fixtures.pr_review_result_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_pr_review_result_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.pr_review_result_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.PR_REVIEW_RESULT_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "pr-review-result trace canonical hash mismatch" in message
            for message in messages
        ))
    def test_pr_review_meta_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.PR_REVIEW_META_NEW_TRACE,
            trace_fixtures.pr_review_meta_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_pr_review_meta_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.pr_review_meta_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.PR_REVIEW_META_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "pr-review-meta trace canonical hash mismatch" in message
            for message in messages
        ))
    def test_pr_fix_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(self.root / ".fkst/run", trace_catalog.PR_FIX_NEW_TRACE, trace_fixtures.pr_fix_trace())

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_pr_fix_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.pr_fix_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.PR_FIX_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "pr-fix trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_pr_review_activation_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.PR_REVIEW_ACTIVATION_NEW_TRACE,
            trace_fixtures.pr_review_activation_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_pr_review_activation_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.pr_review_activation_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.PR_REVIEW_ACTIVATION_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "pr-review-activation trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_observe_pr_fix_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.OBSERVE_PR_FIX_NEW_TRACE,
            trace_fixtures.observe_pr_fix_trace(),
        )
        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_pr_review_loop_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.PR_REVIEW_LOOP_NEW_TRACE,
            trace_fixtures.pr_review_loop_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_pr_review_loop_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.pr_review_loop_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.PR_REVIEW_LOOP_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "pr-review-loop trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_pr_fix_reconcile_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.PR_FIX_RECONCILE_NEW_TRACE,
            trace_fixtures.pr_fix_reconcile_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_pr_fix_reconcile_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.pr_fix_reconcile_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.PR_FIX_RECONCILE_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "pr-fix-reconcile trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_pr_merge_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root / ".fkst/run",
            trace_catalog.PR_MERGE_NEW_TRACE,
            trace_fixtures.pr_merge_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root, trace_root=self.root / ".fkst/run"), [])

    def test_pr_merge_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.pr_merge_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.PR_MERGE_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any(
            "pr-merge trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_idempotent_admission_entitlement_has_no_admission_write(self) -> None:
        write_json(self.root, trace_catalog.THINKING_OLD_CORPUS, trace_fixtures.idempotent_thinking_trace())

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_idempotent_post_admission_repair_write_is_rejected(self) -> None:
        artifact = trace_fixtures.idempotent_thinking_trace()
        fixtures = artifact["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["observable_writes"] = [
            {
                "ordinal": 1,
                "effect_id": "github-proxy.github_issue_comment_request",
                "write_kind": "comment",
                "marker_write": True,
            }
        ]
        artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
        write_json(self.root, trace_catalog.THINKING_OLD_CORPUS, artifact)

        messages = checker.repository_messages(self.root)

        # After the precursor relaxation, idempotent observable writes are allowed only when they
        # exactly equal the edge's declared idempotent entitlement; an isolated post-admission
        # repair write (a single comment that does not match the full entitlement) is rejected by
        # the exact-match check rather than by a blanket no-writes rule.
        self.assertTrue(any("granted_effect_ids must equal observable write order" in message for message in messages))

    def test_thinking_trace_output_mismatch_fails_closed(self) -> None:
        changed = trace_fixtures.thinking_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root / ".fkst/run", trace_catalog.THINKING_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root, trace_root=self.root / ".fkst/run")

        self.assertTrue(any("thinking trace canonical hash mismatch" in message for message in messages))

    def test_thinking_corpus_self_hash_is_protected(self) -> None:
        changed = trace_fixtures.thinking_trace()
        changed["artifact_sha256"] = "f" * 64
        write_json(self.root, trace_catalog.THINKING_OLD_CORPUS, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("artifact_sha256 mismatch" in message for message in messages))

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
            "old_trace_sha256": trace_fixtures.ZERO_HASH,
            "new_trace_sha256": trace_fixtures.ZERO_HASH,
            "behavior_diff_sha256": trace_fixtures.ZERO_HASH,
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
