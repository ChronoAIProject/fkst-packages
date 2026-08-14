"""Tests for the G-DEVLOOP-GODLIB shrink-only coupling ratchet."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_repo_devloop_godlib as m  # noqa: E402


class DevloopGodlibRatchetTest(unittest.TestCase):
    def test_baseline_passes_at_current_counts(self) -> None:
        current = {"install_defs": 51, "m_writes": 875, "package_core_installs": 188, "wildcard_exports": 1}
        baseline = dict(current)
        self.assertEqual(list(m.ratchet_messages(current, baseline)), [])

    def test_shrink_passes(self) -> None:
        baseline = {"install_defs": 51, "m_writes": 875, "package_core_installs": 188, "wildcard_exports": 1}
        shrunk = {"install_defs": 40, "m_writes": 700, "package_core_installs": 150, "wildcard_exports": 1}
        self.assertEqual(list(m.ratchet_messages(shrunk, baseline)), [])

    def test_growth_fails(self) -> None:
        baseline = {"install_defs": 51, "m_writes": 875, "package_core_installs": 188, "wildcard_exports": 1}
        grown = {"install_defs": 52, "m_writes": 875, "package_core_installs": 188, "wildcard_exports": 1}
        messages = list(m.ratchet_messages(grown, baseline))
        self.assertTrue(any("install_defs 52 > baseline 51" in message for message in messages))

    def test_wildcard_growth_fails(self) -> None:
        baseline = {"install_defs": 0, "m_writes": 0, "package_core_installs": 0, "wildcard_exports": 0}
        grown = {"install_defs": 0, "m_writes": 0, "package_core_installs": 0, "wildcard_exports": 1}
        self.assertTrue(
            any("wildcard_exports 1 > baseline 0" in message for message in m.ratchet_messages(grown, baseline))
        )

    def test_missing_baseline_reports(self) -> None:
        messages = list(
            m.ratchet_messages(
                {"install_defs": 1, "m_writes": 0, "package_core_installs": 0, "wildcard_exports": 0},
                None,
            )
        )
        self.assertTrue(messages)
        self.assertIn("missing baseline", messages[0])

    def test_live_repo_at_or_below_baseline(self) -> None:
        root = Path(__file__).resolve().parents[1]
        current = m.measure(root)
        baseline = m.load_baseline(root)
        self.assertIsNotNone(baseline, "committed baseline must exist")
        messages = list(m.ratchet_messages(current, baseline))
        self.assertEqual(messages, [], f"live repo must be at/below baseline (shrink-only); got: {messages}")

    def test_replayer_does_not_read_package_replayers_from_ambient_m(self) -> None:
        root = Path(__file__).resolve().parents[1]
        text = (root / "libraries" / "devloop" / "replayer.lua").read_text(encoding="utf-8")
        forbidden = [
            "M.replay_dependency_wait_state",
            "M.replay_ready_state",
            "M.replay_awaiting_pr_state",
            "M.install_pr_review_replayers",
        ]
        hits = [token for token in forbidden if token in text]
        self.assertEqual(hits, [], f"devloop.replayer must use package-provided registry, not ambient M: {hits}")


if __name__ == "__main__":
    unittest.main()
