local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local forge_validators = require("devloop.forge_validators")
local parsers_misc = require("devloop.parsers.misc")
local source_refs = require("contract.source_ref")
local strings = require("contract.strings")

local E = {}

local POLICY_ID = "adjacent-wall-clock-exhaustion-stationary-head-v1"

local function marker_attr(marker, name)
  return marker:match("%s" .. name .. '="([^"]*)"')
end

local function valid_attempt(value)
  local attempt = tonumber(value)
  if attempt == nil or attempt < 1 or attempt ~= math.floor(attempt) then
    return nil
  end
  return attempt
end

local function valid_identity(proposal_id, version)
  local repo, issue_number = base_ids.parse_proposal_id(proposal_id)
  return repo ~= nil
    and issue_number ~= nil
    and strings.is_path_safe_key(proposal_id, devloop_base._max_key_len)
    and strings.is_bounded_string(version, devloop_base._max_dedup_len)
end

local function worker_outcome(result)
  if type(result) == "table" and result.error_kind == "timeout" then
    return "wall-clock-exhausted"
  end
  return "worker-failed"
end

function E.attempt_result(args)
  local input = args or {}
  local attempt = valid_attempt(input.attempt)
  if not valid_identity(input.proposal_id, input.version) or attempt == nil then
    error("github-devloop: implementation-attempt-result-invalid: identity is invalid")
  end
  if not forge_validators.is_git_sha(input.finish_head_sha) then
    error("github-devloop: implementation-attempt-result-invalid: finish head is invalid")
  end
  if input.start_head_sha ~= nil and not forge_validators.is_git_sha(input.start_head_sha) then
    error("github-devloop: implementation-attempt-result-invalid: start head is invalid")
  end
  local progress = "unmeasured"
  if input.start_head_sha ~= nil then
    progress = input.start_head_sha == input.finish_head_sha and "stationary" or "advanced"
  end
  return {
    proposal_id = input.proposal_id,
    version = input.version,
    attempt = attempt,
    worker_outcome = worker_outcome(input.worker_result),
    progress = progress,
    start_head_sha = input.start_head_sha,
    finish_head_sha = input.finish_head_sha,
  }
end

function E.attempt_result_marker(fact)
  local normalized = E.attempt_result({
    proposal_id = fact and fact.proposal_id,
    version = fact and fact.version,
    attempt = fact and fact.attempt,
    start_head_sha = fact and fact.start_head_sha,
    finish_head_sha = fact and fact.finish_head_sha,
    worker_result = fact and fact.worker_outcome == "wall-clock-exhausted"
      and { error_kind = "timeout" }
      or {},
  })
  local start_field = normalized.start_head_sha ~= nil
    and ' start_head_sha="' .. normalized.start_head_sha .. '"'
    or ""
  return '<!-- fkst:github-devloop:implementation-attempt-result:v1 proposal="'
    .. normalized.proposal_id
    .. '" version="' .. normalized.version
    .. '" attempt="' .. tostring(normalized.attempt)
    .. '" worker_outcome="' .. normalized.worker_outcome
    .. '" progress="' .. normalized.progress .. '"'
    .. start_field
    .. ' finish_head_sha="' .. normalized.finish_head_sha
    .. '" -->'
end

local function attempt_result_from_marker(marker, comment)
  local fact = {
    proposal_id = marker_attr(marker, "proposal"),
    version = marker_attr(marker, "version"),
    attempt = valid_attempt(marker_attr(marker, "attempt")),
    worker_outcome = marker_attr(marker, "worker_outcome"),
    progress = marker_attr(marker, "progress"),
    start_head_sha = marker_attr(marker, "start_head_sha"),
    finish_head_sha = marker_attr(marker, "finish_head_sha"),
    comment_created_at = parsers_misc._comment_created_at(comment),
  }
  if not valid_identity(fact.proposal_id, fact.version)
    or fact.attempt == nil
    or (fact.worker_outcome ~= "wall-clock-exhausted" and fact.worker_outcome ~= "worker-failed")
    or (fact.progress ~= "unmeasured" and fact.progress ~= "advanced" and fact.progress ~= "stationary")
    or not forge_validators.is_git_sha(fact.finish_head_sha)
    or (fact.start_head_sha ~= nil and not forge_validators.is_git_sha(fact.start_head_sha))
    or (fact.progress == "stationary" and fact.start_head_sha ~= fact.finish_head_sha)
    or (fact.progress == "advanced" and (fact.start_head_sha == nil or fact.start_head_sha == fact.finish_head_sha))
    or marker ~= E.attempt_result_marker(fact) then
    return nil
  end
  return fact
end

function E.attempt_result_facts(comments, proposal_id, version)
  local facts = {}
  local pattern = "<!%-%- fkst:github%-devloop:implementation%-attempt%-result:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments or {})) do
    for marker in parsers_misc._comment_body(comment):gmatch(pattern) do
      local fact = attempt_result_from_marker(marker, comment)
      if fact ~= nil and fact.proposal_id == proposal_id and fact.version == tostring(version) then
        facts[fact.attempt] = fact
      end
    end
  end
  return facts
