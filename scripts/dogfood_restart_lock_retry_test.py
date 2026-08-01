#!/usr/bin/env python3
"""Behaviour tests for dogfood.sh's launch_with_lock_retry redb lock-race retry.

`restart` is the deploy path and is NOT atomic: it SIGKILLs the old supervise and then opens the
durable store. That kill does not always release the redb lock in time, and the race loser exits
with `Database already open. Cannot acquire lock.` leaving NOTHING running -- a full pipeline
outage whose next signal is the following operator wake, potentially hours later (incident
2026-08-01, issue #3001).

The retry must be narrow. Retrying every failure would turn a genuine startup error (bad config,
engine panic, missing BIN) into minutes of silent looping before it surfaced, which is strictly
worse than failing immediately. So the fail-fast case below is as load-bearing as the retry case.

These drive the real shell function extracted from dogfood.sh with a stubbed `launch_one`, so they
exercise the shipped code rather than a restatement of it.
"""

import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DOGFOOD_SH = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh"
LOCK_ERROR = "Database already open. Cannot acquire lock."

# Extract only launch_with_lock_retry, then supply a stub launch_one. `sed` range-matches the function header
# through its closing brace at column 0.
HARNESS = r"""
set -u
LOGDIR=$(mktemp -d)
eval "$(sed -n '/^launch_with_lock_retry() { # \$1 name/,/^}/p' "$DOGFOOD_SH")"
ATTEMPTS=0
launch_one() {
  ATTEMPTS=$((ATTEMPTS+1))
  if [ -n "$STUB_LOG_TEXT" ]; then
    printf '%s\n' "$STUB_LOG_TEXT" > "$LOGDIR/x-sv-$ATTEMPTS.log"
  fi
  if [ "$ATTEMPTS" -ge "$SUCCEED_ON" ]; then return 0; fi
  return 1
}
launch_with_lock_retry x 1 >/dev/null 2>&1
rc=$?
rm -rf "$LOGDIR"
echo "rc=$rc attempts=$ATTEMPTS"
"""


def run_case(log_text, succeed_on, dogfood_sh=None):
    """Run launch_with_lock_retry with a stub that writes `log_text` and succeeds on attempt `succeed_on`.

    succeed_on=0 means never succeed.
    """
    env_script = HARNESS
    proc = subprocess.run(
        ["bash", "-c", env_script],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DOGFOOD_SH": str(dogfood_sh or DOGFOOD_SH),
            "STUB_LOG_TEXT": log_text,
            # 0 -> never succeeds; use a value above the retry bound
            "SUCCEED_ON": str(succeed_on if succeed_on else 9999),
        },
        timeout=120,
    )
    out = proc.stdout.strip().split()
    parsed = dict(part.split("=", 1) for part in out if "=" in part)
    return int(parsed["rc"]), int(parsed["attempts"])


class LaunchOneLockRetry(unittest.TestCase):
    def test_lock_race_is_retried_until_it_succeeds(self):
        """The incident case: the lock frees up and the supervise comes back without an operator."""
        rc, attempts = run_case(LOCK_ERROR, succeed_on=3)
        self.assertEqual(rc, 0)
        self.assertEqual(attempts, 3)

    def test_non_lock_failure_fails_fast_without_retrying(self):
        """A real startup error must surface on the first attempt, not after minutes of looping."""
        rc, attempts = run_case("engine panic: bad config", succeed_on=0)
        self.assertEqual(rc, 1)
        self.assertEqual(attempts, 1)

    def test_persistent_lock_is_bounded_and_still_fails(self):
        """A genuinely held lock must not loop forever; it must give up and report failure."""
        rc, attempts = run_case(LOCK_ERROR, succeed_on=0)
        self.assertEqual(rc, 1)
        self.assertEqual(attempts, 5)

    def test_first_attempt_success_does_not_retry(self):
        rc, attempts = run_case("", succeed_on=1)
        self.assertEqual(rc, 0)
        self.assertEqual(attempts, 1)

    def test_missing_log_does_not_retry(self):
        """With no log to classify the failure, the retry must not fire blindly."""
        rc, attempts = run_case("", succeed_on=0)
        self.assertEqual(rc, 1)
        self.assertEqual(attempts, 1)


if __name__ == "__main__":
    unittest.main()
