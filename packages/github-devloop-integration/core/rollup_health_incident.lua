local base_ids = require("devloop.base_ids")
local contract_time = require("contract.time")
local devloop_entity = require("devloop.entity")
local forge_validators = require("devloop.forge_validators")
local parsers_misc = require("devloop.parsers.misc")

local C = {}

local marker_name = "fkst:github-devloop-integration:rollup-health-observation:v1"
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

local function source_event_at(pr, fallback_seconds)
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
  local observation = {
    head_sha = text:match('head_sha="([^"]+)"'),
    status = text:match('status="([^"]+)"'),
    source_event_at = text:match('source_event_at="([^"]+)"'),
  }
  if not forge_validators.is_git_sha(observation.head_sha) or not valid_status[observation.status] then
    return nil
  end
  observation.source_event_at_seconds = contract_time.iso_timestamp_epoch_seconds(observation.source_event_at)
  if observation.source_event_at_seconds == nil then
    return nil
  end
  return observation
end

local function persisted_observations(comments, head_sha)
  local observations = {}
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments or {})) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local observation = parse_marker(marker)
      if observation ~= nil and tostring(observation.head_sha) == tostring(head_sha) then
        table.insert(observations, observation)
      end
    end
  end
  return observations
end

local function same_source_observation(left, right)
  return tostring(left.head_sha) == tostring(right.head_sha)
    and tostring(left.status) == tostring(right.status)
    and tostring(left.source_event_at) == tostring(right.source_event_at)
end

local function sort_observations(observations)
  table.sort(observations, function(left, right)
    if left.source_event_at_seconds ~= right.source_event_at_seconds then
      return left.source_event_at_seconds < right.source_event_at_seconds
    end
    return tostring(left.status) < tostring(right.status)
  end)
end

function C.derive(pr, green, reason, now_seconds)
  local head_sha = type(pr) == "table" and pr.head_sha or nil
  if not forge_validators.is_git_sha(head_sha) then
    error("github-devloop-integration: rollup-health-observation-head-invalid: invalid rollup health observation head sha")
  end
  local status = green and "green" or (reason == "rollup-red" and "red" or "pending")
  local current = {
    head_sha = head_sha,
    status = status,
    source_event_at = source_event_at(pr, now_seconds),
  }
  current.source_event_at_seconds = contract_time.iso_timestamp_epoch_seconds(current.source_event_at)

  local observations = persisted_observations(pr.comments, head_sha)
  local current_is_persisted = false
  for _, observation in ipairs(observations) do
    if same_source_observation(observation, current) then
      current_is_persisted = true
      break
    end
  end
  if not current_is_persisted then
    table.insert(observations, current)
  end
  sort_observations(observations)

  local previous_status = nil
  local last_green_at = ""
  local incident_epoch = ""
  local current_incident_epoch = ""
  for _, observation in ipairs(observations) do
    if observation.status == "green" then
      if previous_status ~= "green" then
        last_green_at = observation.source_event_at
      end
      incident_epoch = ""
    elseif observation.status == "red" and incident_epoch == "" then
      incident_epoch = last_green_at ~= "" and last_green_at or initial_epoch
    end
    if same_source_observation(observation, current) then
      current_incident_epoch = incident_epoch
    end
    previous_status = observation.status
  end

  return {
    head_sha = head_sha,
    status = status,
    source_event_at = current.source_event_at,
    last_green_at = last_green_at,
    incident_epoch = current_incident_epoch,
  }
end

local function marker(observation)
  return "<!-- " .. marker_name
    .. ' head_sha="' .. tostring(observation.head_sha)
    .. '" status="' .. tostring(observation.status)
    .. '" source_event_at="' .. tostring(observation.source_event_at)
    .. '" -->'
end

function C.comment_request(repo, pr_number, observation)
  local body = "github-devloop-integration rollup health observation"
    .. "\n\nstatus=" .. tostring(observation.status)
    .. "\nhead_sha=" .. tostring(observation.head_sha)
    .. "\nsource_event_at=" .. tostring(observation.source_event_at)
    .. "\n\n" .. marker(observation)
  return devloop_entity.build_entity_comment_request({
    kind = "pr",
    repo = repo,
    number = pr_number,
  }, body, base_ids.dedup_key({
    "rollup-health-observation",
    tostring(repo or ""),
    tostring(pr_number or ""),
    tostring(observation.head_sha),
    tostring(observation.status),
    tostring(observation.source_event_at),
  }), devloop_entity.pr_source_ref(repo, pr_number))
end

return C
