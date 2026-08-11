local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local requests_lifecycle = require("devloop.requests.lifecycle")
local m_facts = require("devloop.markers.facts")
local conv_reconcile = require("devloop.convergence.reconcile")
local reimplement_helpers = require("tests.integration_reimplement_helpers")
local m_builders = require("devloop.markers.builders")
local strings = require("contract.strings")
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
local mock_issue_implement_view_only = reimplement_helpers.mock_issue_implement_view_only
local trusted_command = reimplement_helpers.trusted_command

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

local function mock_observe_issue_state_once(labels, comments)
  entity_read_mocks.mock_issue_read_forms(t, {
    labels = labels,
    comments = comments,
    state = "OPEN",
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    times = 1,
  })
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

local function forged_command()
  local command = trusted_command("IC_reimplement_forged")
  command.author_login = "mallory"
  return command
end

local function impl_failed_comments(event, reason, attempt, fault_class, retryable, command)
  local version = payloads_builders.build_devloop_ready_payload(event).dedup_key
  local comments = {
    core.state_marker(event.proposal_id, "impl-failed", version),
    core.impl_failure_marker(
      event.proposal_id, version, reason or "codex-failed", attempt, fault_class, retryable),
  }
  if command ~= nil then
    table.insert(comments, command)
  end
  return comments
end

local function observe_comments(proposal_id, failure_body, command)
  local dedup = tostring(failure_body):match('dedup="([^"]*)"')
  if dedup == nil then
    error("github-devloop test: impl-failure marker carries no dedup attribute")
  end
  local comments = {
    core.state_marker(proposal_id, "impl-failed", dedup),
    failure_body,
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

local function local_iteration_marker(outcome)
  local pair = ({
    PASS = "PASS:NONE",
    SEMANTIC_FAIL = "FAIL:SEMANTIC",
    INFRASTRUCTURE_FAIL = "FAIL:INFRASTRUCTURE",
  })[outcome]
  if pair == nil then
    error("github-devloop test: unknown local iteration outcome " .. tostring(outcome))
  end
  return "FKST_LOCAL_ITERATION_RESULT:v2:" .. pair .. "\n"
end

local function find_impl_failure_comment(raises)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("fkst:github-devloop:impl-failure:v1", 1, true) ~= nil
  end)
end

local function assert_department_success(result, name)
  t.is_true(result.exit_code == 0, name .. ": " .. tostring(
    result.error or result.stderr or (result.failure and result.failure.error)))
end

