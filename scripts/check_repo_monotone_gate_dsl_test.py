#!/usr/bin/env python3
"""Unit tests for the G-MONOTONE-GATE-DSL repository guard."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).with_name("check_repo_monotone_gate_dsl.py")
    spec = importlib.util.spec_from_file_location("check_repo_monotone_gate_dsl", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load check_repo_monotone_gate_dsl.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


dsl = load_module()


class MonotoneGateDslRatchetTest(unittest.TestCase):
    def test_gate_definition_may_require_only_gate_dsl(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "packages" / "github-devloop" / "core" / "gates" / "bad.lua"
            target.parent.mkdir(parents=True)
            target.write_text(
                textwrap.dedent(
                    """\
                    local gate = require("std.devloop_gate")
                    local state = require("std.devloop_state")

                    return gate.require_reached("pr-open", {
                      domain = "github-devloop-pr",
                      raw = state.current_state,
                    })
                    """
                ),
                encoding="utf-8",
            )
            (root / "migration").mkdir()
            (root / dsl.ALLOWLIST).write_text("", encoding="utf-8")

            messages = dsl.repository_messages(root, enforce_base=False)

        joined = "\n".join(messages)
        self.assertIn("require std.devloop_state", joined)
        self.assertIn("raw-token current_state", joined)
        self.assertIn("forbidden in a core/gates DSL definition", joined)

    def test_pure_gate_definition_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "packages" / "github-devloop" / "core" / "gates" / "good.lua"
            target.parent.mkdir(parents=True)
            target.write_text(
                textwrap.dedent(
                    """\
                    local gate = require("std.devloop_gate")

                    return gate.require_reached("pr-open", {
                      domain = "github-devloop-pr",
                      lineage = {
                        proposal_id = true,
                      },
                    })
                    """
                ),
                encoding="utf-8",
            )
            (root / "migration").mkdir()
            (root / dsl.ALLOWLIST).write_text("", encoding="utf-8")

            messages = dsl.repository_messages(root, enforce_base=False)

        self.assertEqual(messages, [])


if __name__ == "__main__":
    unittest.main()
