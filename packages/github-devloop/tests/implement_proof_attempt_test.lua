local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local requests_lifecycle = require("devloop.requests.lifecycle")
local strings = require("contract.strings")

local t = h.t
local core = h.core

local proposal_id = "github-devloop/issue/owner/repo/42"
local implementation_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local target = "Proofs/Target.lean"
local checker_command = "lake env lean -E hasSorry Proofs/Target.lean"

local function load_proof_attempt()
  local ok, proof_attempt = pcall(require, "departments.implement.proof_attempt")
  t.eq(ok, true)
  return proof_attempt
end

local function json_array(values)
  local encoded = {}
  for _, value in ipairs(values or {}) do
    table.insert(encoded, strings.json_string(value))
  end
  return "[" .. table.concat(encoded, ",") .. "]"
end

local function receipt_json(fields)
  local value = fields or {}
  local parts = {
    '"schema":"github-devloop.lean-proof-result.v1"',
    '"status":' .. strings.json_string(value.status or "repair-needed"),
    '"phase":' .. strings.json_string(value.phase or "construction"),
    '"proposal_id":' .. strings.json_string(value.proposal_id or proposal_id),
    '"implementation_version":' .. strings.json_string(value.implementation_version or implementation_version),
    '"attempt":' .. tostring(value.attempt or 1),
    '"target":' .. strings.json_string(value.target or target),
    '"declaration":' .. strings.json_string(value.declaration or "target_theorem"),
    '"checker_command":' .. strings.json_string(value.checker_command or checker_command),
  }
  if value.status ~= "complete" then
    table.insert(parts, '"last_obligation":' .. strings.json_string(value.last_obligation or "case h => False"))
    table.insert(parts, '"attempted_approaches":' .. json_array(value.attempted_approaches or { "simp", "exact helper_lemma" }))
    local search = value.search_evidence or {
      status = "performed",
      queries = { "Nat.succ_eq_add_one" },
    }
    local search_parts = { '"status":' .. strings.json_string(search.status) }
    if search.queries ~= nil then
      table.insert(search_parts, '"queries":' .. json_array(search.queries))
    end
    if search.detail ~= nil then
      table.insert(search_parts, '"detail":' .. strings.json_string(search.detail))
    end
    table.insert(parts, '"search_evidence":{' .. table.concat(search_parts, ",") .. "}")
    if value.omit_blocker ~= true then
      table.insert(parts, '"remaining_blocker":' .. strings.json_string(value.remaining_blocker or "missing monotonicity premise"))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function expected(fields)
  local value = fields or {}
  return {
    proposal_id = value.proposal_id or proposal_id,
    implementation_version = value.implementation_version or implementation_version,
    attempt = value.attempt or 1,
    phase = value.phase or "construction",
    target = value.target or target,
    checker_command = checker_command,
  }
end

return {
  test_typed_repair_receipt_validates_all_negative_knowledge_fields = function()
    local proof_attempt = load_proof_attempt()
    local raw = receipt_json()

    local receipt, err = proof_attempt.decode(raw, expected())

    t.eq(err, nil)
    t.eq(receipt.status, "repair-needed")
    t.eq(receipt.target, target)
    t.eq(receipt.declaration, "target_theorem")
    t.eq(receipt.last_obligation, "case h => False")
    t.eq(receipt.attempted_approaches[2], "exact helper_lemma")
    t.eq(receipt.search_summary, "performed: Nat.succ_eq_add_one")
    t.eq(receipt.remaining_blocker, "missing monotonicity premise")
    t.eq(receipt.raw, raw)
  end,

  test_typed_receipt_rejects_malformed_stale_and_wrong_target_results = function()
    local proof_attempt = load_proof_attempt()
    local malformed, malformed_err = proof_attempt.decode(receipt_json({ omit_blocker = true }), expected())
    t.eq(malformed, nil)
    t.is_true(tostring(malformed_err):find("remaining_blocker", 1, true) ~= nil)

    local stale, stale_err = proof_attempt.decode(receipt_json({ implementation_version = implementation_version .. "/stale" }), expected())
    t.eq(stale, nil)
    t.is_true(tostring(stale_err):find("implementation_version", 1, true) ~= nil)

    local wrong_target, target_err = proof_attempt.decode(receipt_json({ target = "Proofs/Other.lean" }), expected())
    t.eq(wrong_target, nil)
    t.is_true(tostring(target_err):find("target", 1, true) ~= nil)
  end,

  test_typed_receipt_accepts_verified_search_tool_absence = function()
    local proof_attempt = load_proof_attempt()
    local raw = receipt_json({
      search_evidence = {
        status = "unavailable",
        detail = "No repository or mathlib search command is installed.",
      },
    })

    local receipt, err = proof_attempt.decode(raw, expected())

    t.eq(err, nil)
    t.eq(receipt.search_summary, "unavailable: No repository or mathlib search command is installed.")
  end,

  test_replay_rehydrates_prior_receipt_from_trusted_failure_comment = function()
    local proof_attempt = load_proof_attempt()
    local ready = payloads_builders.build_devloop_ready_payload(core, h.reached())
    local raw = receipt_json({ implementation_version = ready.dedup_key })
    local request = requests_lifecycle.build_impl_failure_comment_request(
      core,
      "owner/repo",
      "42",
      ready,
      "lean-proof-repair-needed",
      raw,
      1
    )

    local receipt, receipt_raw = proof_attempt.previous_receipt({
      {
        body = request.body,
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T02:03:04Z",
      },
    }, {
      proposal_id = proposal_id,
      target = target,
      before_attempt = 2,
      checker_command = checker_command,
    })

    t.eq(receipt.last_obligation, "case h => False")
    t.eq(receipt_raw, raw)
  end,

  test_candidate_verifier_runs_shell_free_semantic_no_sorries_checker = function()
    local proof_attempt = load_proof_attempt()
    local calls = {}
    local verified = proof_attempt.verify_candidate("/tmp/proof-worktree", target, 7200, function(opts)
      table.insert(calls, opts)
      return { stdout = "", stderr = "", exit_code = 0 }
    end)

    t.eq(verified.ok, true)
    t.eq(calls[1].cwd, "/tmp/proof-worktree")
    t.eq(calls[1].timeout, 7200)
    t.eq(table.concat(calls[1].argv, " "), checker_command)

    local rejected = proof_attempt.verify_candidate("/tmp/proof-worktree", target, 7200, function()
      return {
        stdout = "",
        stderr = "Proofs/Target.lean:12:8: warning: declaration uses 'sorry'\n",
        exit_code = 1,
      }
    end)
    t.eq(rejected.ok, false)
    t.eq(rejected.reason, "lean-proof-placeholder-detected")
  end,
}
