local base_ids = require("devloop.base_ids")
local convergence_shared = require("devloop.convergence.shared")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local conv_rounds = require("devloop.convergence.rounds")
local conv_reconcile = require("devloop.convergence.reconcile")
local m_builders = require("devloop.markers.builders")
local operator_reentry_inventory = require("core.restart.operator_reentry_inventory")
local t = h.t
local core = h.core
local opts = h.opts
local reviewing = h.reviewing
local merge_ready = h.merge_ready
local issue = h.issue
local reached = h.reached
local run_observe_pr = h.run_observe_pr
local run_observe = h.run_observe
local run_review_pr = h.run_review_pr
local mock_issue_reviewing = h.mock_issue_reviewing
local mock_issue_review = h.mock_issue_review
local mock_issue_state = h.mock_issue_state
local mock_pr_origin = h.mock_pr_origin
local merge_comments = h.merge_comments
local find_raise = h.find_raise
local find_causal_raise = h.find_causal_raise



local function trusted_issue_command(command, id)
  return {
    id = id or ("IC_" .. tostring(command) .. "_issue_1"),
    body = "fkst: " .. tostring(command),
    author_login = "fkst-test-bot",
    created_at = "2026-06-04T03:00:00Z",
  }
end

local function thinking_converge_comments(event, rounds, command)
  local proposal_id = base_ids.proposal_id(event.repo, event.number)
  local base_version = payloads_builders.build_proposal(event).dedup_key
  local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
  local angle_digests = {
    { angle = "minimal", verdict = "abstain", digest = "same-digest" },
  }
  local comments = {
    core.state_marker(proposal_id, "thinking", base_version),
  }
  for n = 1, rounds do
    table.insert(comments, conv_rounds.converge_round_marker(proposal_id,
      base_version,
      sr_digest,
      n,
      base_version .. "/loop/" .. tostring(n),
      "Same narrowed question",
      angle_digests
    ))
  end
  if command ~= nil then
    table.insert(comments, command)
  end
  return comments, base_version
end

local function thinking_changing_converge_comments(event, rounds, command)
  local proposal_id = base_ids.proposal_id(event.repo, event.number)
  local base_version = payloads_builders.build_proposal(event).dedup_key
  local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
  local comments = {
    core.state_marker(proposal_id, "thinking", base_version),
  }
  for n = 1, rounds do
    table.insert(comments, conv_rounds.converge_round_marker(proposal_id,
      base_version,
      sr_digest,
      n,
      base_version .. "/loop/" .. tostring(n),
      "Narrowed question " .. tostring(n),
      {
        { angle = "minimal", verdict = "abstain", digest = "digest-" .. tostring(n) },
      },
      "open:\nNarrowed question " .. tostring(n)
    ))
  end
  if command ~= nil then
    table.insert(comments, command)
  end
  return comments, base_version
end

local function find_issue_comment_raise(raises, needle)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request"
      and raised.payload.body:find(needle, 1, true) ~= nil then
      return raised
    end
  end
  return nil
end

