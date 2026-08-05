#!/usr/bin/env python3
"""End-to-end tests for one authorized intent-diff rollup subject."""

from __future__ import annotations

from dataclasses import FrozenInstanceError
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import check_repo_intent_bounded_replay as checker
import intent_diff_rollup_attestation as entrypoint
from intent_bounded_replay.compare import compare_report
from intent_bounded_replay.normalize import (
    canonical_artifact_hash_v1,
    canonical_json,
    loads_json,
)
from intent_bounded_replay.rollup_attestation import (
    CarrierAuthorizationFacts,
    TracePair,
    canonical_rollup_attestation_sha256,
    derive_rollup_authorization,
    load_carrier_pull_request,
    recompute_trace_hashes,
)
from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256


REPO_ROOT = Path(__file__).resolve().parents[1]


def git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"git {' '.join(args)} failed ({result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout.strip()


def trace_pairs() -> tuple[TracePair, ...]:
    return tuple(
        TracePair(
            old_path=old_path,
            new_path=new_path,
            schema=schema,
            family=family,
            owner=owner,
        )
        for old_path, new_path, schema, family, owner in checker.ADMISSION_TRACE_SPECS
    )


def independently_recompute_trace_hashes(
    root: Path,
    base_sha: str,
    trace_root: Path,
) -> dict[str, str]:
    old_entries: list[dict[str, str]] = []
    new_entries: list[dict[str, str]] = []
    comparisons: list[dict[str, object]] = []
    for pair in sorted(trace_pairs(), key=lambda item: item.family.encode("utf-8")):
        old_raw = subprocess.run(
            ["git", "cat-file", "blob", f"{base_sha}:{pair.old_path}"],
            cwd=root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
        old = loads_json(old_raw)
        new = loads_json((trace_root / pair.new_path).read_bytes())
        report = compare_report(old, new)
        old_hash = str(report["old_hash"])
        new_hash = str(report["new_hash"])
        old_entries.append({"family": pair.family, "trace_sha256": old_hash})
        new_entries.append({"family": pair.family, "trace_sha256": new_hash})
        comparison: dict[str, object] = {
            "equal": bool(report["equal"]),
            "family": pair.family,
            "new_trace_sha256": new_hash,
            "old_trace_sha256": old_hash,
        }
        if not report["equal"]:
            comparison["first_divergence"] = report["first_divergence"]
        comparisons.append(comparison)
    return {
        "old_trace_sha256": canonical_artifact_hash_v1(
            {"schema": "fkst.intent-diff-trace-set.v1", "traces": old_entries}
        ),
        "new_trace_sha256": canonical_artifact_hash_v1(
            {"schema": "fkst.intent-diff-trace-set.v1", "traces": new_entries}
        ),
        "behavior_diff_sha256": canonical_artifact_hash_v1(
            {
                "schema": "fkst.intent-diff-behavior-diff.v1",
                "comparisons": comparisons,
            }
        ),
    }


class AuthorizationTest(unittest.TestCase):
    def facts(self, **overrides: str) -> CarrierAuthorizationFacts:
        values = {
            "event_repository": "owner/repo",
            "head_repository": "owner/repo",
            "head_ref": "integration-test-device",
            "base_ref": "dev",
        }
        values.update(overrides)
        return CarrierAuthorizationFacts(**values)

    def test_same_repository_device_rollup_is_authorized_before_content_exists(self) -> None:
        decision = derive_rollup_authorization(self.facts())

        self.assertTrue(decision.authorized)
        self.assertEqual(decision.facts, self.facts())
        with self.assertRaises(FrozenInstanceError):
            decision.authorized = False

    def test_filename_cannot_authorize_an_ordinary_feature_carrier(self) -> None:
        for facts in (
            self.facts(head_repository="fork/repo"),
            self.facts(head_ref="feature/migration-intent-diffs-123"),
            self.facts(head_ref="integration"),
            self.facts(base_ref="integration-test-device"),
        ):
            with self.subTest(facts=facts):
                self.assertFalse(derive_rollup_authorization(facts).authorized)


class RollupEntrypointTest(unittest.TestCase):
    carrier_pr_number = 999
    subject_pr_number = 3210

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.trace_root = self.root / ".fkst/run/intent-diff-traces"
        self.event_path = self.root / ".fkst/run/github-event.json"
        self.output_dir = self.root / ".fkst/run/intent-diff-rollup-attestations"
        self.output = self.root / ".fkst/run/intent-diff-rollup-attestations/999.json"

        git(self.root, "init", "-q", "-b", "dev")
        git(self.root, "config", "user.email", "rollup@example.invalid")
        git(self.root, "config", "user.name", "Rollup Test")
        self.write(".gitignore", "/.fkst/run/\n")
        self.write(checker.ALLOWLIST, "# protected allowlist\n")
        self.write(f"{checker.INTENT_DIFF_DIR}/.gitkeep", "")
        self.write("tracked.txt", "base\n")
        for relative in checker.PROTECTED_MODULES:
            self.write(relative, "# protected test fixture\n")
        for pair in trace_pairs():
            source = REPO_ROOT / pair.old_path
            destination = self.root / pair.old_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        self.base_sha = self.commit("dev base")

        git(self.root, "switch", "-q", "-c", "integration-test-device")
        self.write("tracked.txt", "carried behavior\n")
        for pair in trace_pairs():
            source = REPO_ROOT / pair.old_path
            destination = self.trace_root / pair.new_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        self.manifest_relative = (
            f"{checker.INTENT_DIFF_DIR}/{self.subject_pr_number}.json"
        )
        self.write(
            checker.ALLOWLIST,
            f"# protected allowlist\n{self.manifest_relative}\n",
        )
        subject_commit = self.commit("integration semantic subject")
        trace_hashes = recompute_trace_hashes(
            self.root,
            self.base_sha,
            self.trace_root,
            trace_pairs(),
        )
        semantic_tree_hash = semantic_tree_sha256(self.root, subject_commit)
        semantic_diff_hash = semantic_diff_sha256(
            self.root, self.base_sha, subject_commit
        )
        manifest: dict[str, object] = {
            "schema": "fkst.intent-diff.v2",
            "intent": "behavior-change",
            "pr_number": self.subject_pr_number,
            "base_sha": self.base_sha,
            "semantic_tree_sha256": semantic_tree_hash,
            "semantic_diff_sha256": semantic_diff_hash,
            "changed_row_ids": [],
            "changed_edge_ids": [],
            "changed_policy_ids": [],
            **trace_hashes,
            "cause": "bounded rollup test",
            "review_reference": "review:test",
            "one_use_identity": (
                f"{self.subject_pr_number}/{self.base_sha}/"
                f"{semantic_tree_hash}/{semantic_diff_hash}"
            ),
            "manifest_sha256": "",
        }
        manifest["manifest_sha256"] = canonical_artifact_hash_v1(manifest)
        self.write_bytes(
            self.manifest_relative,
            canonical_json(manifest) + b"\n",
        )
        self.manifest = manifest
        self.head_sha = self.commit("integration carries one manifest")
        self.write_event()

    def write(self, relative: str, content: str) -> None:
        self.write_bytes(relative, content.encode("utf-8"))

    def write_bytes(self, relative: str, content: bytes) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def commit(self, message: str) -> str:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", message)
        return git(self.root, "rev-parse", "HEAD")

    def write_event(
        self,
        *,
        base_sha: str | None = None,
        head_sha: str | None = None,
        head_repository: str = "owner/repo",
        head_ref: str = "integration-test-device",
        base_ref: str = "dev",
    ) -> None:
        event = {
            "number": self.carrier_pr_number,
            "repository": {"full_name": "owner/repo"},
            "pull_request": {
                "base": {"ref": base_ref, "sha": base_sha or self.base_sha},
                "head": {
                    "ref": head_ref,
                    "sha": head_sha or self.head_sha,
                    "repo": {"full_name": head_repository},
                },
            },
        }
        self.event_path.parent.mkdir(parents=True, exist_ok=True)
        self.event_path.write_text(json.dumps(event), encoding="utf-8")

    def arguments(self) -> list[str]:
        return [
            "--repo-root",
            os.fspath(self.root),
            "--github-event",
            os.fspath(self.event_path),
            "--trace-root",
            os.fspath(self.trace_root),
            "--output-dir",
            os.fspath(self.output_dir),
        ]

    def test_workflow_entrypoint_attests_one_exact_freshly_validated_subject(self) -> None:
        exit_code = entrypoint.main(self.arguments())

        self.assertEqual(exit_code, 0)
        artifact = loads_json(self.output.read_bytes())
        self.assertEqual(artifact["schema"], "fkst.intent-diff-rollup-attestation.v1")
        self.assertEqual(artifact["carrier_pr_number"], self.carrier_pr_number)
        self.assertEqual(artifact["base_sha"], self.base_sha)
        self.assertEqual(artifact["head_sha"], self.head_sha)
        self.assertEqual(
            artifact["manifest_subjects"],
            [
                {
                    "manifest_path": self.manifest_relative,
                    "manifest_blob_sha256": hashlib.sha256(
                        (self.root / self.manifest_relative).read_bytes()
                    ).hexdigest(),
                    "manifest_sha256": self.manifest["manifest_sha256"],
                }
            ],
        )
        independently_recomputed = independently_recompute_trace_hashes(
            self.root,
            self.base_sha,
            self.trace_root,
        )
        for field, expected in independently_recomputed.items():
            self.assertEqual(artifact[field], expected)
            self.assertEqual(self.manifest[field], expected)
        self.assertEqual(
            artifact["attestation_sha256"],
            canonical_rollup_attestation_sha256(artifact),
        )
        self.assertNotIn(
            self.output.relative_to(self.root).as_posix(),
            git(self.root, "ls-files").splitlines(),
        )

    def test_feature_edit_of_prior_manifest_fails_closed_and_leaves_no_artifact(self) -> None:
        feature_base = self.head_sha
        git(self.root, "switch", "-q", "-c", "feature/edit-prior-manifest")
        changed = loads_json((self.root / self.manifest_relative).read_bytes())
        changed["cause"] = "ordinary feature edit"
        changed["manifest_sha256"] = canonical_artifact_hash_v1(changed)
        self.write_bytes(self.manifest_relative, canonical_json(changed) + b"\n")
        feature_head = self.commit("edit prior manifest")
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text("stale artifact\n", encoding="utf-8")

        stderr = io.StringIO()
        self.write_event(
            base_sha=feature_base,
            head_sha=feature_head,
            head_ref="feature/edit-prior-manifest",
            base_ref="integration-test-device",
        )
        with mock.patch("sys.stderr", stderr):
            exit_code = entrypoint.main(self.arguments())

        self.assertEqual(exit_code, 1)
        self.assertIn("ordinary pull request may change only its own numbered manifest", stderr.getvalue())
        self.assertFalse(self.output.exists())

    def test_precheck_precedes_generation_with_the_exact_authorization_decision(self) -> None:
        observed: list[tuple[str, object]] = []
        real_precheck = checker.rollup_precheck
        real_write = entrypoint.write_rollup_attestation

        def observe_precheck(*args, **kwargs):
            observed.append(("precheck", kwargs["authorization"]))
            return real_precheck(*args, **kwargs)

        def observe_write(output, carrier_pr_number, authorization, precheck):
            observed.append(("generation", authorization))
            return real_write(output, carrier_pr_number, authorization, precheck)

        with mock.patch.object(
            checker, "rollup_precheck", side_effect=observe_precheck
        ), mock.patch.object(
            entrypoint, "write_rollup_attestation", side_effect=observe_write
        ):
            exit_code = entrypoint.main(self.arguments())

        self.assertEqual(exit_code, 0)
        self.assertEqual([stage for stage, _ in observed], ["precheck", "generation"])
        self.assertIs(observed[0][1], observed[1][1])

    def test_tampered_declared_trace_hash_fails_closed_and_leaves_no_artifact(self) -> None:
        changed = loads_json((self.root / self.manifest_relative).read_bytes())
        changed["old_trace_sha256"] = "f" * 64
        changed["manifest_sha256"] = canonical_artifact_hash_v1(changed)
        self.write_bytes(self.manifest_relative, canonical_json(changed) + b"\n")
        self.head_sha = self.commit("tamper declared trace hash")
        self.write_event()
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text("stale artifact\n", encoding="utf-8")

        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr):
            exit_code = entrypoint.main(self.arguments())

        self.assertEqual(exit_code, 1)
        self.assertIn("old_trace_sha256 mismatch", stderr.getvalue())
        self.assertFalse(self.output.exists())

    def test_tampered_semantic_subject_fails_closed(self) -> None:
        changed = loads_json((self.root / self.manifest_relative).read_bytes())
        changed["semantic_tree_sha256"] = "f" * 64
        changed["one_use_identity"] = "/".join(
            (
                str(int(changed["pr_number"])),
                str(changed["base_sha"]),
                str(changed["semantic_tree_sha256"]),
                str(changed["semantic_diff_sha256"]),
            )
        )
        changed["manifest_sha256"] = canonical_artifact_hash_v1(changed)
        self.write_bytes(self.manifest_relative, canonical_json(changed) + b"\n")
        self.head_sha = self.commit("tamper semantic subject")
        self.write_event()

        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr):
            exit_code = entrypoint.main(self.arguments())

        self.assertEqual(exit_code, 1)
        self.assertIn("do not identify a valid semantic subject", stderr.getvalue())
        self.assertFalse(self.output.exists())

    def test_extra_non_numbered_intent_path_fails_closed(self) -> None:
        self.write(f"{checker.INTENT_DIFF_DIR}/notes.json", "{}\n")
        self.head_sha = self.commit("add extra intent path")
        self.write_event()

        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr):
            exit_code = entrypoint.main(self.arguments())

        self.assertEqual(exit_code, 1)
        self.assertIn("must carry exactly one numbered manifest", stderr.getvalue())
        self.assertIn("notes.json", stderr.getvalue())
        self.assertFalse(self.output.exists())

    def test_malformed_trace_shape_fails_even_when_manifest_hashes_match(self) -> None:
        pair = trace_pairs()[0]
        trace_path = self.trace_root / pair.new_path
        malformed = loads_json(trace_path.read_bytes())
        malformed["unexpected"] = "attacker-controlled"
        malformed["artifact_sha256"] = canonical_artifact_hash_v1(malformed)
        trace_path.write_bytes(canonical_json(malformed) + b"\n")
        trace_hashes = recompute_trace_hashes(
            self.root, self.base_sha, self.trace_root, trace_pairs()
        )
        changed = loads_json((self.root / self.manifest_relative).read_bytes())
        changed.update(trace_hashes)
        changed["manifest_sha256"] = canonical_artifact_hash_v1(changed)
        self.write_bytes(self.manifest_relative, canonical_json(changed) + b"\n")
        self.head_sha = self.commit("match malformed trace declaration")
        self.write_event()

        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr):
            exit_code = entrypoint.main(self.arguments())

        self.assertEqual(exit_code, 1)
        self.assertIn("unexpected fields", stderr.getvalue())
        self.assertFalse(self.output.exists())

    def test_repository_precheck_admits_only_the_exact_authorized_carrier(self) -> None:
        carrier = load_carrier_pull_request(self.event_path)
        with mock.patch.dict(
            os.environ,
            {"FKST_RESTART_PREFLIGHT_BASE_REF": self.base_sha},
            clear=False,
        ), mock.patch.object(
            checker, "_admission_trace_messages", return_value=[]
        ), mock.patch(
            "check_repo_restart_preflight._step8_complete", return_value=True
        ):
            messages = checker.repository_messages(
                self.root, enforce_base=True, carrier=carrier
            )

        self.assertEqual(messages, [])


if __name__ == "__main__":
    unittest.main()
