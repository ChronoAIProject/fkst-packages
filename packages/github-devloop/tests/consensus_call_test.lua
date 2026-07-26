local consensus = require("consensus")
local consensus_call = require("devloop.consensus_call")
local t = fkst.test

local function proposal()
  return {
    schema = "consensus.proposal.v1",
    proposal_id = "github-devloop/issue/owner/repo/42",
    title = "Judge issue 42",
    body = "Decide whether issue 42 is ready.",
    content_fetch = "fetch-source --ref owner/repo#issue/42 --full",
    dedup_key = "github-devloop/issue/owner/repo/42/2026-07-26T03-00-00Z",
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
  }
end

return {
  test_request_keeps_caller_lineage_outside_the_library_call = function()
    local original_reach = consensus.reach
    local captured = nil
    consensus.reach = function(value)
      captured = value
      return {
        status = "reached",
        schema = "consensus.consensus_reached.v1",
        decision = "approve",
        body = "Ready.",
        dedup_key = "consensus:" .. value.dedup_key,
        source_ref = value.source_ref,
      }
    end

    local ok, result = pcall(function()
      return consensus_call.reach(proposal())
    end)
    consensus.reach = original_reach
    if not ok then
      error(result)
    end

    t.is_nil(captured.proposal_id)
    t.eq(result.status, "reached")
    t.eq(result.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(result.decision, "approve")
  end,
}
