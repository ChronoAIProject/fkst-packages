local contract_time = require("contract.time")
local base_ids = require("devloop.base_ids")
local error_facts = require("contract.error_facts")
local parsers_misc = require("devloop.parsers.misc")
local sha256 = require("contract.sha256")

local C = {}

local marker_pattern = "<!%-%- fkst:premise%-correction:v1.-%-%->"

local function fingerprint(prefix, fields)
  return prefix .. "-" .. error_facts.stable_hash(table.concat(fields, "\0"))
end

function C.normalize_evidence(value)
  local text = tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("[ \t]+\n", "\n")
  return text:gsub("^%s+", ""):gsub("%s+$", "")
end

function C.premise_fingerprint(proposal_id, decision_dedup_key, decline_reason)
  return fingerprint("premise", {
    "proposal=" .. tostring(proposal_id or ""),
    "decision=" .. tostring(decision_dedup_key or ""),
    "reason=" .. C.normalize_evidence(decline_reason),
  })
end

function C.correction_fingerprint(comment_id, evidence)
  local content = table.concat({
    "comment=" .. tostring(comment_id or ""),
    "evidence=" .. C.normalize_evidence(evidence),
  }, "\0")
  return "correction-sha256-" .. sha256.hex(content)
end

function C.decision_dedup_key(base_decision_dedup_key, correction_pair)
  if type(correction_pair) ~= "table"
    or not C.is_premise_fingerprint(correction_pair.premise_fingerprint)
    or not C.is_correction_fingerprint(correction_pair.correction_fingerprint) then
    error("github-devloop: invalid premise correction decision identity")
  end
  return base_ids.dedup_key({
    tostring(base_decision_dedup_key),
    "premise-correction",
    correction_pair.premise_fingerprint,
    correction_pair.correction_fingerprint,
  })
end

local function is_fingerprint(value, prefix)
  return type(value) == "string"
    and #value <= base_ids.max_key_len
    and value:match("^" .. prefix .. "%-fp%-%d+$") ~= nil
end

function C.is_premise_fingerprint(value)
  return is_fingerprint(value, "premise")
end

function C.is_correction_fingerprint(value)
  if type(value) ~= "string" or #value > base_ids.max_key_len then
    return false
  end
  local digest = value:match("^correction%-sha256%-([0-9a-f]+)$")
  return digest ~= nil and #digest == 64
end

function C.correction_comment_fact(comment)
  if type(comment) ~= "table"
    or comment.id == nil
    or tostring(comment.id) == ""
    or #tostring(comment.id) > base_ids.max_key_len
    or parsers_misc._is_trusted_comment(comment) then
    return nil
  end
  local created_at = parsers_misc._comment_created_at(comment)
  local created_epoch = contract_time.iso_timestamp_epoch_seconds(created_at)
  if created_epoch == nil then
    return nil
  end

  local body = parsers_misc._comment_body(comment)
  local selected = nil
  local count = 0
  for marker in body:gmatch(marker_pattern) do
    count = count + 1
    selected = marker
  end
  if count ~= 1 then
    return nil
  end

  local premise = selected:match('premise="([^"]+)"')
  local correction = selected:match('correction="([^"]+)"')
  if not C.is_premise_fingerprint(premise) or not C.is_correction_fingerprint(correction) then
    return nil
  end
  local evidence = C.normalize_evidence(body:gsub(marker_pattern, ""))
  if evidence == "" or correction ~= C.correction_fingerprint(comment.id, evidence) then
    return nil
  end
  return {
    premise_fingerprint = premise,
    correction_fingerprint = correction,
    comment_id = tostring(comment.id),
    comment_created_at = tostring(created_at),
    comment_created_epoch = created_epoch,
    evidence = evidence,
  }
end

function C.matching_correction_fact(comments, decline_fact)
  if type(comments) ~= "table"
    or type(decline_fact) ~= "table"
    or decline_fact.decision ~= "decline"
    or not C.is_premise_fingerprint(decline_fact.premise_fingerprint) then
    return nil
  end
  local decline_epoch = contract_time.iso_timestamp_epoch_seconds(decline_fact.comment_created_at)
  if decline_epoch == nil then
    return nil
  end
  local latest = nil
  for _, comment in ipairs(comments) do
    local fact = C.correction_comment_fact(comment)
    if fact ~= nil
      and fact.premise_fingerprint == decline_fact.premise_fingerprint
      and fact.comment_created_epoch > decline_epoch
      and (latest == nil or fact.comment_created_epoch >= latest.comment_created_epoch) then
      latest = fact
    end
  end
  return latest
end

return C
