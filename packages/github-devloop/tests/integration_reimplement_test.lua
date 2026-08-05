local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local requests_lifecycle = require("devloop.requests.lifecycle")
local m_facts = require("devloop.markers.facts")
local conv_reconcile = require("devloop.convergence.reconcile")
local t = h.t
local core = h.core
local opts = h.opts
local issue = h.issue
local reached = h.reached
local run_observe = h.run_observe
local run_implement = h.run_implement
local mock_issue_state = h.mock_issue_state
local mock_issue_implement = h.mock_issue_implement
local mock_issue_implement_raw = h.mock_issue_implement_raw
local mock_existing_empty_implement_worktree = h.mock_existing_empty_implement_worktree
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local render_comment = h.render_comment
local json_string = h.json_string
local find_raise = h.find_raise
local count_calls = h.count_calls
local deterministic_branch_for = h.deterministic_branch_for
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local strings = require("contract.strings")

local function lean_receipt(event, version, status, phase, attempt)
  local fields = {
    '"schema":"github-devloop.lean-proof-result.v1"',
    '"status":' .. strings.json_string(status),
    '"phase":' .. strings.json_string(phase),
    '"proposal_id":' .. strings.json_string(event.proposal_id),
    '"implementation_version":' .. strings.json_string(version),
    '"attempt":' .. tostring(attempt),
    '"target":"Proofs/Target.lean"',
    '"declaration":"target_theorem"',
    '"checker_command":"lake env lean -E hasSorry Proofs/Target.lean"',
  }
  if status == "repair-needed" then
    table.insert(fields, '"last_obligation":"case h => False"')
    table.insert(fields, '"attempted_approaches":["simp"]')
    table.insert(fields, '"search_evidence":{"status":"performed","queries":["Nat.succ_eq_add_one"]}')
    table.insert(fields, '"remaining_blocker":"missing monotonicity premise"')
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function implementation_receipt(event, version, outcome, attempt, reason, evidence, blocker)
  local fields = {
    '"schema":"github-devloop.implementation-result.v1"',
    '"outcome":' .. strings.json_string(outcome),
    '"proposal_id":' .. strings.json_string(event.proposal_id),
    '"implementation_version":' .. strings.json_string(version),
    '"attempt":' .. tostring(attempt),
  }
  if outcome == "cannot-implement-here" then
    table.insert(fields, '"reason":' .. strings.json_string(reason))
    table.insert(fields, '"evidence":' .. strings.json_string(evidence))
    if blocker ~= nil then
      table.insert(fields, '"blocker":{"repo":' .. strings.json_string(blocker.repo)
        .. ',"issue_number":' .. tostring(blocker.issue_number) .. "}")
    end
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function blocked_by_json(nodes)
  local rendered = {}
  for _, node in ipairs(nodes or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"OPEN","stateReason":"","repository":{"nameWithOwner":"%s"}}',
      node.issue_number,
      json_string(node.repo or "owner/repo")
    ))
  end
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
    .. tostring(#rendered)
    .. ',"pageInfo":{"hasNextPage":false},"nodes":['
    .. table.concat(rendered, ",")
    .. "]}}}}}\n"
end

local function mock_blocked_by(issue_number, nodes)
  t.mock_command(core.gh_blocked_by_cmd("owner/repo", issue_number), {
    stdout = blocked_by_json(nodes),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocker_state(issue_number, state_name)
  local blocker_proposal = "github-devloop/issue/owner/repo/" .. tostring(issue_number)
  local comments = state_name and { h.state_comment(blocker_proposal, state_name, "blocker-v1") } or {}
  local rendered = {}
  for _, comment in ipairs(comments) do
    table.insert(rendered, render_comment(comment))
  end
  t.mock_command(core.gh_issue_view_observe_cmd("owner/repo", issue_number), {
    stdout = '{"state":"OPEN","comments":[' .. table.concat(rendered, ",")
      .. '],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function run_observe_direct(name)
  return h.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = issue({ labels = { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" } }),
  }, opts(name))
end

local function state_comment(raises, state_name)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find('state="' .. state_name .. '"', 1, true) ~= nil
  end)
end

local function mock_issue_implement_view_only(labels, comments, times)
  entity_read_mocks.mock_issue_view_raw_selector(t, {},
    "title,body,labels,comments,state,author", {
      stdout = entity_read_mocks.issue_view_stdout({
        labels = labels,
        comments = comments,
      }),
      stderr = "",
      exit_code = 0,
    }, times or 1)
end

local function mock_linked_pr_state(comments, state)
  local rendered_comments = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered_comments, render_comment(comment))
  end
  entity_read_mocks.mock_pr_view_raw_selector(t, {}, entity_read_mocks.pr_origin_selector, {
    stdout = string.format(
      '{"headRefName":"devloop-owner-repo-42-01HY","headRefOid":"def456","baseRefName":"dev","state":"%s","updatedAt":"2026-06-03T02:03:04Z","comments":[%s]}\n',
      json_string(state or "OPEN"),
      table.concat(rendered_comments, ",")
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function trusted_command(id)
  return {
    id = id or "IC_reimplement_1",
    body = "fkst: reimplement",
    author_login = "fkst-test-bot",
    created_at = "2026-06-04T03:00:00Z",
  }
end

local function forged_command()
  local command = trusted_command("IC_reimplement_forged")
  command.author_login = "mallory"
  return command
end

local function impl_failed_comments(event, reason, attempt, command)
  local version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
  local comments = {
    core.state_marker(event.proposal_id, "impl-failed", version),
    core.impl_failure_marker(event.proposal_id, version, reason or "codex-failed", attempt),
  }
  if command ~= nil then
    table.insert(comments, command)
  end
  return comments
end

local function find_worktree_ready_comment(raises)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("github-devloop implementation worktree ready", 1, true) ~= nil
  end)
end

local function run_refusal_reimplementation_case(reason, evidence, initial_attempt, stop_after_refusal)
  initial_attempt = initial_attempt or 1
  local event = reached()
  local ready = payloads_builders.build_devloop_ready_payload(core, event)
  local ready_comments = {
    initial_attempt == 1
      and h.projected_state_comment(event.proposal_id, "ready", ready.dedup_key)
      or core.state_marker(event.proposal_id, "implementing", ready.dedup_key),
  }
  if initial_attempt == 1 then
    mock_issue_implement_view_only({ "fkst-dev:ready" }, ready_comments, 3)
    mock_existing_empty_implement_worktree({
      impl_version = ready.dedup_key,
      harvest_checks = 1,
    })
  else
    table.insert(ready_comments, core.implement_attempt_marker(
      event.proposal_id, ready.dedup_key, initial_attempt - 1, tostring(now() - 7201)))
    mock_issue_implement({ "fkst-dev:implementing" }, ready_comments)
    local branch = deterministic_branch_for(ready)
    t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", {
      stdout = "",
      stderr = "fatal: couldn't find remote ref",
      exit_code = 128,
    })
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })
    mock_fresh_implement_worktree({
      impl_version = ready.dedup_key,
      harvest_checks = 1,
    })
  end
  mock_implement_codex(0, implementation_receipt(
    event, ready.dedup_key, "cannot-implement-here", initial_attempt, reason, evidence))
  mock_git_status("")
  t.mock_command("rev-list --count", {
    stdout = "0\n",
    stderr = "",
    exit_code = 0,
  })

  local refused = run_implement(ready, opts("implement-" .. reason .. "-refusal"))

  t.eq(refused.exit_code, 0)
  local refusal_comment = find_raise(refused.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("fkst:github-devloop:implementation-refusal:v1", 1, true) ~= nil
  end)
  t.is_true(refusal_comment ~= nil, reason .. ": typed refusal comment was not published")
  t.is_true(refusal_comment.payload.body:find("github-devloop implementation blocked: " .. reason, 1, true) ~= nil,
    reason .. ": typed refusal reason was not rendered")
  t.is_true(refusal_comment.payload.body:find('reason="' .. reason .. '"', 1, true) ~= nil,
    reason .. ": typed refusal marker did not preserve the reason")
  t.is_true(refusal_comment.payload.body:find(evidence, 1, true) ~= nil,
    reason .. ": typed refusal evidence was not preserved")
  t.is_true(refusal_comment.payload.body:find(
    core.state_marker(event.proposal_id, "blocked", ready.dedup_key), 1, true) ~= nil,
    reason .. ": typed refusal did not publish blocked state")
  t.is_true(refusal_comment.payload.body:find(
    "fkst:github-devloop:implement-attempt:v1", 1, true) ~= nil,
    reason .. ": typed refusal did not atomically publish its attempt identity")
  t.is_true(refusal_comment.payload.body:find(
    'attempt="' .. tostring(initial_attempt) .. '"', 1, true) ~= nil,
    reason .. ": typed refusal published the wrong attempt identity")
  t.eq(refusal_comment.payload.body:find("fkst:github-devloop:impl-failure:v1", 1, true), nil)
  t.eq(refusal_comment.payload.body:find('state="impl-failed"', 1, true), nil)
  local blocked_label = find_raise(refused.raises, "github-proxy.github_issue_label_request", function(payload)
    return payload.add_labels[1] == "fkst-dev:blocked"
  end)
  t.is_true(blocked_label ~= nil, reason .. ": typed refusal did not publish blocked label")
  t.eq(find_raise(refused.raises, "github-proxy.github_issue_label_request", function(payload)
    return payload.add_labels[1] == "fkst-dev:impl-failed"
  end), nil)

  local attempt_comment = find_raise(refused.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("fkst:github-devloop:implement-attempt:v1", 1, true) ~= nil
  end)
  t.is_true(attempt_comment ~= nil, reason .. ": trusted implementation attempt was not published")
  t.is_true(attempt_comment.payload.body:find('attempt="' .. tostring(initial_attempt) .. '"', 1, true) ~= nil,
    reason .. ": implementation attempt marker used the wrong attempt")

  local command = trusted_command("IC_reimplement_" .. reason:gsub("%-", "_"))
  -- The refusal fact must remain actionable when eventual consistency exposes
  -- its comment before the separately published attempt comment.
  local blocked_comments = { refusal_comment.payload.body, command }
  local published_refusal = core.implementation_refusal_fact(
    blocked_comments, event.proposal_id, ready.dedup_key)
  t.is_true(published_refusal ~= nil,
    reason .. ": published refusal did not round-trip as a trusted current fact")
  t.eq(published_refusal.reason, reason)
  t.eq(published_refusal.evidence, evidence)
  t.eq(published_refusal.implementation_version, ready.dedup_key)
  t.eq(published_refusal.attempt, initial_attempt)
  if stop_after_refusal then
    return
  end
  mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", blocked_comments)

  local observed = run_observe(
    issue({ labels = { "fkst-dev:enabled", "fkst-dev:blocked" } }),
    opts("operator-reimplement-" .. reason))

  t.eq(observed.exit_code, 0)
  local retry = find_raise(observed.raises, "devloop_ready")
  local emitted = {}
  for _, raised in ipairs(observed.raises) do
    table.insert(emitted, tostring(raised.queue) .. ":" .. tostring(raised.payload.body or ""))
  end
  t.is_true(retry ~= nil,
    reason .. ": trusted typed refusal did not authorize reimplementation; emitted="
      .. table.concat(emitted, " | "))
  local retry_attempt = initial_attempt + 1
  t.eq(retry.payload.impl_retry_attempt, retry_attempt)
  t.eq(retry.payload.operator_reentry.terminal_reason, "implementation-refusal")
  t.eq(retry.payload.operator_reentry.impl_version, ready.dedup_key)

  local retry_version = core.implementation_attempt_version(ready.dedup_key, retry_attempt)
  for _ = 1, 3 do
    mock_issue_implement_raw({ "fkst-dev:blocked" }, blocked_comments)
  end
  mock_existing_empty_implement_worktree({ impl_version = retry_version })
  mock_implement_codex(0, implementation_receipt(
    event, retry_version, "changes-produced", retry_attempt))
  mock_git_status(" M packages/github-devloop/core.lua\n")
  mock_git_commit(nil, devloop_base.implement_branch("owner/repo", "42", ready.dedup_key))

  local implemented = run_implement(retry.payload, opts("implement-after-" .. reason))

  t.eq(implemented.exit_code, 0)
  local output = find_raise(implemented.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("github-devloop implementation output published", 1, true) ~= nil
  end)
  t.is_true(output ~= nil, reason .. ": reimplementation did not publish normal implementation output")
  t.is_true(output.payload.body:find('dedup="' .. retry_version .. '"', 1, true) ~= nil,
    reason .. ": reimplementation output did not use the fresh implementation version")
end

local function run_precursor_refusal(blocker)
  local event = reached()
  local ready = payloads_builders.build_devloop_ready_payload(core, event)
  mock_issue_implement_view_only({ "fkst-dev:ready" }, {
    h.projected_state_comment(event.proposal_id, "ready", ready.dedup_key),
  }, 3)
  mock_existing_empty_implement_worktree({
    impl_version = ready.dedup_key,
    harvest_checks = 1,
  })
  mock_implement_codex(0, implementation_receipt(
    event,
    ready.dedup_key,
    "cannot-implement-here",
    1,
    "precursor-missing",
    "Issue #99 must land before this implementation can proceed.",
    blocker
  ))
  mock_git_status("")
  t.mock_command("rev-list --count", {
    stdout = "0\n",
    stderr = "",
    exit_code = 0,
  })

  return run_implement(ready, opts("implement-precursor-dependency-wait")), event, ready
end

local function mock_precursor_observation(comments, blockers, blocker_state)
  mock_issue_state(
    { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
    "OPEN",
    comments
  )
  mock_blocked_by(42, blockers)
  if #blockers > 0 then
    mock_blocked_by(blockers[1].issue_number, {})
    mock_blocker_state(blockers[1].issue_number, blocker_state)
  end
end

local function run_first_clean_implementation_attempt(name, build_stdout)
  local event = reached()
  local ready = payloads_builders.build_devloop_ready_payload(core, event)
  local ready_comments = {
    h.projected_state_comment(event.proposal_id, "ready", ready.dedup_key),
  }
  mock_issue_implement_view_only({ "fkst-dev:ready" }, ready_comments, 3)
  mock_existing_empty_implement_worktree({ impl_version = ready.dedup_key })
  mock_implement_codex(0, build_stdout(event, ready))
  mock_git_status("")
  t.mock_command("rev-list --count", {
    stdout = "0\n",
    stderr = "",
    exit_code = 0,
  })
  return run_implement(ready, opts(name))
end

local function assert_invalid_implementation_result(name, build_stdout, decoder_error)
  local result = run_first_clean_implementation_attempt(name, build_stdout)

  t.eq(result.exit_code, 0)
  local failure_comment = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find(
      "github-devloop implementation failed: invalid-implementation-result", 1, true) ~= nil
  end)
  t.is_true(failure_comment ~= nil)
  t.is_true(failure_comment.payload.body:find(
    "Invalid typed result envelope: " .. decoder_error, 1, true) ~= nil)
  t.eq(failure_comment.payload.body:find("implementation failed: no-changes", 1, true), nil)
  t.eq(failure_comment.payload.body:find("fkst:github-devloop:implementation-refusal:v1", 1, true), nil)
  t.is_true(find_raise(result.raises, "github-proxy.github_issue_label_request", function(payload)
    return payload.add_labels[1] == "fkst-dev:impl-failed"
  end) ~= nil)
  t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request", function(payload)
    return payload.add_labels[1] == "fkst-dev:blocked"
  end), nil)
