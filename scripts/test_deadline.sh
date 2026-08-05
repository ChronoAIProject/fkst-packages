#!/usr/bin/env bash
# Bounded-execution watchdog for `scripts/run.sh test` (sourced by run.sh; armed in cmd_test).
#
# Rationale (CLAUDE.md error-cleanup-patrol + harness doctrine, prevention half): a test run whose launching
# parent (a codex implement/fix worker, or the operator shell) is SIGKILLed does NOT die with it —
# SIGKILL neither propagates to children nor fires run.sh's EXIT trap — so the run orphans to init and
# hangs UNBOUNDED (observed 2026-07-22: 6 orphaned trees 44min–1h15min old, a real load driver). Make
# that illegal state unrepresentable at the source: arm_test_deadline forks a watchdog that group-kills
# the whole run after FKST_TEST_DEADLINE_SECONDS (default 1800s ≈ 4-8x the ~230-440s healthy suite), so
# an orphaned run self-terminates instead of hanging. It arms ONLY when this shell leads its own process
# group (the codex/dogfood launch path new-sessions run.sh, pgid==pid); in an interactive shell the group
# is shared — killing it would take the user's shell, and an interactive hang is Ctrl-C's job — so arming
# is skipped there. run.sh's EXIT trap calls disarm_test_deadline so a normal finish leaves nothing behind.

# TEST_DEADLINE_WATCHDOG holds the watchdog pid so disarm_test_deadline can stop it on a normal exit.
TEST_DEADLINE_WATCHDOG=""

arm_test_deadline() {
  local secs="${FKST_TEST_DEADLINE_SECONDS:-1800}" pgid
  case "$secs" in ''|*[!0-9]*) return 0 ;; esac
  [ "$secs" -gt 0 ] || return 0
  # Read our pgid failure-safely: under `set -euo pipefail` a denied/failed ps must degrade to "don't arm"
  # (empty pgid), never abort the whole test run. Arm ONLY when this shell IS its own group leader
  # (pgid==$$) — the codex/dogfood launch path new-sessions run.sh into its own group (observed: the leaked
  # zsh harness had pgid==pid), so kill -9 -$pgid can only ever target this run's tree; an interactive/shared
  # group is skipped (Ctrl-C's job) so the watchdog never kills a bystander.
  pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ') || pgid=""
  [ -n "$pgid" ] && [ "$pgid" = "$$" ] || return 0
  (
    sleep "$secs"
    echo "run.sh test: FKST_TEST_DEADLINE_SECONDS=${secs}s exceeded — group-killing runaway test tree (pgid $pgid)" >&2
    kill -9 -"$pgid" 2>/dev/null
  ) &
  TEST_DEADLINE_WATCHDOG=$!
}

disarm_test_deadline() {
  [ -n "${TEST_DEADLINE_WATCHDOG:-}" ] || return 0
  # Reap the WHOLE watchdog subtree, not just the subshell: the subshell's `sleep` child must be killed
  # too, or on a normal finish it is left orphaned — where it (a) holds any inherited fds open and, worse,
  # (b) fires a STALE `kill -9 -pgid` up to FKST_TEST_DEADLINE_SECONDS later, when that pgid may have been
  # reused by an unrelated process. pkill -P kills the sleep child; then stop the subshell and reap it.
  pkill -P "$TEST_DEADLINE_WATCHDOG" 2>/dev/null || true
  kill "$TEST_DEADLINE_WATCHDOG" 2>/dev/null || true
  wait "$TEST_DEADLINE_WATCHDOG" 2>/dev/null || true
  TEST_DEADLINE_WATCHDOG=""
}
