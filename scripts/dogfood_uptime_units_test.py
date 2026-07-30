#!/usr/bin/env python3
"""Behavior tests for dogfood.sh rendering process uptime in EXPLICIT units.

`ps -o etime=` emits `[[DD-]HH:]MM:SS`, whose leading field means a different unit depending on how
many fields are present. `09:30` is nine minutes thirty seconds; `03:00:30` is three hours. Rendered
raw, the two are indistinguishable at a glance, and the operator misread a 9m30s supervise uptime as
9h30m and began diagnosing a nine-hour stall on a process that had been running for twelve minutes.
The same `MM:SS`-as-`HH:MM` shape is already on the repo's deception ledger in CLAUDE.md.

The producer is the natural owner of an unambiguous rendering: fixing it here protects every reader
of `status`, `doctor` and `board` at once, rather than asking each reader to remember the format.
dogfood.sh already parses this format correctly for the reaper (`[[DD-]HH:]MM:SS -> seconds`), so the
knowledge existed; only the human-facing rendering was raw.

These tests drive the real shell function; nothing in the operator's dogfood state is touched.
"""

from __future__ import annotations

import subprocess
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DOGFOOD = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh"


def _run(etime: str) -> subprocess.CompletedProcess:
    script = textwrap.dedent(f"""
        set -u
        DOGFOOD_CONFIG=/nonexistent
        export DOGFOOD_CONFIG
        # shellcheck disable=SC1090
        . "{DOGFOOD}" >/dev/null 2>&1 || true
        fmt_uptime '{etime}' 2>/tmp/fmt_uptime_stderr_probe
        printf '\\n---STDERR---\\n'
        cat /tmp/fmt_uptime_stderr_probe
    """)
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True)


def fmt(etime: str) -> str:
    out = _run(etime).stdout
    return out.split("\n---STDERR---\n")[0].strip()


def fmt_stderr(etime: str) -> str:
    out = _run(etime).stdout
    return out.split("\n---STDERR---\n")[1].strip() if "---STDERR---" in out else ""


class UptimeUnitsTest(unittest.TestCase):
    def test_minutes_and_seconds_are_not_renderable_as_hours(self) -> None:
        """The exact shape that deceived the operator: MM:SS must carry an explicit minute unit."""
        out = fmt("09:30")
        self.assertEqual(out, "9m30s")
        self.assertNotIn("h", out, "a sub-hour uptime must not contain an hour unit")
        self.assertNotIn(":", out, "a bare colon is what makes the unit ambiguous")

    def test_hours_render_with_an_hour_unit(self) -> None:
        self.assertEqual(fmt("03:00:30"), "3h00m")

    def test_days_render_with_a_day_unit(self) -> None:
        self.assertEqual(fmt("2-04:15:00"), "2d04h")

    def test_every_rendering_is_self_describing(self) -> None:
        """No output may be a bare number pair; each must name its own units."""
        for etime in ("00:05", "11:56", "59:59", "01:00:00", "23:59:59", "1-00:00:00"):
            with self.subTest(etime=etime):
                out = fmt(etime)
                self.assertRegex(out, r"^\d+[dhms]", f"{etime!r} rendered without a leading unit: {out!r}")
                self.assertNotIn(":", out, f"{etime!r} kept an ambiguous colon: {out!r}")

    def test_missing_input_is_reported_not_silently_blank(self) -> None:
        """A dead or unreadable process must be visibly unknown, never an empty gap in the line."""
        self.assertEqual(fmt(""), "?")

    def test_no_shell_diagnostics_on_any_field_count(self) -> None:
        """A correct value printed alongside a shell warning is still a defect.

        The first implementation indexed a fixed offset from the end of a split array, so the
        two-field `MM:SS` case evaluated a negative subscript and emitted `bad array subscript`
        on stderr while still printing the right answer. Asserting stdout alone let that pass.
        """
        for etime in ("", "00:05", "09:30", "59:59", "03:00:30", "23:59:59", "2-04:15:00"):
            with self.subTest(etime=etime):
                self.assertEqual(fmt_stderr(etime), "", f"{etime!r} emitted shell diagnostics")


if __name__ == "__main__":
    unittest.main()
