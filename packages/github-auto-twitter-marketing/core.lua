-- github-auto-twitter-marketing/core.lua - pure issue contract mapping helpers.
-- The durable payload carries only source_ref plus small control fields; strategy
-- and weekly content stay in the GitHub issue and are re-fetched through source_ref.
local M = {}
local strings = require("contract.strings")

local WORK_LABEL = "auto-twitter-marketing"
local CONTROL_VALUE_LIMIT = 512

local ALLOWED_CONTROL_FIELDS = {
  account = true,
  ["calendar-ref"] = true,
  channel = true,
  ["interval-minutes"] = true,
  locale = true,
  mode = true,
  owner = true,
  project = true,
  recurrence = true,
  ["scheduled-at"] = true,
  ["strategy-ref"] = true,
  time = true,
  timezone = true,
  type = true,
  week = true,
}

local SENSITIVE_PATTERNS = {
  "authorization",
  "api_key",
  "apikey",
  "bearer",
  "credential",
  "oauth",
  "password",
  "provider_response",
  "raw_response",
  "secret",
  "token",
}

local SOURCE_REF_FIELDS = {
  kind = true,
  ref = true,
  reference = true,
  uri = true,
  version = true,
}

local function is_small_scalar(value)
  local value_type = type(value)
  if value_type ~= "string" and value_type ~= "number" and value_type ~= "boolean" then
    return false
  end
  return #tostring(value) <= CONTROL_VALUE_LIMIT
end

local function normalized_key(key)
  return strings.trim(key):lower():gsub("_", "-")
end

local function has_sensitive_name(key)
  local normalized = normalized_key(key)
  for _, pattern in ipairs(SENSITIVE_PATTERNS) do
    if normalized:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function copy_source_ref(source_ref)
  local out = {}
  if type(source_ref) ~= "table" then
    return out
  end
  for key, value in pairs(source_ref) do
    if SOURCE_REF_FIELDS[key] and is_small_scalar(value) then
      out[key] = value
    end
  end
  if out.ref == nil and out.reference ~= nil then
    out.ref = out.reference
  end
  if out.reference == nil and out.ref ~= nil then
    out.reference = out.ref
  end
  return out
end

local function safe_id(value)
  local text = strings.trim(value):gsub("[^%w._#/-]", "-")
  text = text:gsub("-+", "-"):gsub("^[-/]+", ""):gsub("[-/]+$", "")
  if text == "" then
    return "unknown"
  end
  if #text > 180 then
    return text:sub(1, 180)
  end
  return text
end