local function mock_blocked_by(issue_number, nodes)
  local rendered = {}
  for _, node in ipairs(nodes or {}) do
    table.insert(rendered, string.format(
      '{"number":%s,"state":"OPEN","stateReason":"","repository":{"nameWithOwner":"%s"}}',
      tostring(node.number),
      tostring(node.repo or "owner/repo")
    ))
  end
  t.mock_command(core.gh_blocked_by_cmd("owner/repo", issue_number), {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
      .. tostring(#rendered)
      .. ',"pageInfo":{"hasNextPage":false},"nodes":['
      .. table.concat(rendered, ",")
      .. ']}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_open_blocker(issue_number)
  t.mock_command(core.gh_issue_view_observe_cmd("owner/repo", issue_number), {
    stdout = '{"state":"OPEN","comments":[],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function blocked_dependency_reready_comments(event, state_version, marker_version, command_id)
  local proposal_id = base_ids.proposal_id(event.repo, event.number)
  return {
    core.state_marker(proposal_id, "blocked", state_version),
    "github-devloop dependency hold: unresolvable\n\nReason: gh-failed\n\n"
      .. core.dependency_unresolvable_marker(proposal_id, marker_version, { 43 }),
    trusted_issue_command("reready", command_id),
  }
end

local function find_projected_state_raise(raises, proposal_id, expected_state)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    local projected = core.current_state({ payload.body }, proposal_id)
    return projected.state == expected_state
  end)
end

local function run_blocked_dependency_reready(event, comments, name)
  mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", comments)
  return run_observe(event, opts(name))
end

return {
  test_issue_rereview_command_reenters_thinking_converge = function()
    local event = issue()
    local command = trusted_issue_command("rereview", "IC_issue_rereview_stalled")
    local comments, base_version = thinking_converge_comments(event, 7, command)
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", comments)

    local result = run_observe(event, opts("operator-issue-rereview-thinking-converge"))
    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    local proposal_raise = find_raise(result.raises, "devloop_consensus_request")
    t.is_true(comment_raise.payload.body:find("operator command accepted: rereview", 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find("fkst:github-devloop:operator-command:v1", 1, true) ~= nil)
    t.eq(proposal_raise.payload.dedup_key, base_version .. "/loop/8")
    t.eq(proposal_raise.payload.round, 8)
    t.eq(proposal_raise.payload.convergence_question, "Same narrowed question")
    t.eq(proposal_raise.payload.source_ref.ref, "owner/repo#issue/42")
  end,

  test_issue_rereview_command_replays_round_seven_converge_without_true_stall = function()
    local event = issue()
    local command = trusted_issue_command("rereview", "IC_issue_rereview_round_7")
    local comments, base_version = thinking_changing_converge_comments(event, 7, command)
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", comments)

    local result = run_observe(event, opts("operator-issue-rereview-round-7"))
    t.eq(result.exit_code, 0)
    local proposal_raise = find_raise(result.raises, "devloop_consensus_request")
    t.eq(proposal_raise.payload.dedup_key, base_version .. "/loop/8")
    t.eq(proposal_raise.payload.round, 8)
    t.eq(proposal_raise.payload.convergence_question, "Narrowed question 7")
    t.eq(proposal_raise.payload.findings_record, "open:\nNarrowed question 7")
    t.eq(proposal_raise.payload.prior_round_digests, nil)
  end,

  test_issue_rereview_command_reenters_stalled_plain_thinking = function()
    local event = issue({
      updated_at = "2026-06-03T04:05:06Z",
    })
    local command = trusted_issue_command("rereview", "IC_issue_rereview_plain_stalled")
    local base_version = payloads_builders.build_proposal(event).dedup_key
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      core.state_marker(base_ids.proposal_id(event.repo, event.number), "thinking", base_version),
      command,
    })

    local result = run_observe(event, opts("operator-issue-rereview-plain-stalled"))
    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    local proposal_raise = find_raise(result.raises, "devloop_consensus_request")
    t.is_true(comment_raise.payload.body:find("operator command accepted: rereview", 1, true) ~= nil)
    t.eq(proposal_raise.payload.dedup_key, base_version)
    t.eq(proposal_raise.payload.round, nil)
    t.eq(proposal_raise.payload.source_ref.ref, "owner/repo#issue/42")
  end,

  test_issue_rereview_command_active_thinking_refuses_once = function()
    local event = issue()
    local command = trusted_issue_command("rereview", "IC_issue_rereview_active")
    local base_version = payloads_builders.build_proposal(event).dedup_key
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      {
        body = core.state_marker(base_ids.proposal_id(event.repo, event.number), "thinking", base_version),
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now()),
      },
      command,
    })

    local result = run_observe(event, opts("operator-issue-rereview-active"))
    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment_raise.payload.body:find("operator command refused", 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find("stalled thinking state", 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find('outcome="refused"', 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_consensus_request"), nil)

    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      {
        body = core.state_marker(base_ids.proposal_id(event.repo, event.number), "thinking", base_version),
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now()),
      },
      command,
      comment_raise.payload.body,
    })
    local replay = run_observe(event, opts("operator-issue-rereview-active-replay"))
    t.eq(replay.exit_code, 0)
    t.eq(find_raise(replay.raises, "devloop_consensus_request"), nil)
    local replay_comment = find_raise(replay.raises, "github-proxy.github_issue_comment_request")
    t.is_true(replay_comment ~= nil)
    t.is_true(replay_comment.payload.body:find("operator command refused", 1, true) ~= nil)
    t.is_true(replay_comment.payload.body:find("stalled thinking state", 1, true) ~= nil)
    t.is_true(replay_comment.payload.body:find('outcome="refused"', 1, true) ~= nil)
  end,

  test_issue_reready_command_rechecks_dependency_gate = function()
    local event = reached()
    local command = trusted_issue_command("reready", "IC_issue_reready_release")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" }, "OPEN", {
      h.projected_state_comment(event.proposal_id, "dependency_wait", event.dedup_key),
      "github-devloop dependency hold: unresolvable\n\nReason: gh-failed\n\n"
        .. core.dependency_unresolvable_marker(event.proposal_id, event.dedup_key, { 42 }),
      command,
    })

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:ready" } }), opts("operator-issue-reready-release"))
    t.eq(result.exit_code, 0)
    local command_response = find_issue_comment_raise(result.raises, "operator command accepted: reready")
    t.is_true(command_response ~= nil)
    t.is_true(command_response.payload.body:find('outcome="applied"', 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    local ready_comment = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return type(payload.handoff) == "table"
        and payload.handoff.kind == "github-devloop.ready"
    end)
    t.is_true(ready_comment ~= nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.is_true(type(ready_comment.payload.handoff.label_request) == "table")
  end,

  test_issue_reready_command_reenters_dependency_blocked_to_ready_when_fresh_gate_is_satisfied = function()
    local event = issue({ labels = { "fkst-dev:enabled", "fkst-dev:blocked" } })
    local proposal_id = base_ids.proposal_id(event.repo, event.number)
    local blocked_version = "dependency-blocked/satisfied"
    local comments = blocked_dependency_reready_comments(
      event, blocked_version, blocked_version, "IC_issue_reready_dependency_satisfied")
    mock_blocked_by(42, {})

    local result = run_blocked_dependency_reready(
      event, comments, "operator-issue-reready-dependency-satisfied")

    t.eq(result.exit_code, 0)
    local response = find_issue_comment_raise(result.raises, "operator command accepted: reready")
    t.is_true(response ~= nil)
    t.is_true(response.payload.body:find('outcome="applied"', 1, true) ~= nil)
    t.is_true(find_projected_state_raise(result.raises, proposal_id, "ready") ~= nil)
    t.eq(find_projected_state_raise(result.raises, proposal_id, "dependency_wait"), nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_issue_reready_command_reenters_dependency_blocked_to_waiting_when_fresh_gate_is_waiting = function()
    local event = issue({ labels = { "fkst-dev:enabled", "fkst-dev:blocked" } })
    local proposal_id = base_ids.proposal_id(event.repo, event.number)
    local blocked_version = "dependency-blocked/waiting"
    local comments = blocked_dependency_reready_comments(
      event, blocked_version, blocked_version, "IC_issue_reready_dependency_waiting")
    mock_blocked_by(42, { { number = 43 } })
    mock_blocked_by(43, {})
    mock_open_blocker(43)

    local result = run_blocked_dependency_reready(
      event, comments, "operator-issue-reready-dependency-waiting")

    t.eq(result.exit_code, 0)
    local response = find_issue_comment_raise(result.raises, "operator command accepted: reready")
    t.is_true(response ~= nil)
    t.is_true(response.payload.body:find('outcome="applied"', 1, true) ~= nil)
    t.is_true(find_projected_state_raise(result.raises, proposal_id, "dependency_wait") ~= nil)
    t.eq(find_projected_state_raise(result.raises, proposal_id, "ready"), nil)
  end,

  test_issue_reready_command_keeps_dependency_blocked_when_fresh_gate_still_has_terminal_proof = function()
    local event = issue({ labels = { "fkst-dev:enabled", "fkst-dev:blocked" } })
    local proposal_id = base_ids.proposal_id(event.repo, event.number)
    local blocked_version = "dependency-blocked/verified"
    local comments = blocked_dependency_reready_comments(
      event, blocked_version, blocked_version, "IC_issue_reready_dependency_verified")
    mock_blocked_by(42, { { number = 43 } })
    mock_blocked_by(43, { { number = 42 } })

    local result = run_blocked_dependency_reready(
      event, comments, "operator-issue-reready-dependency-verified")

    t.eq(result.exit_code, 0)
    local response = find_issue_comment_raise(result.raises, "operator command accepted: reready")
    t.is_true(response ~= nil)
    t.is_true(response.payload.body:find('outcome="applied"', 1, true) ~= nil)
    t.eq(find_projected_state_raise(result.raises, proposal_id, "ready"), nil)
    t.eq(find_projected_state_raise(result.raises, proposal_id, "dependency_wait"), nil)

  end,

  test_issue_reready_command_keeps_dependency_blocked_when_fresh_gate_is_unavailable = function()
    local event = issue({ labels = { "fkst-dev:enabled", "fkst-dev:blocked" } })
    local proposal_id = base_ids.proposal_id(event.repo, event.number)
    local blocked_version = "dependency-blocked/unavailable"
    local comments = blocked_dependency_reready_comments(
      event, blocked_version, blocked_version, "IC_issue_reready_dependency_unavailable")
    t.mock_command(core.gh_blocked_by_cmd("owner/repo", 42), {
      stdout = "",
      stderr = "graphql failed",
      exit_code = 1,
    })

    local result = run_blocked_dependency_reready(
      event, comments, "operator-issue-reready-dependency-unavailable")

    t.eq(result.exit_code, 0)
    local response = find_issue_comment_raise(result.raises, "operator command accepted: reready")
    t.is_true(response ~= nil)
    t.is_true(response.payload.body:find('outcome="applied"', 1, true) ~= nil)
    t.eq(find_projected_state_raise(result.raises, proposal_id, "ready"), nil)
    t.eq(find_projected_state_raise(result.raises, proposal_id, "dependency_wait"), nil)

  end,

  test_issue_reready_dependency_blocked_origin_must_match_current_version = function()
    local event = issue({ labels = { "fkst-dev:enabled", "fkst-dev:blocked" } })
    local proposal_id = base_ids.proposal_id(event.repo, event.number)
    local blocked_version = "dependency-blocked/current"
    local mismatched = blocked_dependency_reready_comments(
      event, blocked_version, "dependency-blocked/stale", "IC_issue_reready_dependency_stale")
    mock_blocked_by(42, {})

    local refused = run_blocked_dependency_reready(
      event, mismatched, "operator-issue-reready-dependency-stale")
    t.eq(refused.exit_code, 0)
    local refusal = find_issue_comment_raise(refused.raises, "operator command refused")
    t.is_true(refusal ~= nil)
    t.eq(find_projected_state_raise(refused.raises, proposal_id, "ready"), nil)

    local reready_declared = false
    for _, edge in ipairs(operator_reentry_inventory) do
      local source = edge.source or {}
      local cause = edge.cause_evidence or {}
      reready_declared = reready_declared
        or source.state == "blocked"
          and source.boundary == "dependency-hold"
          and cause.command == "reready"
    end
    t.eq(reready_declared, true)
  end,

  test_issue_reready_command_invalid_state_refuses = function()
    local event = issue()
    local command = trusted_issue_command("reready", "IC_issue_reready_invalid")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      core.state_marker(base_ids.proposal_id(event.repo, event.number), "thinking", payloads_builders.build_proposal(event).dedup_key),
      command,
    })

    local result = run_observe(event, opts("operator-issue-reready-invalid"))
    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment_raise.payload.body:find("operator command refused", 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find("reready requires ready or dependency_wait state", 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_issue_reready_command_reenters_timeout_reconcile_blocked_from_ready = function()
    local event = issue()
    local proposal_id = base_ids.proposal_id(event.repo, event.number)
    local ready_version = "consensus:github-devloop/issue/owner/repo/42/intake/1116/loop/1"
    local blocked_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)
    local command = trusted_issue_command("reready", "IC_issue_reready_timeout_ready")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", {
      h.projected_state_comment(proposal_id, "ready", ready_version, "result-marker,ready-label,devloop-ready"),
      core.state_marker(proposal_id, "blocked", blocked_version),
      conv_reconcile.timeout_reconcile_marker(proposal_id, ready_version, "ready", 3, "drop", {
        terminal_version = blocked_version,
        from_state = "ready",
        from_version = ready_version,
        source_ref = event.source_ref,
      }),
      command,
    })

    local result = run_observe(event, opts("operator-issue-reready-timeout-ready"))
    t.eq(result.exit_code, 0)
    local command_response = find_issue_comment_raise(result.raises, "operator command accepted: reready")
    local ready_raise = find_raise(result.raises, "devloop_ready")
    t.is_true(command_response ~= nil)
    t.is_true(command_response.payload.body:find('outcome="applied"', 1, true) ~= nil)
    t.is_true(ready_raise ~= nil)
    t.eq(ready_raise.payload.proposal_id, proposal_id)
    t.eq(ready_raise.payload.ready_hand_off.marker_version, ready_version)
  end,

  test_issue_reready_command_refuses_blocked_without_timeout_reconcile = function()
    local event = issue()
    local command = trusted_issue_command("reready", "IC_issue_reready_blocked_plain")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", {
      core.state_marker(base_ids.proposal_id(event.repo, event.number), "blocked", "manual-blocked"),
      command,
    })

    local result = run_observe(event, opts("operator-issue-reready-blocked-plain"))
    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment_raise.payload.body:find("operator command refused", 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find("reready requires ready or dependency_wait state", 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_issue_reready_command_refuses_timeout_reconcile_blocked_with_pr_link = function()
    local event = issue()
    local proposal_id = base_ids.proposal_id(event.repo, event.number)
    local ready_version = "consensus:github-devloop/issue/owner/repo/42/intake/1116/loop/1"
    local blocked_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)
    local command = trusted_issue_command("reready", "IC_issue_reready_timeout_pr_link")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", {
      h.projected_state_comment(proposal_id, "ready", ready_version, "result-marker,ready-label,devloop-ready"),
      core.state_marker(proposal_id, "blocked", blocked_version),
      m_builders.pr_link_marker(proposal_id, "7", "devloop-owner-repo-42-01HY", ready_version, "dev"),
      conv_reconcile.timeout_reconcile_marker(proposal_id, ready_version, "ready", 3, "drop", {
        terminal_version = blocked_version,
        from_state = "ready",
        from_version = ready_version,
        source_ref = event.source_ref,
      }),
      command,
    })
    mock_pr_origin({
      m_builders.pr_origin_marker(proposal_id, "42", "devloop-owner-repo-42-01HY", ready_version, "dev"),
    }, "devloop-owner-repo-42-01HY", "feedface")

    local result = run_observe(event, opts("operator-issue-reready-timeout-pr-link"))
    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment_raise.payload.body:find("operator command refused", 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_issue_reimplement_command_reenters_impl_failed = function()
    local event = reached()
    local ready_version = payloads_builders.build_devloop_ready_payload(core, event).dedup_key
    local command = trusted_issue_command("reimplement", "IC_issue_reimplement")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN", {
      core.state_marker(event.proposal_id, "impl-failed", ready_version),
      core.impl_failure_marker(
        event.proposal_id, ready_version, "codex-failed", nil, "UNKNOWN", true),
      command,
    })

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("operator-issue-reimplement"))
    t.eq(result.exit_code, 0)
    local command_response = find_issue_comment_raise(result.raises, "operator command accepted: reimplement")
    local ready_raise = find_raise(result.raises, "devloop_ready")
    t.is_true(command_response ~= nil)
    t.is_true(command_response.payload.body:find('command="reimplement"', 1, true) ~= nil)
    t.is_true(ready_raise ~= nil)
    t.eq(ready_raise.payload.proposal_id, event.proposal_id)
    t.eq(ready_raise.payload.implementation_version, ready_version)
    t.eq(ready_raise.payload.operator_reimplement_delivery.command_key,
      "operator-command/IC_issue_reimplement")
    t.is_true(ready_raise.payload.dedup_key ~= ready_version)
    t.eq(ready_raise.payload.impl_retry_attempt, 2)
  end,

  test_issue_reimplement_command_reenters_blocked_implementing_timeout_without_pr = function()
    local event = issue()
    local proposal_id = base_ids.proposal_id(event.repo, event.number)
    local inner_version = "github-devloop/issue/owner/repo/42/intake/2226"
    local ready_version = payloads_builders.build_devloop_ready_payload(core, {
      proposal_id = proposal_id,
      dedup_key = inner_version,
      source_ref = event.source_ref,
    }).dedup_key
    local blocked_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "implementing", 3)
    local command = trusted_issue_command("reimplement", "IC_issue_reimplement_timeout_without_pr")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", {
      core.state_marker(proposal_id, "implementing", ready_version),
      core.state_marker(proposal_id, "blocked", blocked_version),
      conv_reconcile.timeout_reconcile_marker(proposal_id, ready_version, "implementing", 3, "drop", {
        terminal_version = blocked_version,
        from_state = "implementing",
        from_version = ready_version,
        reason_class = "state-output-obligation-timeout",
        source_ref = event.source_ref,
      }),
      command,
    })

    local result = run_observe(event, opts("operator-issue-reimplement-timeout-without-pr"))
    t.eq(result.exit_code, 0)
    local command_response = find_issue_comment_raise(result.raises, "operator command accepted: reimplement")
    local ready_raise = find_raise(result.raises, "devloop_ready")
    t.is_true(command_response ~= nil)
    t.is_true(ready_raise ~= nil)
    t.eq(ready_raise.payload.proposal_id, proposal_id)
    t.eq(ready_raise.payload.implementation_version, ready_version)
    t.eq(ready_raise.payload.operator_reimplement_delivery.command_key,
      "operator-command/IC_issue_reimplement_timeout_without_pr")
    t.is_true(ready_raise.payload.dedup_key ~= ready_version)
    t.eq(ready_raise.payload.impl_retry_attempt, 2)
    t.eq(core.implementation_attempt_version(ready_raise.payload.implementation_version,
      ready_raise.payload.impl_retry_attempt), ready_version .. "/reimplement/2")
    t.eq(ready_raise.payload.operator_reentry.command, "reimplement")
    t.eq(ready_raise.payload.operator_reentry.from_state, "blocked")
    t.eq(ready_raise.payload.operator_reentry.terminal_reason, "implementing-timeout-without-pr")
    t.eq(ready_raise.payload.operator_reentry.state_version, blocked_version)
    t.eq(ready_raise.payload.operator_reentry.impl_version, ready_version)
    t.eq(ready_raise.payload.operator_reentry.timeout_round, 3)
    t.eq(ready_raise.payload.operator_reentry.pr_number, nil)
  end,
}
