#!/usr/bin/env python3
"""Tests for the R9 protected-base restart preflight scanner."""

from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import check_repo_restart_preflight as preflight
from intent_bounded_replay.normalize import canonical_artifact_hash_v1
from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256


ZERO_HASH = "0" * 64
MANIFEST = "migration/intent-diffs/123.json"
ANOMALY_QUEUES = [
    "github-devloop-pr.restart_transition_anomaly",
    "github-devloop.restart_transition_anomaly",
]
DELIVERY_DELTA = ";".join([
    "github-devloop-pr.observe_pr->github-devloop-pr.restart_transition_anomaly",
    "github-devloop.observe_issue->github-devloop.restart_transition_anomaly",
])


CHECKER_PATH = "scripts/check_repo_restart_preflight.py"
ADDED_CHECKER_PATH = "scripts/check_repo_intent_bounded_replay.py"
SEMANTIC_PATH = "packages/github-devloop/departments/loop/main.lua"
GRANT_PATH = "migration/restart-cochange-grants/test-promotion.json"
SECOND_GRANT_PATH = "migration/restart-cochange-grants/second-promotion.json"
BASE_CHECKER = "# protected preflight\\n"
BASE_SEMANTICS = "return {}\\n"
CHANGED_CHECKER = "# changed checker\\n"
CHANGED_SEMANTICS = "return { changed = true }\\n"
ADDED_CHECKER = "# added checker\\n"


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=root, check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


class RestartPreflightTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        git(self.root, "init", "-q", "--object-format=sha1")
        git(self.root, "config", "user.email", "preflight@example.invalid")
        git(self.root, "config", "user.name", "Preflight Test")
        self.write(CHECKER_PATH, BASE_CHECKER)
        self.write("scripts/intent_bounded_replay/semantic_tree.py", "FIXED = (_is_numbered_intent_diff_manifest,)\\n")
        self.write("migration/intent-bounded-replay.allowlist", "# protected allowlist\\n")
        self.write("migration/intent-diffs/.gitkeep", "")
        self.write(
            "packages/github-devloop-ops/fkst.toml",
            "kind = 'package.composed'\nname = 'github-devloop-ops'\n"
            "[event_deps]\npackages = ['github-devloop']\n",
        )
        self.write(
            "migration/restart-lifecycle.inventory.json",
            json.dumps({
                "watched_files": ["packages/github-devloop/departments/loop/main.lua"],
                "production_writer_sites": [{
                    "ordinal": "versioned_transition_status:thinking->blocked",
                }],
            }),
        )
        self.write(SEMANTIC_PATH, BASE_SEMANTICS)
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "base")
        self.base = git(self.root, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, relative: str, content: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self) -> None:
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "head")

    def hash_blob(self, content: str) -> str:
        result = subprocess.run(
            ["git", "hash-object", "--stdin"],
            cwd=self.root,
            check=False,
            input=content,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def promotion_entries(self) -> list[dict[str, str]]:
        return [
            {
                "path": CHECKER_PATH,
                "status": "M",
                "old_blob": self.hash_blob(BASE_CHECKER),
                "new_blob": self.hash_blob(CHANGED_CHECKER),
            },
            {
                "path": SEMANTIC_PATH,
                "status": "M",
                "old_blob": self.hash_blob(BASE_SEMANTICS),
                "new_blob": self.hash_blob(CHANGED_SEMANTICS),
            },
        ]

    def added_deleted_entries(self) -> list[dict[str, str]]:
        return [
            {
                "path": ADDED_CHECKER_PATH,
                "status": "A",
                "old_blob": "",
                "new_blob": self.hash_blob(ADDED_CHECKER),
            },
            {
                "path": SEMANTIC_PATH,
                "status": "D",
                "old_blob": self.hash_blob(BASE_SEMANTICS),
                "new_blob": "",
            },
        ]

    def signed_grant_json(self, document: dict[str, object]) -> str:
        canonical = json.dumps(
            document,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        signed = {**document, "grant_sha256": hashlib.sha256(canonical).hexdigest()}
        return json.dumps(signed, ensure_ascii=False, indent=2, sort_keys=True) + "\n"

    def grant_json(self, entries: list[dict[str, str]]) -> str:
        return self.signed_grant_json({
            "schema": "fkst.restart-cochange-grant.v1",
            "entries": entries,
        })

    def restore_base_files(self) -> None:
        self.write(CHECKER_PATH, BASE_CHECKER)
        self.write(SEMANTIC_PATH, BASE_SEMANTICS)
        added_checker = self.root / ADDED_CHECKER_PATH
        if added_checker.exists():
            added_checker.unlink()

    def install_base_grants(self, grants: dict[str, str]) -> None:
        self.restore_base_files()
        grant_dir = self.root / "migration/restart-cochange-grants"
        if grant_dir.exists():
            for path in grant_dir.glob("*.json"):
                path.unlink()
        for path, content in grants.items():
            self.write(path, content)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "base grant")
        self.base = git(self.root, "rev-parse", "HEAD")

    def install_base_grant(self, entries: list[dict[str, str]]) -> str:
        content = self.grant_json(entries)
        self.install_base_grants({GRANT_PATH: content})
        return content

    def write_cochange(self) -> None:
        self.write(CHECKER_PATH, CHANGED_CHECKER)
        self.write(SEMANTIC_PATH, CHANGED_SEMANTICS)

    def apply_cochange(self) -> None:
        self.write_cochange()
        self.commit()

    def apply_added_deleted_cochange(self) -> None:
        self.write(ADDED_CHECKER_PATH, ADDED_CHECKER)
        (self.root / SEMANTIC_PATH).unlink()
        self.commit()

    def messages(self, *, head_ref: str = "HEAD") -> list[str]:
        return preflight.repository_messages(
            self.root, base_ref=self.base, head_ref=head_ref
        )

    def activate_anomaly_transport(
        self,
        *,
        extra_queue: bool = False,
        forbidden_field: str | None = None,
        mint_grant: bool = False,
        non_ephemeral: bool = False,
        old_authority: bool = False,
    ) -> None:
        issue_queues = ["restart_transition_anomaly"]
        if extra_queue:
            issue_queues.append("restart_transition_anomaly_extra")
        issue_queue_source = ", ".join(repr(queue) for queue in issue_queues)
        payload_field = f", {forbidden_field} = 'forbidden'" if forbidden_field else ""
        mint = "local grant = restart_effects.mint_grant(snapshot, decision, 'queue')\n" if mint_grant else ""
        self.write(
            "packages/github-devloop/departments/observe_issue/main.lua",
            "M.spec = { produces = { " + issue_queue_source + " } }\n"
            + mint
            + "local anomaly = { schema = 'restart-transition-anomaly.v1'" + payload_field + " }\n"
            + "devloop_logging.log_raise('observe_issue', 'entity', 'restart_transition_anomaly', anomaly)\n",
        )
        self.write(
            "packages/github-devloop-pr/departments/observe_pr/main.lua",
            "M.spec = { produces = { 'restart_transition_anomaly' } }\n"
            "local anomaly = { schema = 'restart-transition-anomaly.v1' }\n"
            "devloop_logging.log_raise('observe_pr', 'entity', 'restart_transition_anomaly', anomaly)\n",
        )
        self.write(
            "packages/github-devloop/core/restart/sink_inventory.lua",
            "queue('observe_issue', 'restart_transition_anomaly', 'grantless-telemetry', 'anomaly:v1/pass')\n",
        )
        self.write(
            "packages/github-devloop-pr/core/restart/sink_inventory.lua",
            "queue('observe_pr', 'restart_transition_anomaly', 'grantless-telemetry', 'anomaly:v1/pass')\n",
        )
        ephemeral = ANOMALY_QUEUES[:1] if non_ephemeral else ANOMALY_QUEUES
        self.write(
            "packages/github-devloop-ops/departments/observability/main.lua",
            "local spec = {\n"
            f"  consumes = {{ {', '.join(repr(queue) for queue in ANOMALY_QUEUES)} }},\n"
            f"  ephemeral = {{ {', '.join(repr(queue) for queue in ephemeral)} }},\n"
            "}\nreturn spec\n",
        )
        self.write(
            "packages/github-devloop-ops/fkst.toml",
            "kind = 'package.composed'\nname = 'github-devloop-ops'\n"
            "[event_deps]\npackages = ['github-devloop', 'github-devloop-pr']\n",
        )
        if old_authority:
            self.write("libraries/devloop/restart_effect_seal.lua", "return { old_authority = true }\n")

    def write_valid_manifest(self, overrides: dict[str, object] | None = None) -> None:
        artifact: dict[str, object] = {
            "schema": "fkst.intent-diff.v2",
            "intent": "behavior-change",
            "pr_number": 123,
            "base_sha": self.base,
            "semantic_tree_sha256": semantic_tree_sha256(self.root),
            "semantic_diff_sha256": semantic_diff_sha256(self.root, self.base),
            "changed_row_ids": [],
            "changed_edge_ids": [],
            "changed_policy_ids": [],
            "old_trace_sha256": ZERO_HASH,
            "new_trace_sha256": ZERO_HASH,
            "behavior_diff_sha256": ZERO_HASH,
            "cause": "activate post-terminal R7 anomaly transport",
            "review_reference": "review:r7-test",
            "one_use_identity": "",
            "anomaly_transport": {
                "qualified_queues": ANOMALY_QUEUES,
                "ops_dependency": "github-devloop-pr",
                "ephemeral_consumes": ANOMALY_QUEUES,
                "ingestion": "github-devloop-ops.observability",
                "package_visible_delivery_delta": DELIVERY_DELTA,
            },
            "manifest_sha256": "",
        }
        if overrides:
            artifact.update(overrides)
        artifact["one_use_identity"] = "/".join(str(artifact[field]) for field in (
            "pr_number", "base_sha", "semantic_tree_sha256", "semantic_diff_sha256",
        ))
        artifact["manifest_sha256"] = canonical_artifact_hash_v1(artifact)
        self.write(MANIFEST, json.dumps(artifact, sort_keys=True) + "\n")
        self.commit()

    def commit_transport(self) -> None:
        self.write("migration/intent-bounded-replay.allowlist", "# protected allowlist\n" + MANIFEST + "\n")
        self.commit()

    def test_unchanged_protected_base_passes(self) -> None:
        self.assertEqual(self.messages(), [])

    def test_tracked_attestation_fails(self) -> None:
        self.write("migration/intent-diffs/attestation.json", json.dumps({"schema": "fkst.intent-diff-attestation.v1"}))
        self.commit()
        self.assertTrue(any("tracked-attestation" in message for message in self.messages()))

    def test_exclusion_control_change_fails(self) -> None:
        self.write("scripts/intent_bounded_replay/semantic_tree.py", "FIXED = (_is_numbered_intent_diff_manifest, lambda path: True)\\n")
        self.commit()
        self.assertTrue(any("exclusion-control-changed" in message for message in self.messages()))

    def test_checker_and_production_semantics_cochange_fails(self) -> None:
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def assert_attestation_control_cochange_fails(self, path: str) -> None:
        self.write(path, "# changed attestation control\n")
        self.write(SEMANTIC_PATH, CHANGED_SEMANTICS)
        self.commit()
        self.assertTrue(
            any("checker-checked-cochange" in message for message in self.messages())
        )

    def test_ci_attestation_step_and_production_semantics_cochange_fail(self) -> None:
        self.assert_attestation_control_cochange_fails(".github/workflows/ci.yml")

    def test_attestation_generator_and_production_semantics_cochange_fail(self) -> None:
        self.assert_attestation_control_cochange_fails(
            "scripts/generate_intent_diff_attestation.py"
        )

    def test_attestation_verifier_and_production_semantics_cochange_fail(self) -> None:
        self.assert_attestation_control_cochange_fails(
            "scripts/intent_bounded_replay/attestation.py"
        )

    def test_promotion_grant_absent_still_fails_cochange(self) -> None:
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_valid_base_resident_grant_admits_exact_cochange(self) -> None:
        self.install_base_grant(self.promotion_entries())
        self.apply_cochange()
        self.assertFalse(any("checker-checked-cochange" in message for message in self.messages()))

    def test_head_minted_grant_rejected(self) -> None:
        entries = [self.promotion_entries()[1]]
        self.write(SEMANTIC_PATH, CHANGED_SEMANTICS)
        self.write(GRANT_PATH, self.grant_json(entries))
        self.commit()
        self.assertFalse(
            preflight._cochange_promotion_admitted(
                self.root, self.base, "HEAD", [], [SEMANTIC_PATH]
            )
        )
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_modified_in_head_rejected(self) -> None:
        content = self.install_base_grant([self.promotion_entries()[1]])
        self.write(SEMANTIC_PATH, CHANGED_SEMANTICS)
        self.write(GRANT_PATH, " " + content)
        self.commit()
        self.assertFalse(
            preflight._cochange_promotion_admitted(
                self.root, self.base, "HEAD", [], [SEMANTIC_PATH]
            )
        )
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_invalid_self_hash_rejected(self) -> None:
        document = json.loads(self.grant_json(self.promotion_entries()))
        document["grant_sha256"] = "0" * 64
        self.install_base_grants({
            GRANT_PATH: json.dumps(document, indent=2, sort_keys=True) + "\n",
        })
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_missing_entry_rejected(self) -> None:
        self.install_base_grant(self.promotion_entries()[:-1])
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_extra_entry_rejected(self) -> None:
        entries = self.promotion_entries()
        inventory_path = "migration/restart-lifecycle.inventory.json"
        inventory_blob = git(self.root, "rev-parse", f"{self.base}:{inventory_path}")
        entries.append(
            {
                "path": inventory_path,
                "status": "M",
                "old_blob": inventory_blob,
                "new_blob": inventory_blob,
            }
        )
        self.install_base_grant(entries)
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_duplicate_entry_rejected(self) -> None:
        entries = self.promotion_entries()
        entries.append(dict(entries[0]))
        self.install_base_grant(entries)
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_status_mismatch_rejected(self) -> None:
        entries = self.promotion_entries()
        entries[1] = {**entries[1], "status": "A"}
        self.install_base_grant(entries)
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_wrong_old_blob_rejected(self) -> None:
        entries = self.promotion_entries()
        entries[1] = {**entries[1], "old_blob": "0" * 40}
        self.install_base_grant(entries)
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_wrong_new_blob_rejected(self) -> None:
        entries = self.promotion_entries()
        entries[1] = {**entries[1], "new_blob": "0" * 40}
        self.install_base_grant(entries)
        self.apply_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_added_and_deleted_paths(self) -> None:
        entries = self.added_deleted_entries()
        self.install_base_grant(entries)
        self.apply_added_deleted_cochange()
        self.assertFalse(any("checker-checked-cochange" in message for message in self.messages()))

        entries[0] = {**entries[0], "old_blob": self.hash_blob(BASE_CHECKER)}
        self.install_base_grant(entries)
        self.apply_added_deleted_cochange()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

    def test_multiple_grants(self) -> None:
        entries = self.promotion_entries()
        nonmatching_entries = [dict(entry) for entry in entries]
        nonmatching_entries[1]["new_blob"] = "0" * 40
        self.install_base_grants({
            GRANT_PATH: self.grant_json(entries),
            SECOND_GRANT_PATH: self.grant_json(nonmatching_entries),
        })
        self.apply_cochange()
        self.assertFalse(any("checker-checked-cochange" in message for message in self.messages()))

        self.install_base_grants({
            GRANT_PATH: self.grant_json(entries),
            SECOND_GRANT_PATH: "{malformed json\n",
        })
        self.apply_cochange()
        self.assertFalse(any("checker-checked-cochange" in message for message in self.messages()))

    def test_grant_malformed_schema_rejected(self) -> None:
        entries = self.promotion_entries()
        malformed_documents = {
            "missing required field": {"entries": entries},
            "extra field": {
                "schema": "fkst.restart-cochange-grant.v1",
                "entries": entries,
                "unexpected": True,
            },
            "wrong schema": {
                "schema": "fkst.restart-cochange-grant.v2",
                "entries": entries,
            },
        }
        for label, document in malformed_documents.items():
            with self.subTest(label=label):
                self.install_base_grants({
                    GRANT_PATH: self.signed_grant_json(document),
                })
                self.apply_cochange()
                self.assertTrue(any(
                    "checker-checked-cochange" in message for message in self.messages()
                ))

    def test_repository_messages_binds_changed_paths_and_grant_blobs_to_head_ref(self) -> None:
        self.install_base_grant(self.promotion_entries())
        self.apply_cochange()
        candidate = git(self.root, "rev-parse", "HEAD")
        git(self.root, "switch", "--detach", "-q", self.base)
        self.assertEqual(
            preflight._changed_paths(self.root, self.base, candidate),
            {CHECKER_PATH, SEMANTIC_PATH},
        )
        self.assertFalse(any(
            "checker-checked-cochange" in message
            for message in self.messages(head_ref=candidate)
        ))

    def test_unlisted_authority_caller_fails(self) -> None:
        self.write("packages/github-devloop/departments/new_caller/main.lua", "local result = restart_authority.decide_transition(snapshot, intent)\\n")
        self.commit()
        self.assertTrue(any("unlisted-authority-caller" in message for message in self.messages()))

    def test_unlisted_writer_derived_from_frozen_inventory_fails(self) -> None:
        self.write(
            "packages/github-devloop/departments/new_writer/main.lua",
            "local result = devloop_state.versioned_transition_status(current, sources, target, version)\\n",
        )
        self.commit()
        self.assertTrue(any("unlisted-writer" in message for message in self.messages()))

    def test_shared_grant_factory_exposure_fails(self) -> None:
        self.write("libraries/devloop/public_grants.lua", "function M.mint_grant(binding) end\\n")
        self.commit()
        self.assertTrue(any("grant-factory-exposure" in message for message in self.messages()))

    def test_watched_authority_caller_consumption_is_not_exposure(self) -> None:
        self.write(
            "packages/github-devloop/departments/loop/main.lua",
            "local grant = restart_effects.mint_grant(snapshot)\\n"
            "restart_effects.verify_grant(grant)\\n"
            "restart_effects.seal_snapshot(snapshot)\\n",
        )
        self.commit()
        messages = self.messages()
        self.assertFalse(any("grant-factory-exposure" in message for message in messages))
        self.assertFalse(any("owner-seal-exposure" in message for message in messages))

    def test_nonwatched_authority_caller_consumption_is_exposure(self) -> None:
        self.write(
            "packages/github-devloop/departments/new_caller/main.lua",
            "local grant = restart_effects.mint_grant(snapshot)\\n"
            "restart_effects.verify_grant(grant)\\n"
            "restart_effects.seal_snapshot(snapshot)\\n",
        )
        self.commit()
        messages = self.messages()
        self.assertTrue(any("grant-factory-exposure" in message for message in messages))
        self.assertTrue(any("owner-seal-exposure" in message for message in messages))

    def test_owner_seal_di_exposure_fails(self) -> None:
        self.write("libraries/devloop/di/providers.lua", "caps.owner_seal = owner_seal\\n")
        self.commit()
        self.assertTrue(any("owner-seal-exposure" in message for message in self.messages()))

    def test_anomaly_shadow_module_is_allowed(self) -> None:
        self.write("libraries/devloop/restart_transition_anomaly.lua", "local schema = 'restart-transition-anomaly.v1'\\nreturn { schema = schema }\\n")
        self.commit()
        self.assertEqual(self.messages(), [])

    def test_anomaly_transport_activation_fails(self) -> None:
        self.write("packages/github-devloop/departments/observe_issue/main.lua", "M.spec = { produces = { 'restart_transition_anomaly' } }\\n")
        self.commit()
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_anomaly_activation_without_manifest_preserves_current_rejection(self) -> None:
        self.activate_anomaly_transport()
        self.commit()
        paths = [
            "packages/github-devloop-pr/core/restart/sink_inventory.lua",
            "packages/github-devloop-pr/departments/observe_pr/main.lua",
            "packages/github-devloop/core/restart/sink_inventory.lua",
            "packages/github-devloop/departments/observe_issue/main.lua",
        ]
        self.assertEqual(self.messages(), [
            f"anomaly-transport-activation: {path} activates restart anomaly production, ingestion, dependency, or delivery during refactor"
            for path in paths
        ])

    def test_exact_bidirectional_anomaly_atoms_are_admitted(self) -> None:
        self.activate_anomaly_transport()
        self.commit_transport()
        self.write_valid_manifest()
        self.assertEqual(self.messages(), [])

    def test_extra_same_path_anomaly_atom_is_rejected(self) -> None:
        self.activate_anomaly_transport(extra_queue=True)
        self.commit_transport()
        self.write_valid_manifest()
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_unused_manifest_authorization_atom_is_rejected(self) -> None:
        self.activate_anomaly_transport()
        self.commit_transport()
        extra = ANOMALY_QUEUES + ["github-devloop.unused_restart_transition_anomaly"]
        self.write_valid_manifest({
            "anomaly_transport": {
                "qualified_queues": extra,
                "ops_dependency": "github-devloop-pr",
                "ephemeral_consumes": ANOMALY_QUEUES,
                "ingestion": "github-devloop-ops.observability",
                "package_visible_delivery_delta": DELIVERY_DELTA,
            },
        })
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_mis_self_hashed_manifest_is_rejected(self) -> None:
        self.activate_anomaly_transport()
        self.commit_transport()
        self.write_valid_manifest()
        artifact = json.loads((self.root / MANIFEST).read_text(encoding="utf-8"))
        artifact["manifest_sha256"] = "f" * 64
        self.write(MANIFEST, json.dumps(artifact, sort_keys=True) + "\n")
        self.commit()
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_wrong_manifest_base_is_rejected(self) -> None:
        self.activate_anomaly_transport()
        self.commit_transport()
        self.write_valid_manifest({"base_sha": "f" * 40})
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_durable_identity_is_rejected_with_matching_manifest(self) -> None:
        self.activate_anomaly_transport(forbidden_field="source_ref")
        self.commit_transport()
        self.write_valid_manifest()
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_dedup_key_is_rejected_with_matching_manifest(self) -> None:
        self.activate_anomaly_transport(forbidden_field="dedup_key")
        self.commit_transport()
        self.write_valid_manifest()
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_delivery_identity_is_rejected_with_matching_manifest(self) -> None:
        self.activate_anomaly_transport(forbidden_field="delivery_id")
        self.commit_transport()
        self.write_valid_manifest()
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_grant_minting_path_is_rejected_with_matching_manifest(self) -> None:
        self.activate_anomaly_transport(mint_grant=True)
        self.commit_transport()
        self.write_valid_manifest()
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_non_ephemeral_consume_is_rejected_with_matching_manifest(self) -> None:
        self.activate_anomaly_transport(non_ephemeral=True)
        self.commit_transport()
        self.write_valid_manifest()
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))

    def test_step8_old_authority_is_derived_despite_manifest_claim(self) -> None:
        self.activate_anomaly_transport(old_authority=True)
        self.commit_transport()
        self.write_valid_manifest({"cause": "step_8_complete=true; activate R7 transport"})
        self.assertTrue(any("anomaly-transport-activation" in message for message in self.messages()))


if __name__ == "__main__":
    unittest.main()
