local consensus = require("consensus")
local testing = require("testkit_internal.testing")
local t = fkst.test

local function proposal(extra)
  local value = {
    schema = "consensus.proposal.v1",
    proposal_id = "caller-owned/proposal/42",
    title = "Adopt synchronous consensus",
    body = "Return the judgment directly to the caller.",
    content_fetch = "fetch-source --ref demo/consensus/42 --full",
    angles = { "teleology" },
    dedup_key = "caller-owned/proposal/42/v1",
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

local function mock_reached()
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/consensus-library/runtime",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("consensus-angle-teleology", {
    stdout = testing.codex_agent_message_jsonl(
      "⟦FKST:VERDICT⟧ approve\n⟦FKST:REPLY⟧ The synchronous contract is sound.\n"
    ),
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_reach_returns_reached_value_without_requester_correlation = function()
    mock_reached()

    local result = consensus.reach(proposal())

    t.eq(result.status, "reached")
    t.eq(result.schema, "consensus.consensus_reached.v1")
    t.eq(result.decision, "approve")
    t.eq(result.body, "teleology:\nThe synchronous contract is sound.")
    t.eq(result.dedup_key, "consensus:caller-owned/proposal/42/v1")
    t.eq(result.source_ref.kind, "proposal")
    t.eq(result.source_ref.ref, "demo/consensus/42")
    t.is_nil(result.proposal_id)
  end,
}
