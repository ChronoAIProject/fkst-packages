#!/usr/bin/env python3
"""Contract tests for the host profile documentation scaffold."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class HostProfileScaffoldTest(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (REPO_ROOT / relative).read_text(encoding="utf-8")

    def uncommented_assignment_names(self, content: str) -> set[str]:
        names: set[str] = set()
        for raw in content.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
            if match:
                names.add(match.group(1))
        return names

    def test_global_host_profile_doc_pins_xdg_location_and_check_test_invocation(self) -> None:
        doc = self.read("docs/user/global-host-profiles.md")

        self.assertIn("${XDG_CONFIG_HOME:-$HOME/.config}/fkst/host.env", doc)
        self.assertIn('"$FKST_PLATFORM_ROOT/scripts/run.sh" host', doc)
        self.assertIn('--host-root "$FKST_HOST_ROOT"', doc)
        self.assertIn("-- check", doc)
        self.assertIn("-- test", doc)
        self.assertNotIn("-- supervise", doc)
        self.assertIn("fkst.workspace.toml", doc)
        self.assertIn("fkst.lock", doc)
        self.assertIn("There is no `--profile <name>`", doc)
        self.assertIn("Documentation beats scaffolds; explicit CLI/env beats documentation.", doc)
        self.assertNotIn("AI:FKST", doc)

    def test_host_profile_scaffold_excludes_operator_owned_deployment_roots(self) -> None:
        scaffold = self.read("docs/user/host-profile.env.example")
        assignments = self.uncommented_assignment_names(scaffold)

        self.assertTrue(
            {
                "BIN",
                "FKST_HOST_ROOT",
                "FKST_PLATFORM_ROOT",
                "FKST_GITHUB_REPO",
                "FKST_GITHUB_BOT_LOGIN",
                "FKST_DEVLOOP_INTEGRATION_BRANCH",
            }.issubset(assignments)
        )
        self.assertNotIn("FKST_PROFILE", assignments)
        self.assertNotIn("FKST_PROFILE_NAME", assignments)
        self.assertNotIn("FKST_DURABLE_ROOT", assignments)
        self.assertNotIn("FKST_RATE_POOL_ROOT", assignments)
        self.assertNotRegex(scaffold, r"(?m)^FKST_RUNTIME_ROOT=")
        self.assertNotIn("chmod", scaffold)

    def test_documentation_index_links_global_host_profiles(self) -> None:
        docs_index = self.read("docs/README.md")
        readme = self.read("README.md")

        self.assertIn("user/global-host-profiles.md", docs_index)
        self.assertIn("docs/user/global-host-profiles.md", readme)

    def test_devloop_local_iteration_gate_is_documented_as_a_host_contract(self) -> None:
        doc = self.read("docs/user/global-host-profiles.md")
        scaffold = self.read("docs/user/host-profile.env.example")

        self.assertIn("`FKST_DEVLOOP_LOCAL_TEST_COMMAND`", doc)
        self.assertIn("scripts/run.sh test-affected", doc)
        self.assertIn("local and CI gate", doc)
        self.assertIn("FKST_DEVLOOP_LOCAL_TEST_COMMAND", scaffold)
        self.assertIn("make preflight", scaffold)

    def test_claim_label_suffix_is_a_supported_host_declaration(self) -> None:
        doc = self.read("docs/user/global-host-profiles.md")
        scaffold = self.read("docs/user/host-profile.env.example")

        self.assertIn("`FKST_GITHUB_CLAIM_LABEL_SUFFIX`", doc)
        self.assertIn("FKST_GITHUB_CLAIM_LABEL_SUFFIX=macstudio-4", scaffold)

    def test_devloop_cache_preparation_is_documented_as_an_optional_host_contract(self) -> None:
        doc = self.read("docs/user/global-host-profiles.md")
        scaffold = self.read("docs/user/host-profile.env.example")

        self.assertIn("`FKST_DEVLOOP_CACHE_PREPARATION_COMMAND`", doc)
        self.assertIn("10-minute timeout", doc)
        self.assertIn("must be idempotent", doc)
        self.assertIn("trusted supervisor project root", doc)
        self.assertIn("`FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE`", doc)
        self.assertIn("FKST_DEVLOOP_CACHE_PREPARATION_COMMAND", scaffold)
        self.assertIn("make prepare-cache", scaffold)


if __name__ == "__main__":
    unittest.main()
