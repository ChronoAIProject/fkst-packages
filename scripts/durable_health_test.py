#!/usr/bin/env python3
"""Behavior test for dogfood.sh durable_health_one dead-letter recency-scoping (#2517).

A redb dead-letter is a permanent audit record that never drains, so flagging ⚠ on the cumulative count
degrades the first-line health signal forever. durable_health_one now recency-scopes the dead-letter count
to the last 6h (via each entry's dead_at_ms), exactly like it already scopes pending. This test drives the
real function (dogfood.sh is source-guarded) with a faked `fkst-framework observe` output and asserts:
a dead-letter within 6h flags ⚠; only-old dead-letters do NOT flag ⚠ but still appear in the total.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DOGFOOD = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh"


def _run_durable_health(dead_letters: list[dict]) -> str:
    """Source dogfood.sh, point cfg/BIN at a fake observe emitting dead_letters, call durable_health_one."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        (d / "delivery.redb").write_text("")  # so the store-exists check passes
        observe = {"queues": [], "dead_letters": dead_letters}
        (d / "observe.json").write_text(json.dumps(observe), encoding="utf-8")
        fake_bin = d / "fkst-framework"
        fake_bin.write_text(f'#!/bin/sh\ncat "{d / "observe.json"}"\n', encoding="utf-8")
        fake_bin.chmod(fake_bin.stat().st_mode | stat.S_IXUSR)
        script = (
            f'source "{DOGFOOD}"\n'
            f'cfg() {{ DUR="{d}"; return 0; }}\n'  # override config resolution to our temp durable root
            f'BIN="{fake_bin}"\n'
            "durable_health_one packages\n"
        )
        result = subprocess.run(
            ["/bin/bash", "-c", script],
            cwd=str(REPO_ROOT),
            env={**os.environ, "DOGFOOD_REPOS": "packages"},
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.stdout + result.stderr


class DurableHealthRecency(unittest.TestCase):
    def test_recent_dead_letter_flags_warning(self) -> None:
        now_ms = int(time.time() * 1000)
        out = _run_durable_health([{"dead_at_ms": now_ms, "queue": "q", "dept": "d"}])
        self.assertIn("⚠", out, f"a dead-letter within 6h must flag ⚠: {out!r}")
        self.assertIn("1 dead-letters<6h", out, out)

    def test_only_old_dead_letters_do_not_flag_but_show_in_total(self) -> None:
        now_ms = int(time.time() * 1000)
        seven_h_ago = now_ms - 7 * 3600 * 1000
        out = _run_durable_health(
            [
                {"dead_at_ms": seven_h_ago, "queue": "q", "dept": "d"},
                {"dead_at_ms": seven_h_ago, "queue": "q", "dept": "d"},
            ]
        )
        # the cumulative-audit anti-pattern is fixed: 2 old dead-letters must NOT flag ⚠ ...
        self.assertNotIn("⚠", out, f"only-old dead-letters must not flag ⚠: {out!r}")
        # ... but stay visible in the total for the audit trail.
        self.assertIn("0 dead-letters<6h (2 total)", out, out)


if __name__ == "__main__":
    unittest.main()
