local provenance = require("departments.decide.provenance")

local M = {}

local function clean_source_ref(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  return {
    kind = source_ref.kind,
    ref = source_ref.ref,
  }
end

local function proposal_identity(proposal)
  return {
    proposal_id = proposal and proposal.proposal_id or nil,
    dedup_key = proposal and proposal.dedup_key or nil,
    source_ref = clean_source_ref(proposal and proposal.source_ref),
    content_fetch = proposal and proposal.content_fetch or nil,
  }
end

local function absent()
  return {
    oracle_consulted = false,
    oracle_addressed = 0,
  }
end

function M.consult(ctx, consult_port)
  if type(consult_port) ~= "function" then
    return absent()
  end
  local request = {
    schema = "consensus.oracle_advisory_request.v1",
    phase = "R",
    proposal = proposal_identity(ctx and ctx.proposal),
    p1_results = provenance.verdict_vector(ctx and ctx.p1_results),
  }
  local ok, result = pcall(consult_port, request)
  if not ok or type(result) ~= "table" then
    return absent()
  end
  return absent()
end

function M.absent()
  return absent()
end

return M
