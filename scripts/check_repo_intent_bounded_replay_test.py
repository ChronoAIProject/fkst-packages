#!/usr/bin/env python3
"""Unit tests for the R9 canonical artifact hashing foundation."""

from __future__ import annotations

from decimal import Decimal
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import check_repo_intent_bounded_replay as checker
from check_repo_intent_bounded_replay import _admission_trace_shape_messages
from intent_bounded_replay.compare import artifacts_equal, compare_report
from intent_bounded_replay.normalize import (
    canonical_artifact_hash_v1,
    canonical_json,
    loads_json,
)
from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256


ZERO_HASH = "0" * 64
ALLOWLIST_HEADER = "# protected allowlist\n"


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=root, check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


class CanonicalJsonTest(unittest.TestCase):
    def test_object_keys_are_sorted_by_utf8_bytes(self) -> None:
        first = {"b": 1, "a": 2}
        second = {"a": 2, "b": 1}

        self.assertEqual(canonical_json(first), b'{"a":2,"b":1}')
        self.assertEqual(
            canonical_artifact_hash_v1(first),
            canonical_artifact_hash_v1(second),
        )
        # UTF-8 byte ordering puts ASCII z before the first byte of non-ASCII e-acute.
        self.assertEqual(
            canonical_artifact_hash_v1(first),
            "d3626ac30a87e6f7a6428233b3c68299976865fa5508e4267c5415c76af7a772",
        )
        self.assertEqual(canonical_json({"\u00e9": 1, "z": 2}), b'{"z":2,"\xc3\xa9":1}')

    def test_array_order_is_preserved(self) -> None:
        self.assertNotEqual(
            canonical_artifact_hash_v1([1, 2]),
            canonical_artifact_hash_v1([2, 1]),
        )

    def test_insignificant_input_formatting_does_not_affect_hash(self) -> None:
        formatted = loads_json('{\n  "b": 1.00,\n  "a": [true, null]\n}')
        compact = loads_json('{"a":[true,null],"b":1}')

        self.assertEqual(
            canonical_artifact_hash_v1(formatted),
            canonical_artifact_hash_v1(compact),
        )

    def test_duplicate_object_keys_are_rejected_before_information_is_lost(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
            loads_json('{"same":1,"same":2}')

    def test_numbers_use_minimal_exponent_free_decimal_form(self) -> None:
        variants = [1, 1.0, loads_json("1.00")]
        hundreds = [100, 1e2, loads_json("1e2")]

        self.assertEqual({canonical_json(value) for value in variants}, {b"1"})
        self.assertEqual({canonical_json(value) for value in hundreds}, {b"100"})
        self.assertEqual(canonical_json(-0.0), b"0")
        self.assertEqual(canonical_json(loads_json("0.0012300")), b"0.00123")

    def test_non_finite_numbers_are_rejected(self) -> None:
        for value in (math.nan, math.inf, -math.inf):
            with self.subTest(value=value), self.assertRaises(ValueError):
                canonical_json(value)


class ArtifactHashTest(unittest.TestCase):
    def test_artifact_own_self_hash_value_is_omitted(self) -> None:
        for field in ("artifact_sha256", "manifest_sha256", "attestation_sha256"):
            with self.subTest(field=field):
                first = {"schema": "example.v1", "value": 7, field: "old"}
                second = {"schema": "example.v1", "value": 7, field: "new"}

                self.assertEqual(
                    canonical_artifact_hash_v1(first),
                    canonical_artifact_hash_v1(second),
                )
                self.assertEqual(first[field], "old")
                self.assertEqual(second[field], "new")

    def test_more_than_one_top_level_self_hash_field_is_rejected(self) -> None:
        artifact = {
            "schema": "example.v1",
            "artifact_sha256": "a",
            "manifest_sha256": "b",
        }

        with self.assertRaisesRegex(ValueError, "multiple self-hash fields"):
            canonical_artifact_hash_v1(artifact)

    def test_nested_hash_references_are_not_omitted(self) -> None:
        first = {"schema": "example.v1", "child": {"artifact_sha256": "a"}}
        second = {"schema": "example.v1", "child": {"artifact_sha256": "b"}}

        self.assertNotEqual(
            canonical_artifact_hash_v1(first),
            canonical_artifact_hash_v1(second),
        )

    def test_schema_and_version_are_included(self) -> None:
        baseline = {"schema": "example.v1", "version": 1, "value": "same"}

        self.assertNotEqual(
            canonical_artifact_hash_v1(baseline),
            canonical_artifact_hash_v1({**baseline, "schema": "example.v2"}),
        )
        self.assertNotEqual(
            canonical_artifact_hash_v1(baseline),
            canonical_artifact_hash_v1({**baseline, "version": 2}),
        )


class ManifestGrowthAdmissionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "intent@example.invalid")
        git(self.root, "config", "user.name", "Intent Test")
        for relative in checker.PROTECTED_MODULES:
            self.write(relative, "# protected fixture\n")
        self.write(checker.ALLOWLIST, ALLOWLIST_HEADER)
        self.write(f"{checker.INTENT_DIFF_DIR}/.gitkeep", "")
        self.write("tracked.txt", "base\n")
        self.base = self.commit("base")

    def write(self, relative: str, content: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, message: str) -> str:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", message)
        return git(self.root, "rev-parse", "HEAD")

    def add_growth(self, entries: list[int] | None = None) -> None:
        numbers = entries or [123]
        paths = [f"{checker.INTENT_DIFF_DIR}/{number}.json" for number in numbers]
        self.write(checker.ALLOWLIST, ALLOWLIST_HEADER + "\n".join(paths) + "\n")
        self.write("tracked.txt", "behavior change\n")
        self.commit("behavior")

    def manifest(self, pr_number: int = 123, **overrides: object) -> dict[str, object]:
        tree_hash = semantic_tree_sha256(self.root)
        diff_hash = semantic_diff_sha256(self.root, self.base)
        artifact: dict[str, object] = {
            "schema": "fkst.intent-diff.v2",
            "intent": "behavior-change",
            "pr_number": pr_number,
            "base_sha": self.base,
            "semantic_tree_sha256": tree_hash,
            "semantic_diff_sha256": diff_hash,
            "changed_row_ids": [],
            "changed_edge_ids": [],
            "changed_policy_ids": [],
            "old_trace_sha256": ZERO_HASH,
            "new_trace_sha256": ZERO_HASH,
            "behavior_diff_sha256": ZERO_HASH,
            "cause": "bounded test change",
            "review_reference": "review:test",
            "one_use_identity": f"{pr_number}/{self.base}/{tree_hash}/{diff_hash}",
            "manifest_sha256": "",
        }
        artifact.update(overrides)
        artifact["manifest_sha256"] = canonical_artifact_hash_v1(artifact)
        return artifact

    def write_manifest(self, artifact: dict[str, object]) -> None:
        number = int(artifact["pr_number"])
        self.write(
            f"{checker.INTENT_DIFF_DIR}/{number}.json",
            json.dumps(artifact, sort_keys=True) + "\n",
        )
        self.commit(f"manifest {number}")

    def messages(self) -> list[str]:
        with mock.patch.object(checker, "_admission_trace_messages", return_value=[]), mock.patch.dict(
            os.environ, {"FKST_RESTART_PREFLIGHT_BASE_REF": self.base}, clear=False,
        ):
            return checker.repository_messages(self.root, enforce_base=True)

    def test_unmanifested_allowlist_growth_preserves_current_rejection(self) -> None:
        self.add_growth()
        self.assertIn(
            f"{checker.INTENT_DIFF_DIR}/123.json grows {checker.ALLOWLIST} relative to the protected base",
            self.messages(),
        )

    def test_post_terminal_valid_manifest_growth_is_admitted(self) -> None:
        self.add_growth()
        self.write_manifest(self.manifest())
        self.assertEqual(self.messages(), [])

    def test_during_refactor_valid_manifest_growth_is_forbidden(self) -> None:
        self.write("libraries/devloop/restart_effect_seal.lua", "return {}\n")
        self.commit("retain old authority")
        self.add_growth()
        self.write_manifest(self.manifest())
        self.assertIn(
            f"{checker.INTENT_DIFF_DIR}/123.json grows {checker.ALLOWLIST} relative to the protected base",
            self.messages(),
        )

    def test_malformed_manifest_does_not_admit_growth(self) -> None:
        self.add_growth()
        artifact = self.manifest()
        del artifact["review_reference"]
        artifact["manifest_sha256"] = canonical_artifact_hash_v1(artifact)
        self.write_manifest(artifact)
        self.assertTrue(any("grows" in message for message in self.messages()))

    def test_mis_self_hashed_manifest_does_not_admit_growth(self) -> None:
        self.add_growth()
        artifact = self.manifest()
        artifact["manifest_sha256"] = "f" * 64
        self.write_manifest(artifact)
        self.assertTrue(any("grows" in message for message in self.messages()))

    def test_wrong_base_manifest_does_not_admit_growth(self) -> None:
        self.add_growth()
        artifact = self.manifest(base_sha="f" * 40)
        self.write_manifest(artifact)
        self.assertTrue(any("grows" in message for message in self.messages()))

    def test_reused_one_use_identity_does_not_admit_growth(self) -> None:
        self.add_growth([123, 124])
        first = self.manifest(123)
        reused = self.manifest(124, one_use_identity=first["one_use_identity"])
        self.write_manifest(first)
        self.write_manifest(reused)
        messages = self.messages()
        self.assertTrue(any("one_use_identity" in message for message in messages))
        self.assertTrue(any("grows" in message for message in messages))