local function runtime_key_segment(value, limit)
  local max_len = limit or 120
  local raw = tostring(value or "")
  local safe = strings.runtime_safe_segment(raw)
  local suffix = "_" .. strings.decimal_checksum(raw)
  if #safe > max_len then
    safe = safe:sub(1, math.max(1, max_len - #suffix)) .. suffix
  end
  return safe
end

function M.work_label()
  return WORK_LABEL
end

function M.saga_conformance_errors()
  return {}
end

function M.has_work_label(labels)
  if type(labels) ~= "table" then
    return false
  end
  for _, label in ipairs(labels) do
    if tostring(label) == WORK_LABEL then
      return true
    end
  end
  return false
end

function M.parse_control_fields(body)
  local fields = {}
  if type(body) ~= "string" then
    return fields
  end
  for line in body:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
    if key ~= nil then
      local normalized = normalized_key(key)
      local cleaned = strings.trim(value)
      if ALLOWED_CONTROL_FIELDS[normalized] and not has_sensitive_name(normalized)
          and cleaned ~= "" and #cleaned <= CONTROL_VALUE_LIMIT then
        fields[normalized] = cleaned
      end
    end
  end
  return fields
end

local function control_fields(payload, opts)
  local options = opts or {}
  local fields = M.parse_control_fields(options.issue_body)
  if type(payload.controls) == "table" then
    for key, value in pairs(payload.controls) do
      local normalized = normalized_key(key)
      if ALLOWED_CONTROL_FIELDS[normalized] and not has_sensitive_name(normalized)
          and is_small_scalar(value) and tostring(value) ~= "" then
        fields[normalized] = tostring(value)
      end
    end
  end
  return fields
end

local function source_ref_for(payload)
  local source_ref = copy_source_ref(payload.source_ref)
  if source_ref.ref ~= nil and source_ref.ref ~= "" then
    return source_ref
  end
  if payload.repo ~= nil and payload.number ~= nil then
    local reference = tostring(payload.repo) .. "#issue/" .. tostring(payload.number)
    return {
      kind = "external",
      ref = reference,
      reference = reference,
    }
  end
  return nil
end

local function trace_id_for(source_ref)
  return "github:auto-twitter-marketing:" .. tostring(source_ref.ref)
end

local function dedup_key_for(kind, fields, payload, source_ref)
  local parts = {
    "auto-twitter-marketing",
    safe_id(kind),
    safe_id(fields.project),
    safe_id(fields.week or fields.account or "default"),
    safe_id(source_ref.ref),
    safe_id(payload.updated_at or payload.dedup_key or "unversioned"),
  }
  return table.concat(parts, "/")
end

local function normalize_kind(value)
  local kind = normalized_key(value)
  if kind == "strategy" then
    return "strategy"
  end
  if kind == "weekly-content" or kind == "weekly" then
    return "weekly-content"
  end
  if kind == "schedule-publish" or kind == "schedule" then
    return "schedule-publish"
  end
  if kind == "recurring-schedule-publish" or kind == "daily-schedule-publish" then
    return "schedule-publish"
  end
  return nil
end

local function normalize_mode(value)
  local mode = normalized_key(value or "shadow")
  if mode == "live" then
    return "live"
  end
  return "shadow"
end

local function normalize_recurrence(value)
  local recurrence = normalized_key(value)
  if recurrence == "" then
    return nil
  end
  if recurrence == "daily" then
    return "daily"
  end
  if recurrence == "every-minutes" or recurrence == "every-minute" or recurrence == "minutely" then
    return "every-minutes"
  end
  return nil
end

local function parse_interval_minutes(value)
  local text = strings.trim(value)
  local minutes = tonumber(text)
  if minutes == nil or minutes < 1 or minutes > 1440 or minutes ~= math.floor(minutes) then
    return nil
  end
  return minutes
end

local function parse_timezone_offset(value)
  local zone = strings.trim(value)
  if zone == "" or zone == "Z" or zone == "UTC" or zone == "Etc/UTC" then
    return 0, "+00:00"
  end
  if zone == "Asia/Shanghai" or zone == "Asia/Chongqing" then
    return 8 * 60 * 60, "+08:00"
  end
  local sign, hours, minutes = zone:match("^([+-])(%d%d):(%d%d)$")
  if sign == nil then
    sign, hours, minutes = zone:match("^([+-])(%d%d)(%d%d)$")
  end
  if sign == nil then
    return nil, "unsupported timezone"
  end
  local hour_value = tonumber(hours)
  local minute_value = tonumber(minutes)
  if hour_value == nil or minute_value == nil or hour_value > 23 or minute_value > 59 then
    return nil, "invalid timezone"
  end
  local offset = hour_value * 60 * 60 + minute_value * 60
  if sign == "-" then
    offset = -offset
  end
  return offset, string.format("%s%02d:%02d", sign, hour_value, minute_value)
end

local function is_leap_year(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local function days_in_month(year, month)
  local month_days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and is_leap_year(year) then
    return 29
  end
  return month_days[month]
end

local function epoch_seconds_utc(year, month, day, hour, minute, second)
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  minute = tonumber(minute)
  second = tonumber(second or 0)
  if year == nil or month == nil or day == nil or hour == nil or minute == nil or second == nil then
    return nil
  end
  if year < 1970 or year > 2200 or month < 1 or month > 12 then
    return nil
  end
  local max_day = days_in_month(year, month)
  if day < 1 or day > max_day or hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59 then
    return nil
  end
  local days = 0
  for y = 1970, year - 1 do
    days = days + (is_leap_year(y) and 366 or 365)
  end
  for m = 1, month - 1 do
    days = days + days_in_month(year, m)
  end
  days = days + day - 1
  return (((days * 24 + hour) * 60 + minute) * 60 + second)
end

local function parse_clock_time(value)
  local text = strings.trim(value)
  local hour, minute, second = text:match("^(%d%d):(%d%d):(%d%d)$")
  if hour == nil then
    hour, minute = text:match("^(%d%d):(%d%d)$")
    second = "00"
  end
  local h = tonumber(hour)
  local m = tonumber(minute)
  local s = tonumber(second)
  if h == nil or m == nil or s == nil or h > 23 or m > 59 or s > 59 then
    return nil
  end
  return h, m, s
end

local function parse_iso8601(value)
  local text = strings.trim(value)
  local year, month, day, hour, minute, second, zone =
    text:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
  if year == nil then
    year, month, day, hour, minute, zone =
      text:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d)(.*)$")
    second = "00"
  end
  if year == nil then
    return nil, "invalid scheduled-at"
  end
  local offset, _offset_text = parse_timezone_offset(zone)
  if offset == nil then
    return nil, "invalid scheduled-at timezone"
  end
  local epoch = epoch_seconds_utc(year, month, day, hour, minute, second)
  if epoch == nil then
    return nil, "invalid scheduled-at"
  end
  return {
    epoch_seconds = epoch - offset,
    offset_seconds = offset,
    offset_text = _offset_text,
  }, nil
end

local function parse_iso8601_seconds(value)
  local parsed, why = parse_iso8601(value)
  if parsed == nil then
    return nil, why
  end
  return parsed.epoch_seconds, nil
end

local function format_epoch_with_offset(epoch_seconds, offset_seconds, offset_text)
  local local_date = os.date("!*t", epoch_seconds + offset_seconds)
  if type(local_date) ~= "table" then
    return nil
  end
  return string.format(
    "%04d-%02d-%02dT%02d:%02d:%02d%s",
    local_date.year,
    local_date.month,
    local_date.day,
    local_date.hour,
    local_date.min,
    local_date.sec,
    offset_text
  )
end

local function daily_occurrence(item, now_seconds)
  local hour, minute, second = parse_clock_time(item.time)
  if hour == nil then
    return { due = false, reason = "invalid daily time" }
  end
  local offset, offset_text = parse_timezone_offset(item.timezone)
  if offset == nil then
    return { due = false, reason = offset_text }
  end
  local local_date = os.date("!*t", now_seconds + offset)
  if type(local_date) ~= "table" then
    return { due = false, reason = "invalid now" }
  end
  local due_epoch = epoch_seconds_utc(local_date.year, local_date.month, local_date.day, hour, minute, second)
  if due_epoch == nil then
    return { due = false, reason = "invalid occurrence date" }
  end
  due_epoch = due_epoch - offset
  local local_day = string.format("%04d-%02d-%02d", local_date.year, local_date.month, local_date.day)
  local local_time = string.format("%02d:%02d:%02d", hour, minute, second)
  return {
    due = now_seconds >= due_epoch,
    reason = now_seconds >= due_epoch and "due" or "not due",
    occurrence_id = local_day .. "T" .. local_time .. offset_text,
    scheduled_at = local_day .. "T" .. local_time .. offset_text,
    due_epoch_seconds = due_epoch,
  }
end

local function every_minutes_occurrence(item, now_seconds)
  local parsed, why = parse_iso8601(item.scheduled_at)
  if parsed == nil then
    return { due = false, reason = why or "invalid scheduled-at" }
  end
  local interval_minutes = parse_interval_minutes(item.interval_minutes)
  if interval_minutes == nil then
    return { due = false, reason = "invalid interval-minutes" }
  end
  if now_seconds < parsed.epoch_seconds then
    return {
      due = false,
      reason = "not due",
      occurrence_id = item.scheduled_at,
      scheduled_at = item.scheduled_at,
      due_epoch_seconds = parsed.epoch_seconds,
    }
  end
  local interval_seconds = interval_minutes * 60
  local occurrence_index = math.floor((now_seconds - parsed.epoch_seconds) / interval_seconds)
  local due_epoch = parsed.epoch_seconds + occurrence_index * interval_seconds
  local scheduled_at = format_epoch_with_offset(due_epoch, parsed.offset_seconds, parsed.offset_text)
  if scheduled_at == nil then
    return { due = false, reason = "invalid occurrence date" }
  end
  return {
    due = true,
    reason = "due",
    occurrence_id = scheduled_at,
    scheduled_at = scheduled_at,
    due_epoch_seconds = due_epoch,
  }
end

function M.classify_issue(payload, opts)
  local options = opts or {}
  if type(payload) ~= "table" then
    return nil, "invalid payload"
  end
  if payload.schema ~= "github-proxy.v1" and payload.schema ~= "github-proxy.issue-observed.v1" then
    return nil, "unsupported schema"
  end
  if payload.type ~= "issue" then
    return nil, "not issue"
  end
  if not M.has_work_label(payload.labels) and not M.has_work_label(options.issue_labels) then
    return nil, "missing work label"
  end

  local fields = control_fields(payload, options)
  local kind = normalize_kind(fields.type)
  if kind == nil then
    return nil, "missing type"
  end
  if fields.project == nil then
    return nil, "missing project"
  end

  local source_ref = source_ref_for(payload)
  if source_ref == nil then
    return nil, "missing source_ref"
  end

  local raw_type = normalized_key(fields.type)
  local recurrence = normalize_recurrence(fields.recurrence)
  if recurrence == nil and (raw_type == "recurring-schedule-publish" or raw_type == "daily-schedule-publish") then
    recurrence = "daily"
  end

  local out = {
    kind = kind,
    project = safe_id(fields.project),
    account = safe_id(fields.account or "main"),
    week = fields.week,
    strategy_ref = fields["strategy-ref"],
    calendar_ref = fields["calendar-ref"],
    mode = normalize_mode(fields.mode or fields.channel),
    recurrence = recurrence,
    scheduled_at = fields["scheduled-at"],
    interval_minutes = parse_interval_minutes(fields["interval-minutes"]),
    time = fields.time,
    timezone = fields.timezone,
    locale = fields.locale,
    owner = fields.owner,
    issue_number = payload.number,
    repo = payload.repo,
    source_ref = source_ref,
    trace_id = trace_id_for(source_ref),
  }
  out.dedup_key = dedup_key_for(kind, fields, payload, source_ref)

  if kind == "weekly-content" and out.week == nil then
    return nil, "missing week"
  end
  if kind == "schedule-publish" then
    if out.week == nil or out.calendar_ref == nil then
      return nil, "missing schedule fields"
    end
    if out.recurrence == "daily" then
      if out.time == nil or out.timezone == nil then
        return nil, "missing recurring schedule fields"
      end
      if parse_clock_time(out.time) == nil then
        return nil, "invalid recurring time"
      end
      if parse_timezone_offset(out.timezone) == nil then
        return nil, "invalid recurring timezone"
      end
    elseif out.recurrence == "every-minutes" then
      if out.scheduled_at == nil or fields["interval-minutes"] == nil then
        return nil, "missing recurring schedule fields"
      end
      if out.interval_minutes == nil then
        return nil, "invalid interval-minutes"
      end
      if parse_iso8601_seconds(out.scheduled_at) == nil then
        return nil, "invalid scheduled-at"
      end
    elseif fields.recurrence ~= nil then
      return nil, "unsupported recurrence"
    elseif out.scheduled_at == nil then
      return nil, "missing schedule fields"
    elseif parse_iso8601_seconds(out.scheduled_at) == nil then
      return nil, "invalid scheduled-at"
    end
  end
  return out
end

function M.artifact_id(item)
  if item.kind == "strategy" then
    return "auto-twitter-marketing/" .. item.project .. "/strategy"
  end
  if item.kind == "weekly-content" then
    return "auto-twitter-marketing/" .. item.project .. "/" .. tostring(item.week) .. "/weekly-content"
  end
  return "auto-twitter-marketing/" .. item.project .. "/" .. tostring(item.week) .. "/schedule"
end

function M.strategy_imported(item)
  return {
    schema = "auto-twitter-marketing.strategy-imported.v1",
    artifact_id = M.artifact_id(item),
    project = item.project,
    account = item.account,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.weekly_content_imported(item)
  return {
    schema = "auto-twitter-marketing.weekly-content-imported.v1",
    artifact_id = M.artifact_id(item),
    project = item.project,
    week = item.week,
    strategy_ref = item.strategy_ref,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.live_gate(item, opts)
  opts = opts or {}
  return item ~= nil
    and item.mode == "live"
    and type(opts.nyxid_x_service) == "string"
    and opts.nyxid_x_service ~= ""
    and opts.live_write_enabled == true
end

function M.schedule_decision(item, now_seconds)
  if type(item) ~= "table" or item.kind ~= "schedule-publish" then
    return { due = false, reason = "not schedule" }
  end
  local current = tonumber(now_seconds)
  if current == nil then
    return { due = false, reason = "invalid now" }
  end
  if item.recurrence == "daily" then
    return daily_occurrence(item, current)
  end
  if item.recurrence == "every-minutes" then
    return every_minutes_occurrence(item, current)
  end
  local scheduled_seconds, why = parse_iso8601_seconds(item.scheduled_at)
  if scheduled_seconds == nil then
    return { due = false, reason = why or "invalid scheduled-at" }
  end
  return {
    due = current >= scheduled_seconds,
    reason = current >= scheduled_seconds and "due" or "not due",
    occurrence_id = tostring(item.scheduled_at),
    scheduled_at = item.scheduled_at,
    due_epoch_seconds = scheduled_seconds,
  }
end

function M.schedule_once_key(item, decision)
  local occurrence = decision and decision.occurrence_id or item and item.scheduled_at or "unknown"
  return table.concat({
    "auto-twitter-marketing",
    "schedule",
    runtime_key_segment(item and item.project or "project", 80),
    runtime_key_segment(item and item.week or "week", 80),
    runtime_key_segment(item and item.source_ref and item.source_ref.ref or "source", 120),
    runtime_key_segment(occurrence, 120),
  }, "/")
end

function M.schedule_publish_dedup_key(item, decision)
  local occurrence = decision and decision.occurrence_id or item.scheduled_at or "unscheduled"
  return table.concat({
    "auto-twitter-marketing",
    safe_id(item.project),
    safe_id(item.week),
    "schedule",
    safe_id(item.source_ref and item.source_ref.ref or "source"),
    safe_id(occurrence),
    "x-publish",
  }, "/")
end

function M.x_publish_request(item, opts, decision)
  local live = M.live_gate(item, opts)
  local metadata = {
    campaign_id = item.project,
    content_type = "weekly-content",
    tag = "calendar:" .. tostring(item.calendar_ref),
    variant = live and "live" or "preview",
  }
  if item.recurrence ~= nil then
    metadata.schedule_type = item.recurrence
  end
  if item.interval_minutes ~= nil then
    metadata.interval_minutes = item.interval_minutes
  end
  if decision ~= nil and decision.occurrence_id ~= nil then
    metadata.occurrence_id = decision.occurrence_id
  end
  if item.locale ~= nil then
    metadata.locale = item.locale
  end
  if item.owner ~= nil then
    metadata.owner = item.owner
  end
  return {
    artifact_id = M.artifact_id(item),
    source_ref = copy_source_ref(item.source_ref),
    content_ref = item.calendar_ref,
    platform = "x",
    channel = live and "live" or "shadow",
    dedup_key = M.schedule_publish_dedup_key(item, decision),
    trace_id = item.trace_id,
    scheduled_at = decision and decision.scheduled_at or item.scheduled_at,
    metadata = metadata,
  }
end

M.parse_iso8601_seconds = parse_iso8601_seconds
M.runtime_key_segment = runtime_key_segment

function M.status_comment(item, status)
  local body = "Auto Twitter marketing: " .. tostring(status) .. "\n\n"
    .. "source_ref: " .. tostring((item.source_ref or {}).ref) .. "\n"
    .. "dedup_key: " .. tostring(item.dedup_key)
  return {
    schema = "github-proxy.v1",
    repo = item.repo,
    issue_number = item.issue_number,
    body = body,
    dedup_key = item.dedup_key .. "/status/" .. safe_id(status),
    source_ref = copy_source_ref(item.source_ref),
  }
end

return M
