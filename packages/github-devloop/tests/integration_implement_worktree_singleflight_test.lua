local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local payloads_shared = require("devloop.payloads.shared")

local t = h.t
local core = h.core

local function redrive_ready(event)
  local payload = payloads_builders.build_devloop_ready_payload({
    proposal_id = event.proposal_id,
    dedup_key = core.ready_payload_inner_version(event.dedup_key),
    source_ref = event.source_ref,
    impl_retry_attempt = core.implementation_retry_attempt(event.dedup_key),
    redrive_delivery = {
      generation_key = "restart-liveness-v2/implementing/implementing.active/codex_run-v1/codex-run-not-running/1783840000000",
      attempt = 1,
    },
  })
  t.eq(payload.dedup_key, payloads_shared.issue_redrive_delivery_dedup_key(
    payload.proposal_id, payload.implementation_version, payload.redrive_delivery
  ))
  return payload
end

local function mock_redrive_attempt(event)
  local branch = h.deterministic_branch_for(event)
  local comments = {
    core.state_marker(event.proposal_id, "implementing", event.dedup_key),
    core.implement_attempt_marker(
      event.proposal_id,
      event.dedup_key,
      1,
      tostring(now() - 7201)
    ),
  }
  h.mock_issue_implement({ "fkst-dev:implementing" }, comments)
  t.mock_command("git fetch 'origin' '" .. branch .. "'", {
    stdout = "",
    stderr = "fatal: couldn't find remote ref",
    exit_code = 128,
  })
  t.mock_command("show-ref --verify --quiet", {
    stdout = "",
    stderr = "",
    exit_code = 1,
  })
  h.mock_fresh_implement_worktree()
  h.mock_implement_codex(0, "implemented after redrive")
  h.mock_git_status(" M packages/github-devloop/core.lua\n")
  h.mock_git_commit("def456", branch)
  h.mock_issue_implement({ "fkst-dev:implementing" }, comments)
end

return {
  test_redrive_drops_before_worktree_preparation_when_verification_is_in_flight = function()
    local current = h.ready()
    local event = redrive_ready(current)
    mock_redrive_attempt(current)
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_LEASE:v1", {
      stdout = "FKST_IMPLEMENTATION_WORKTREE_LEASE:v1:BUSY:4242\n",
      stderr = "",
      exit_code = 0,
    })

    local result = h.run_implement(event, h.opts("implement-redrive-worktree-busy"))

    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("git fetch"), 0)
    t.eq(h.count_calls("git worktree"), 0)
    t.eq(h.count_calls("reset --hard"), 0)
    t.eq(h.count_calls("clean -fd"), 0)
    t.eq(h.count_calls("codex exec"), 0)
    t.eq(h.count_calls("scripts/run.sh test-affected"), 0)
    t.eq(h.count_calls("FKST_IMPLEMENTATION_WORKTREE_LEASE:v1"), 1)
  end,

  test_redrive_prepares_and_verifies_when_worktree_is_idle = function()
    local current = h.ready()
    local event = redrive_ready(current)
    mock_redrive_attempt(current)

    local result = h.run_implement(event, h.opts("implement-redrive-worktree-idle"))

    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("reset --hard"), 1)
    t.eq(h.count_calls("clean -fd"), 1)
    t.eq(h.count_calls("codex exec"), 1)
  end,
}
