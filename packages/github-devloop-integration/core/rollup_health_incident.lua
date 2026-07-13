local base_ids = require("devloop.base_ids")
local contract_time = require("contract.time")
local devloop_entity = require("devloop.entity")
local forge_validators = require("devloop.forge_validators")
local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")

local C = {}

local marker_name = "fkst:github-devloop-integration:rollup-health-observation:v1"
local marker_pattern = "<!%-%-%s*" .. marker_name:gsub("%-", "%%-") .. ".-%-%->"
local initial_epoch = "initial"

local valid_status = {
  green = true,
  pending = true,
  red = true,
}

local function timestamp_fact(value)
  local text = tostring(value or "")
  local whole, fraction = text:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.(%d+)Z$")
  local seconds = nil
  if whole ~= nil then
    seconds = contract_time.iso_timestamp_epoch_seconds(whole .. "Z")
  else
    seconds = contract_time.iso_timestamp_epoch_seconds(text)
    fraction = ""
  end
  if seconds == nil then
    return nil
  end
  return {
    value = text,
    seconds = seconds,
    fraction = fraction,
  }
end

local function compare_timestamp(left, right)
  if left.seconds ~= right.seconds then
    return left.seconds < right.seconds and -1 or 1
  end
  local width = math.max(#left.fraction, #right.fraction)
  local left_fraction = left.fraction .. string.rep("0", width - #left.fraction)
  local right_fraction = right.fraction .. string.rep("0", width - #right.fraction)
  if left_fraction == right_fraction then
    return 0
  end
  return left_fraction < right_fraction and -1 or 1
end

local function check_timestamp(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local state = tostring(entry.state or entry.status or ""):upper()
  if state == "COMPLETED" then
    return entry.completedAt or entry.completed_at
  end
  return entry.startedAt or entry.started_at
end

local function source_identity(entry)
  for _, key in ipairs({
    "id",
    "databaseId",
    "database_id",
    "detailsUrl",
    "details_url",
    "targetUrl",
    "target_url",
  }) do
    local value = entry[key]
    if tostring(value or "") ~= "" then
      return tostring(value)
    end
  end
  return nil
end

local function framed(value)
  local text = tostring(value or "")
  return tostring(#text) .. ":" .. text
end

local function entry_event_id(entry, timestamp)
  local identity = source_identity(entry)
  if identity == nil then
    error("github-devloop-integration: rollup-health-source-event-id-missing: status check provider identity is required")
  end
  return "entry-" .. strings.decimal_checksum(table.concat({
    framed(entry.__typename or entry.type),
    framed(identity),
    framed(entry.name or entry.context or entry.workflowName or entry.workflow_name),
    framed(timestamp.value),
    framed(entry.state or entry.status),
    framed(entry.conclusion),
  }))
end

local function source_event(pr)
  local entry_ids = {}
  local latest = nil
  for _, entry in ipairs(type(pr) == "table" and pr.status_check_rollup or {}) do
    local timestamp = timestamp_fact(check_timestamp(entry))
    if timestamp == nil then
      error("github-devloop-integration: rollup-health-source-event-time-missing: status check source timestamp is required")
    end
    table.insert(entry_ids, entry_event_id(entry, timestamp))
    if latest == nil or compare_timestamp(latest, timestamp) < 0 then
      latest = timestamp
    end
  end
  if latest == nil then
    error("github-devloop-integration: rollup-health-source-event-missing: status check source event is required")
  end
  table.sort(entry_ids)
  return {
    id = "event-" .. strings.decimal_checksum(table.concat(entry_ids, "\n")),
    timestamp = latest,
  }
end

local function valid_source_event_id(value)
  return tostring(value or ""):match("^event%-%d%d%d%d%d%d%d%d%d%d$") ~= nil
end

local function parse_marker(marker)
  local text = tostring(marker or "")
  local observation = {
    head_sha = text:match('head_sha="([^"]+)"'),
    status = text:match('status="([^"]+)"'),
    source_event_at = text:match('source_event_at="([^"]+)"'),
    source_event_id = text:match('source_event_id="([^"]+)"'),
  }
  if not forge_validators.is_git_sha(observation.head_sha)
    or not valid_status[observation.status]
    or not valid_source_event_id(observation.source_event_id) then
    return nil
  end
  local timestamp = timestamp_fact(observation.source_event_at)
  if timestamp == nil then
    return nil
  end
  observation.source_event_at_seconds = timestamp.seconds
  observation.source_event_at_fraction = timestamp.fraction
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
    and tostring(left.source_event_id) == tostring(right.source_event_id)
end

local function sort_observations(observations)
  table.sort(observations, function(left, right)
    local timestamp_order = compare_timestamp({
      seconds = left.source_event_at_seconds,
      fraction = left.source_event_at_fraction,
    }, {
      seconds = right.source_event_at_seconds,
      fraction = right.source_event_at_fraction,
    })
    if timestamp_order ~= 0 then
      return timestamp_order < 0
    end
    if (left.status == "green" and right.status == "red")
      or (left.status == "red" and right.status == "green") then
      error("github-devloop-integration: rollup-health-source-order-ambiguous: red and green source events have identical chronology")
    end
    return tostring(left.source_event_id) < tostring(right.source_event_id)
  end)
end

function C.derive(pr, green, reason)
  local head_sha = type(pr) == "table" and pr.head_sha or nil
  if not forge_validators.is_git_sha(head_sha) then
    error("github-devloop-integration: rollup-health-observation-head-invalid: invalid rollup health observation head sha")
  end
  local status = green and "green" or (reason == "rollup-red" and "red" or "pending")
  local event = source_event(pr)
  local current = {
    head_sha = head_sha,
    status = status,
    source_event_at = event.timestamp.value,
    source_event_id = event.id,
    source_event_at_seconds = event.timestamp.seconds,
    source_event_at_fraction = event.timestamp.fraction,
  }

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
  local last_green_event_id = ""
  local incident_epoch = ""
  local current_incident_epoch = ""
  for _, observation in ipairs(observations) do
    if observation.status == "green" then
      if previous_status ~= "green" then
        last_green_at = observation.source_event_at
        last_green_event_id = observation.source_event_id
      end
      incident_epoch = ""
    elseif observation.status == "red" and incident_epoch == "" then
      incident_epoch = last_green_event_id ~= "" and last_green_event_id or initial_epoch
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
    source_event_id = current.source_event_id,
    last_green_at = last_green_at,
    incident_epoch = current_incident_epoch,
  }
end

local function marker(observation)
  return "<!-- " .. marker_name
    .. ' head_sha="' .. tostring(observation.head_sha)
    .. '" status="' .. tostring(observation.status)
    .. '" source_event_at="' .. tostring(observation.source_event_at)
    .. '" source_event_id="' .. tostring(observation.source_event_id)
    .. '" -->'
end

function C.comment_request(repo, pr_number, observation)
  local body = "github-devloop-integration rollup health observation"
    .. "\n\nstatus=" .. tostring(observation.status)
    .. "\nhead_sha=" .. tostring(observation.head_sha)
    .. "\nsource_event_at=" .. tostring(observation.source_event_at)
    .. "\nsource_event_id=" .. tostring(observation.source_event_id)
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
    tostring(observation.source_event_id),
  }), devloop_entity.pr_source_ref(repo, pr_number))
end

return C
