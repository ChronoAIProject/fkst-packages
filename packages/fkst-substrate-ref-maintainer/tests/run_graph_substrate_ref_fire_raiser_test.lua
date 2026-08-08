local fixture = require("tests.substrate_ref_scan_helpers")

local t = fixture.t

local function mock_positive_merge()
  fixture.mock_env("1")
  fixture.mock_current_pin(fixture.current_pin)
  fixture.mock_substrate_head(fixture.target_sha)
  fixture.mock_substrate_check_runs_green(fixture.target_sha, 3)
  fixture.mock_no_existing_pr()
  fixture.mock_branch_missing()
  fixture.mock_base_head()
  fixture.mock_runtime_root("substrate-fire-raiser")
  fixture.mock_no_checked_out_bump_branch()
  fixture.mock_worktree_commands("substrate-fire-raiser", false)
  fixture.mock_pr_create()
  fixture.mock_bump_pr_view()
  fixture.mock_bump_diff()
  fixture.mock_branch_head_for_merge(fixture.pr_head_sha, fixture.target_sha)
  fixture.mock_branch_head_for_merge(fixture.pr_head_sha, fixture.target_sha)
  fixture.mock_substrate_pin_ancestor(fixture.target_sha)
  fixture.mock_bump_diff()
  fixture.mock_branch_head_for_merge(fixture.pr_head_sha, fixture.target_sha)
  fixture.mock_substrate_pin_ancestor(fixture.target_sha)
  fixture.mock_merge_success()
end

return {
  test_fire_raiser_substrate_ref_poll_raises_deterministic_merge_audit = function()
    mock_positive_merge()

    local trace = t.fire_raiser("substrate_ref_poll")

    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "fkst-substrate-ref-maintainer.substrate_ref_poll")
    t.eq(trace.routed_to[1], "fkst-substrate-ref-maintainer.substrate_ref_scan")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    local audit = nil
    for _, raised in ipairs(trace.raised) do
      if raised.queue == "github-proxy.github_pr_comment_request"
        and tostring(raised.payload.body):find("fkst:github-devloop:substrate-ref-merge:v1", 1, true) ~= nil then
        audit = raised
      end
    end
    t.is_true(audit ~= nil)
    t.eq(audit.payload.pr_number, fixture.pr_number)
    t.is_true(audit.payload.body:find('target_sha="' .. fixture.target_sha .. '"', 1, true) ~= nil)
  end,
}
