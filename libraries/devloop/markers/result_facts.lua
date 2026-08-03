local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local parsers_misc = require("devloop.parsers.misc")
local shared = require("devloop.markers.shared")

local C = {}
local marker_attr = shared.marker_attr

local function result_fact(marker, proposal_id)
  local decision = marker_attr(marker, "decision")
  local marker_identity = marker_attr(marker, "lineage") or marker_attr(marker, "dedup")
  if marker_attr(marker, "proposal") ~= tostring(proposal_id)
    or marker_identity == nil
    or marker_identity == ""
    or (decision ~= "approve" and decision ~= "reject") then
    return nil
  end
  local raw_framing = marker_attr(marker, "framing")
  local framing = shared.decode_exact_marker_attr(raw_framing)
  if raw_framing ~= nil
    and (framing == nil or not shared.strings.is_bounded_string(framing, devloop_base._max_framing_len)) then
    return nil
  end
  return {
    decision = decision,
    dedup_key = marker_attr(marker, "dedup"),
    framing = framing,
    logical_identity = marker_identity,
  }
end

function C.first_review_result_fact(comments, review_proposal_id, issue_proposal_id)
  if type(comments) ~= "table" then return nil end
  local marker_pattern = "<!%-%- fkst:github%-devloop:review%-result:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local marker_proposal = marker_attr(marker, "proposal")
      local marker_dedup = devloop_base.canonical_pr_review_consensus_dedup_for_proposal(
        marker_attr(marker, "dedup"), marker_proposal)
      local decision = marker_attr(marker, "decision")
      if marker_proposal == tostring(review_proposal_id)
        and marker_attr(marker, "issue_proposal") == tostring(issue_proposal_id)
        and marker_dedup ~= nil
        and (decision == "approve" or decision == "reject") then
        return { decision = decision, dedup_key = marker_dedup }
      end
    end
  end
  return nil
end

function C.first_result_fact(comments, proposal_id, logical_identity)
  if type(comments) ~= "table" then return nil end
  local marker_pattern = "<!%-%- fkst:github%-devloop:result:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local fact = result_fact(marker, proposal_id)
      if fact ~= nil and fact.logical_identity == tostring(logical_identity) then
        return fact
      end
    end
  end
  return nil
end

function C.current_result_fact(comments, proposal_id, current_version)
  if type(comments) ~= "table" then return nil end
  local version = tostring(current_version or "")
  local latest = nil
  local marker_pattern = "<!%-%- fkst:github%-devloop:result:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local fact = result_fact(marker, proposal_id)
      if fact ~= nil then
        local ready_identity = base_ids.dedup_key({ "ready", fact.logical_identity })
        local matches = version == ready_identity
          or version:sub(1, #ready_identity + 1) == ready_identity .. "/"
        if matches and (latest == nil or #fact.logical_identity > #latest.logical_identity) then
          latest = fact
        end
      end
    end
  end
  return latest
end

return C