class ProtectedBaseSelectionTest(unittest.TestCase):
    def test_intent_replay_uses_github_target_merge_base_before_dev(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init", "-q")
            git(root, "config", "user.email", "intent@example.invalid")
            git(root, "config", "user.name", "Intent Test")
            (root / "base.txt").write_text("dev\n", encoding="utf-8")
            git(root, "add", "base.txt")
            git(root, "commit", "-qm", "dev")
            dev_commit = git(root, "rev-parse", "HEAD")
            git(root, "update-ref", "refs/remotes/origin/dev", dev_commit)
            (root / "base.txt").write_text("integration\n", encoding="utf-8")
            git(root, "commit", "-qam", "integration")
            integration_commit = git(root, "rev-parse", "HEAD")
            git(root, "update-ref", "refs/remotes/origin/integration", integration_commit)
            (root / "head.txt").write_text("feature\n", encoding="utf-8")
            git(root, "add", "head.txt")
            git(root, "commit", "-qm", "feature")

            with mock.patch.dict(
                os.environ,
                {
                    "FKST_RESTART_PREFLIGHT_BASE_REF": "",
                    "FKST_RATCHET_TARGET_REF": "",
                    "GITHUB_BASE_REF": "integration",
                },
                clear=False,
            ):
                self.assertEqual(checker._protected_base_sha(root), integration_commit)

    def test_unresolved_target_does_not_fall_back_to_dev(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init", "-q")
            git(root, "config", "user.email", "intent@example.invalid")
            git(root, "config", "user.name", "Intent Test")
            for relative in checker.PROTECTED_MODULES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("# protected fixture\n", encoding="utf-8")
            allowlist = root / checker.ALLOWLIST
            allowlist.parent.mkdir(parents=True, exist_ok=True)
            allowlist.write_text(ALLOWLIST_HEADER, encoding="utf-8")
            intent_diff_dir = root / checker.INTENT_DIFF_DIR
            intent_diff_dir.mkdir(parents=True, exist_ok=True)
            (intent_diff_dir / ".gitkeep").write_text("", encoding="utf-8")
            git(root, "add", "-A")
            git(root, "commit", "-qm", "dev")
            dev_commit = git(root, "rev-parse", "HEAD")
            git(root, "update-ref", "refs/remotes/origin/dev", dev_commit)

            with mock.patch.object(checker, "_admission_trace_messages", return_value=[]), mock.patch.dict(
                os.environ,
                {
                    "FKST_RESTART_PREFLIGHT_BASE_REF": "",
                    "FKST_RATCHET_TARGET_REF": "refs/remotes/origin/missing",
                },
                clear=False,
            ):
                messages = checker.repository_messages(root, enforce_base=True)

            self.assertIn(
                f"cannot resolve protected base {checker.ALLOWLIST} to enforce the shrink-only ratchet",
                messages,
            )


class CompareTest(unittest.TestCase):
    def test_identical_artifacts_compare_equal(self) -> None:
        old = {"schema": "example.v1", "values": [1, 2], "artifact_sha256": "old"}
        new = {"values": [1.0, 2.00], "artifact_sha256": "new", "schema": "example.v1"}

        self.assertTrue(artifacts_equal(old, new))
        report = compare_report(old, new)
        self.assertTrue(report["equal"])
        self.assertEqual(report["old_hash"], report["new_hash"])
        self.assertNotIn("first_divergence", report)

    def test_difference_report_points_to_first_canonical_difference(self) -> None:
        old = {"schema": "example.v1", "payload": {"count": 1, "name": "same"}}
        new = {"schema": "example.v1", "payload": {"count": 2, "name": "same"}}

        self.assertFalse(artifacts_equal(old, new))
        report = compare_report(old, new)
        self.assertFalse(report["equal"])
        self.assertNotEqual(report["old_hash"], report["new_hash"])
        self.assertEqual(report["first_divergence"], "/payload/count")


class AdmissionTraceShapeTest(unittest.TestCase):
    @staticmethod
    def artifact(
        status: str,
        effect_ids: list[str],
        writes: list[dict[str, object]],
        entitlement_id: str | None = "owner/edge/idempotent",
    ) -> dict[str, object]:
        artifact: dict[str, object] = {
            "schema": "restart-example-trace.v1",
            "owner": "github-devloop",
            "family": "example",
            "fixtures": [
                {
                    "fixture_id": "fixture",
                    "edge_id": "owner/edge",
                    "cas_status": status,
                    "reason_code": "reason",
                    "cas_outcome": "outcome",
                    "effect_entitlement_id": entitlement_id,
                    "granted_effect_ids": effect_ids,
                    "observable_writes": writes,
                }
            ],
            "artifact_sha256": "0" * 64,
        }
        artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
        return artifact

    @staticmethod
    def write(ordinal: int, effect_id: str) -> dict[str, object]:
        return {
            "ordinal": Decimal(ordinal),
            "effect_id": effect_id,
            "write_kind": "queue",
            "marker_write": False,
        }

    def messages(self, artifact: dict[str, object]) -> list[str]:
        return _admission_trace_shape_messages(
            artifact,
            "trace.json",
            "restart-example-trace.v1",
            "example",
        )

    def test_captured_sink_effects_is_active_in_trace_hash(self) -> None:
        artifact = self.artifact("pending", [], [], entitlement_id=None)
        shadow_hash = artifact["artifact_sha256"]
        artifact["captured_sink_effects"] = [
            {
                "effect_id": "codex.dispatch:fix",
                "old_callsite": "packages/github-devloop-pr/departments/fix/main.lua:248",
                "old_probe_ids": ["entry-fix-new-fix-push-routes-reviewing"],
                "ordinal": Decimal(1),
                "owning_effect_entitlement_ids": [
                    "github-devloop-pr/fixing/autonomous/revision_published/apply"
                ],
                "sink_kind": "codex",
            }
        ]
        active_hash = canonical_artifact_hash_v1(artifact)
        self.assertNotEqual(active_hash, shadow_hash)
        artifact["artifact_sha256"] = active_hash
        self.assertEqual(self.messages(artifact), [])

    def test_idempotent_writes_may_exactly_equal_declared_entitlement(self) -> None:
        effect_ids = ["queue.one", "queue.two"]
        artifact = self.artifact(
            "idempotent",
            effect_ids,
            [self.write(index, effect_id) for index, effect_id in enumerate(effect_ids, 1)],
        )

        self.assertEqual(self.messages(artifact), [])

    def test_idempotent_writes_must_not_be_a_subset_of_declared_entitlement(self) -> None:
        artifact = self.artifact(
            "idempotent",
            ["queue.one", "queue.two"],
            [self.write(1, "queue.one")],
        )

        self.assertTrue(
            any("granted_effect_ids must equal observable write order" in message for message in self.messages(artifact))
        )

    def test_idempotent_writes_require_a_declared_entitlement(self) -> None:
        artifact = self.artifact(
            "idempotent",
            ["queue.one"],
            [self.write(1, "queue.one")],
            entitlement_id=None,
        )

        self.assertTrue(
            any("idempotent observable writes require an effect entitlement" in message for message in self.messages(artifact))
        )

    def test_pending_stale_and_illegal_admissions_remain_write_free(self) -> None:
        for status in ("pending", "stale", "illegal"):
            with self.subTest(status=status):
                artifact = self.artifact(status, ["queue.one"], [self.write(1, "queue.one")])
                self.assertTrue(
                    any(f"{status} admission must not include observable writes" in message for message in self.messages(artifact))
                )


if __name__ == "__main__":
    unittest.main()
