local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local strings = require("contract.strings")
local source_refs = require("contract.source_ref")
local payloads_shared = require("devloop.payloads.shared")

local C = {}
function C.is_supported_review_meta(payload)
  if type(payload) ~= "table"
    or payload.schema ~= "github-devloop.review-meta.v1"
    or not devloop_base.is_safe_pr_review_result_ref(payload.review_proposal_id, payload.review_dedup_key) then
    return false
  end
  local has_valid_identity = payload.mode == "fix-reflection"
    and entity_lib.parse_entity_proposal_id(payload.proposal_id) ~= nil
    and strings.is_path_safe_key(payload.dedup_key, devloop_base._max_dedup_len)
  if payload.mode ~= "fix-reflection" then
    has_valid_identity = entity_lib.is_safe_entity_proposal_ref(payload.proposal_id, payload.dedup_key)
  end
  local supported = has_valid_identity
    and strings.is_bounded_string(payload.version, devloop_base._max_dedup_len)
    and require("devloop.pr_safety").is_safe_pr_number(payload.pr_number)
    and tonumber(payload.n) ~= nil
    and (payload.mode == nil or payload.mode == "fix-reflection")
    and (payload.fix_round == nil or tonumber(payload.fix_round) ~= nil)
    and (payload.blocking_gap == nil or strings.is_bounded_string(payload.blocking_gap, devloop_base._max_blocking_gap_len))
    and source_refs.has_bounded_source_ref(payload.source_ref, devloop_base._max_key_len)
  if not supported or payload.redrive_delivery == nil then
    return supported
  end

  local builders = require("devloop.payloads.builders")
  local fact = {
    proposal_id = payload.review_proposal_id,
    dedup_key = payload.review_dedup_key,
    review_dedup_key = payload.review_dedup_key,
    source_ref = payload.source_ref,
  }
  local logical
  if payload.mode == "fix-reflection" then
    logical = builders.build_devloop_fix_reflection_payload(
      fact, payload.proposal_id, payload.version, payload.pr_number,
      payload.fix_round, payload.source_ref)
  else
    logical = builders.build_devloop_review_meta_payload(
      fact, payload.proposal_id, payload.version, payload.pr_number,
      payload.n, payload.source_ref)
  end
  local ok, expected = pcall(
    payloads_shared.issue_redrive_delivery_dedup_key,
    payload.proposal_id,
    logical.dedup_key,
    payload.redrive_delivery
  )
  return ok and tostring(payload.dedup_key) == expected
end

return C
