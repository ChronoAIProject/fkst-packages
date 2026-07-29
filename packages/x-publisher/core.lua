-- x-publisher/core.lua - pure, side-effect-free publish contract helpers. Payloads carry only
-- small control fields and a source_ref pointer; post content is re-fetched by the host seam.
local M = {}
local strings = require("contract.strings")

local TOP_LEVEL_FIELDS = {
  artifact_id = true,
  source_ref = true,
  content_ref = true,
  platform = true,
  channel = true,
  dedup_key = true,
  trace_id = true,
  approval_id = true,
  scheduled_at = true,
  metadata = true,
}

local SENSITIVE_PATTERNS = {
  "token",
  "bearer",
  "oauth",
  "secret",
  "credential",
  "password",
  "api_key",
  "apikey",
  "authorization",
  "provider_response",
  "raw_response",
}

local CONTENT_FIELDS = {
  tweet = true,
  body = true,
  text = true,
  message = true,
  media_bytes = true,
  media = true,
  raw = true,
  raw_provider_response = true,
  provider_raw_response = true,
  provider_response = true,
}

local SOURCE_REF_FIELDS = {
  kind = true,
  ref = true,
  reference = true,
  uri = true,
  version = true,
}

local METADATA_FIELDS = {
  campaign_id = true,
  content_type = true,
  interval_minutes = true,
  occurrence_id = true,
  locale = true,
  owner = true,
  schedule_type = true,
  tag = true,
  variant = true,
}

local SCALAR_TYPES = {
  boolean = true,
  number = true,
  string = true,
}

function M.persistence_class()
  return "saga"
end

function M.saga_conformance_errors()
  return {}
end

local function is_scalar(value)
  return SCALAR_TYPES[type(value)] == true
end

local function is_small_scalar(value)
  local value_type = type(value)
  if not SCALAR_TYPES[value_type] then
    return false
  end
  if value_type == "string" and #value > 512 then
    return false
  end
  return true
end

local function has_denylisted_name(key)
  local normalized = tostring(key or ""):lower()
  if CONTENT_FIELDS[normalized] then
    return true
  end
  for _, pattern in ipairs(SENSITIVE_PATTERNS) do
    if normalized:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function validate_small_table(value, allowed_fields, label)
  if type(value) ~= "table" then
    return false, "invalid " .. label
  end
  local count = 0
  for key, item in pairs(value) do
    count = count + 1
    local key_type = type(key)
    if key_type ~= "string" or allowed_fields[key] ~= true then
      return false, "unsupported " .. label .. " field"
    end
    if has_denylisted_name(key) then
      return false, "unsafe " .. label .. " field"
    end
    if not is_small_scalar(item) then
      return false, "unsafe " .. label .. " value"
    end
    if count > 12 then
      return false, label .. " too large"
    end
  end
  return true, nil
end

local function copy_allowed_scalars(source, allowed_fields)
  local safe = {}
  if type(source) ~= "table" then
    return safe
  end
  for key, value in pairs(source) do
    local allowed = allowed_fields[key] == true
    if allowed and is_small_scalar(value) then
      safe[key] = value
    end
  end
  return safe
end

