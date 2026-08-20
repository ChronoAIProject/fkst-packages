local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
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
local issue_implement_selector = "title,body,labels,comments,state,author"

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

local function render_comment(body)
  return string.format(
    '{"body":"%s","author":{"login":"fkst-test-bot"},"createdAt":"2026-08-01T00:00:00Z"}',
    tostring(body or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
  )
end

local function mock_wip_cap_reached()
  local holder_number = 51
  local holder_proposal = base_ids.proposal_id("owner/repo", holder_number)
  local holder_version = "ready/github-devloop/issue/owner/repo/51/intake/1"
  t.mock_command('printf %s "$FKST_DEVLOOP_MAX_INFLIGHT"', {
    stdout = "1", stderr = "", exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = "dev", stderr = "", exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = "integration", stderr = "", exit_code = 0,
  })
  t.mock_command(core.gh_issue_list_wip_cmd("owner/repo"), {
    stdout = '[{"number":51}]\n', stderr = "", exit_code = 0,
  })
  t.mock_command(core.gh_issue_view_state_cmd("owner/repo", holder_number), {
    stdout = string.format(
      '{"title":"WIP holder","state":"OPEN","labels":[{"name":"fkst-dev:implementing"}],"comments":[%s],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
      render_comment(core.state_marker(holder_proposal, "implementing", holder_version))
    ),
    stderr = "", exit_code = 0,
  })
end

local function impl_failed_comments(event, ready_version, command, earlier_comments)
  local comments = {}
  for _, comment in ipairs(earlier_comments or {}) do
    table.insert(comments, comment)
  end
  table.insert(comments, core.state_marker(event.proposal_id, "impl-failed", ready_version))
  table.insert(comments,
    core.impl_failure_marker(event.proposal_id, ready_version, "codex-failed", 2, "UNKNOWN", true))
  table.insert(comments, command)
  return comments
end

local function operator_ready_source(event, key)
  return {
    proposal_id = event.proposal_id,
    dedup_key = event.dedup_key,
    source_ref = event.source_ref,
    impl_retry_attempt = 2,
    operator_reimplement_delivery = {
      command_key = key,
    },
  }
end

local function observe_reimplement(event, ready_version, command, earlier_comments, name)
  local entity_version = command.created_at
  entity_read_mocks.mock_issue_view_selector(t, {
    labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" },
    comments = impl_failed_comments(event, ready_version, command, earlier_comments),
    state = "OPEN",
  }, issue_state_selector, 1)
  local result = run_observe(
    issue({
      labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" },
      updated_at = entity_version,
      dedup_key = "owner/repo#issue#42@" .. entity_version,
    }),
    opts(name)
  )
  t.eq(result.exit_code, 0)
  local ready = find_raise(result.raises, "devloop_ready")
  local response = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("operator command accepted: reimplement", 1, true) ~= nil
  end)
  t.is_true(ready ~= nil, name .. ": reimplement did not raise devloop_ready")
  t.eq(response, nil, name .. ": observe_issue emitted applied before lifecycle admission")
  return ready.payload
end

local function admit_reimplementation(event, ready, name)
  local logical_version = ready.implementation_version
  local worktree_version = core.implementation_attempt_version(logical_version, ready.impl_retry_attempt)
  local branch_version = core.implementation_branch_version(logical_version, ready.impl_retry_attempt)
  local comments = {
    core.state_marker(event.proposal_id, "impl-failed", logical_version),
    core.impl_failure_marker(event.proposal_id, logical_version, "codex-failed", 2, "UNKNOWN", true),
  }
  entity_read_mocks.mock_issue_view_selector(t, {
    labels = { "fkst-dev:impl-failed" },
    comments = comments,
    state = "OPEN",
  }, issue_implement_selector, 3)
  entity_read_mocks.mock_issue_view_selector(t, {
    title = "Implement decision recorder",
    author_login = "fkst-test-bot",
  }, "number,title,author", 1)
  mock_existing_empty_implement_worktree({
    impl_version = worktree_version,
  })
  mock_implement_codex(0, "implemented")
  mock_git_status(" M packages/github-devloop/core.lua\n")
  mock_git_commit(nil, devloop_base.implement_branch("owner/repo", "42", branch_version))

  local result = run_implement(ready, opts(name))
  t.eq(result.exit_code, 0)
  local worktree_ready = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("github-devloop implementation worktree ready", 1, true) ~= nil
  end)
  t.is_true(worktree_ready ~= nil, name .. ": implement did not admit the reimplementation")
  t.is_true(worktree_ready.payload.body:find('state="implementing"', 1, true) ~= nil,
    name .. ": lifecycle admission state fact is missing")
  t.is_true(worktree_ready.payload.body:find('outcome="applied"', 1, true) ~= nil,
    name .. ": lifecycle admission did not acknowledge the command")
  return worktree_ready.payload
