local M = {}

local strings = require("contract.strings")

-- Pure marketing-content logic for chrono-marketing. Kept in a dedicated module
-- (not the ambient package `core`) so the department requires it DIRECTLY, per the
-- devloop-decouple / service-locator conventions. All helpers are file-local and
-- exported on M at the bottom (no `M.x(` / `core.x(` self-calls).
--
-- chrono-marketing is REACTIVE: a maintainer files an OPEN `fkst-marketing`
-- content-request issue; the `generate` department drafts one content artifact
-- (codex) and posts it back as a comment through github-proxy's comment seam.

local department_label = "fkst-marketing"

local limits = {
  repo = 200,
  body = 60000,
  dedup_key = 512,
  field = 20000,
}

local channels = {
  ["social"] = true,
  ["blog"] = true,
  ["release-note"] = true,
  ["email"] = true,
}

local function department_labels()
  return { "fkst-company", department_label }
end

local function has_label(labels, name)
  if type(labels) ~= "table" then
    return false
  end
  for _, label in ipairs(labels) do
    if label == name then
      return true
    end
    if type(label) == "table" and label.name == name then
      return true
    end
  end
  return false
end

-- An OPEN issue carrying the department label is a content request this desk owns.
local function is_marketing_request(payload)
  return type(payload) == "table"
    and payload.schema == "github-proxy.v1"
    and payload.type == "issue"
    and payload.state == "OPEN"
    and has_label(payload.labels, department_label)
end

-- Normalize an entity_changed issue payload into the request the drafter consumes.
local function request_from_entity(payload)
  if not is_marketing_request(payload) then
    error("chrono-marketing: not-a-request: payload is not an open fkst-marketing issue")
  end
  if not strings.is_bounded_string(payload.repo, limits.repo) then
    error("chrono-marketing: invalid-repo: repo out of bounds")
  end
  if type(payload.number) ~= "number" then
    error("chrono-marketing: invalid-issue-number: number must be numeric")
  end
  return {
    repo = payload.repo,
    issue_number = payload.number,
    title = tostring(payload.title or ""),
    brief = tostring(payload.body or ""),
  }
end

local function build_prompt(repo, request)
  return table.concat({
    "You are a marketing content drafter for repository " .. tostring(repo) .. ".",
    "A maintainer filed an fkst-marketing content request:",
    "  issue: #" .. tostring(request.issue_number),
    "  title: " .. tostring(request.title),
    "  brief: " .. tostring(request.brief),
    "Read the repository README and CHANGELOG yourself for real product context.",
    "Do not edit files, run gh, or run git. Do not invent facts not in the checkout or brief.",
    "Draft ONE truthful, concise artifact free of secrets or internal-only details.",
    "Return strict JSON only: a single object, no prose, no code fences.",
    'Object schema: {"title":"...","channel":"social|blog|release-note|email",'
      .. '"body_markdown":"...","image_prompt":"..."}',
  }, "\n")
end

local function parse_content(stdout)
  local raw = strings.trim(stdout or "")
  if raw:sub(1, 1) ~= "{" or raw:sub(-1) ~= "}" then
    error("chrono-marketing: malformed-json: codex output is not a JSON object")
  end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    error("chrono-marketing: malformed-json: codex output is malformed JSON")
  end
  if not strings.is_bounded_string(decoded.title, limits.field) then
    error("chrono-marketing: invalid-title: content title missing or too long")
  end
  if type(decoded.channel) ~= "string" or not channels[decoded.channel] then
    error("chrono-marketing: invalid-channel: unsupported content channel")
  end
  if not strings.is_bounded_string(decoded.body_markdown, limits.field) then
    error("chrono-marketing: invalid-body: content body missing or too long")
  end
  local image_prompt = decoded.image_prompt
  if image_prompt ~= nil and not strings.is_bounded_string(image_prompt, limits.field) then
    error("chrono-marketing: invalid-image-prompt: image prompt too long")
  end
  return {
    title = decoded.title,
    channel = decoded.channel,
    body_markdown = decoded.body_markdown,
    image_prompt = image_prompt,
  }
end

local function content_dedup_key(request, content)
  local seed = table.concat({
    tostring(request.repo),
    tostring(request.issue_number),
    tostring(content.channel),
  }, "|")
  local readable = table.concat({
    "chrono-marketing",
    strings.sanitize_key(request.repo, 120),
    tostring(request.issue_number),
    strings.decimal_checksum(seed),
  }, "/")
  return readable:sub(1, limits.dedup_key)
end

local function comment_markdown(content, dedup_key)
  local lines = {
    "Drafted by the fkst company marketing department.",
    "",
    "**Channel:** " .. tostring(content.channel),
    "**Title:** " .. tostring(content.title),
    "",
    content.body_markdown,
  }
  if content.image_prompt ~= nil and content.image_prompt ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "**Suggested image prompt:** " .. tostring(content.image_prompt)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<!-- fkst:chrono-marketing:draft:v1 " .. dedup_key .. " -->"
  return table.concat(lines, "\n")
end

-- Map a validated request + drafted content into a github-proxy comment request.
local function comment_request(request, content)
  local dedup_key = content_dedup_key(request, content)
  local body = comment_markdown(content, dedup_key)
  if not strings.is_bounded_string(body, limits.body) then
    error("chrono-marketing: invalid-comment: comment body out of bounds")
  end
  return {
    schema = "github-proxy.v1",
    repo = tostring(request.repo),
    issue_number = request.issue_number,
    body = body,
    dedup_key = dedup_key,
    source_ref = {
      kind = "repo-site",
      ref = (tostring(request.repo) .. "#issue/" .. tostring(request.issue_number)
        .. "#chrono-marketing"):sub(1, limits.repo),
    },
  }
end

M.department_labels = department_labels
M.is_marketing_request = is_marketing_request
M.request_from_entity = request_from_entity
M.build_prompt = build_prompt
M.parse_content = parse_content
M.dedup_key = content_dedup_key
M.comment_request = comment_request

return M
