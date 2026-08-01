#!/usr/bin/env python3
"""Tests for verifier-owned intent-diff trace attestation."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

import generate_intent_diff_attestation as generator
from intent_bounded_replay.attestation import (
    AttestationError,
    TRACE_PAIRS,
    TracePair,
    canonical_attestation_sha256,
    recompute_trace_hashes,
)
from intent_bounded_replay.normalize import (
    canonical_artifact_hash_v1,
    canonical_json,
)
from intent_bounded_replay.semantic_tree import (
    semantic_diff_sha256,
    semantic_tree_sha256,
)


PAIR = TracePair(
    family="example",
    old_path="migration/intent_bounded_replay/corpus/example.json",
    new_path=".fkst/run/r9-example-new-trace.json",
    schema="example-trace.v1",
    owner="example-owner",
)


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=root, check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def write_json(root: Path, relative: str, value: object) -> Path:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(value) + b"\n")
    return path


def trace(value: str) -> dict[str, object]:
    artifact: dict[str, object] = {
        "schema": PAIR.schema,
        "owner": PAIR.owner,
        "family": PAIR.family,
        "value": value,
        "artifact_sha256": "",
    }
    artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
    return artifact


class TraceAggregationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_recomputes_deterministic_aggregate_and_behavior_diff_hashes(self) -> None:
        old = trace("old")
        new = trace("new")
        write_json(self.root, PAIR.old_path, old)
        write_json(self.root, PAIR.new_path, new)

        actual = recompute_trace_hashes(self.root, (PAIR,))

        old_hash = canonical_artifact_hash_v1(old)
        new_hash = canonical_artifact_hash_v1(new)
        old_set = {
            "schema": "fkst.intent-diff-trace-set.v1",
            "traces": [{"family": PAIR.family, "trace_sha256": old_hash}],
        }
        new_set = {
            "schema": "fkst.intent-diff-trace-set.v1",
            "traces": [{"family": PAIR.family, "trace_sha256": new_hash}],
        }
        behavior_diff = {
            "schema": "fkst.intent-diff-behavior-diff.v1",
            "comparisons": [
                {
                    "equal": False,
                    "family": PAIR.family,
                    "first_divergence": "/value",
                    "new_trace_sha256": new_hash,
                    "old_trace_sha256": old_hash,
                }
            ],
        }
        self.assertEqual(
            actual,
            {
                "old_trace_sha256": canonical_artifact_hash_v1(old_set),
                "new_trace_sha256": canonical_artifact_hash_v1(new_set),
                "behavior_diff_sha256": canonical_artifact_hash_v1(behavior_diff),
            },
        )

    def test_missing_emitted_trace_fails_closed(self) -> None:
        write_json(self.root, PAIR.old_path, trace("old"))

        with self.assertRaisesRegex(AttestationError, PAIR.new_path):
            recompute_trace_hashes(self.root, (PAIR,))

    def test_every_canonical_new_trace_has_a_package_test_emitter(self) -> None:
        repo_root = Path(__file__).resolve().parents[1]
        test_sources = {
            path: path.read_text(encoding="utf-8")
            for path in sorted((repo_root / "packages").glob("*/tests/*.lua"))
        }

        for pair in TRACE_PAIRS:
            with self.subTest(family=pair.family):
                emitters = [
                    path
                    for path, source in test_sources.items()
                    if pair.new_path in source and "file.write(" in source
                ]
                self.assertNotEqual(
                    emitters,
                    [],
                    f"missing package test emitter for {pair.family}: {pair.new_path}",
                )


class AttestationGenerationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "attestation@example.invalid")
        git(self.root, "config", "user.name", "Attestation Test")
        (self.root / ".gitignore").write_text("/.fkst/run/\n", encoding="utf-8")
        write_json(self.root, PAIR.old_path, trace("old"))
        (self.root / "tracked.txt").write_text("base\n", encoding="utf-8")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "base")
        self.base_sha = git(self.root, "rev-parse", "HEAD")
        git(self.root, "branch", "protected-base")
        (self.root / "tracked.txt").write_text("behavior change\n", encoding="utf-8")
        git(self.root, "add", "tracked.txt")
        git(self.root, "commit", "-qm", "behavior change")
        write_json(self.root, PAIR.new_path, trace("new"))

    def add_manifest(
        self,
        pr_number: int = 123,
        trace_hashes: dict[str, str] | None = None,
    ) -> dict[str, object]:
        if trace_hashes is None:
            trace_hashes = recompute_trace_hashes(self.root, (PAIR,))
        tree_hash = semantic_tree_sha256(self.root)
        diff_hash = semantic_diff_sha256(self.root, self.base_sha)
        manifest: dict[str, object] = {
            "schema": "fkst.intent-diff.v2",
            "intent": "behavior-change",
            "pr_number": pr_number,
            "base_sha": self.base_sha,
            "semantic_tree_sha256": tree_hash,
            "semantic_diff_sha256": diff_hash,
            "changed_row_ids": [],
            "changed_edge_ids": [],
            "changed_policy_ids": [],
            **trace_hashes,
            "cause": "bounded test behavior change",
            "review_reference": "review:test",
            "one_use_identity": f"{pr_number}/{self.base_sha}/{tree_hash}/{diff_hash}",
            "manifest_sha256": "",
        }
        manifest["manifest_sha256"] = canonical_artifact_hash_v1(manifest)
        write_json(self.root, f"migration/intent-diffs/{pr_number}.json", manifest)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "intent manifest")
        return manifest

    def generate(
        self,
        pr_number: int = 123,
        head_ref: str = "HEAD",
    ) -> dict[str, object] | None:
        output_dir = self.root / ".fkst/run/intent-diff-attestations"
        return generator.generate_attestation(
            root=self.root,
            pr_number=pr_number,
            base_ref="protected-base",
            head_ref=head_ref,
            output_dir=output_dir,
            trace_pairs=(PAIR,),
        )

    def test_generates_manifest_bound_head_attestation_from_recomputed_traces(self) -> None:
        manifest = self.add_manifest()

        artifact = self.generate()

        self.assertIsNotNone(artifact)
        assert artifact is not None
        output = self.root / ".fkst/run/intent-diff-attestations/123.json"
        self.assertEqual(output.read_bytes(), canonical_json(artifact) + b"\n")
        self.assertEqual(artifact["head_sha"], git(self.root, "rev-parse", "HEAD"))
        self.assertEqual(artifact["base_sha"], self.base_sha)
        self.assertEqual(artifact["manifest_sha256"], manifest["manifest_sha256"])
        self.assertEqual(
            artifact["manifest_blob_sha256"],
            hashlib.sha256((self.root / "migration/intent-diffs/123.json").read_bytes()).hexdigest(),
        )
        self.assertEqual(artifact["result"], "approved")
        self.assertEqual(artifact["attestation_sha256"], canonical_attestation_sha256(artifact))

    def test_changed_trace_cannot_reuse_manifest_declaration(self) -> None:
        self.add_manifest()
        write_json(self.root, PAIR.new_path, trace("tampered after manifest"))

        with self.assertRaisesRegex(AttestationError, "new_trace_sha256 mismatch"):
            self.generate()

    def test_checkout_commit_must_match_attested_head(self) -> None:
        self.add_manifest()
        git(self.root, "branch", "different-head", self.base_sha)

        with self.assertRaisesRegex(
            AttestationError,
            "checked out commit .* does not match attested head",
        ):
            self.generate(head_ref="different-head")

    def test_old_trace_is_loaded_from_protected_base(self) -> None:
        base_trace_hashes = recompute_trace_hashes(self.root, (PAIR,))
        write_json(self.root, PAIR.old_path, trace("head-controlled old trace"))
        git(self.root, "add", PAIR.old_path)
        git(self.root, "commit", "-qm", "change old corpus in head")
        manifest = self.add_manifest(trace_hashes=base_trace_hashes)

        artifact = self.generate()

        self.assertIsNotNone(artifact)
        assert artifact is not None
        self.assertEqual(artifact["old_trace_sha256"], base_trace_hashes["old_trace_sha256"])
        self.assertEqual(manifest["old_trace_sha256"], base_trace_hashes["old_trace_sha256"])

    def test_changed_manifest_must_match_actual_pr_number(self) -> None:
        self.add_manifest(pr_number=124)

        with self.assertRaisesRegex(AttestationError, "actual PR 123"):
            self.generate(pr_number=123)

    def test_deleted_manifest_fails_closed(self) -> None:
        self.add_manifest()
        git(self.root, "branch", "-f", "protected-base", "HEAD")
        (self.root / "migration/intent-diffs/123.json").unlink()
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "delete intent manifest")

        with self.assertRaisesRegex(AttestationError, "missing intent-diff manifest"):
            self.generate()

    def test_pr_without_changed_manifest_has_no_attestation_claim(self) -> None:
        self.assertIsNone(self.generate())
        self.assertFalse((self.root / ".fkst/run/intent-diff-attestations/123.json").exists())

    def test_pr_without_changed_manifest_still_requires_trace_evidence(self) -> None:
        (self.root / PAIR.new_path).unlink()

        with self.assertRaisesRegex(AttestationError, "missing trace artifact"):
            self.generate()


if __name__ == "__main__":
    unittest.main()
