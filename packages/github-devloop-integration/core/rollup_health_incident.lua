local base_ids = require("devloop.base_ids")
local contract_time = require("contract.time")
local devloop_entity = require("devloop.entity")
local forge_validators = require("devloop.forge_validators")
local parsers_misc = require("devloop.parsers.misc")

local C = {}

local marker_name = "fkst:github-devloop-integration:rollup-health-state:v1"
local replace_marker = "<!-- " .. marker_name
local marker_pattern = "<!%-%-%s*" .. marker_name:gsub("%-", "%%-") .. ".-%-%->"
local initial_epoch = "initial"

local valid_status = {
  green = true,
  pending = true,
  red = true,
}

local function format_timestamp(value)
  if type(value) == "number" then
    return os.date("!%Y-%m-%dT%H:%M:%SZ", value)
  end
  local seconds = contract_time.iso_timestamp_epoch_seconds(value)
  if seconds == nil then
    return nil
  end
  return os.date("!%Y-%m-%dT%H:%M:%SZ", seconds)
end

local function check_timestamp(entry)
  if type(entry) ~= "table" then
    return nil
  end
  return entry.completedAt or entry.completed_at or entry.updatedAt or entry.updated_at
    or entry.createdAt or entry.created_at
end

local function green_recovery_at(pr, fallback_seconds)
  local latest_at = nil
  local latest_seconds = nil
  for _, entry in ipairs(type(pr) == "table" and pr.status_check_rollup or {}) do
    local timestamp = check_timestamp(entry)
    local seconds = contract_time.iso_timestamp_epoch_seconds(timestamp)
    if seconds ~= nil and (latest_seconds == nil or seconds > latest_seconds) then
      latest_at = timestamp
      latest_seconds = seconds
    end
  end
  return format_timestamp(latest_at) or format_timestamp(fallback_seconds)
end

local function parse_marker(marker)
  local text = tostring(marker or "")
  local state = {
    head_sha = text:match('head_sha="([^"]+)"'),
    status = text:match('status="([^"]+)"'),
    last_green_at = text:match('last_green_at="([^"]*)"') or "",
    incident_epoch = text:match('incident_epoch="([^"]*)"') or "",
    observed_at = text:match('observed_at="([^"]+)"'),
  }
  if not forge_validators.is_git_sha(state.head_sha) or not valid_status[state.status] then
    return nil
  end
  if state.last_green_at ~= "" and contract_time.iso_timestamp_epoch_seconds(state.last_green_at) == nil then
    return nil
  end
  if state.incident_epoch ~= ""
    and state.incident_epoch ~= initial_epoch
    and contract_time.iso_timestamp_epoch_seconds(state.incident_epoch) == nil then
    return nil
  end
  state.observed_at_seconds = contract_time.iso_timestamp_epoch_seconds(state.observed_at)
  if state.observed_at_seconds == nil then
    return nil
  end
  if state.status == "red" and state.incident_epoch == "" then
    return nil
  end
  return state
end

local function latest_state(comments, head_sha)
  local latest = nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments or {})) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local state = parse_marker(marker)
      if state ~= nil
        and tostring(state.head_sha) == tostring(head_sha)
        and (latest == nil or state.observed_at_seconds >= latest.observed_at_seconds) then
        latest = state
      end
    end
  end
  return latest
end

function C.derive(pr, green, reason, now_seconds)
  local head_sha = type(pr) == "table" and pr.head_sha or nil
  if not forge_validators.is_git_sha(head_sha) then
    error("github-devloop-integration: rollup-health-state-head-invalid: invalid rollup health state head sha")
  end
  local status = green and "green" or (reason == "rollup-red" and "red" or "pending")
  local previous = latest_state(pr.comments, head_sha)
  local last_green_at = previous and previous.last_green_at or ""
  local incident_epoch = previous and previous.incident_epoch or ""

  if status == "green" then
    if previous == nil or previous.status ~= "green" or last_green_at == "" then
      last_green_at = green_recovery_at(pr, now_seconds)
    end
    incident_epoch = ""
  elseif status == "red" and incident_epoch == "" then
    incident_epoch = last_green_at ~= "" and last_green_at or initial_epoch
  end

  return {
    head_sha = head_sha,
    status = status,
    last_green_at = last_green_at,
    incident_epoch = incident_epoch,
    observed_at = format_timestamp(now_seconds),
  }
end

local function marker(state)
  return "<!-- " .. marker_name
    .. ' head_sha="' .. tostring(state.head_sha)
    .. '" status="' .. tostring(state.status)
    .. '" last_green_at="' .. tostring(state.last_green_at)
    .. '" incident_epoch="' .. tostring(state.incident_epoch)
    .. '" observed_at="' .. tostring(state.observed_at)
    .. '" -->'
end

function C.comment_request(repo, pr_number, state)
  local body = "github-devloop-integration rollup health state"
    .. "\n\nstatus=" .. tostring(state.status)
    .. "\nhead_sha=" .. tostring(state.head_sha)
    .. "\nlast_green_at=" .. tostring(state.last_green_at)
    .. "\nincident_epoch=" .. tostring(state.incident_epoch)
    .. "\nobserved_at=" .. tostring(state.observed_at)
    .. "\n\n" .. marker(state)
  return devloop_entity.build_entity_comment_request({
    kind = "pr",
    repo = repo,
    number = pr_number,
  }, body, base_ids.dedup_key({
    "rollup-health-state",
    tostring(repo or ""),
    tostring(pr_number or ""),
  }), devloop_entity.pr_source_ref(repo, pr_number), {
    replace_marker = replace_marker,
  })
end

return C
