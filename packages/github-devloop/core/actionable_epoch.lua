local S = {}
local decimal_checksum = require("std.strings").decimal_checksum

function S.install(M)
local contract_version = "actionable-epoch:v1"

local function attr(marker, name)
  return tostring(marker or ""):match(name .. '="([^"]*)"')
end

local function epoch_ms(created_at)
  local seconds = M.iso_timestamp_epoch_seconds(created_at)
  return seconds and seconds * 1000 or nil
end

local function age_minutes(epoch, now_seconds)
  local seconds = tonumber(epoch) and math.floor(tonumber(epoch) / 1000) or nil
  local current = tonumber(now_seconds)
  if seconds ~= nil and current ~= nil and current >= seconds then
    return math.floor((current - seconds) / 60)
  end
  return nil
end

local function signal_for(row)
  return type(row and row.liveness_contract) == "table" and row.liveness_contract.signal or nil
end

local function comments_for(signal, facts)
  if signal and signal.surface == "pr-comment-stream" then
    return facts and facts.current_pr and facts.current_pr.comments or nil
  end
  return facts and facts.current and facts.current.comments or nil
end

local function newest(comments, family, matches)
  local marker_pattern = "<!%-%- fkst:github%-devloop:" .. tostring(family):gsub("%-", "%%-") .. ":v1.-%-%->"
  local found = nil
  for _, comment in ipairs(M._trusted_marker_comments(comments or {})) do
    local created_at = M._comment_created_at(comment)
    local seconds = M.iso_timestamp_epoch_seconds(created_at)
    for marker in M._comment_body(comment):gmatch(marker_pattern) do
      if seconds ~= nil and matches(marker) and (found == nil or seconds > found.seconds) then
        found = { family = family, opened_at = created_at, epoch_ms = seconds * 1000, seconds = seconds }
      end
    end
  end
  return found
end

local function has_dependency_marker(comments, proposal_id, version)
  for _, family in ipairs({ "dependency-wait", "dependency-cycle", "dependency-unresolvable" }) do
    if newest(comments, family, function(marker)
      return attr(marker, "proposal") == tostring(proposal_id)
        and attr(marker, "version") == tostring(version or "")
    end) ~= nil then
      return true
    end
  end
  return false
end

local function live_fact(row, state, facts)
  local signal = signal_for(row) or {}
  local resolver = signal.resolver or signal.family
  local comments = comments_for(signal, facts)
  local proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id)
  local version = M.liveness_heartbeat_version(state and state.version, signal)
  if resolver == "dependency-hold" then
    local release = M.dependency_release_fact(comments, proposal_id, version)
    if release ~= nil then
      return nil, release, true
    end
    local hold = M.dependency_hold_fact(comments, proposal_id)
    if hold ~= nil and tostring(hold.version or "") == tostring(version or "") then
      return { family = hold.marker_kind or "dependency-wait", opened_at = hold.comment_created_at, epoch_ms = epoch_ms(hold.comment_created_at) }, nil, true
    end
    return nil, nil, has_dependency_marker(comments, proposal_id, version)
  end
  if resolver == "implement-attempt" then
    local attempt = M.latest_implement_attempt_fact(comments, proposal_id, version)
    local started = attempt and tonumber(attempt.started_at) or nil
    if started ~= nil then
      return { family = "implement-attempt", opened_at = tostring(attempt.started_at), epoch_ms = started * 1000 }, nil
    end
    return newest(comments, "implement-attempt", function(marker)
      return attr(marker, "proposal") == tostring(proposal_id) and attr(marker, "dedup") == tostring(version or "")
    end), nil
  end
  if resolver == "converge-round" then
    local sr_digest = M.source_ref_digest(facts and facts.source_ref)
    local base_version = M.version_loop_round(version) > 0 and M.converge_base_version(version) or version
    return newest(comments, "converge-round", function(marker)
      return attr(marker, "proposal") == tostring(proposal_id) and attr(marker, "version") == tostring(base_version) and attr(marker, "source_ref") == tostring(sr_digest)
    end), nil
  end
  if resolver == "review-converge-round" then
    local head_sha = facts and facts.head_sha
    local review_proposal_id = facts and facts.review_proposal_id
    local source_repo, source_pr = M.parse_pr_source_ref(facts and facts.source_ref)
    if source_repo ~= nil and source_pr ~= nil and M._is_git_sha(head_sha) then
      review_proposal_id = M.pr_review_proposal_id(source_repo, source_pr, M.strip_liveness_timeout_suffixes(state and state.version), head_sha)
    end
    local sr_digest = M.source_ref_digest(facts and facts.source_ref)
    return newest(comments, "review-converge-round", function(marker)
      return attr(marker, "proposal") == tostring(review_proposal_id) and attr(marker, "issue_proposal") == tostring(proposal_id) and attr(marker, "version") == tostring(version) and attr(marker, "head_sha") == tostring(head_sha) and attr(marker, "source_ref") == tostring(sr_digest)
    end), nil
  end
  if resolver == "merge-gate-wait" then
    local _, source_pr = M.parse_pr_source_ref(facts and facts.source_ref)
    local pr_number = source_pr or (facts and facts.current_pr and facts.current_pr.number) or (facts and facts.link and facts.link.pr_number)
    local head_sha = (facts and facts.current_pr and facts.current_pr.head_sha) or (facts and facts.head_sha)
    local wait_version = M.merge_gate_wait_version_lineage(state and state.version)
    return newest(comments, "merge-gate-wait", function(marker)
      return attr(marker, "proposal") == tostring(proposal_id) and attr(marker, "version") == tostring(wait_version) and attr(marker, "pr") == tostring(pr_number) and attr(marker, "head_sha") == tostring(head_sha)
    end), nil
  end
  return nil, nil
