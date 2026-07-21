#!/usr/bin/env python3
"""Tests for the R9 protected-base restart preflight scanner."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import check_repo_restart_preflight as preflight


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
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "preflight@example.invalid")
        git(self.root, "config", "user.name", "Preflight Test")
        self.write("scripts/check_repo_restart_preflight.py", "# protected preflight\\n")
        self.write("scripts/intent_bounded_replay/semantic_tree.py", "FIXED = (_is_numbered_intent_diff_manifest,)\\n")
        self.write(
            "migration/restart-lifecycle.inventory.json",
            json.dumps({
                "watched_files": ["packages/github-devloop/departments/loop/main.lua"],
                "production_writer_sites": [{
                    "ordinal": "versioned_transition_status:thinking->blocked",
                }],
            }),
        )
        self.write("packages/github-devloop/departments/loop/main.lua", "return {}\\n")
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

    def messages(self) -> list[str]:
        return preflight.repository_messages(self.root, base_ref=self.base)

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
        self.write("scripts/check_repo_restart_preflight.py", "# changed checker\\n")
        self.write("packages/github-devloop/departments/loop/main.lua", "return { changed = true }\\n")
        self.commit()
        self.assertTrue(any("checker-checked-cochange" in message for message in self.messages()))

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


if __name__ == "__main__":
    unittest.main()