local function source_ref_reference(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  local reference = source_ref.ref or source_ref.reference
  if type(reference) ~= "string" or reference == "" then
    return nil
  end
  return reference
end

local function source_ref_repo(source_ref)
  local reference = source_ref_reference(source_ref)
  if reference == nil then
    return nil
  end
  return reference:match("^([^#]+)#issue/%d+$")
end

local function normalized_platform(platform)
  if platform == nil or platform == "" then
    return "x"
  end
  local value = tostring(platform):lower()
  if value == "x" or value == "twitter" then
    return "x"
  end
  return nil
end

-- A publish request is usable only if it carries an artifact_id and a safe source_ref pointer.
-- Fail-closed: unsupported fields, content fields, or sensitive field names are rejected.
function M.validate_publish_request(payload)
  payload = payload or {}
  if type(payload) ~= "table" then
    return false, "invalid payload"
  end
  for key, _ in pairs(payload) do
    if type(key) ~= "string" or not TOP_LEVEL_FIELDS[key] then
      return false, "unsupported field"
    end
    if has_denylisted_name(key) then
      return false, "unsafe field"
    end
  end
  if type(payload.artifact_id) ~= "string" or payload.artifact_id == "" then
    return false, "missing artifact_id"
  end
  if source_ref_reference(payload.source_ref) == nil then
    return false, "missing source_ref"
  end
  local platform = normalized_platform(payload.platform)
  if not platform then
    return false, "unsupported platform"
  end
  local source_ok, source_why = validate_small_table(payload.source_ref, SOURCE_REF_FIELDS, "source_ref")
  if not source_ok then
    return false, source_why
  end
  if payload.metadata ~= nil then
    local metadata_ok, metadata_why = validate_small_table(payload.metadata, METADATA_FIELDS, "metadata")
    if not metadata_ok then
      return false, metadata_why
    end
  end
  for _, field in ipairs({ "channel", "dedup_key", "trace_id", "approval_id", "scheduled_at" }) do
    if payload[field] ~= nil and not is_small_scalar(payload[field]) then
      return false, "invalid " .. field
    end
  end
  if payload.content_ref ~= nil and not is_small_scalar(payload.content_ref) then
    return false, "invalid content_ref"
  end
  return true, nil
end

function M.is_usable_request(payload)
  return M.validate_publish_request(payload)
end

function M.preview_receipt(payload, status)
  if type(payload) ~= "table" then
    payload = {}
  end
  local source_ref = copy_allowed_scalars(payload.source_ref, SOURCE_REF_FIELDS)
  if source_ref.ref == nil and source_ref.reference ~= nil then
    source_ref.ref = source_ref.reference
  end
  if source_ref.reference == nil and source_ref.ref ~= nil then
    source_ref.reference = source_ref.ref
  end
  return {
    artifact_id = payload.artifact_id,
    platform = "x",
    status = status or "preview",
    post_uri = nil,
    source_ref = source_ref,
    content_ref = payload.content_ref,
    channel = payload.channel,
    dedup_key = payload.dedup_key,
    trace_id = payload.trace_id,
    approval_id = payload.approval_id,
    scheduled_at = payload.scheduled_at,
    metadata = copy_allowed_scalars(payload.metadata, METADATA_FIELDS),
  }
end

local function normalized_channel(payload)
  if type(payload) ~= "table" then
    return "shadow"
  end
  local channel = tostring(payload.channel or ""):lower()
  if channel == "live" then
    return "live"
  end
  local metadata = payload.metadata
  if type(metadata) == "table" and tostring(metadata.variant or ""):lower() == "live" then
    return "live"
  end
  return "shadow"
end

local function safe_service_slug(value)
  local slug = strings.trim(value)
  if slug == "" then
    return nil
  end
  if slug:find("secret://", 1, true) or slug:find("token", 1, true) then
    return nil
  end
  if not slug:match("^[%w._-]+$") then
    return nil
  end
  return slug
end

function M.live_gate(payload, opts)
  local options = opts or {}
  local service_slug = safe_service_slug(options.nyxid_x_service)
  if normalized_channel(payload) ~= "live" then
    return false, "not live"
  end
  if options.live_write_enabled ~= true then
    return false, "live gate disabled"
  end
  if service_slug == nil then
    return false, "missing nyxid x service"
  end
  return true, nil
end

function M.publish_once_key(payload)
  if type(payload) ~= "table" or type(payload.dedup_key) ~= "string" or payload.dedup_key == "" then
    return nil
  end
  local raw = payload.dedup_key
  local segment = strings.runtime_safe_segment(raw)
  local suffix = "_" .. strings.decimal_checksum(raw)
  if #segment > 160 then
    segment = segment:sub(1, 160 - #suffix) .. suffix
  end
  return "x-publisher/publish/" .. segment
end

local function metadata_tag_content_ref(payload)
  if type(payload) ~= "table" or type(payload.metadata) ~= "table" then
    return nil
  end
  local tag = tostring(payload.metadata.tag or "")
  return tag:match("^calendar:(.+)$")
end

function M.content_source_ref(payload)
  if type(payload) ~= "table" then
    return nil, "invalid payload"
  end
  local raw_ref = strings.trim(payload.content_ref or metadata_tag_content_ref(payload))
  if raw_ref == "" then
    return nil, "missing content_ref"
  end

  local direct_repo, direct_number = raw_ref:match("^([^#]+)#issue/(%d+)$")
  if direct_repo ~= nil then
    local reference = direct_repo .. "#issue/" .. direct_number
    return { kind = "external", ref = reference, reference = reference }, nil
  end

  local url_repo, url_issue = raw_ref:match("^https://github%.com/([^/]+/[^/]+)/issues/(%d+)")
  if url_repo ~= nil then
    local reference = url_repo .. "#issue/" .. url_issue
    return { kind = "external", ref = reference, reference = reference }, nil
  end

  local number = raw_ref:match("^#(%d+)$") or raw_ref:match("^(%d+)$")
  if number ~= nil then
    local repo = source_ref_repo(payload.source_ref)
    if repo == nil then
      return nil, "content_ref requires issue source_ref repo"
    end
    local reference = repo .. "#issue/" .. number
    return { kind = "external", ref = reference, reference = reference }, nil
  end

  return nil, "unsupported content_ref"
end

local TWEET_PLACEHOLDERS = {
  interval_minutes = true,
  occurrence_id = true,
  scheduled_at = true,
  schedule_type = true,
}

local function template_scalar(value)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return strings.trim(value)
  end
  return ""
end

local function tweet_placeholder_value(name, payload)
  local data = type(payload) == "table" and payload or {}
  local metadata = type(data.metadata) == "table" and data.metadata or {}
  if name == "scheduled_at" then
    return template_scalar(data.scheduled_at)
  end
  if name == "occurrence_id" then
    return template_scalar(metadata.occurrence_id or data.scheduled_at)
  end
  if name == "interval_minutes" then
    return template_scalar(metadata.interval_minutes)
  end
  if name == "schedule_type" then
    return template_scalar(metadata.schedule_type)
  end
  return ""
end

local function render_tweet_template(text, payload)
  local failure = nil
  local rendered = tostring(text or ""):gsub("{{%s*([%w_%-]+)%s*}}", function(name)
    if not TWEET_PLACEHOLDERS[name] then
      failure = "unsupported tweet placeholder"
      return ""
    end
    local value = tweet_placeholder_value(name, payload)
    if value == "" then
      failure = "missing tweet placeholder value"
      return ""
    end
    return value
  end)
  if failure ~= nil then
    return nil, failure
  end
  return rendered, nil
end

local function normalize_tweet_text(text, payload)
  local rendered, template_why = render_tweet_template(text, payload)
  if rendered == nil then
    return nil, template_why
  end
  local cleaned = strings.trim(rendered:gsub("\r\n", "\n"):gsub("\r", "\n"))
  if cleaned == "" then
    return nil, "missing tweet text"
  end
  if #cleaned > 280 then
    return nil, "tweet text too long"
  end
  return cleaned, nil
end

function M.extract_tweet_text(body, payload)
  local text = tostring(body or "")
  for _, marker in ipairs({ "tweet%-text", "tweet", "x%-post", "post" }) do
    local fenced = text:match(marker .. "%s*:%s*```[^\n]*\n(.-)\n```")
    if fenced ~= nil then
      return normalize_tweet_text(fenced, payload)
    end
  end
  for line in text:gmatch("[^\r\n]+") do
    for _, marker in ipairs({ "tweet%-text", "tweet", "x%-post", "post" }) do
      local inline = line:match("^%s*" .. marker .. "%s*:%s*(.-)%s*$")
      if inline ~= nil and strings.trim(inline) ~= "" and inline:sub(1, 3) ~= "```" then
        return normalize_tweet_text(inline, payload)
      end
    end
  end
  return nil, "missing tweet text"
end

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  return text
end

function M.tweet_body_json(text)
  return '{"text":"' .. json_escape(text) .. '"}'
end

local function decode_json(stdout)
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    return nil
  end
  local ok, decoded = pcall(json.decode, tostring(stdout or ""))
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

function M.parse_nyxid_username(stdout)
  local decoded = decode_json(stdout)
  local data = type(decoded) == "table" and decoded.data or nil
  return type(data) == "table" and data.username or nil
end

function M.parse_nyxid_tweet_id(stdout)
  local decoded = decode_json(stdout)
  local data = type(decoded) == "table" and decoded.data or nil
  local post_id = type(data) == "table" and data.id or nil
  if type(post_id) == "string" and post_id ~= "" then
    return post_id
  end
  return nil
end

function M.blocked_receipt(payload, reason)
  local receipt = M.preview_receipt(payload, "blocked")
  receipt.blocked_reason = reason
  return receipt
end

function M.live_receipt(payload, opts)
  local options = opts or {}
  local receipt = M.preview_receipt(payload, "published")
  local post_id = tostring(options.id or "")
  receipt.platform_post_id = post_id
  receipt.post_uri = post_id ~= "" and ("https://x.com/i/web/status/" .. post_id) or nil
  receipt.account_username = options.username
  receipt.nyxid_x_service = safe_service_slug(options.nyxid_x_service)
  return receipt
end

return M
