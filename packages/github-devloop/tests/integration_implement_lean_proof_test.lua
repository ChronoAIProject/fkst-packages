local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local requests_lifecycle = require("devloop.requests.lifecycle")
local strings = require("contract.strings")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local projected_transitions = require("tests.projected_transition_helpers")

local t = h.t
local core = h.core
local target = "Proofs/Target.lean"
local checker_command = "lake env lean -E hasSorry " .. target

local function find_comment(raises, text)
  return h.find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find(text, 1, true) ~= nil
  end)
end

local function count_comments(raises, text)
  local count = 0
  for _, raised in ipairs(raises or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request"
      and tostring(raised.payload and raised.payload.body or ""):find(text, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function json_array(values)
  local encoded = {}
  for _, value in ipairs(values or {}) do
    table.insert(encoded, strings.json_string(value))
  end
  return "[" .. table.concat(encoded, ",") .. "]"
end

local function receipt_json(event, fields)
  local value = fields or {}
  local status = value.status or "repair-needed"
  local parts = {
    '"schema":"github-devloop.lean-proof-result.v1"',
    '"status":' .. strings.json_string(status),
    '"phase":' .. strings.json_string(value.phase or "construction"),
    '"proposal_id":' .. strings.json_string(event.proposal_id),
    '"implementation_version":' .. strings.json_string(value.implementation_version or event.dedup_key),
    '"attempt":' .. tostring(value.attempt or 1),
    '"target":' .. strings.json_string(value.target or target),
    '"declaration":"target_theorem"',
    '"checker_command":' .. strings.json_string(checker_command),
  }
  if status ~= "complete" then
    table.insert(parts, '"last_obligation":' .. strings.json_string(value.last_obligation or "case h => False"))
    table.insert(parts, '"attempted_approaches":' .. json_array(value.attempted_approaches or { "simp", "exact helper_lemma" }))
    table.insert(parts, '"search_evidence":{"status":"performed","queries":["Nat.succ_eq_add_one"]}')
    if value.omit_blocker ~= true then
      table.insert(parts, '"remaining_blocker":' .. strings.json_string(value.remaining_blocker or "missing monotonicity premise"))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function proof_event()
  local accepted = h.reached({
    title = "Complete the bounded Lean proof",
    framing = "Complete `Proofs/Target.lean` without changing the theorem statement.",
  })
  return payloads_builders.build_devloop_ready_payload(core, accepted), accepted
end

local function accepted_result_comment(accepted)
  return projected_transitions.result_comment(core, "owner/repo", "42", accepted).body
end

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at,
  }
end

local function mock_toolchain(branch)
  t.mock_command("git cat-file -t " .. branch .. ":lean-toolchain", {
    stdout = "blob\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_checker(result)
  t.mock_command(checker_command, result or {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_implementation_issue_reads(labels, comments)
  local fields = {
    labels = labels,
    comments = comments,
    state = "OPEN",
    title = "Complete the bounded Lean proof",
  }
  entity_read_mocks.mock_issue_view_selector(t, fields, "title,body,labels,comments,state,author", 3)
  entity_read_mocks.mock_issue_view_selector(t, fields, "number,title,author", 1)
end

local function mock_observe_impl_failed(comments)
  local fields = {
    labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" },
    comments = comments,
    state = "OPEN",
    updated_at = "2026-06-03T04:00:00Z",
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    times = 1,
  }
  entity_read_mocks.mock_issue_read_with_defaults(t, fields.labels, comments, fields)
end

local function run_construction(raw, id)
  local ready, accepted = proof_event()
  local branch = devloop_base.implement_branch("owner/repo", "42", ready.dedup_key)
  mock_implementation_issue_reads({ "fkst-dev:ready", "fkst-dev:thinking" }, {
    accepted_result_comment(accepted),
  })
  h.mock_fresh_implement_worktree()
  mock_toolchain(branch)
  h.mock_implement_codex(0, raw)
  h.mock_git_status(" M " .. target .. "\n")
  h.mock_git_commit("def456", branch)
  local result = h.run_implement(ready, h.opts(id))
  return ready, accepted, branch, result
end

local function retry_from_failure(ready, accepted, failure_body, raw, id, checker)
  local comments = {
    trusted_comment(accepted_result_comment(accepted), "2026-06-03T01:00:00Z"),
    trusted_comment(failure_body, "2026-06-03T02:00:00Z"),
  }
  local failure_fact = core.impl_failure_fact(comments, ready.proposal_id, ready.dedup_key)
  t.is_true(failure_fact ~= nil, "construction failure comment must expose impl-failure:v1")
  t.eq(failure_fact.reason, "lean-proof-repair-needed")
  t.eq(core.impl_failure_retry_allowed(failure_fact), true, "lean repair must use the existing bounded retry policy")
  t.eq(core.current_state(comments, ready.proposal_id).state, "impl-failed",
    "the later failure receipt must be the authoritative lifecycle fact")
  mock_observe_impl_failed({
    trusted_comment(failure_body, "2026-06-03T02:00:00Z"),
  })
  local observed = h.run_observe(h.issue({
    labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" },
  }), h.opts(id .. "-observe"))
  local replay = h.find_raise(observed.raises, "devloop_ready")
  t.is_true(replay ~= nil, "impl-failed observation must emit attempt-two devloop_ready")
  t.eq(replay.payload.impl_retry_attempt, 2)

  mock_implementation_issue_reads({ "fkst-dev:impl-failed" }, comments)
  h.mock_existing_empty_implement_worktree({
    impl_version = ready.dedup_key .. "/reimplement/2",
  })
  local branch = devloop_base.implement_branch("owner/repo", "42", ready.dedup_key)
  mock_toolchain(branch)
  h.mock_implement_codex(0, raw)
  h.mock_git_status(" M " .. target .. "\n")
  if checker ~= false then
    mock_checker(type(checker) == "table" and checker or nil)
  end
  h.mock_git_commit("fedcba", branch)
  local repaired = h.run_implement(replay.payload, h.opts(id .. "-repair"))
  return observed, repaired
end

return {
  test_lean_proof_repair_uses_existing_attempt_two_and_publishes_once = function()
    local ready = proof_event()
    local first_raw = receipt_json(ready, {
      last_obligation = "target_theorem: unsolved goals\ncase h => False",
    })
    local actual_ready, accepted, _, first = run_construction(first_raw, "lean-proof-construction")
    local first_failure = find_comment(first.raises, "github-devloop implementation failed: lean-proof-repair-needed")
    t.is_true(first_failure ~= nil, "construction must publish lean-proof-repair-needed")
    t.eq(count_comments(first.raises, "github-devloop implementation output published"), 0)

    local second_version = actual_ready.dedup_key .. "/reimplement/2"
    local complete = receipt_json(actual_ready, {
      status = "complete",
      phase = "strong-repair",
      attempt = 2,
      implementation_version = second_version,
    })
    local _, repaired = retry_from_failure(actual_ready, accepted, first_failure.payload.body,
      complete, "lean-proof-complete")

    t.eq(repaired.exit_code, 0)
    t.eq(count_comments(repaired.raises, "github-devloop implementation output published"), 1)
    t.eq(find_comment(repaired.raises, "fkst:github-devloop:impl-failure:v1"), nil)
    t.eq(h.count_calls("codex exec"), 2)
    t.eq(h.count_calls(checker_command), 1)
    t.eq(h.count_calls("scripts/run.sh test-affected"), 1)

    local prompts = {}
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find("codex exec", 1, true) ~= nil then
        table.insert(prompts, call.stdin)
      end
    end
    t.eq(#prompts, 2)
    t.is_true(prompts[2]:find("Strong repair phase", 1, true) ~= nil)
    t.is_true(prompts[2]:find("target_theorem: unsolved goals\ncase h => False", 1, true) ~= nil)
    t.is_true(prompts[2]:find("Do not restart from the whole theorem", 1, true) ~= nil)
  end,

  test_lean_proof_exhaustion_keeps_typed_negative_knowledge_and_never_hands_off = function()
    local ready = proof_event()
    local first_raw = receipt_json(ready, { last_obligation = "case h => False" })
    local actual_ready, accepted, _, first = run_construction(first_raw, "lean-proof-exhaustion-construction")
    local first_failure = find_comment(first.raises, "lean-proof-repair-needed")
    t.is_true(first_failure ~= nil, "construction must publish a repair receipt before exhaustion")

    local exhausted_raw = receipt_json(actual_ready, {
      phase = "strong-repair",
      attempt = 2,
      implementation_version = actual_ready.dedup_key .. "/reimplement/2",
      last_obligation = "case h => False",
      attempted_approaches = { "simp", "exact helper_lemma", "omega" },
      remaining_blocker = "the required monotonicity premise is unavailable",
    })
    local _, exhausted = retry_from_failure(actual_ready, accepted, first_failure.payload.body,
      exhausted_raw, "lean-proof-exhausted", false)

    local final_failure = find_comment(exhausted.raises, "github-devloop implementation failed: lean-proof-exhausted")
    t.is_true(final_failure ~= nil)
    t.is_true(final_failure.payload.body:find('"target":"Proofs/Target.lean"', 1, true) ~= nil)
    t.is_true(final_failure.payload.body:find('"last_obligation":"case h => False"', 1, true) ~= nil)
    t.is_true(final_failure.payload.body:find('"attempted_approaches":["simp","exact helper_lemma","omega"]', 1, true) ~= nil)
    t.is_true(final_failure.payload.body:find('"remaining_blocker":"the required monotonicity premise is unavailable"', 1, true) ~= nil)
    t.eq(count_comments(exhausted.raises, "github-devloop implementation output published"), 0)
    t.eq(h.count_calls(checker_command), 0)

    mock_observe_impl_failed({
      trusted_comment(accepted_result_comment(accepted), "2026-06-03T01:00:00Z"),
      trusted_comment(final_failure.payload.body, "2026-06-03T03:00:00Z"),
    })
    local observed = h.run_observe(h.issue({
      labels = { "fkst-dev:enabled", "fkst-dev:impl-failed" },
    }), h.opts("lean-proof-exhausted-observe"))
    t.eq(h.find_raise(observed.raises, "devloop_ready"), nil)
  end,

  test_lean_proof_malformed_result_fails_closed_without_handoff = function()
    local ready, _, _, result = run_construction("not-json", "lean-proof-malformed")
    local failure = find_comment(result.raises, "github-devloop implementation failed: lean-proof-invalid-result")
    t.is_true(failure ~= nil)
    t.is_true(failure.payload.body:find("typed result envelope", 1, true) ~= nil)
    t.eq(count_comments(result.raises, "github-devloop implementation output published"), 0)
    t.eq(ready.proposal_id, "github-devloop/issue/owner/repo/42")
  end,

  test_lean_proof_wrong_target_result_fails_closed_without_handoff = function()
    local ready = proof_event()
    local raw = receipt_json(ready, { target = "Proofs/Other.lean" })
    local _, _, _, result = run_construction(raw, "lean-proof-wrong-target")
    t.is_true(find_comment(result.raises, "github-devloop implementation failed: lean-proof-invalid-result") ~= nil)
    t.eq(count_comments(result.raises, "github-devloop implementation output published"), 0)
  end,

  test_lean_proof_checker_failure_and_semantic_placeholder_diagnostic_fail_closed = function()
    local ready = proof_event()
    local complete = receipt_json(ready, { status = "complete" })
    local cases = {
      {
        id = "lean-proof-checker-red",
        checker = { stdout = "", stderr = "type mismatch\n", exit_code = 1 },
        reason = "lean-proof-checker-failed",
      },
      {
        id = "lean-proof-sorry-red",
        checker = {
          stdout = "",
          stderr = target .. ":12:8: warning: declaration uses 'sorry'\n",
          exit_code = 1,
        },
        reason = "lean-proof-placeholder-detected",
      },
    }
    for _, case in ipairs(cases) do
      local actual_ready, accepted = proof_event()
      local branch = devloop_base.implement_branch("owner/repo", "42", actual_ready.dedup_key)
      h.mock_issue_implement({ "fkst-dev:ready", "fkst-dev:thinking" }, {
        accepted_result_comment(accepted),
      })
      h.mock_fresh_implement_worktree()
      mock_toolchain(branch)
      t.mock_command("codex exec", { stdout = complete, stderr = "", exit_code = 0 })
      mock_checker(case.checker)
      h.mock_git_status(" M " .. target .. "\n")
      t.mock_command("scripts/run.sh test-affected", { stdout = "", stderr = "", exit_code = 0 })
      h.mock_git_commit("def456", branch)

      local result = h.run_implement(actual_ready, h.opts(case.id))
      t.is_true(find_comment(result.raises, "github-devloop implementation failed: " .. case.reason) ~= nil)
      t.eq(count_comments(result.raises, "github-devloop implementation output published"), 0)
    end
  end,

  test_lean_proof_local_verification_failure_never_hands_off = function()
    local ready, accepted = proof_event()
    local branch = devloop_base.implement_branch("owner/repo", "42", ready.dedup_key)
    h.mock_issue_implement({ "fkst-dev:ready", "fkst-dev:thinking" }, {
      accepted_result_comment(accepted),
    })
    h.mock_fresh_implement_worktree()
    mock_toolchain(branch)
    t.mock_command("codex exec", {
      stdout = receipt_json(ready, { status = "complete" }),
      stderr = "",
      exit_code = 0,
    })
    mock_checker()
    h.mock_git_status(" M " .. target .. "\n")
    for _ = 1, 2 do
      t.mock_command("scripts/run.sh test-affected", {
        stdout = "",
        stderr = "local iteration runner unavailable\n",
        exit_code = 2,
      })
    end

    local result = h.run_implement(ready, h.opts("lean-proof-local-gate-red"))
    t.is_true(find_comment(result.raises,
      "github-devloop implementation failed: local-iteration-attribution-indeterminate") ~= nil)
    t.eq(count_comments(result.raises, "github-devloop implementation output published"), 0)
  end,
}
