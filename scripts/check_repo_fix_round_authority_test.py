#!/usr/bin/env python3
"""Unit tests for the G-FIX-ROUND-AUTHORITY repository guard."""

from __future__ import annotations

import tempfile
import textwrap
import unittest
from pathlib import Path

import check_repo_fix_round_authority as authority


class FixRoundAuthorityRatchetTest(unittest.TestCase):
    def test_raw_fix_round_constructor_outside_authority_is_forbidden(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "packages/github-devloop-pr/core/restart.lua"
            target.parent.mkdir(parents=True)
            target.write_text(
                "local next_version = devloop_state.next_fix_version(state.version)\n",
                encoding="utf-8",
            )

            messages = authority.repository_messages(root)

        self.assertEqual(len(messages), 1)
        self.assertIn("packages/github-devloop-pr/core/restart.lua:1", messages[0])
        self.assertIn("next_fix_version", messages[0])

    def test_direct_fix_suffix_arithmetic_is_forbidden(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "libraries/devloop/replayer.lua"
            target.parent.mkdir(parents=True)
            target.write_text(
                textwrap.dedent(
                    """\
                    local round = devloop_state.version_fix_round(version) + 1
                    return version .. "/fix/" .. tostring(round)
                    """
                ),
                encoding="utf-8",
            )

            messages = authority.repository_messages(root)

        joined = "\n".join(messages)
        self.assertIn("version_fix_round arithmetic", joined)
        self.assertIn("fix suffix construction", joined)

    def test_canonical_authority_may_own_private_constructor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / authority.AUTHORITY_PATH
            target.parent.mkdir(parents=True)
            target.write_text(
                textwrap.dedent(
                    """\
                    local M = {}
                    local function next_fix_version(version)
                      return version .. "/fix/1"
                    end
                    function M.next_or_decompose(version)
                      return next_fix_version(version)
                    end
                    return M
                    """
                ),
                encoding="utf-8",
            )

            messages = authority.repository_messages(root)

        self.assertEqual(messages, [])

    def test_tests_are_excluded_but_public_state_constructor_is_forbidden(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            test_file = root / "packages/github-devloop-pr/tests/fixture.lua"
            test_file.parent.mkdir(parents=True)
            test_file.write_text("return core.next_fix_version(version)\n", encoding="utf-8")
            primitive = root / "libraries/devloop/state.lua"
            primitive.parent.mkdir(parents=True)
            primitive.write_text(
                "function M.next_fix_version(version) return version .. '/fix/1' end\n",
                encoding="utf-8",
            )

            messages = authority.repository_messages(root)

        self.assertEqual(len(messages), 1)
        self.assertIn("libraries/devloop/state.lua:1", messages[0])
        self.assertIn("next_fix_version", messages[0])


if __name__ == "__main__":
    unittest.main()