end

return {
  test_reimplement_does_not_report_applied_when_wip_admission_has_no_postcondition = function()
    local event = reached()
    local ready_version = payloads_builders.build_devloop_ready_payload(event).dedup_key
    local command = trusted_command("IC_reimplement_wip_held")
    local comments = impl_failed_comments(event, ready_version, command)
    entity_read_mocks.mock_issue_view_selector(t, {
      labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" },
      comments = comments,
      state = "OPEN",
    }, issue_state_selector, 1)

    local observed = run_observe(
      issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }),
      opts("observe-reimplement-before-wip-hold")
    )
    t.eq(observed.exit_code, 0)
    local ready = find_raise(observed.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    local early_applied = find_raise(observed.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('outcome="applied"', 1, true) ~= nil
    end)

    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)
    mock_wip_cap_reached()
    local implemented = run_implement(ready.payload, opts("implement-reimplement-wip-held"))

    t.eq(implemented.exit_code, 0)
    t.eq(find_raise(implemented.raises, "github-proxy.github_issue_comment_request"), nil,
      "WIP-held reimplement must not emit a lifecycle postcondition or applied response")
    t.eq(early_applied, nil,
      "observe_issue reported applied before the lifecycle owner admitted work")
  end,

  test_operator_reimplement_delivery_identity_is_replay_stable_and_command_distinct = function()
    local event = reached()
    local normal_ready = payloads_builders.build_devloop_ready_payload(event)
    local first_key = command_key(trusted_command("IC_reimplement_first"))
    local second_key = command_key(trusted_command("IC_reimplement_second"))

    local first = payloads_builders.build_devloop_ready_payload(operator_ready_source(event, first_key)
    )
    local replay = payloads_builders.build_devloop_ready_payload(operator_ready_source(event, first_key)
    )
    local second = payloads_builders.build_devloop_ready_payload(operator_ready_source(event, second_key)
    )

    t.eq(first.implementation_version, normal_ready.dedup_key)
    t.eq(first.dedup_key, replay.dedup_key)
    t.is_true(first.dedup_key ~= second.dedup_key)
    t.eq(first.operator_reimplement_delivery.command_key, first_key)
    t.eq(second.operator_reimplement_delivery.command_key, second_key)
  end,

  test_distinct_reimplement_commands_deliver_and_admit_under_unchanged_failure = function()
    local event = reached()
    local ready_version = payloads_builders.build_devloop_ready_payload(event).dedup_key
    local first_command = trusted_command("IC_reimplement_delivery_first", "2026-08-01T01:00:00Z")
    local second_command = trusted_command("IC_reimplement_delivery_second", "2026-08-01T01:02:00Z")

    local first = observe_reimplement(
      event,
      ready_version,
      first_command,
      nil,
      "observe-reimplement-first-command"
    )
    local first_response = admit_reimplementation(event, first, "implement-reimplement-first-command")
    local second_ready_version = core.implementation_attempt_version(
      first.implementation_version,
      first.impl_retry_attempt
    )
    local second = observe_reimplement(event, second_ready_version, second_command, {
      first_command,
      {
        id = "IC_reimplement_delivery_first_response",
        body = first_response.body,
        author_login = "fkst-test-bot",
        created_at = "2026-08-01T01:01:00Z",
      },
    }, "observe-reimplement-second-command")

    t.eq(first.impl_retry_attempt, 2)
    t.eq(second.impl_retry_attempt, 3)
    t.eq(first.implementation_version, ready_version)
    t.eq(second.implementation_version, second_ready_version)
    t.eq(first.operator_reimplement_delivery.command_key, command_key(first_command))
    t.eq(second.operator_reimplement_delivery.command_key, command_key(second_command))
    t.is_true(first.dedup_key ~= second.dedup_key)

    admit_reimplementation(event, second, "implement-reimplement-second-command")
  end,
}
