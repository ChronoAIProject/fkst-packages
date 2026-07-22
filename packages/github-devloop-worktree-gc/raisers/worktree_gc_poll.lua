-- Periodic tick driving the level-triggered worktree GC sweep. The sweep is
-- stateless and idempotent: a worktree not safely removable this tick is simply
-- retried next tick. 30m is a coarse cadence — the leak is slow (accumulates only
-- across restarts and terminal branches) and the sweep must never contend with
-- active worktree creation, which it already avoids via the old-runtime-root scope.
return {
  type = "cron",
  interval = "30m",
  produces = "worktree_gc_tick",
}
