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


def thinking_trace() -> dict[str, object]:
    artifact: dict[str, object] = {
        "schema": "restart-thinking-trace.v1",
        "owner": "github-devloop",
        "family": "thinking",
        "fixtures": [
            {
                "fixture_id": "source-equal-apply",
                "edge_id": "github-devloop/thinking/autonomous/consensus-reached",
                "cas_status": "apply",
                "reason_code": "apply",
                "cas_outcome": "applied",
                "effect_entitlement_id": "github-devloop/thinking/autonomous/consensus-reached/apply",
                "granted_effect_ids": [
                    "github-proxy.github_issue_comment_request",
                    "github-proxy.github_issue_label_request",
                ],
                "observable_writes": [
                    {
                        "ordinal": 1,
                        "effect_id": "github-proxy.github_issue_comment_request",
                        "write_kind": "comment",
                        "marker_write": True,
                    },
                    {
                        "ordinal": 2,
                        "effect_id": "github-proxy.github_issue_label_request",
                        "write_kind": "label",
                        "marker_write": False,
                    },
                ],
            }
        ],
        "artifact_sha256": "",
    }
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def issue_reconcile_trace() -> dict[str, object]:
    artifact = thinking_trace()
    artifact["schema"] = "restart-issue-reconcile-trace.v1"
    artifact["family"] = "issue-reconcile"
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    fixture["edge_id"] = "github-devloop/thinking/entry/issue_reconcile_true_stall"
    fixture["effect_entitlement_id"] = (
        "github-devloop/thinking/entry/issue_reconcile_true_stall/apply"
    )
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def loop_plain_trace() -> dict[str, object]:
    artifact = thinking_trace()
    artifact["schema"] = "restart-loop-plain-trace.v1"
    artifact["family"] = "loop-plain"
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    fixture["edge_id"] = "github-devloop/thinking/autonomous/consensus-stalled"
    fixture["effect_entitlement_id"] = (
        "github-devloop/thinking/autonomous/consensus-stalled/apply"
    )
    fixture["granted_effect_ids"] = ["github-proxy.github_issue_comment_request"]
    fixture["observable_writes"] = [fixture["observable_writes"][0]]
    fixture["observable_writes"][0]["marker_write"] = False
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def implement_activation_trace() -> dict[str, object]:
    artifact = thinking_trace()
    artifact["schema"] = "restart-implement-activation-trace.v1"
    artifact["family"] = "implement-activation"
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    fixture["edge_id"] = "github-devloop/ready/entry/implementation_kicked_off"
    fixture["effect_entitlement_id"] = (
        "github-devloop/ready/entry/implementation_kicked_off/apply"
    )
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def awaiting_pr_trace() -> dict[str, object]:
    artifact = thinking_trace()
    artifact["schema"] = "restart-awaiting-pr-trace.v1"
    artifact["family"] = "awaiting-pr"
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    edge_id = "github-devloop/awaiting-pr/canonicalization/implementing_merged_delegated_pr"
    fixture["edge_id"] = edge_id
    fixture["effect_entitlement_id"] = f"{edge_id}/apply"
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def timeout_reconcile_trace() -> dict[str, object]:
    artifact = thinking_trace()
    artifact["schema"] = "restart-timeout-reconcile-trace.v1"
    artifact["family"] = "timeout-reconcile"
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    edge_id = "github-devloop/ready/timeout/actionable_kickoff_timeout"
    fixture["edge_id"] = edge_id
    fixture["effect_entitlement_id"] = f"{edge_id}/apply"
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def observe_issue_entry_trace() -> dict[str, object]:
    artifact = thinking_trace()
    artifact["schema"] = "restart-observe-issue-entry-trace.v1"
    artifact["family"] = "observe-issue-entry"
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    edge_id = "github-devloop/thinking/entry/unmanaged_issue"
    fixture["fixture_id"] = "unmanaged-source-apply"
    fixture["edge_id"] = edge_id
    fixture["effect_entitlement_id"] = f"{edge_id}/apply"
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def pr_review_result_trace() -> dict[str, object]:
    artifact = thinking_trace()
    artifact["schema"] = "restart-pr-review-result-trace.v1"
    artifact["owner"] = "github-devloop-pr"
    artifact["family"] = "pr-review-result"
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    edge_id = "github-devloop-pr/reviewing/autonomous/changes_requested"
    fixture["edge_id"] = edge_id
    fixture["effect_entitlement_id"] = f"{edge_id}/apply"
    fixture["granted_effect_ids"][0] = "github-proxy.github_pr_comment_request"
    fixture["observable_writes"][0]["effect_id"] = "github-proxy.github_pr_comment_request"
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def pr_fix_trace() -> dict[str, object]:
    artifact = pr_review_result_trace()
    artifact["schema"] = "restart-pr-fix-trace.v1"
    artifact["family"] = "pr-fix"
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    edge_id = "github-devloop-pr/fixing/autonomous/revision_published"
    fixture["edge_id"] = edge_id
    fixture["effect_entitlement_id"] = f"{edge_id}/apply"
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


