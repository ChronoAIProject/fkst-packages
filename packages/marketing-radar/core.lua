-- marketing-radar/core.lua - pure GitHub issue contract mapping helpers.
--
-- Durable radar payloads carry source_ref plus small control fields. Long-form
-- strategy, signal context, and generated content remain in GitHub issues and
-- are re-fetched through source_ref by downstream packages.
local M = {}
local strings = require("contract.strings")

local WORK_LABEL = "auto-twitter-marketing"
local CONTROL_VALUE_LIMIT = 512
local TWEET_TEXT_LIMIT = 1200
local ISSUE_BODY_LIMIT = 11000

local ALLOWED_CONTROL_FIELDS = {
  account = true,
  assignee = true,
  cadence = true,
  ["calendar-ref"] = true,
  competitors = true,
  insight = true,
  locale = true,
  mode = true,
  output = true,
  priority = true,
  project = true,
  recurrence = true,
  ["scheduled-at"] = true,
  ["source-url"] = true,
  ["strategy-ref"] = true,
  time = true,
  timezone = true,
  topic = true,
  topics = true,
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
  local supported = {
    boolean = true,
    number = true,
    string = true,
  }
  return supported[type(value)] == true and #tostring(value) <= CONTROL_VALUE_LIMIT
end

local function normalized_key(key)
  return strings.trim(key):lower():gsub("_", "-")
end

local function has_sensitive_name(key)
  local normalized = normalized_key(key)
  for index = 1, #SENSITIVE_PATTERNS do
    if normalized:find(SENSITIVE_PATTERNS[index], 1, true) then
      return true
    end
  end
  return false
end

local function copy_source_ref(source_ref)
  if type(source_ref) ~= "table" then
    return {}
  end
  local out = {}
  for key, value in pairs(source_ref) do
    local exportable = SOURCE_REF_FIELDS[key] == true and is_small_scalar(value)
    if exportable then
      out[key] = value
    end
  end
  out.ref = out.ref or out.reference
  out.reference = out.reference or out.ref
  return out
end

local function safe_id(value)
  local raw = strings.trim(value)
  local text = raw:gsub("[^%w._#/-]", "-"):gsub("-+", "-")
  text = text:gsub("^[-/]+", ""):gsub("[-/]+$", "")
  if text == "" then
    return "unknown"
  end
  if #text > 180 then
    return text:sub(1, 180)
  end
  return text
end

local function safe_optional(value)
  local text = strings.trim(value)
  if text == "" then
    return nil
  end
  if #text > CONTROL_VALUE_LIMIT then
    return text:sub(1, CONTROL_VALUE_LIMIT)
  end
  return text
end

local function safe_login(value)
  local text = strings.trim(value)
  if text == "" then
    return nil
  end
  if #text > 80 or text:find("^[%w%-%[%]_.]+$") == nil then
    return nil
  end
  return text
end

local function runtime_key_segment(value, limit)
  local raw = tostring(value or "")
  local safe = strings.runtime_safe_segment(raw)
  local max_len = tonumber(limit) or 120
  local suffix = "_" .. strings.decimal_checksum(raw)
  if #safe <= max_len then
    return safe
  end
  if max_len > #suffix then
    safe = safe:sub(1, math.max(1, max_len - #suffix)) .. suffix
  else
    safe = suffix:sub(1, max_len)
  end
  return safe
end

local function bounded_text(value, limit)
  local text = strings.trim(value)
  text = text:gsub("[%z\1-\8\11\12\14-\31]", " ")
  local max_len = limit or CONTROL_VALUE_LIMIT
  if #text > max_len then
    return text:sub(1, max_len)
  end
  return text
end

local function append_line(lines, line)
  table.insert(lines, tostring(line or ""))
end

local function trim_body(body)
  local text = tostring(body or "")
  if #text <= ISSUE_BODY_LIMIT then
    return text
  end
  return text:sub(1, ISSUE_BODY_LIMIT) .. "\n\n[truncated by marketing-radar issue body guard]\n"
end

local function line_iter(body)
  local text = tostring(body or "")
  if text == "" then
    return function()
      return nil
    end
  end
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local pos = 1
  return function()
    if pos > #text then
      return nil
    end
    local next_pos = text:find("\n", pos, true)
    local line = text:sub(pos, next_pos - 1):gsub("\r$", "")
    pos = next_pos + 1
    return line
  end
end

local function parse_fenced_field(body, field)
  local target = normalized_key(field)
  local waiting_for_fence = false
  local collecting = false
  local lines = {}

  for line in line_iter(body) do
    if collecting then
      if line:match("^%s*```") ~= nil then
        local text = bounded_text(table.concat(lines, "\n"), TWEET_TEXT_LIMIT)
        return text ~= "" and text or nil
      end
      table.insert(lines, line)
    elseif waiting_for_fence then
      if line:match("^%s*```") ~= nil then
        collecting = true
      elseif strings.trim(line) ~= "" then
        return bounded_text(line, TWEET_TEXT_LIMIT)
      end
    else
      local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
      if key ~= nil and normalized_key(key) == target then
        local cleaned = strings.trim(value)
        if cleaned ~= "" and cleaned ~= "|" and cleaned ~= ">" then
          return bounded_text(cleaned, TWEET_TEXT_LIMIT)
        end
        waiting_for_fence = true
      end
    end
  end

  if collecting and #lines > 0 then
    local text = bounded_text(table.concat(lines, "\n"), TWEET_TEXT_LIMIT)
    return text ~= "" and text or nil
  end
  return nil
end

local function normalize_kind(value)
  local kind = normalized_key(value)
  if kind == "radar-config" or kind == "radarconfig" then
    return "radar-config"
  end
  if kind == "radar-signal" or kind == "radarsignal" or kind == "signal" then
    return "radar-signal"
  end
  if kind == "radar-run" or kind == "radarrun" or kind == "radar" then
    return "radar-run"
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
  return nil
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
  return "github:marketing-radar:" .. tostring(source_ref.ref)
end

local function dedup_key_for(kind, fields, payload, source_ref)
  local parts = {
    "marketing-radar",
    safe_id(kind),
    safe_id(fields.project),
    safe_id(fields.week or fields.topic or fields.account or "default"),
    safe_id(source_ref.ref),
    safe_id(payload.updated_at or payload.dedup_key or "unversioned"),
  }
  return table.concat(parts, "/")
end

local function control_fields(payload, opts)
  local options = opts or {}
  local fields = M.parse_control_fields(options.issue_body or payload.body)
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

local function artifact_week_segment(item)
  return safe_id(item.week or item.topic or item.source_ref and item.source_ref.ref or "default")
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
  for line in line_iter(body) do
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

  local issue_body = options.issue_body or payload.body
  local out = {
    kind = kind,
    project = safe_id(fields.project),
    account = safe_id(fields.account or "main"),
    assignee = safe_login(fields.assignee),
    cadence = safe_optional(fields.cadence),
    competitors = safe_optional(fields.competitors),
    insight = safe_optional(fields.insight),
    locale = safe_optional(fields.locale),
    mode = normalize_mode(fields.mode),
    output = safe_optional(fields.output),
    priority = safe_optional(fields.priority),
    recurrence = normalize_recurrence(fields.recurrence),
    scheduled_at = safe_optional(fields["scheduled-at"]),
    source_url = safe_optional(fields["source-url"]),
    strategy_ref = safe_optional(fields["strategy-ref"]),
    calendar_ref = safe_optional(fields["calendar-ref"]),
    time = safe_optional(fields.time),
    timezone = safe_optional(fields.timezone),
    topic = safe_optional(fields.topic),
    topics = safe_optional(fields.topics),
    week = safe_optional(fields.week),
    tweet_text = parse_fenced_field(issue_body, "tweet-text"),
    issue_number = payload.number,
    repo = payload.repo,
    source_ref = source_ref,
    trace_id = trace_id_for(source_ref),
  }
  out.dedup_key = dedup_key_for(kind, fields, payload, source_ref)

  if kind == "radar-run" and out.week == nil then
    return nil, "missing week"
  end
  if kind == "radar-run" and out.calendar_ref ~= nil and out.recurrence == nil and fields.recurrence ~= nil then
    return nil, "unsupported recurrence"
  end
  if kind == "radar-run" and out.calendar_ref ~= nil and out.recurrence == "daily"
      and (out.time == nil or out.timezone == nil) then
    return nil, "missing recurring schedule fields"
  end
  return out
end

function M.artifact_id(item)
  if item.kind == "radar-config" then
    return "marketing-radar/" .. item.project .. "/config"
  end
  if item.kind == "radar-signal" then
    return "marketing-radar/" .. item.project .. "/" .. artifact_week_segment(item) .. "/signal"
  end
  return "marketing-radar/" .. item.project .. "/" .. artifact_week_segment(item) .. "/brief"
end

function M.radar_config_imported(item)
  return {
    schema = "marketing-radar.config-imported.v1",
    artifact_id = M.artifact_id(item),
    project = item.project,
    account = item.account,
    cadence = item.cadence,
    timezone = item.timezone,
    topics = item.topics,
    competitors = item.competitors,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.radar_signal_imported(item)
  return {
    schema = "marketing-radar.signal-imported.v1",
    artifact_id = M.artifact_id(item),
    project = item.project,
    week = item.week,
    topic = item.topic,
    source_url = item.source_url,
    insight = item.insight,
    priority = item.priority,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

function M.radar_brief_created(item)
  return {
    schema = "marketing-radar.brief-created.v1",
    artifact_id = M.artifact_id(item),
    project = item.project,
    week = item.week,
    topic = item.topic,
    source_url = item.source_url,
    insight = item.insight,
    strategy_ref = item.strategy_ref,
    calendar_ref = item.calendar_ref,
    source_ref = copy_source_ref(item.source_ref),
    dedup_key = item.dedup_key,
    trace_id = item.trace_id,
  }
end

local function issue_assignees(item)
  if item.assignee == nil then
    return {}
  end
  return { item.assignee }
end

local function weekly_title(item)
  return "Radar weekly content: " .. tostring(item.project) .. " " .. tostring(item.week)
end

local function schedule_title(item)
  return "Radar schedule publish: " .. tostring(item.project) .. " " .. tostring(item.week)
end

local function radar_brief_ref(item)
  if item.issue_number ~= nil then
    return "#" .. tostring(item.issue_number)
  end
  return tostring(item.source_ref and item.source_ref.ref or "unknown")
end

local function default_tweet_text(item)
  if item.insight ~= nil and item.insight ~= "" then
    return item.insight
  end
  if item.topic ~= nil and item.topic ~= "" then
    return "Radar brief: " .. item.topic
  end
  return "Radar generated weekly content for " .. tostring(item.project) .. " " .. tostring(item.week) .. "."
end

local function append_optional_field(lines, key, value)
  if value ~= nil and tostring(value) ~= "" then
    append_line(lines, tostring(key) .. ": " .. tostring(value))
  end
end

function M.weekly_content_issue_request(item)
  local lines = {}
  append_line(lines, "type: weekly-content")
  append_line(lines, "project: " .. tostring(item.project))
  append_line(lines, "week: " .. tostring(item.week))
  append_optional_field(lines, "strategy-ref", item.strategy_ref)
  append_line(lines, "radar-brief-ref: " .. radar_brief_ref(item))
  append_optional_field(lines, "topic", item.topic)
  append_optional_field(lines, "source-url", item.source_url)
  append_line(lines, "")
  append_line(lines, "tweet-text:")
  append_line(lines, "```")
  append_line(lines, bounded_text(item.tweet_text or default_tweet_text(item), TWEET_TEXT_LIMIT))
  append_line(lines, "```")
  append_line(lines, "")
  append_line(lines, "Generated by marketing-radar. Edit this issue before scheduling if needed.")

  return {
    schema = "github-proxy.issue-create.v1",
    repo = item.repo,
    title = weekly_title(item),
    body = trim_body(table.concat(lines, "\n")),
    labels = { WORK_LABEL },
    assignees = issue_assignees(item),
    dedup_key = table.concat({
      "marketing-radar",
      runtime_key_segment(item.project, 80),
      runtime_key_segment(item.week, 80),
      runtime_key_segment(item.source_ref and item.source_ref.ref or "source", 120),
      "weekly-content",
    }, "/"),
    source_ref = copy_source_ref(item.source_ref),
    parent_comment_target = {
      repo = item.repo,
      issue_number = item.issue_number,
    },
  }
end

function M.schedule_issue_request(item)
  local lines = {}
  append_line(lines, "type: schedule-publish")
  append_line(lines, "project: " .. tostring(item.project))
  append_line(lines, "week: " .. tostring(item.week))
  append_line(lines, "calendar-ref: " .. tostring(item.calendar_ref))
  append_line(lines, "mode: " .. tostring(item.mode or "shadow"))
  append_optional_field(lines, "scheduled-at", item.scheduled_at)
  append_optional_field(lines, "recurrence", item.recurrence)
  append_optional_field(lines, "time", item.time)
  append_optional_field(lines, "timezone", item.timezone)
  append_optional_field(lines, "locale", item.locale)
  append_line(lines, "")
  append_line(lines, "Generated by marketing-radar. Close this issue to stop future recurring dispatches.")

  return {
    schema = "github-proxy.issue-create.v1",
    repo = item.repo,
    title = schedule_title(item),
    body = trim_body(table.concat(lines, "\n")),
    labels = { WORK_LABEL },
    assignees = issue_assignees(item),
    dedup_key = table.concat({
      "marketing-radar",
      runtime_key_segment(item.project, 80),
      runtime_key_segment(item.week, 80),
      runtime_key_segment(item.source_ref and item.source_ref.ref or "source", 120),
      "schedule-publish",
    }, "/"),
    source_ref = copy_source_ref(item.source_ref),
    parent_comment_target = {
      repo = item.repo,
      issue_number = item.issue_number,
    },
  }
end

function M.status_comment(item, status)
  local body = "Marketing radar: " .. tostring(status) .. "\n\n"
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
