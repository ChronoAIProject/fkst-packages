local consensus_call = require("devloop.consensus_call")
local devloop_logging = require("devloop.logging")
local review_result = require("departments.review_result.main")
local testing = require("testkit_internal.testing")

local t = fkst.test

local function review_proposal()
  local proposal_id = "github-devloop/pr-review/owner-repo/7/version/def456"
  return {
    schema = "consensus.proposal.v1",
    proposal_id = proposal_id,
    dedup_key = proposal_id .. "/review",
    source_ref = { kind = "external", ref = "owner/repo#pr/7" },
  }
end

return {
  test_review_request_raise_records_lineage_after_actual_emission = function()
    local proposal = review_proposal()
    local sequence = {}
    local original_raise = raise
    local original_info = log.info
    raise = function(queue, payload)
      t.eq(queue, "devloop_review_request")
      t.eq(payload, proposal)
      table.insert(sequence, "raise")
    end
    log.info = function(message)
      table.insert(sequence, tostring(message))
    end

    local ok, err = pcall(function()
      devloop_logging.log_raise(
        "review_pr",
        "github-devloop/issue/owner/repo/42",
        "devloop_review_request",
        proposal
      )
    end)
    raise = original_raise
    log.info = original_info
    if not ok then
      error(err, 0)
    end

    t.eq(#sequence, 2)
    t.eq(sequence[1], "raise")
    t.is_true(sequence[2]:find("tag=RAISE", 1, true) ~= nil)
    t.is_true(sequence[2]:find("queue=devloop_review_request", 1, true) ~= nil)
    t.is_true(sequence[2]:find("payload_schema=consensus.proposal.v1", 1, true) ~= nil)
    t.is_true(sequence[2]:find("payload_proposal_id=" .. proposal.proposal_id, 1, true) ~= nil)
    t.is_true(sequence[2]:find("dedup_key=" .. proposal.dedup_key, 1, true) ~= nil)
    t.is_true(sequence[2]:find("source_ref=external:owner/repo#pr/7", 1, true) ~= nil)
  end,

  test_review_result_records_entry_before_consensus_and_nil_outcome = function()
    local proposal = review_proposal()
    local sequence = {}
    local original_reach = consensus_call.reach
    local original_info = log.info
    consensus_call.reach = function(actual)
      t.eq(actual, proposal)
      table.insert(sequence, "consensus")
      return nil
    end
    log.info = function(message)
      local text = tostring(message)
      if text:find("github-devloop dept=review_result", 1, true) ~= nil then
        table.insert(sequence, text)
      end
    end

    local ok, outcome = pcall(function()
      return testing.run_fake_outcome(review_result, {
        queue = "github-devloop-pr.devloop_review_request",
        payload = proposal,
        ts = "2026-08-08T03:05:47Z",
      })
    end)
    consensus_call.reach = original_reach
    log.info = original_info
    if not ok then
      error(outcome, 0)
    end

    t.eq(outcome.exit_code, 0)
    t.eq(#outcome.raises, 0)
    t.eq(#sequence, 3)
    t.is_true(sequence[1]:find("tag=ENTRY", 1, true) ~= nil)
    t.is_true(sequence[1]:find("proposal_id=" .. proposal.proposal_id, 1, true) ~= nil)
    t.is_true(sequence[1]:find("dedup_key=" .. proposal.dedup_key, 1, true) ~= nil)
    t.eq(sequence[2], "consensus")
    t.is_true(sequence[3]:find("tag=OUTCOME", 1, true) ~= nil)
    t.is_true(sequence[3]:find("outcome=no-result", 1, true) ~= nil)
    t.is_true(sequence[3]:find("reason=consensus-call-returned-nil", 1, true) ~= nil)
  end,
}
