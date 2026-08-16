local consensus = require("consensus")
local core = require("core")
local mapping = require("departments.reply.mapping")
local saga = require("workflow.saga")

local spec = {
  consumes = { "judge_issue" },
  produces = { "reply" },
  stall_window = "30s",
}

local function parse_judgment(payload)
  if type(payload) ~= "table" or payload.schema ~= "autochrono.judge_issue.v1" then
    return nil
  end

  local repo = tostring(payload.repo or "")
  local issue_number = tostring(payload.issue_number or "")
  if not core.issue_ref_round_trips(repo, issue_number) then
    error("autochrono: judgment-invalid: malformed issue reference")
  end
  local expected_source_ref = tostring(repo) .. "#issue/" .. tostring(issue_number)
  local proposal = payload.proposal
  if not core.validate_proposal(proposal)
    or payload.dedup_key ~= proposal.dedup_key
    or type(payload.source_ref) ~= "table"
    or payload.source_ref.kind ~= "external"
    or payload.source_ref.ref ~= expected_source_ref
    or proposal.source_ref.kind ~= "external"
    or proposal.source_ref.ref ~= expected_source_ref then
    error("autochrono: judgment-invalid: local judgment intent violates the caller contract")
  end
  return proposal, repo, issue_number, expected_source_ref
end

local function reply_done(event)
  local payload = event.payload
  local _, repo, issue_number = parse_judgment(payload)
  if repo == nil then
    return true
  end

  local cache_key = core.replied_cache_key(repo, issue_number)
  local already_replied = false
  with_lock(cache_key, function()
    already_replied = cache_get(cache_key) ~= nil
  end)
  return already_replied
end

local function act_reply(event)
  local payload = event.payload
  local proposal, repo, issue_number, expected_source_ref = parse_judgment(payload)
  if proposal == nil then
    return
  end
  local reached = consensus.reach(proposal, {
    invocation_id = core.proposal_id(repo, issue_number),
  })
  if reached == nil or reached.status == "converge" then
    return
  end
  if reached.status ~= "reached"
    or reached.schema ~= "consensus.consensus_reached.v1"
    or (reached.decision ~= "approve" and reached.decision ~= "reject")
    or not core.validate_reached(reached)
    or reached.source_ref.kind ~= "external"
    or reached.source_ref.ref ~= expected_source_ref then
    error("autochrono: consensus-result-invalid: consensus result violates the caller contract")
  end
  if reached.decision == "reject" then
    return
  end

  local cache_key = core.replied_cache_key(repo, issue_number)
  with_lock(cache_key, function()
    if cache_get(cache_key) then
      return
    end

    raise("reply", mapping.build_reply(reached, repo, issue_number))
    cache_set(cache_key, core.reply_dedup_key(repo, issue_number))
  end)
end

return saga.department(spec, {
  done = reply_done,
  act = act_reply,
  wrap = core.wrap_pipeline_failure,
  name = "reply",
})
