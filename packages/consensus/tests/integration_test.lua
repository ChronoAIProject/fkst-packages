local t = fkst.test
local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"
local meta_decision_label = "⟦FKST:META_DECISION⟧"
local meta_reason_label = "⟦FKST:META_REASON⟧"

local function nonce()
  return tostring({}):gsub("[^%w._-]", "_")
end

local function runtime_root(name)
  return "/tmp/fkst-packages-test/consensus/" .. tostring(now()) .. "/" .. nonce() .. "/" .. name
end

local function opts(name)
  return {
    env = {
      FKST_RUNTIME_ROOT = runtime_root(name),
    },
  }
end

local function proposal(extra)
  local value = {
    schema = "consensus.proposal.v1",
    proposal_id = "proposal-42",
    title = "Adopt consensus package",
    body = "Create a small flat package that asks several angles to judge a proposal.",
    context = "The package must stay silent unless all angles agree.",
    angles = { "minimal", "structural", "delete" },
    dedup_key = "proposal-42-v1",
    -- Source-agnostic sample: an opaque {kind, ref} pointer, not tied to any provider.
    source_ref = {
      kind = "proposal",
      ref = "demo/consensus/42",
    },
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function run_decide(event_payload, run_opts)
  return t.run_department("departments/decide/main.lua", {
    queue = "proposal",
    payload = event_payload,
  }, run_opts)
end

local function codex_calls()
  local calls = {}
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find("codex exec", 1, true) ~= nil then
      table.insert(calls, call)
    end
  end
  return calls
end

local function mock_angle(verdict, reply, exit_code)
  t.mock_command("codex exec", {
    stdout = verdict_label .. " " .. verdict .. "\n" .. reply_label .. " " .. reply .. "\n",
    stderr = "",
    exit_code = exit_code or 0,
  })
end

local function mock_meta(decision, reason, exit_code)
  t.mock_command("codex exec", {
    stdout = meta_decision_label .. " " .. decision .. "\n" .. meta_reason_label .. " " .. reason .. "\n",
    stderr = "",
    exit_code = exit_code or 0,
  })
end

return {
  test_all_angles_approve_raises_consensus_reached = function()
    mock_angle("approve", "Minimal angle approves.")
    mock_angle("approve", "Structural angle approves.")
    mock_angle("approve", "Delete angle approves.")

    local result = run_decide(proposal(), opts("all-approve"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_reached")
    t.eq(result.raises[1].payload.schema, "consensus.consensus_reached.v1")
    t.eq(result.raises[1].payload.proposal_id, "proposal-42")
    t.eq(result.raises[1].payload.decision, "approve")
    t.eq(result.raises[1].payload.dedup_key, "consensus:proposal-42-v1")
    t.eq(result.raises[1].payload.source_ref.kind, "proposal")
    t.eq(result.raises[1].payload.source_ref.ref, "demo/consensus/42")
    t.eq(#result.raises[1].payload.angle_results, 3)

    local calls = codex_calls()
    t.eq(#calls, 3)
    t.is_true(calls[1].stdin:find("Angle: minimal", 1, true) ~= nil)
    t.is_true(calls[2].stdin:find("Angle: structural", 1, true) ~= nil)
    t.is_true(calls[3].stdin:find("Angle: delete", 1, true) ~= nil)
  end,

  test_unanimous_reject_raises_consensus_reached = function()
    mock_angle("reject", "Minimal angle rejects.")
    mock_angle("reject", "Structural angle rejects.")
    mock_angle("reject", "Delete angle rejects.")

    local result = run_decide(proposal(), opts("all-reject"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.decision, "reject")
    t.eq(#codex_calls(), 3)
  end,

  test_split_verdicts_raise_consensus_unresolved = function()
    mock_angle("approve", "Minimal angle approves.")
    mock_angle("reject", "Structural angle rejects.")
    mock_angle("approve", "Delete angle approves.")

    local result = run_decide(proposal(), opts("split"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_unresolved")
    t.eq(result.raises[1].payload.schema, "consensus.consensus_unresolved.v1")
    t.eq(result.raises[1].payload.proposal_id, "proposal-42")
    t.eq(result.raises[1].payload.dedup_key, "consensus:proposal-42-v1")
    t.eq(result.raises[1].payload.source_ref.kind, "proposal")
    t.eq(result.raises[1].payload.source_ref.ref, "demo/consensus/42")
    t.is_nil(result.raises[1].payload.body)
    t.is_nil(result.raises[1].payload.angle_results)
    t.is_nil(result.raises[1].payload.decision)
    t.eq(#codex_calls(), 3)
  end,

  test_close_disagreement_meta_converges_to_consensus_reached = function()
    mock_angle("approve", "Minimal angle approves the small scope.")
    mock_angle("abstain", "Structural angle needs the scope stated explicitly.")
    mock_angle("approve", "Delete angle accepts because no extra package surface is added.")
    mock_meta("approve", "The abstention is a scope wording concern, not a different action.")

    local result = run_decide(proposal(), opts("meta-converges"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_reached")
    t.eq(result.raises[1].payload.decision, "approve")
    t.eq(result.raises[1].payload.meta_result.decision, "approve")
    t.eq(result.raises[1].payload.meta_result.reason, "The abstention is a scope wording concern, not a different action.")
    t.is_true(result.raises[1].payload.body:find("meta-judge:", 1, true) ~= nil)

    local calls = codex_calls()
    t.eq(#calls, 4)
    t.is_true(calls[4].stdin:find("Meta-judge this non-unanimous consensus result.", 1, true) ~= nil)
    t.is_true(calls[4].stdin:find("Candidate decision: approve", 1, true) ~= nil)
    t.is_true(calls[4].stdin:find("Structural angle needs the scope stated explicitly.", 1, true) ~= nil)
  end,

  test_close_disagreement_polluted_meta_output_stays_unresolved = function()
    mock_angle("approve", "Minimal angle approves the small scope.")
    mock_angle("abstain", "Structural angle needs the scope stated explicitly.")
    mock_angle("approve", "Delete angle accepts because no extra package surface is added.")
    t.mock_command("codex exec", {
      stdout = meta_decision_label .. " maybe\n"
        .. meta_reason_label .. " polluted\n"
        .. meta_decision_label .. " approve\n"
        .. meta_reason_label .. " Later valid lines must not hide marker pollution.\n",
      stderr = "",
      exit_code = 0,
    })

    local result = run_decide(proposal(), opts("meta-polluted"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_unresolved")
    t.is_nil(result.raises[1].payload.meta_result)
    t.eq(#codex_calls(), 4)
  end,

  test_close_disagreement_meta_unresolved_stays_unresolved = function()
    mock_angle("approve", "Minimal angle approves.")
    mock_angle("abstain", "Structural angle says the contract is underspecified.")
    mock_angle("approve", "Delete angle approves.")
    mock_meta("unresolved", "The abstention depends on a contract detail that is not present.")

    local result = run_decide(proposal(), opts("meta-unresolved"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_unresolved")
    t.is_nil(result.raises[1].payload.meta_result)
    t.eq(#codex_calls(), 4)
  end,

  test_all_abstain_raises_consensus_unresolved_without_meta = function()
    mock_angle("abstain", "Minimal angle abstains.")
    mock_angle("abstain", "Structural angle abstains.")
    mock_angle("abstain", "Delete angle abstains.")

    local result = run_decide(proposal(), opts("all-abstain"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_unresolved")
    t.eq(#codex_calls(), 3)
  end,

  test_failed_codex_call_raises_consensus_unresolved = function()
    mock_angle("approve", "Minimal angle approves.")
    t.mock_command("codex exec", {
      stderr = "forced failure",
      exit_code = 7,
    })
    mock_angle("approve", "Delete angle approves.")

    local result = run_decide(proposal(), opts("codex-fails"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_unresolved")
    t.eq(#codex_calls(), 3)
  end,

  test_unparseable_output_raises_consensus_unresolved = function()
    t.mock_command("codex exec", { stdout = "no verdict here", exit_code = 0 })
    t.mock_command("codex exec", { stdout = "still nothing useful", exit_code = 0 })
    t.mock_command("codex exec", { stdout = "garbage output", exit_code = 0 })

    local result = run_decide(proposal(), opts("unparseable"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_unresolved")
    t.eq(#codex_calls(), 3)
  end,

  test_missing_source_ref_fails_closed_without_codex = function()
    local result = run_decide(proposal({ source_ref = false }), opts("no-source-ref"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    -- fail-closed BEFORE spawning any codex angle
    t.eq(#codex_calls(), 0)
  end,

  test_angles_override_runs_only_named_angles = function()
    mock_angle("approve", "Minimal angle approves.")
    mock_angle("approve", "Delete angle approves.")

    local result = run_decide(proposal({ angles = { "minimal", "delete" } }), opts("angles-override"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.decision, "approve")
    t.eq(#result.raises[1].payload.angle_results, 2)

    local calls = codex_calls()
    t.eq(#calls, 2)
    t.is_true(calls[1].stdin:find("Angle: minimal", 1, true) ~= nil)
    t.is_true(calls[2].stdin:find("Angle: delete", 1, true) ~= nil)
  end,

  test_same_dedup_key_skips_second_run = function()
    local run_opts = opts("cache-hit")
    mock_angle("approve", "Minimal angle approves.")
    mock_angle("approve", "Structural angle approves.")
    mock_angle("approve", "Delete angle approves.")

    local first = run_decide(proposal(), run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 1)

    -- identical dedup_key -> idempotent skip, no new codex calls
    local second = run_decide(proposal(), run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 0)
    t.eq(#codex_calls(), 3)
  end,

  test_new_version_reruns_consensus = function()
    local run_opts = opts("new-version")
    mock_angle("approve", "Minimal angle approves.")
    mock_angle("approve", "Structural angle approves.")
    mock_angle("approve", "Delete angle approves.")

    local first = run_decide(proposal(), run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 1)
    t.eq(first.raises[1].payload.dedup_key, "consensus:proposal-42-v1")

    -- a new version (different dedup_key) re-derives consensus instead of being skipped
    mock_angle("approve", "Minimal angle approves again.")
    mock_angle("approve", "Structural angle approves again.")
    mock_angle("approve", "Delete angle approves again.")

    local second = run_decide(proposal({ dedup_key = "proposal-42-v2" }), run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 1)
    t.eq(second.raises[1].payload.dedup_key, "consensus:proposal-42-v2")
    t.eq(#codex_calls(), 6)
  end,
}
