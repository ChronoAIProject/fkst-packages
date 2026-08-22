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

  test_request_uses_effect_version_as_the_consensus_identity = function()
    local original_reach = consensus.reach
    local captured = nil
    consensus.reach = function(value)
      captured = value
      return {
        status = "converge",
        schema = "consensus.consensus_converge.v1",
        dedup_key = "consensus:" .. value.dedup_key,
        effect_version = value.effect_version,
        source_ref = value.source_ref,
      }
    end

    local request = proposal()
    local logical_version = request.dedup_key
    request.effect_version = logical_version
    request.dedup_key = logical_version .. "/delivery-redrive/restart-liveness-v2/1"
    local ok, result = pcall(function()
      return consensus_call.reach(request)
    end)
    consensus.reach = original_reach
    if not ok then
      error(result)
    end

    t.eq(captured.dedup_key, logical_version)
    t.eq(captured.effect_version, logical_version)
    t.eq(result.dedup_key, "consensus:" .. logical_version)
    t.eq(result.effect_version, logical_version)
    t.eq(result.proposal_id, request.proposal_id)
  end,

  test_pr_request_supplies_canonical_progress_target_to_consensus_runs = function()
    local original_reach = consensus.reach
    local captured_options = nil
    consensus.reach = function(value, options)
      captured_options = options
      return {
        status = "reached",
        schema = "consensus.consensus_reached.v1",
        decision = "approve",
        body = "Ready.",
        dedup_key = "consensus:" .. value.dedup_key,
        source_ref = value.source_ref,
      }
    end

    local request = proposal()
    request.proposal_id = "github-devloop/pr-review/owner/repo/7/review-v1/abcdef1"
    request.source_ref = { kind = "external", ref = "owner/repo#pr/7" }
    local ok, result = pcall(function()
      return consensus_call.reach(request)
    end)
    consensus.reach = original_reach
    if not ok then
      error(result)
    end

    t.eq(captured_options.invocation_id, request.proposal_id)
    t.eq(captured_options.target_proposal_id, "github-devloop/pr/owner/repo/7")
    t.eq(result.proposal_id, request.proposal_id)
  end,
}
