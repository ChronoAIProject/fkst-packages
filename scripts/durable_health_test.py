#!/usr/bin/env python3
"""Behavior tests for dogfood.sh durable dead-letter health reporting."""

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


def _dead_letter(delivery_id: str, dead_at_ms: int, dept: str = "dept-a") -> dict:
    return {
        "delivery_id": delivery_id,
        "dead_at_ms": dead_at_ms,
        "queue": "queue-a",
        "dept": dept,
    }


def _cause_fact(
    delivery_id: str,
    error_class: str,
    fingerprint: str,
    dept: str = "dept-a",
) -> str:
    return (
        "TIMESTAMP=2026-07-30T01:00:00Z LEVEL=warn MSG=fixture "
        f"dept=dead_letter tag=DEAD_LETTER error_class={error_class} "
        f"fingerprint={fingerprint} terminal=true delivery_id={delivery_id} "
        f"queue=queue-a dead_dept={dept} error=ignored prose"
    )


def _run_durable_health(
    dead_letters: list[dict],
    *,
    fact_lines: list[str] | None = None,
    truncated: bool = False,
    cleanup_before_health: bool = False,
) -> str:
    """Run the real durable_health_one against a fake observe snapshot and child logs."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        durable_root = root / "durable"
        durable_root.mkdir()
        (durable_root / "delivery.redb").write_text("")
        observe = {
            "queues": [],
            "dead_letters": dead_letters,
            "truncated": {"dead_letters": truncated},
        }
        (root / "observe.json").write_text(json.dumps(observe), encoding="utf-8")
        fake_bin = root / "fkst-framework"
        fake_bin.write_text(
            f'#!/bin/sh\ncat "{root / "observe.json"}"\n',
            encoding="utf-8",
        )
        fake_bin.chmod(fake_bin.stat().st_mode | stat.S_IXUSR)

        log_root = root / "logs"
        child_logs = log_root / "dogfood-rt-packages.1" / "logs" / "framework-child"
        child_logs.mkdir(parents=True)
        if fact_lines:
            (child_logs / "dead-letter.log").write_text(
                "\n".join(fact_lines) + "\n",
                encoding="utf-8",
            )

        script = (
            f'source "{DOGFOOD}"\n'
            f'cfg() {{ DUR="{durable_root}"; return 0; }}\n'
            f'BIN="{fake_bin}"\n'
            f'LOGDIR="{log_root}"\n'
        )
        if cleanup_before_health:
            script += (
                f'PKGSRC="{root / "not-a-checkout"}"\n'
                f'clean_stale_runtime_worktrees packages "{log_root / "dogfood-rt-packages.current"}"\n'
            )
        script += "durable_health_one packages\n"
        result = subprocess.run(
            ["/bin/bash", "-c", script],
            cwd=str(REPO_ROOT),
            env={**os.environ, "DOGFOOD_REPOS": "packages"},
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.stdout + result.stderr


class DurableHealthTest(unittest.TestCase):
    def test_recent_dead_letter_flags_warning_and_renders_dominant_cause(self) -> None:
        now_ms = int(time.time() * 1000)
        dead_letters = [
            _dead_letter("delivery-1", now_ms, "dept-a"),
            _dead_letter("delivery-2", now_ms, "dept-b"),
            _dead_letter("delivery-3", now_ms, "dept-c"),
        ]
        facts = [
            _cause_fact("delivery-1", "quota-exhausted", "fp-quota", "dept-a"),
            _cause_fact("delivery-2", "quota-exhausted", "fp-quota", "dept-b"),
            _cause_fact("delivery-3", "other-failure", "fp-other", "dept-c"),
        ]

        out = _run_durable_health(dead_letters, fact_lines=facts)

        self.assertIn("3 dead-letters<6h", out)
        self.assertIn("⚠", out)
        self.assertIn(
            "dead-letter cause (top): error_class=quota-exhausted "
            "fingerprint=fp-quota 2x depts=dept-a,dept-b",
            out,
        )

    def test_restart_cleanup_retains_structured_cause_fact(self) -> None:
        now_ms = int(time.time() * 1000)

        out = _run_durable_health(
            [_dead_letter("delivery-1", now_ms, "dept-a")],
            fact_lines=[_cause_fact("delivery-1", "quota-exhausted", "fp-quota")],
            cleanup_before_health=True,
        )

        self.assertIn(
            "dead-letter cause (top): error_class=quota-exhausted "
            "fingerprint=fp-quota 1x dept=dept-a",
            out,
        )

    def test_retry_only_and_stale_facts_do_not_affect_ranking(self) -> None:
        now_ms = int(time.time() * 1000)
        seven_hours_ago = now_ms - 7 * 3600 * 1000
        dead_letters = [
            _dead_letter("recent", now_ms, "current-dept"),
            _dead_letter("stale-1", seven_hours_ago, "stale-dept"),
            _dead_letter("stale-2", seven_hours_ago, "stale-dept"),
        ]
        facts = [
            _cause_fact("recent", "current-cause", "fp-current", "current-dept"),
            _cause_fact("stale-1", "stale-cause", "fp-stale", "stale-dept"),
            _cause_fact("stale-2", "stale-cause", "fp-stale", "stale-dept"),
            _cause_fact("retry-only-1", "retry-cause", "fp-retry", "retry-dept"),
            _cause_fact("retry-only-2", "retry-cause", "fp-retry", "retry-dept"),
            (
                "TIMESTAMP=2026-07-30T01:00:00Z LEVEL=warn "
                "MSG=framework failed error_class=prose-only fingerprint=fp-prose "
                "delivery_id=recent"
            ),
        ]

        out = _run_durable_health(dead_letters, fact_lines=facts)

        self.assertIn("error_class=current-cause fingerprint=fp-current 1x", out)
        self.assertNotIn("stale-cause", out)
        self.assertNotIn("retry-cause", out)
        self.assertNotIn("prose-only", out)

    def test_unmatched_rows_participate_in_ranking(self) -> None:
        now_ms = int(time.time() * 1000)
        dead_letters = [
            _dead_letter("unmatched-1", now_ms, "dept-a"),
            _dead_letter("unmatched-2", now_ms, "dept-b"),
            _dead_letter("matched", now_ms, "dept-c"),
        ]

        out = _run_durable_health(
            dead_letters,
            fact_lines=[_cause_fact("matched", "matched-cause", "fp-matched", "dept-c")],
        )

        self.assertIn("dead-letter cause (top): unattributed 2x depts=dept-a,dept-b", out)
        self.assertNotIn("dead-letter cause (top): error_class=matched-cause", out)

    def test_non_dominant_unmatched_rows_remain_explicit(self) -> None:
        now_ms = int(time.time() * 1000)
        dead_letters = [
            _dead_letter("matched-1", now_ms, "dept-a"),
            _dead_letter("matched-2", now_ms, "dept-a"),
            _dead_letter("unmatched", now_ms, "dept-z"),
        ]
        facts = [
            _cause_fact("matched-1", "matched-cause", "fp-matched", "dept-a"),
            _cause_fact("matched-2", "matched-cause", "fp-matched", "dept-a"),
        ]

        out = _run_durable_health(dead_letters, fact_lines=facts)

        self.assertIn("error_class=matched-cause fingerprint=fp-matched 2x dept=dept-a", out)
        self.assertIn("unattributed=1x dept=dept-z", out)

    def test_truncated_dead_letter_details_fail_visibly(self) -> None:
        out = _run_durable_health([], truncated=True)

        self.assertIn("⚠", out)
        self.assertIn(
            "dead-letter cause: unavailable (observe dead-letter details truncated)",
            out,
        )
        self.assertNotIn("dead-letter cause (top):", out)

    def test_only_old_dead_letters_do_not_flag_or_render_a_cause(self) -> None:
        now_ms = int(time.time() * 1000)
        seven_hours_ago = now_ms - 7 * 3600 * 1000
        old = [
            _dead_letter("old-1", seven_hours_ago),
            _dead_letter("old-2", seven_hours_ago),
        ]

        out = _run_durable_health(
            old,
            fact_lines=[
                _cause_fact("old-1", "old-cause", "fp-old"),
                _cause_fact("old-2", "old-cause", "fp-old"),
            ],
        )

        self.assertNotIn("⚠", out)
        self.assertIn("0 dead-letters<6h (2 total)", out)
        self.assertNotIn("dead-letter cause", out)

    def test_cause_ranking_ties_are_deterministic(self) -> None:
        now_ms = int(time.time() * 1000)
        dead_letters = [
            _dead_letter("beta", now_ms, "dept-b"),
            _dead_letter("alpha", now_ms, "dept-a"),
        ]
        facts = [
            _cause_fact("beta", "beta-cause", "fp-beta", "dept-b"),
            _cause_fact("alpha", "alpha-cause", "fp-alpha", "dept-a"),
        ]

        out = _run_durable_health(dead_letters, fact_lines=facts)

        self.assertIn(
            "dead-letter cause (top): error_class=alpha-cause "
            "fingerprint=fp-alpha 1x dept=dept-a",
            out,
        )


if __name__ == "__main__":
    unittest.main()
