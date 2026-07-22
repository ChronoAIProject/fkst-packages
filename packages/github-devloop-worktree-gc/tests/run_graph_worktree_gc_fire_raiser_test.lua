-- Producer-liveness: the real worktree_gc_poll cron tick must route to the
-- worktree_gc department and be accepted end-to-end through production ports.
local graph = require("testkit.graph")
local t = fkst.test

return {
  test_fire_raiser_worktree_gc_poll_routes_real_tick_to_worktree_gc = function()
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/runtime/dogfood-rt-packages.current",
      stderr = "",
      exit_code = 0,
    })
    -- Dry-run posture (removal disabled) — the dept reads this host fact each pass.
    t.mock_command('printf %s "$FKST_WORKTREE_GC_REMOVE"', { stdout = "", stderr = "", exit_code = 0 })
    -- No worktrees registered this pass: the sweep is a clean no-op.
    t.mock_command("git worktree list --porcelain", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git worktree prune", { stdout = "", stderr = "", exit_code = 0 })

    local trace = t.fire_raiser("worktree_gc_poll")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "worktree_gc_poll")
    t.eq(trace.routed_to[1], "worktree_gc")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    -- The GC is a terminal effect sweep; it raises no downstream events.
    t.eq(#trace.raised, 0)
    graph.assert_covers(trace, {})
  end,
}
