-- Reproduction for the SECOND consecutive operator `reimplement`.
local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local t = h.t
local core = h.core
local opts = h.opts
local issue = h.issue
local reached = h.reached
local run_observe = h.run_observe
local run_implement = h.run_implement
local mock_issue_state = h.mock_issue_state
local mock_issue_implement_raw = h.mock_issue_implement_raw
local mock_existing_empty_implement_worktree = h.mock_existing_empty_implement_worktree
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local find_raise = h.find_raise

local function trusted_command(id)
  return {
    id = id or "IC_second_reimplement",
    body = "fkst: reimplement",
    author_login = "fkst-test-bot",
    created_at = "2026-06-04T03:00:00Z",
  }
end

local function second_round_comments(event, base_version, command)
  local replacement_version = base_version .. "/reimplement/2"
  local comments = {
    core.state_marker(event.proposal_id, "impl-failed", replacement_version),
    core.impl_failure_marker(event.proposal_id, replacement_version, "codex-failed", 2),
  }
  if command ~= nil then
    table.insert(comments, command)
  end
  return comments, replacement_version
end

local function find_worktree_ready_comment(raises)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("github-devloop implementation worktree ready", 1, true) ~= nil
  end)
end

local function assert_invalid_lineage(fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find("invalid-version-lineage", 1, true) ~= nil)
end

return {
  test_next_attempt_version_derives_from_a_prior_replacement_round = function()
    local event = reached()
    local base_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local replacement_version = base_version .. "/reimplement/2"

    t.eq(core.implementation_branch_version(replacement_version, 3), base_version)
    t.eq(core.implementation_attempt_version(replacement_version, 3), base_version .. "/reimplement/3")
  end,

  test_retry_lineage_accepts_only_the_current_or_immediate_next_attempt = function()
    local event = reached()
    local base_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local first_replacement_version = base_version .. "/reimplement/1"
    local replacement_version = base_version .. "/reimplement/2"

    t.eq(core.implementation_branch_version(first_replacement_version, 1), first_replacement_version)
    t.eq(core.implementation_attempt_version(first_replacement_version, 1), first_replacement_version)
    t.eq(core.implementation_branch_version(first_replacement_version, 2), base_version)
    t.eq(core.implementation_attempt_version(first_replacement_version, 2), replacement_version)
    assert_invalid_lineage(function()
      core.implementation_attempt_version(first_replacement_version, 3)
    end)

    t.eq(core.implementation_branch_version(replacement_version, 2), base_version)
    t.eq(core.implementation_attempt_version(replacement_version, 2), replacement_version)
    assert_invalid_lineage(function()
      core.implementation_branch_version(replacement_version, 1)
    end)
    assert_invalid_lineage(function()
      core.implementation_attempt_version(replacement_version, 4)
    end)
  end,

  test_malformed_retry_lineage_records_visible_failure_instead_of_crashing = function()
    local event = reached()
    local base_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local first_replacement_version = base_version .. "/reimplement/1"
    local ready = payloads_builders.build_devloop_ready_payload(core, event)
    ready.dedup_key = first_replacement_version
    ready.impl_retry_attempt = 3
    local comments = {
      core.state_marker(event.proposal_id, "impl-failed", first_replacement_version),
      core.impl_failure_marker(event.proposal_id, first_replacement_version, "codex-failed", 1),
    }
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)

    local result = run_implement(ready, opts("implement-malformed-retry-lineage"))

    t.eq(result.exit_code, 0)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment ~= nil)
    t.is_true(comment.payload.body:find("invalid-version-lineage", 1, true) ~= nil)
    t.is_true(comment.payload.body:find(
      core.state_marker(event.proposal_id, "impl-failed", first_replacement_version),
      1,
      true
    ) ~= nil)
    local label = find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.eq(label.payload.add_labels[1], "fkst-dev:impl-failed")
  end,

  test_second_operator_reimplement_raises_next_attempt = function()
    local event = reached()
    local base_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local comments, replacement_version = second_round_comments(event, base_version, trusted_command())
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN", comments)

    local result = run_observe(
      issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }),
      opts("observe-second-reimplement")
    )

    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.implementation_version, replacement_version)
    t.eq(ready.payload.operator_reimplement_delivery.command_key,
      "operator-command/IC_second_reimplement")
    t.is_true(ready.payload.dedup_key ~= replacement_version)
    t.eq(ready.payload.impl_retry_attempt, 3)
  end,

  test_second_reimplement_ready_event_runs_the_retry_instead_of_crashing = function()
    local event = reached()
    local base_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local replacement_version = base_version .. "/reimplement/2"
    local ready = payloads_builders.build_devloop_ready_payload(core, event)
    ready.dedup_key = replacement_version
    ready.impl_retry_attempt = 3

    local comments = second_round_comments(event, base_version)
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)
    mock_existing_empty_implement_worktree({
      impl_version = base_version .. "/reimplement/3",
    })
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(nil, devloop_base.implement_branch("owner/repo", "42", base_version))
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)

    local result = run_implement(ready, opts("implement-second-reimplement"))

    t.eq(result.exit_code, 0)
    local comment = find_worktree_ready_comment(result.raises)
    t.is_true(comment ~= nil)
    t.is_true(comment.payload.body:find(
      core.state_marker(event.proposal_id, "implementing", base_version .. "/reimplement/3"),
      1,
      true
    ) ~= nil)
  end,
}