def idempotent_thinking_trace() -> dict[str, object]:
    artifact = thinking_trace()
    fixtures = artifact["fixtures"]
    assert isinstance(fixtures, list)
    fixture = fixtures[0]
    assert isinstance(fixture, dict)
    fixture["fixture_id"] = "target-incomplete-idempotent"
    fixture["cas_status"] = "idempotent"
    fixture["reason_code"] = "already-at-target"
    fixture["cas_outcome"] = "skip-idempotent(already at to_state)"
    fixture["effect_entitlement_id"] = (
        "github-devloop/thinking/autonomous/consensus-reached/idempotent"
    )
    fixture["observable_writes"] = []
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


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
        write_json(self.root, checker.THINKING_OLD_CORPUS, thinking_trace())
        write_json(self.root, checker.ISSUE_RECONCILE_OLD_CORPUS, issue_reconcile_trace())
        write_json(self.root, checker.LOOP_PLAIN_OLD_CORPUS, loop_plain_trace())
        write_json(
            self.root,
            checker.IMPLEMENT_ACTIVATION_OLD_CORPUS,
            implement_activation_trace(),
        )
        write_json(self.root, checker.AWAITING_PR_OLD_CORPUS, awaiting_pr_trace())
        write_json(
            self.root,
            checker.TIMEOUT_RECONCILE_OLD_CORPUS,
            timeout_reconcile_trace(),
        )

        write_json(
            self.root,
            checker.OBSERVE_ISSUE_ENTRY_OLD_CORPUS,
            observe_issue_entry_trace(),
        )
        write_json(
            self.root,
            checker.PR_REVIEW_RESULT_OLD_CORPUS,
            pr_review_result_trace(),
        )
        write_json(self.root, checker.PR_FIX_OLD_CORPUS, pr_fix_trace())

    def allow(self, relative_path: str) -> None:
        write(self.root, checker.ALLOWLIST, HEADER + relative_path + "\n")

    def test_clean_refactor_state_passes(self) -> None:
        self.assertEqual(checker.repository_messages(self.root), [])

    def test_missing_thinking_corpus_fails_closed(self) -> None:
        (self.root / checker.THINKING_OLD_CORPUS).unlink()

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("missing protected input" in message for message in messages))

    def test_thinking_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(self.root, checker.THINKING_NEW_TRACE, thinking_trace())

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_missing_issue_reconcile_corpus_fails_closed(self) -> None:
        (self.root / checker.ISSUE_RECONCILE_OLD_CORPUS).unlink()

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("missing protected input" in message for message in messages))

    def test_issue_reconcile_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root,
            checker.ISSUE_RECONCILE_NEW_TRACE,
            issue_reconcile_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_issue_reconcile_trace_output_mismatch_fails_closed(self) -> None:
        changed = issue_reconcile_trace()
        changed["artifact_sha256"] = "f" * 64
        write_json(self.root, checker.ISSUE_RECONCILE_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("artifact_sha256 mismatch" in message for message in messages))

    def test_loop_plain_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(self.root, checker.LOOP_PLAIN_NEW_TRACE, loop_plain_trace())

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_loop_plain_trace_output_mismatch_fails_closed(self) -> None:
        changed = loop_plain_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root, checker.LOOP_PLAIN_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("loop-plain trace canonical hash mismatch" in message for message in messages))

    def test_implement_activation_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root,
            checker.IMPLEMENT_ACTIVATION_NEW_TRACE,
            implement_activation_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_implement_activation_trace_output_mismatch_fails_closed(self) -> None:
        changed = implement_activation_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(
            self.root,
            checker.IMPLEMENT_ACTIVATION_NEW_TRACE,
            changed,
        )

        messages = checker.repository_messages(self.root)

        self.assertTrue(
            any("implement-activation trace canonical hash mismatch" in message for message in messages)
        )

    def test_awaiting_pr_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(self.root, checker.AWAITING_PR_NEW_TRACE, awaiting_pr_trace())

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_awaiting_pr_trace_output_mismatch_fails_closed(self) -> None:
        changed = awaiting_pr_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root, checker.AWAITING_PR_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("awaiting-pr trace canonical hash mismatch" in message for message in messages))

    def test_timeout_reconcile_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root,
            checker.TIMEOUT_RECONCILE_NEW_TRACE,
            timeout_reconcile_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_timeout_reconcile_trace_output_mismatch_fails_closed(self) -> None:
        changed = timeout_reconcile_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root, checker.TIMEOUT_RECONCILE_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any(
            "timeout-reconcile trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_observe_issue_entry_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root,
            checker.OBSERVE_ISSUE_ENTRY_NEW_TRACE,
            observe_issue_entry_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_observe_issue_entry_trace_output_mismatch_fails_closed(self) -> None:
        changed = observe_issue_entry_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root, checker.OBSERVE_ISSUE_ENTRY_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any(
            "observe-issue-entry trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_pr_review_result_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(
            self.root,
            checker.PR_REVIEW_RESULT_NEW_TRACE,
            pr_review_result_trace(),
        )

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_pr_review_result_trace_output_mismatch_fails_closed(self) -> None:
        changed = pr_review_result_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root, checker.PR_REVIEW_RESULT_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any(
            "pr-review-result trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_pr_fix_trace_output_with_equal_canonical_hash_passes(self) -> None:
        write_json(self.root, checker.PR_FIX_NEW_TRACE, pr_fix_trace())

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_pr_fix_trace_output_mismatch_fails_closed(self) -> None:
        changed = pr_fix_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root, checker.PR_FIX_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any(
            "pr-fix trace canonical hash mismatch" in message
            for message in messages
        ))

    def test_idempotent_admission_entitlement_has_no_admission_write(self) -> None:
        write_json(self.root, checker.THINKING_OLD_CORPUS, idempotent_thinking_trace())

        self.assertEqual(checker.repository_messages(self.root), [])

    def test_idempotent_post_admission_repair_write_is_rejected(self) -> None:
        artifact = idempotent_thinking_trace()
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
        write_json(self.root, checker.THINKING_OLD_CORPUS, artifact)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("idempotent admission must not include observable writes" in message for message in messages))

    def test_thinking_trace_output_mismatch_fails_closed(self) -> None:
        changed = thinking_trace()
        fixtures = changed["fixtures"]
        assert isinstance(fixtures, list)
        fixture = fixtures[0]
        assert isinstance(fixture, dict)
        fixture["cas_outcome"] = "skip-advanced-or-diverged"
        changed["artifact_sha256"] = canonical_artifact_hash_v1(changed)
        write_json(self.root, checker.THINKING_NEW_TRACE, changed)

        messages = checker.repository_messages(self.root)

        self.assertTrue(any("thinking trace canonical hash mismatch" in message for message in messages))

    def test_thinking_corpus_self_hash_is_protected(self) -> None:
        changed = thinking_trace()
        changed["artifact_sha256"] = "f" * 64
        write_json(self.root, checker.THINKING_OLD_CORPUS, changed)

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