end

return {
  test_observe_autoretries_codex_failed_once = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN", impl_failed_comments(event, "codex-failed", 1))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("observe-impl-failed-retry"))
    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.dedup_key, payloads_builders.build_devloop_ready_payload(core, event).dedup_key)
    t.eq(ready.payload.impl_retry_attempt, 2)
  end,

  test_observe_autoretries_non_descendant_head_once = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN", impl_failed_comments(event, "non-descendant-head", 1))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("observe-non-descendant-head-retry"))
    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.dedup_key, payloads_builders.build_devloop_ready_payload(core, event).dedup_key)
    t.eq(ready.payload.impl_retry_attempt, 2)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
  end,

  test_observe_stops_after_bounded_codex_failed_retry = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN", impl_failed_comments(event, "codex-failed", 2))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("observe-impl-failed-limit"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_observe_stops_after_bounded_non_descendant_head_retry = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN", impl_failed_comments(event, "non-descendant-head", 2))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("observe-non-descendant-head-limit"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_reimplement_command_reenters_after_retry_limit = function()
    local event = reached()
    local command = trusted_command()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN", impl_failed_comments(event, "codex-failed", 2, command))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("operator-reimplement"))
    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    local ready_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    t.eq(ready.payload.implementation_version, ready_version)
    t.eq(ready.payload.operator_reimplement_delivery.command_key, "operator-command/IC_reimplement_1")
    t.is_true(ready.payload.dedup_key ~= ready_version)
    t.eq(ready.payload.impl_retry_attempt, 3)
    local response = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(response.payload.body:find("operator command accepted: reimplement", 1, true) ~= nil)
    t.is_true(response.payload.body:find('command="reimplement"', 1, true) ~= nil)
  end,

  test_forged_reimplement_command_is_ignored = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN", impl_failed_comments(event, "codex-failed", 2, forged_command()))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("operator-reimplement-forged"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_reimplement_command_reenters_blocked_open_pr_from_issue = function()
    local event = reached()
    local ready_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local blocked_version = ready_version .. "/review-loop/3"
    local command = trusted_command("IC_reimplement_blocked")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", {
      m_builders.pr_link_marker(event.proposal_id, 7, "devloop-owner-repo-42-01HY", ready_version, "dev"),
      core.state_marker(event.proposal_id, "blocked", blocked_version),
      command,
    })
    mock_linked_pr_state({}, "OPEN")

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:blocked" } }), opts("operator-reimplement-blocked-open-pr"))
    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.proposal_id, event.proposal_id)
    t.eq(ready.payload.implementation_version, ready_version)
    t.eq(ready.payload.operator_reimplement_delivery.command_key, "operator-command/IC_reimplement_blocked")
    t.is_true(ready.payload.dedup_key ~= ready_version)
    t.eq(ready.payload.impl_retry_attempt, 2)
    t.eq(ready.payload.operator_reentry.command, "reimplement")
    t.eq(ready.payload.operator_reentry.from_state, "blocked")
    t.eq(ready.payload.operator_reentry.state_version, blocked_version)
    t.eq(ready.payload.operator_reentry.impl_version, ready_version)
    t.eq(ready.payload.operator_reentry.pr_number, 7)
    local response = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(response.payload.body:find("operator command accepted: reimplement", 1, true) ~= nil)
  end,

  test_reimplement_command_refuses_blocked_without_open_linked_pr = function()
    local event = reached()
    local ready_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local command = trusted_command("IC_reimplement_blocked_unlinked")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", {
      core.state_marker(event.proposal_id, "blocked", ready_version .. "/review-loop/3"),
      command,
    })

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:blocked" } }), opts("operator-reimplement-blocked-unlinked"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    local response = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(response.payload.body:find("operator command refused", 1, true) ~= nil)
    t.is_true(response.payload.body:find("reimplement requires impl-failed, blocked state with an open linked PR, or blocked state from implementing timeout without a PR", 1, true) ~= nil)
    t.is_true(response.payload.body:find("file a new issue for blocked thinking convergence drops", 1, true) ~= nil)
  end,

  test_retry_implementation_writes_attempt_version = function()
    local event = reached()
    local ready = payloads_builders.build_devloop_ready_payload(core, event)
    ready.impl_retry_attempt = 2
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, {
      core.state_marker(event.proposal_id, "impl-failed", ready.dedup_key),
      core.impl_failure_marker(event.proposal_id, ready.dedup_key, "codex-failed", 1),
    })
    mock_existing_empty_implement_worktree({
      impl_version = ready.dedup_key .. "/reimplement/2",
    })
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(nil, devloop_base.implement_branch("owner/repo", "42", ready.dedup_key))
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, {
      core.state_marker(event.proposal_id, "impl-failed", ready.dedup_key),
      core.impl_failure_marker(event.proposal_id, ready.dedup_key, "codex-failed", 1),
    })
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, {
      core.state_marker(event.proposal_id, "impl-failed", ready.dedup_key),
      core.impl_failure_marker(event.proposal_id, ready.dedup_key, "codex-failed", 1),
    })

    local result = run_implement(ready, opts("implement-retry-success"))
    t.eq(result.exit_code, 0)
    local comment = find_worktree_ready_comment(result.raises)
    t.is_true(comment ~= nil)
    t.is_true(comment.payload.body:find(core.state_marker(event.proposal_id, "implementing", ready.dedup_key .. "/reimplement/2"), 1, true) ~= nil)
    t.eq(m_facts.implementing_fact({ comment.payload.body }, event.proposal_id, ready.dedup_key .. "/reimplement/2"), nil)
  end,

  test_completed_codex_with_vanished_worktree_returns_typed_retry = function()
    local event = reached()
    local ready = payloads_builders.build_devloop_ready_payload(core, event)
    ready.impl_retry_attempt = 2
    local comments = {
      core.state_marker(event.proposal_id, "impl-failed", ready.dedup_key),
      core.impl_failure_marker(event.proposal_id, ready.dedup_key, "codex-failed", 1),
    }
    for _ = 1, 3 do
      mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)
    end
    mock_existing_empty_implement_worktree({
      impl_version = ready.dedup_key .. "/reimplement/2",
      harvest = false,
    })
    mock_implement_codex(0, "implemented")
    local stable_root = devloop_base.implementation_worktree_root(
      "/tmp/fkst-packages-test/github-devloop/durable")
    local worktree = devloop_base.implement_worktree_path(
      stable_root, "owner/repo", 42, ready.dedup_key)
    t.mock_command("[ -d '" .. worktree .. "' ]", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })
    mock_git_status("", 128, "fatal: cannot change to missing worktree")

    local result = run_implement(ready, opts("implement-worktree-vanished-after-codex"))

    t.eq(result.exit_code, 0, "vanished worktree retry failed: "
      .. tostring(result.error or result.stderr or "unknown error"))
    t.eq(count_calls("status --porcelain"), 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:impl-failure:v1", 1, true) ~= nil
    end), nil)
  end,

  test_replayed_ready_rederives_proof_profile_from_accepted_result = function()
    local framing = "Change `Proofs/Target.lean` only."
    local event = reached({
      title = "Complete Proofs/Target.lean",
      framing = framing,
    })
    local ready = payloads_builders.build_devloop_ready_payload(core, event)
    ready.framing = nil
    ready.impl_retry_attempt = 2
    local result_comment = requests_lifecycle.build_result_comment_request(core, "owner/repo", "42", event).body
    local prior_receipt = lean_receipt(event, ready.dedup_key, "repair-needed", "construction", 1)
    local failure_comment = requests_lifecycle.build_impl_failure_comment_request(core, "owner/repo", "42", ready,
      "lean-proof-repair-needed", prior_receipt, 1).body
    local comments = {
      result_comment,
      failure_comment,
    }
    local branch = devloop_base.implement_branch("owner/repo", "42", ready.dedup_key)
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)
    mock_existing_empty_implement_worktree({
      impl_version = ready.dedup_key .. "/reimplement/2",
    })
    t.mock_command("git cat-file -t " .. branch .. ":lean-toolchain", {
      stdout = "blob\n",
      stderr = "",
      exit_code = 0,
    })
    mock_implement_codex(0, lean_receipt(event, ready.dedup_key .. "/reimplement/2",
      "complete", "strong-repair", 2))
    mock_git_status(" M Proofs/Target.lean\n")
    t.mock_command("lake env lean -E hasSorry Proofs/Target.lean", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    mock_git_commit(nil, branch)
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, comments)

    local result = run_implement(ready, opts("implement-replay-lean-proof"))

    t.eq(result.exit_code, 0)
    local prompt = nil
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find("codex exec", 1, true) ~= nil then
        prompt = call.stdin
      end
    end
    t.is_true(prompt ~= nil)
    t.is_true(prompt:find("Implementation profile: `lean-proof`", 1, true) ~= nil)
    t.is_true(prompt:find(framing, 1, true) ~= nil)
  end,

  test_blocked_reimplement_receiver_writes_fresh_attempt_version = function()
    local event = reached()
    local ready = payloads_builders.build_devloop_ready_payload(core, event)
    local blocked_version = ready.dedup_key .. "/review-loop/3"
    ready.impl_retry_attempt = 2
    ready.operator_reentry = {
      command = "reimplement",
      from_state = "blocked",
      pr_number = 7,
      state_version = blocked_version,
      impl_version = ready.dedup_key,
    }
    mock_issue_implement_raw({ "fkst-dev:blocked" }, {
      m_builders.pr_link_marker(event.proposal_id, 7, "devloop-owner-repo-42-01HY", ready.dedup_key, "dev"),
      core.state_marker(event.proposal_id, "blocked", blocked_version),
    })
    mock_existing_empty_implement_worktree({
      impl_version = ready.dedup_key .. "/reimplement/2",
    })
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(nil, devloop_base.implement_branch("owner/repo", "42", ready.dedup_key))
    mock_issue_implement_raw({ "fkst-dev:blocked" }, {
      m_builders.pr_link_marker(event.proposal_id, 7, "devloop-owner-repo-42-01HY", ready.dedup_key, "dev"),
      core.state_marker(event.proposal_id, "blocked", blocked_version),
    })
    mock_issue_implement_raw({ "fkst-dev:blocked" }, {
      m_builders.pr_link_marker(event.proposal_id, 7, "devloop-owner-repo-42-01HY", ready.dedup_key, "dev"),
      core.state_marker(event.proposal_id, "blocked", blocked_version),
    })

    local result = run_implement(ready, opts("implement-blocked-reimplement-success"))
    t.eq(result.exit_code, 0)
    local comment = find_worktree_ready_comment(result.raises)
    t.is_true(comment ~= nil)
    t.is_true(comment.payload.body:find(core.state_marker(event.proposal_id, "implementing", ready.dedup_key .. "/reimplement/2"), 1, true) ~= nil)
    t.eq(m_facts.implementing_fact({ comment.payload.body }, event.proposal_id, ready.dedup_key .. "/reimplement/2"), nil)
  end,

  test_blocked_timeout_reimplement_receiver_rejects_missing_timeout_source_ref = function()
    local event = reached()
    local ready = payloads_builders.build_devloop_ready_payload(core, event)
    local blocked_version = conv_reconcile.timeout_reconcile_state_version(ready.dedup_key, "implementing", 3)
    ready.impl_retry_attempt = 2
    ready.operator_reentry = {
      command = "reimplement",
      from_state = "blocked",
      terminal_reason = "implementing-timeout-without-pr",
      state_version = blocked_version,
      impl_version = ready.dedup_key,
      timeout_round = 3,
    }
    mock_issue_implement_raw({ "fkst-dev:blocked" }, {
      core.state_marker(event.proposal_id, "implementing", ready.dedup_key),
      core.state_marker(event.proposal_id, "blocked", blocked_version),
      conv_reconcile.timeout_reconcile_marker(event.proposal_id, ready.dedup_key, "implementing", 3, "drop", {
        terminal_version = blocked_version,
        from_state = "implementing",
        from_version = ready.dedup_key,
        reason_class = "state-output-obligation-timeout",
      }),
    })

    local result = run_implement(ready, opts("implement-blocked-timeout-reimplement-missing-source-ref"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_precursor_missing_refusal_waits_for_source_visible_merged_blocker_then_releases_fresh_ready = function()
    local blocker = { repo = "owner/repo", issue_number = 99 }
    local refused, event, ready = run_precursor_refusal(blocker)

    t.eq(refused.exit_code, 0)
    local wait_version = core.ready_split_version(ready.dedup_key)
    local refusal = state_comment(refused.raises, "dependency_wait")
    t.is_true(refusal ~= nil)
    t.is_true(refusal.payload.body:find(
      core.dependency_wait_marker(
        event.proposal_id, wait_version, { 99 }, "expected-edge", "precursor-edge-not-visible"),
      1,
      true
    ) ~= nil)
    t.eq(state_comment(refused.raises, "blocked"), nil)
    t.eq(refusal.payload.handoff.kind, "github-devloop.ready-split-label")
    t.eq(refusal.payload.handoff.marker_version, wait_version)
    t.eq(refusal.payload.handoff.label_request.expected_state, "dependency_wait")
    t.eq(refusal.payload.handoff.label_request.expected_version, wait_version)
    t.is_true(table.concat(
      refusal.payload.handoff.label_request.add_labels,
      ","
    ):find(core._blocked_on_dependency_label, 1, true) ~= nil)
    local direct_wait_label = find_raise(
      refused.raises,
      "github-proxy.github_issue_label_request",
      function(payload) return payload.expected_state == "dependency_wait" end
    )
    t.eq(direct_wait_label, nil)

    local edge_request = find_raise(
      refused.raises, "github-proxy.github_issue_blocked_by_request")
    t.is_true(edge_request ~= nil)
    t.eq(edge_request.payload.repo, "owner/repo")
    t.eq(edge_request.payload.blocked_issue_number, 42)
    t.eq(edge_request.payload.blocking_issue_number, 99)
    local refusal_comments = { refusal.payload.body }

    mock_precursor_observation(refusal_comments, {}, nil)
    local edge_absent = run_observe_direct("precursor-edge-absent")
    t.eq(edge_absent.exit_code, 0)
    t.eq(state_comment(edge_absent.raises, "ready"), nil)

    mock_precursor_observation(refusal_comments, { blocker }, "ready")
    local blocker_open = run_observe_direct("precursor-edge-visible-blocker-open")
    t.eq(blocker_open.exit_code, 0)
    t.eq(state_comment(blocker_open.raises, "ready"), nil)

    mock_precursor_observation(refusal_comments, { blocker }, "merged")
    local blocker_merged = run_observe_direct("precursor-edge-visible-blocker-merged")
    t.eq(blocker_merged.exit_code, 0)
    local released = state_comment(blocker_merged.raises, "ready")
    t.is_true(released ~= nil)
    local released_version = core.ready_split_version(wait_version)
    t.is_true(released.payload.body:find(
      h.projected_state_comment(
        event.proposal_id, "ready", released_version, "result-marker,ready-label,devloop-ready"),
      1,
      true
    ) ~= nil)
    t.is_true(released_version ~= ready.dedup_key)
    t.is_true(released_version ~= wait_version)
  end,

  test_same_version_second_attempt_refusal_uses_trusted_attempt_fact = function()
    run_refusal_reimplementation_case(
      "wrong-layer",
      "The required primitive belongs in fkst-substrate.",
      2,
      true)
  end,

  test_wrong_layer_refusal_blocks_then_reimplements_from_trusted_fact = function()
    run_refusal_reimplementation_case(
      "wrong-layer",
      "`fkst.observe()` provides no cross-request snapshot isolation, and `raise()` only buffers in-process; durable publish occurs later in the supervisor after `once` returns. Package-side revalidation therefore leaves the prohibited check-to-enqueue race. The required producer-owned atomic version validation needs an engine primitive in `fkst-substrate`, while this repository explicitly owns only Lua package behavior. `scripts/run.sh test-affected` passed with `FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE`; the worktree remains clean.")
  end,

  test_already_satisfied_refusal_blocks_then_reimplements_from_trusted_fact = function()
    run_refusal_reimplementation_case(
      "already-satisfied",
      "HEAD aba2a4da already has `github-devloop-ops.observability` consume both `restart_transition_anomaly` queues ephemerally, with composition dependencies and regression coverage introduced atomically by 9b0f6aff. `scripts/run.sh test-affected` exited 0: 22 packages and composed conformance 31/31 passed. The worktree is clean, so no scoped change is justified.")
  end,

  test_missing_outcome_fails_closed_as_invalid_implementation_result = function()
    assert_invalid_implementation_result("implement-missing-outcome", function(event, ready)
      local raw = implementation_receipt(
        event,
        ready.dedup_key,
        "cannot-implement-here",
        1,
        "wrong-layer",
        "The requested engine primitive belongs in fkst-substrate."
      )
      return (raw:gsub('"outcome":"cannot%-implement%-here",', ""))
    end, "outcome must be changes-produced or cannot-implement-here")
  end,

  test_unsupported_reason_fails_closed_as_invalid_implementation_result = function()
    assert_invalid_implementation_result("implement-unsupported-refusal-reason", function(event, ready)
      return implementation_receipt(
        event, ready.dedup_key, "cannot-implement-here", 1, "scope-mismatch",
        "The requested engine primitive belongs in another scope.")
    end, "reason must be one of precursor-missing, wrong-layer, already-satisfied")
  end,

  test_blank_evidence_fails_closed_as_invalid_implementation_result = function()
    assert_invalid_implementation_result("implement-blank-refusal-evidence", function(event, ready)
      return implementation_receipt(
        event, ready.dedup_key, "cannot-implement-here", 1, "wrong-layer", "   ")
    end, "evidence must be a non-empty string")
  end,

  test_whitespace_only_result_preserves_the_decoder_rejection = function()
    assert_invalid_implementation_result("implement-whitespace-result", function()
      return " \n\t"
    end, "typed result envelope is empty or exceeds the implementation receipt bound")
  end,

  test_changes_produced_receipt_without_a_diff_remains_no_changes = function()
    local result = run_first_clean_implementation_attempt("implement-clean-changes-produced", function(event, ready)
      return implementation_receipt(event, ready.dedup_key, "changes-produced", 1)
    end)

    t.eq(result.exit_code, 0)
    local failure_comment = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("github-devloop implementation failed: no-changes", 1, true) ~= nil
    end)
    t.is_true(failure_comment ~= nil)
    t.eq(failure_comment.payload.body:find("invalid-implementation-result", 1, true), nil)
  end,
}