local function mock_base_probe(worktree, outcome)
  local base_probe = worktree .. "-base-probe"
  for _ = 1, 2 do
    h.mock_force_clean(base_probe)
  end
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git worktree add --detach", {
    stdout = "Preparing worktree (detached HEAD abc123)\n",
    stderr = "",
    exit_code = 0,
  })
  -- The base probe now proves the tree materialized before any test verdict can form, so the
  -- harness must model those reads; an unmocked command fails closed and would look like an
  -- unmaterialized tree.
  t.mock_command("status --porcelain", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("ls-files", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("ls-tree", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("rev-parse HEAD", { stdout = "abc123\n", stderr = "", exit_code = 0 })
  t.mock_command("scripts/run.sh test-affected", {
    stdout = local_iteration_marker(outcome),
    stderr = "",
    exit_code = outcome == "PASS" and 0 or 1,
  })
end

local function run_initial_typed_failure(event, outcome, name, base_outcome)
  local ready = payloads_builders.build_devloop_ready_payload(event)
  mock_issue_implement_view_only({ "fkst-dev:ready", "fkst-dev:thinking" }, {
    h.projected_state_comment(event.proposal_id, "ready", ready.dedup_key),
  }, 3)
  local worktree = mock_fresh_implement_worktree()
  t.mock_command("codex exec", { stdout = "implemented", stderr = "", exit_code = 0 })
  mock_git_status(" M packages/github-devloop/core.lua\n")
  mock_git_commit(nil, devloop_base.implement_branch("owner/repo", "42", ready.dedup_key))
  t.mock_command("scripts/run.sh test-affected", {
    stdout = "",
    stderr = local_iteration_marker(outcome) .. "typed local iteration failure\n",
    exit_code = 1,
  })
  if outcome == "SEMANTIC_FAIL" then
    mock_base_probe(worktree, base_outcome or "PASS")
  end

  local result = run_implement(ready, opts(name))
  assert_department_success(result, name)
  local failure = find_impl_failure_comment(result.raises)
  t.is_true(failure ~= nil, name .. ": implement did not publish impl-failure:v1")
  return ready, failure
end


return {
  test_infrastructure_failure_is_durable_but_not_autoretried_and_operator_reenters = function()
    local event = reached()
    local first_ready, first_failure = run_initial_typed_failure(
      event, "INFRASTRUCTURE_FAIL", "implement-infrastructure-failure-first")
    t.is_true(first_failure.payload.body:find('fault_class="INFRASTRUCTURE"', 1, true) ~= nil)
    t.is_true(first_failure.payload.body:find('retryable="false"', 1, true) ~= nil)
    local first_fact = core.impl_failure_fact(
      { first_failure.payload.body }, event.proposal_id, first_ready.dedup_key)
    t.is_true(first_fact ~= nil, "INFRASTRUCTURE marker did not round-trip as an implementation failure fact")
    t.eq(first_fact.fault_class, "INFRASTRUCTURE")
    t.eq(first_fact.retryable, false)
    t.eq(core.impl_failure_retry_allowed(first_fact), false)

    mock_observe_issue_state_once(
      { "fkst-dev:enabled", "fkst-dev:impl-failed" },
      observe_comments(event.proposal_id, first_failure.payload.body))
    local observed = run_observe(
      issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }),
      opts("observe-infrastructure-failure-first"))
    assert_department_success(observed, "observe-infrastructure-failure-first")
    t.eq(find_raise(observed.raises, "devloop_ready"), nil)

    local command = trusted_command("IC_reimplement_infrastructure")
    mock_observe_issue_state_once(
      { "fkst-dev:enabled", "fkst-dev:impl-failed" },
      observe_comments(event.proposal_id, first_failure.payload.body, command))
    local operator = run_observe(
      issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }),
      opts("operator-reimplement-infrastructure"))
    assert_department_success(operator, "operator-reimplement-infrastructure")
    local operator_retry = find_raise(operator.raises, "devloop_ready")
    t.is_true(operator_retry ~= nil, "operator reimplement did not rescue infrastructure failure")
    t.eq(operator_retry.payload.impl_retry_attempt, 2)
  end,

  test_base_infrastructure_failure_is_durable_but_not_autoretried = function()
    local event = reached()
    local ready, failure = run_initial_typed_failure(
      event, "SEMANTIC_FAIL", "implement-base-infrastructure-failure", "INFRASTRUCTURE_FAIL")
    t.is_true(failure.payload.body:find(
      "github-devloop implementation failed: base-local-iteration-infrastructure-failed", 1, true) ~= nil)
    t.is_true(failure.payload.body:find('fault_class="INFRASTRUCTURE"', 1, true) ~= nil)
    t.is_true(failure.payload.body:find('retryable="false"', 1, true) ~= nil)
    local fact = core.impl_failure_fact(
      { failure.payload.body }, event.proposal_id, ready.dedup_key)
    t.is_true(fact ~= nil, "base INFRASTRUCTURE marker did not round-trip as an implementation failure fact")
    t.eq(fact.fault_class, "INFRASTRUCTURE")
    t.eq(fact.retryable, false)
    t.eq(core.impl_failure_retry_allowed(fact), false)

    mock_observe_issue_state_once(
      { "fkst-dev:enabled", "fkst-dev:impl-failed" },
      observe_comments(event.proposal_id, failure.payload.body))
    local observed = run_observe(
      issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }),
      opts("observe-base-infrastructure-failure"))
    assert_department_success(observed, "observe-base-infrastructure-failure")
    t.eq(find_raise(observed.raises, "devloop_ready"), nil)
  end,

  test_semantic_failure_is_durable_but_not_autoretried = function()
    local event = reached()
    local semantic_ready, failure = run_initial_typed_failure(
      event, "SEMANTIC_FAIL", "implement-semantic-failure")
    t.is_true(failure.payload.body:find('fault_class="SEMANTIC"', 1, true) ~= nil)
    t.is_true(failure.payload.body:find('retryable="false"', 1, true) ~= nil)
    local semantic_fact = core.impl_failure_fact(
      { failure.payload.body }, event.proposal_id, semantic_ready.dedup_key)
    t.is_true(semantic_fact ~= nil, "SEMANTIC marker did not round-trip as an implementation failure fact")
    t.eq(semantic_fact.fault_class, "SEMANTIC")
    t.eq(semantic_fact.retryable, false)
    t.eq(core.impl_failure_retry_allowed(semantic_fact), false)

    mock_observe_issue_state_once(
      { "fkst-dev:enabled", "fkst-dev:impl-failed" },
      observe_comments(event.proposal_id, failure.payload.body))
    local observed = run_observe(
      issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }),
      opts("observe-semantic-failure"))
    assert_department_success(observed, "observe-semantic-failure")
    t.eq(find_raise(observed.raises, "devloop_ready"), nil)
  end,

  test_observe_autoretries_codex_failed_once = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN",
      impl_failed_comments(event, "codex-failed", 1, "UNKNOWN", true))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("observe-impl-failed-retry"))
    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.dedup_key, payloads_builders.build_devloop_ready_payload(event).dedup_key)
    t.eq(ready.payload.impl_retry_attempt, 2)
  end,

  test_observe_autoretries_non_descendant_head_once = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN",
      impl_failed_comments(event, "non-descendant-head", 1, "UNKNOWN", true))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("observe-non-descendant-head-retry"))
    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.dedup_key, payloads_builders.build_devloop_ready_payload(event).dedup_key)
    t.eq(ready.payload.impl_retry_attempt, 2)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
  end,

  test_observe_stops_after_bounded_codex_failed_retry = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN",
      impl_failed_comments(event, "codex-failed", 2, "UNKNOWN", true))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("observe-impl-failed-limit"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_observe_stops_after_bounded_non_descendant_head_retry = function()
    local event = reached()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN",
      impl_failed_comments(event, "non-descendant-head", 2, "UNKNOWN", true))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("observe-non-descendant-head-limit"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_reimplement_command_reenters_after_retry_limit = function()
    local event = reached()
    local command = trusted_command()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN",
      impl_failed_comments(event, "codex-failed", 2, "UNKNOWN", true, command))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("operator-reimplement"))
    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    local ready_version = payloads_builders.build_devloop_ready_payload(event).dedup_key
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
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, "OPEN",
      impl_failed_comments(event, "codex-failed", 2, "UNKNOWN", true, forged_command()))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" } }), opts("operator-reimplement-forged"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_reimplement_command_reenters_blocked_open_pr_from_issue = function()
    local event = reached()
    local ready_version = payloads_builders.build_devloop_ready_payload(event).dedup_key
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
    local ready_version = payloads_builders.build_devloop_ready_payload(event).dedup_key
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
    local ready = payloads_builders.build_devloop_ready_payload(event)
    ready.impl_retry_attempt = 2
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, {
      core.state_marker(event.proposal_id, "impl-failed", ready.dedup_key),
      core.impl_failure_marker(
        event.proposal_id, ready.dedup_key, "codex-failed", 1, "UNKNOWN", true),
    })
    mock_existing_empty_implement_worktree({
      impl_version = ready.dedup_key .. "/reimplement/2",
    })
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(nil, devloop_base.implement_branch("owner/repo", "42", ready.dedup_key))
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, {
      core.state_marker(event.proposal_id, "impl-failed", ready.dedup_key),
      core.impl_failure_marker(
        event.proposal_id, ready.dedup_key, "codex-failed", 1, "UNKNOWN", true),
    })
    mock_issue_implement_raw({ "fkst-dev:impl-failed" }, {
      core.state_marker(event.proposal_id, "impl-failed", ready.dedup_key),
      core.impl_failure_marker(
        event.proposal_id, ready.dedup_key, "codex-failed", 1, "UNKNOWN", true),
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
    local ready = payloads_builders.build_devloop_ready_payload(event)
    ready.impl_retry_attempt = 2
    local comments = {
      core.state_marker(event.proposal_id, "impl-failed", ready.dedup_key),
      core.impl_failure_marker(
        event.proposal_id, ready.dedup_key, "codex-failed", 1, "UNKNOWN", true),
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
    local ready = payloads_builders.build_devloop_ready_payload(event)
    ready.framing = nil
    ready.impl_retry_attempt = 2
    local result_comment = requests_lifecycle.build_result_comment_request(core.output_language, "owner/repo", "42", event).body
    local prior_receipt = lean_receipt(event, ready.dedup_key, "repair-needed", "construction", 1)
    local failure_comment = requests_lifecycle.build_impl_failure_comment_request(core.impl_failure_marker, core.output_language, "owner/repo", "42", ready,
      "lean-proof-repair-needed", prior_receipt, 1, "UNKNOWN", true).body
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
    local ready = payloads_builders.build_devloop_ready_payload(event)
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
    local ready = payloads_builders.build_devloop_ready_payload(event)
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
}
