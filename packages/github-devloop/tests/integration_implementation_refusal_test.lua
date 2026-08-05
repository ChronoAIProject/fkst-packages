local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local reimplement_helpers = require("tests.integration_reimplement_helpers")
local strings = require("contract.strings")
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
local deterministic_branch_for = h.deterministic_branch_for
local mock_issue_implement_view_only = reimplement_helpers.mock_issue_implement_view_only
local trusted_command = reimplement_helpers.trusted_command

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
  test_precursor_missing_refusal_replays_dropped_edge_request_until_visible_then_releases_fresh_ready = function()
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
    local replayed_edge_request = find_raise(
      edge_absent.raises, "github-proxy.github_issue_blocked_by_request")
    t.is_true(replayed_edge_request ~= nil)
    t.eq(replayed_edge_request.payload.repo, edge_request.payload.repo)
    t.eq(replayed_edge_request.payload.blocked_issue_number, edge_request.payload.blocked_issue_number)
    t.eq(replayed_edge_request.payload.blocking_issue_number, edge_request.payload.blocking_issue_number)
    t.eq(replayed_edge_request.payload.dedup_key, edge_request.payload.dedup_key)

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
