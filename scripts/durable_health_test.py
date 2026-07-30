#!/usr/bin/env python3
"""Behavior tests for dogfood.sh durable dead-letter health reporting."""

from __future__ import annotations

import json
import os
import signal
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
    census_failure: bool = False,
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

        command_path = os.environ["PATH"]
        if census_failure:
            fake_commands = root / "bin"
            fake_commands.mkdir()
            fake_lsof = fake_commands / "lsof"
            fake_lsof.write_text(
                "#!/bin/sh\necho 'fixture census failure' >&2\nexit 1\n",
                encoding="utf-8",
            )
            fake_lsof.chmod(fake_lsof.stat().st_mode | stat.S_IXUSR)
            command_path = f"{fake_commands}:{command_path}"

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
            f'PATH="{command_path}"\n'
        )
        if cleanup_before_health:
            script += (
                f'PKGSRC="{root / "not-a-checkout"}"\n'
                f'clean_stale_runtime_worktrees packages "{log_root / "dogfood-rt-packages.current"}"\n'
                f'[ -d "{child_logs.parent.parent}" ] && echo "runtime-retained" || echo "runtime-removed"\n'
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


def _run_restart_ordering_health(dead_letter: dict, late_fact: str) -> subprocess.CompletedProcess[str]:
    """Restart while an orphaned old-runtime writer emits a post-readiness cause."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        durable_root = root / "durable"
        durable_root.mkdir()
        (durable_root / "delivery.redb").write_text("")
        observe = {
            "queues": [],
            "dead_letters": [dead_letter],
            "truncated": {"dead_letters": False},
        }
        (root / "observe.json").write_text(json.dumps(observe), encoding="utf-8")
        fake_bin = root / "fkst-framework"
        fake_bin.write_text(
            f'#!/bin/sh\ncat "{root / "observe.json"}"\n',
            encoding="utf-8",
        )
        fake_bin.chmod(fake_bin.stat().st_mode | stat.S_IXUSR)

        log_root = root / "logs"
        old_child_logs = (
            log_root / "dogfood-rt-packages.old" / "logs" / "framework-child"
        )
        old_child_logs.mkdir(parents=True)
        old_writer_log = old_child_logs / "late-dead-letter.log"
        old_writer_ready = root / "old-writer.ready"
        old_writer_release = root / "old-writer.release"
        old_writer_done = root / "old-writer.done"
        fake_pid_file = root / "fake-supervise.pid"
        package_root = root / "packages"
        (package_root / "scripts").mkdir(parents=True)
        fake_host_run = package_root / "scripts" / "run.sh"
        fake_host_run.write_text(
            """#!/bin/bash
set -eu
printf '%s\n' "$$" > "$FAKE_SUPERVISE_PID_FILE"
echo "EVENT=code_provenance source=fixture ENGINE_VER=fixture PKG_VERS=fixture"
echo "MSG=event runtime running"
echo "REPLACEMENT_READY=1"
sleep 30
""",
            encoding="utf-8",
        )
        fake_host_run.chmod(fake_host_run.stat().st_mode | stat.S_IXUSR)

        writer_env = {
            **os.environ,
            "LATE_CAUSE_FACT": late_fact,
            "OLD_WRITER_LOG": str(old_writer_log),
            "OLD_WRITER_READY": str(old_writer_ready),
            "OLD_WRITER_RELEASE": str(old_writer_release),
            "OLD_WRITER_DONE": str(old_writer_done),
        }
        old_supervisor = subprocess.Popen(
            [
                "/bin/bash",
                "-c",
                """
(
  exec 3>> "$OLD_WRITER_LOG"
  : > "$OLD_WRITER_READY"
  while [ ! -e "$OLD_WRITER_RELEASE" ]; do sleep 0.01; done
  printf '%s\n' "$LATE_CAUSE_FACT" >&3
  : > "$OLD_WRITER_DONE"
) &
wait
""",
            ],
            env=writer_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        deadline = time.monotonic() + 5
        while not old_writer_ready.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if not old_writer_ready.exists():
            old_supervisor.kill()
            old_supervisor.wait(timeout=5)
            raise RuntimeError("old-runtime writer did not open its log")
        old_supervisor.kill()
        old_supervisor.wait(timeout=5)

        script = f'''source "{DOGFOOD}"
cfg() {{ DUR="{durable_root}"; return 0; }}
derive_devloop_pkgs_from_workspace() {{ DEVLOOP_PKGS="github-proxy"; }}
wait_supervise_ready() {{
  local pid="$1" log="$2" attempts=0
  while [ "$attempts" -lt 500 ]; do
    grep -q "REPLACEMENT_READY=1" "$log" 2>/dev/null && return 0
    pid_alive_non_zombie "$pid" || return 1
    attempts=$((attempts + 1))
    sleep 0.01
  done
  return 2
}}
PKGSRC="{package_root}"
HOST="{package_root}"
DUR="{durable_root}"
LOGDIR="{log_root}"
BIN="{fake_bin}"
REPO="ChronoAIProject/fkst-packages"
BOT="fixture-bot"
LOCAL_PKGS=""
launch_one packages 1
launch_status=$?
if [ ! -d "{old_child_logs}" ]; then
  echo "old runtime removed while its orphaned writer was active" >&2
  launch_status=42
else
  : > "{old_writer_release}"
  attempts=0
  while [ ! -e "{old_writer_done}" ] && [ "$attempts" -lt 500 ]; do
    attempts=$((attempts + 1))
    sleep 0.01
  done
  if [ ! -e "{old_writer_done}" ]; then
    echo "old-runtime writer did not emit its late cause" >&2
    launch_status=43
  fi
fi
if [ -f "{fake_pid_file}" ]; then
  fake_pid=$(sed -n '1p' "{fake_pid_file}")
  kill "$fake_pid" 2>/dev/null || true
  wait "$fake_pid" 2>/dev/null || true
fi
durable_health_one packages
exit "$launch_status"
'''
        try:
            return subprocess.run(
                ["/bin/bash", "-c", script],
                cwd=str(REPO_ROOT),
                env={
                    **os.environ,
                    "DOGFOOD_REPOS": "packages",
                    "FAKE_SUPERVISE_PID_FILE": str(fake_pid_file),
                },
                capture_output=True,
                text=True,
                timeout=30,
            )
        finally:
            old_writer_release.touch(exist_ok=True)
            try:
                os.killpg(old_supervisor.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


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

    def test_restart_cleanup_retains_runtime_when_writer_census_fails(self) -> None:
        now_ms = int(time.time() * 1000)

        out = _run_durable_health(
            [_dead_letter("delivery-1", now_ms, "dept-a")],
            fact_lines=[_cause_fact("delivery-1", "quota-exhausted", "fp-quota")],
            cleanup_before_health=True,
            census_failure=True,
        )

        self.assertIn("runtime-retained", out)
        self.assertNotIn("runtime-removed", out)
        self.assertIn("fixture census failure", out)

    def test_restart_retains_old_runtime_until_orphaned_writer_finishes(self) -> None:
        now_ms = int(time.time() * 1000)

        result = _run_restart_ordering_health(
            _dead_letter("delivery-late", now_ms, "dept-late"),
            _cause_fact(
                "delivery-late",
                "late-terminal-failure",
                "fp-late",
                "dept-late",
            ),
        )
        output = result.stdout + result.stderr

        self.assertEqual(result.returncode, 0, output)
        self.assertIn(
            "dead-letter cause (top): error_class=late-terminal-failure "
            "fingerprint=fp-late 1x dept=dept-late",
            output,
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
