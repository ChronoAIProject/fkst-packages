#!/usr/bin/env python3
"""Tests for the known-dialogue fanout-only shrink-only ratchet."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


scripts_dir = Path(__file__).resolve().parent
fanout = load_module("check_repo_fanout_only", scripts_dir / "check_repo_fanout_only.py")

MIGRATION = (
    "migration=docs/devloop/plans/sagagraph-restart-lifecycle-refactor-spec.md"
    "#r11-fanout-only-message-semantics"
)


def entry(kind: str, path: str, surface: str):
    return fanout.KnownDialogueEntry.parse(
        f"{kind}|{path}|{surface}|{MIGRATION}|why=existing consensus request-reply migration debt"
    )


class FanoutOnlyRatchetTest(unittest.TestCase):
    def setUp(self) -> None:
        self.path = "packages/example/departments/reply/main.lua"
        self.source = '''
local spec = {
  consumes = { "consensus.consensus_reached" },
}
local function act(event)
  local reached = event.payload or {}
  if reached.proposal_id:match("^example/") == nil then
    log.warn("skip-foreign(proposal_id)")
    return
  end
end
'''
        self.current = fanout.source_surfaces(self.path, self.source)
        self.reply = entry("reply-consumer", self.path, "consensus.consensus_reached")
        self.origin = entry(
            "origin-filter",
            self.path,
            "consensus.consensus_reached:proposal_id",
        )

    def test_allowlisted_known_dialogue_surfaces_pass(self) -> None:
        self.assertEqual(
            fanout.ratchet_messages(self.current, {self.reply, self.origin}),
            [],
        )

    def test_new_non_allowlisted_origin_filter_fails(self) -> None:
        messages = fanout.ratchet_messages(self.current, {self.reply})

        self.assertEqual(len(messages), 1)
        self.assertIn("new known-dialogue surface", messages[0])
        self.assertIn("origin-filter", messages[0])

    def test_stale_allowlist_entry_fails(self) -> None:
        messages = fanout.ratchet_messages({self.reply}, {self.reply, self.origin})

        self.assertEqual(len(messages), 1)
        self.assertIn("prune the stale entry", messages[0])

    def test_allowlist_growth_relative_to_protected_base_fails(self) -> None:
        messages = fanout.ratchet_messages(
            self.current,
            {self.reply, self.origin},
            base_allowlist={self.reply},
        )

        self.assertEqual(len(messages), 1)
        self.assertIn("grows the known-dialogue allowlist", messages[0])


if __name__ == "__main__":
    unittest.main()