end

local function key(row, state, eval)
  return "aeg-" .. decimal_checksum(table.concat({ contract_version, tostring(eval.proposal_id or ""), tostring(row and row.from_state or state and state.state or ""), tostring(eval.liveness_class_id or ""), tostring(eval.epoch_source or ""), tostring(eval.generation_opened_by or ""), tostring(eval.epoch_ms or "") }, "|"))
end

local function state_entry(row, state, facts, now_seconds, class_id)
  local opened = epoch_ms(state and state.marker_created_at)
  if opened == nil then
    return { status = "contract_invalid", reason = "missing-state-entry-time" }
  end
  local eval = { status = "actionable", epoch_ms = opened, epoch_source = "state-entry", generation_opened_by = tostring(state and state.marker_created_at or ""), proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id), liveness_class_id = class_id, age_minutes = age_minutes(opened, now_seconds) }
  eval.generation_key = key(row, state, eval)
  return eval
end

function M.actionable_epoch_resolve(row, state, facts, now_seconds)
  local class_id = tostring(row and (row.liveness_class_id or row.from_state) or state and state.state or "")
  if row == nil or row.terminal == true then
    return { status = "contract_invalid", reason = "missing-row" }
  end
  local source = row.actionable_epoch and row.actionable_epoch.source or nil
  if source == "state_entry:v1" then
    return state_entry(row, state, facts, now_seconds, class_id)
  end
  if source ~= nil and source ~= "live_defer_epoch:v1" then
    return { status = "contract_invalid", reason = "unsupported-actionable-epoch-source", epoch_source = tostring(source), liveness_class_id = class_id }
  end
  if type(row.liveness_contract) == "table" and row.liveness_contract.mode == "live-defer" then
    local signal = signal_for(row) or {}
    local live, clear, observed = live_fact(row, state, facts)
    local max_age = tonumber(signal.max_age_minutes)
    if live ~= nil and live.epoch_ms ~= nil and max_age ~= nil then
      local signal_age = age_minutes(live.epoch_ms, now_seconds) or 0
      if signal_age < max_age then
        return { status = "deferred", epoch_ms = live.epoch_ms, epoch_source = source, generation_opened_by = "live-marker:" .. tostring(live.family or signal.family or "live-defer") .. "@" .. tostring(live.opened_at or ""), liveness_class_id = class_id, age_minutes = signal_age }
      end
      local opened = live.epoch_ms + max_age * 60 * 1000
      local eval = { status = "actionable", epoch_ms = opened, epoch_source = source, generation_opened_by = "stale-live-marker:" .. tostring(live.family or signal.family or "live-defer") .. "@" .. tostring(live.opened_at or ""), proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id), liveness_class_id = class_id, age_minutes = age_minutes(opened, now_seconds) or 0, signal_age_minutes = signal_age }
      eval.generation_key = key(row, state, eval)
      return eval
    end
    if clear ~= nil then
      local opened = epoch_ms(clear.comment_created_at)
      if opened == nil then
        return { status = "contract_invalid", reason = "invalid-clear-fact-time" }
      end
      local eval = { status = "actionable", epoch_ms = opened, epoch_source = source, generation_opened_by = "clear-fact:" .. tostring(row.defer and row.defer.clear_fact or signal.resolver or signal.family or "live-defer") .. "@" .. tostring(clear.comment_created_at or ""), proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id), liveness_class_id = class_id, age_minutes = age_minutes(opened, now_seconds) or 0 }
      eval.generation_key = key(row, state, eval)
      return eval
    end
    if type(row.defer) == "table" and observed == true then
      return { status = "contract_invalid", reason = "missing-live-defer-marker-and-clear-fact", epoch_source = source, liveness_class_id = class_id }
    end
  end
  return state_entry(row, state, facts, now_seconds, class_id)
end

M.actionable_epoch = { resolve = M.actionable_epoch_resolve }
M.actionable_epoch_age_minutes = age_minutes

end

return S
