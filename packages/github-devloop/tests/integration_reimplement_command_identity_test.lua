local devloop_base = require("devloop.base")
local operator_commands = require("devloop.operator_commands")
local payloads_builders = require("devloop.payloads.builders")
local h = require("tests.devloop_helpers")
local entity_read_mocks = require("tests.entity_read_mock_helpers")

local t = h.t
local core = h.core
local opts = h.opts
local issue = h.issue
local reached = h.reached
local run_observe = h.run_observe
local run_implement = h.run_implement
local mock_issue_implement_raw = h.mock_issue_implement_raw
local mock_existing_empty_implement_worktree = h.mock_existing_empty_implement_worktree
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local find_raise = h.find_raise

local issue_state_selector = "title,body,comments,labels,state,createdAt,updatedAt,assignees,author"

local function trusted_command(id, created_at)
  return {
    id = id,
    body = "fkst: reimplement",
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-08-01T01:00:00Z",
  }
end

local function command_key(command)
  return operator_commands.operator_command_fact({ command }, "reimplement").key
end

local function impl_failed_comments(event, ready_version, command, earlier_comments)
  local comments = {
    h.state_marker(event.proposal_id, "impl-failed", ready_version),
    core.impl_failure_marker(event.proposal_id, ready_version, "codex-failed", 2),
  }
  for _, comment in ipairs(earlier_comments or {}) do
    table.insert(comments, comment)
  end
  table.insert(comments, command)
  return comments
end

local function operator_ready_source(event, key)
  return {
    proposal_id = event.proposal_id,
    dedup_key = event.dedup_key,
    source_ref = event.source_ref,
    impl_retry_attempt = 3,
    operator_reimplement_delivery = {
      command_key = key,
    },
  }
end

local function observe_reimplement(event, ready_version, command, earlier_comments, name)
  entity_read_mocks.mock_issue_view_selector(t, {
    labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" },
    comments = impl_failed_comments(event, ready_version, command, earlier_comments),
    state = "OPEN",
  }, issue_state_selector, 1)
  local result = run_observe(
    issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }),
    opts(name)
  )
  t.eq(result.exit_code, 0)
  local ready = find_raise(result.raises, "devloop_ready")
  local response = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("operator command accepted: reimplement", 1, true) ~= nil
  end)
  t.is_true(ready ~= nil, name .. ": reimplement did not raise devloop_ready")
  t.is_true(response ~= nil, name .. ": reimplement did not raise an applied response")
  return ready.payload, response.payload
end

local function admit_reimplementation(event, ready, name)
  local logical_version = ready.implementation_version
  local comments = {
    h.state_marker(event.proposal_id, "impl-failed", logical_version),
    core.impl_failure_marker(event.proposal_id, logical_version, "codex-failed", 2),
  }
  for _ = 1, 3 do
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)
  end
  mock_existing_empty_implement_worktree({
    impl_version = logical_version .. "/reimplement/3",
  })
  mock_implement_codex(0, "implemented")
  mock_git_status(" M packages/github-devloop/core.lua\n")
  mock_git_commit(nil, devloop_base.implement_branch("owner/repo", "42", logical_version))

  local result = run_implement(ready, opts(name))
  t.eq(result.exit_code, 0)
  local worktree_ready = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("github-devloop implementation worktree ready", 1, true) ~= nil
  end)
  t.is_true(worktree_ready ~= nil, name .. ": implement did not admit the reimplementation")
end

return {
  test_operator_reimplement_delivery_identity_is_replay_stable_and_command_distinct = function()
    local event = reached()
    local normal_ready = payloads_builders.build_devloop_ready_payload(core, event)
    local first_key = command_key(trusted_command("IC_reimplement_first"))
    local second_key = command_key(trusted_command("IC_reimplement_second"))

    local first = payloads_builders.build_devloop_ready_payload(
      core,
      operator_ready_source(event, first_key)
    )
    local replay = payloads_builders.build_devloop_ready_payload(
      core,
      operator_ready_source(event, first_key)
    )
    local second = payloads_builders.build_devloop_ready_payload(
      core,
      operator_ready_source(event, second_key)
    )

    t.eq(first.implementation_version, normal_ready.dedup_key)
    t.eq(first.dedup_key, replay.dedup_key)
    t.is_true(first.dedup_key ~= second.dedup_key)
    t.eq(first.operator_reimplement_delivery.command_key, first_key)
    t.eq(second.operator_reimplement_delivery.command_key, second_key)
  end,

  test_distinct_reimplement_commands_deliver_and_admit_under_unchanged_failure = function()
    local event = reached()
    local ready_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local first_command = trusted_command("IC_reimplement_delivery_first", "2026-08-01T01:00:00Z")
    local second_command = trusted_command("IC_reimplement_delivery_second", "2026-08-01T01:02:00Z")

    local first, first_response = observe_reimplement(
      event,
      ready_version,
      first_command,
      nil,
      "observe-reimplement-first-command"
    )
    local second = observe_reimplement(event, ready_version, second_command, {
      first_command,
      {
        id = "IC_reimplement_delivery_first_response",
        body = first_response.body,
        author_login = "fkst-test-bot",
        created_at = "2026-08-01T01:01:00Z",
      },
    }, "observe-reimplement-second-command")

    t.eq(first.impl_retry_attempt, 3)
    t.eq(second.impl_retry_attempt, 3)
    t.eq(first.implementation_version, ready_version)
    t.eq(second.implementation_version, ready_version)
    t.eq(first.operator_reimplement_delivery.command_key, command_key(first_command))
    t.eq(second.operator_reimplement_delivery.command_key, command_key(second_command))
    t.is_true(first.dedup_key ~= second.dedup_key)

    admit_reimplementation(event, first, "implement-reimplement-first-command")
    admit_reimplementation(event, second, "implement-reimplement-second-command")
  end,
}