end

function E.escalation_evidence(comments, current)
  if type(current) ~= "table"
    or current.worker_outcome ~= "wall-clock-exhausted"
    or current.progress ~= "stationary"
    or current.start_head_sha ~= current.finish_head_sha then
    return nil
  end
  local previous_attempt = valid_attempt(current.attempt) and current.attempt - 1 or 0
  if previous_attempt < 1 then
    return nil
  end
  local previous = E.attempt_result_facts(comments, current.proposal_id, current.version)[previous_attempt]
  if previous == nil
    or previous.worker_outcome ~= "wall-clock-exhausted"
    or previous.finish_head_sha ~= current.start_head_sha then
    return nil
  end
  return {
    policy_id = POLICY_ID,
    previous_attempt = previous_attempt,
    attempt = current.attempt,
    head_sha = current.finish_head_sha,
  }
end

function E.escalation_marker(proposal_id, version, evidence)
  if not valid_identity(proposal_id, version)
    or type(evidence) ~= "table"
    or evidence.policy_id ~= POLICY_ID
    or valid_attempt(evidence.previous_attempt) == nil
    or valid_attempt(evidence.attempt) == nil
    or evidence.attempt ~= evidence.previous_attempt + 1
    or not forge_validators.is_git_sha(evidence.head_sha) then
    error("github-devloop: implementation-escalation-evidence-invalid: evidence is invalid")
  end
  return '<!-- fkst:github-devloop:implementation-escalation:v1 proposal="' .. proposal_id
    .. '" version="' .. version
    .. '" previous_attempt="' .. tostring(evidence.previous_attempt)
    .. '" attempt="' .. tostring(evidence.attempt)
    .. '" head_sha="' .. evidence.head_sha
    .. '" evidence_policy="' .. POLICY_ID
    .. '" -->'
end

function E.escalation_fact(comments, proposal_id, version)
  local pattern = "<!%-%- fkst:github%-devloop:implementation%-escalation:v1.-%-%->"
  local latest = nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments or {})) do
    for marker in parsers_misc._comment_body(comment):gmatch(pattern) do
      local fact = {
        proposal_id = marker_attr(marker, "proposal"),
        version = marker_attr(marker, "version"),
        previous_attempt = valid_attempt(marker_attr(marker, "previous_attempt")),
        attempt = valid_attempt(marker_attr(marker, "attempt")),
        head_sha = marker_attr(marker, "head_sha"),
        policy_id = marker_attr(marker, "evidence_policy"),
        comment_created_at = parsers_misc._comment_created_at(comment),
      }
      if fact.proposal_id == proposal_id
        and fact.version == tostring(version)
        and fact.policy_id == POLICY_ID
        and fact.previous_attempt ~= nil
        and fact.attempt == fact.previous_attempt + 1
        and forge_validators.is_git_sha(fact.head_sha)
        and marker == E.escalation_marker(fact.proposal_id, fact.version, fact)
        and (latest == nil or fact.attempt > latest.attempt) then
        latest = fact
      end
    end
  end
  return latest
end

function E.build_payload(context, evidence)
  local payload = {
    schema = "github-devloop.implementation-escalation.v1",
    proposal_id = context and context.proposal_id,
    version = context and context.version,
    branch = context and context.branch,
    head_sha = evidence and evidence.head_sha,
    previous_attempt = evidence and evidence.previous_attempt,
    attempt = evidence and evidence.attempt,
    evidence_policy = evidence and evidence.policy_id,
    source_ref = base_ids.normalize_source_ref(context and context.source_ref),
  }
  payload.dedup_key = base_ids.dedup_key({
    "implementation-escalation",
    tostring(payload.proposal_id),
    tostring(payload.version),
    tostring(payload.attempt),
    tostring(payload.head_sha),
  })
  return payload
end

function E.is_supported_payload(payload)
  return type(payload) == "table"
    and payload.schema == "github-devloop.implementation-escalation.v1"
    and valid_identity(payload.proposal_id, payload.version)
    and forge_validators.is_git_ref_safe(payload.branch)
    and forge_validators.is_git_sha(payload.head_sha)
    and valid_attempt(payload.previous_attempt) ~= nil
    and valid_attempt(payload.attempt) == payload.previous_attempt + 1
    and payload.evidence_policy == POLICY_ID
    and strings.is_path_safe_key(payload.dedup_key, devloop_base._max_dedup_len)
    and payload.dedup_key == E.build_payload(payload, {
      policy_id = payload.evidence_policy,
      previous_attempt = payload.previous_attempt,
      attempt = payload.attempt,
      head_sha = payload.head_sha,
    }).dedup_key
    and source_refs.has_bounded_source_ref(payload.source_ref, devloop_base._max_key_len)
end

return E
