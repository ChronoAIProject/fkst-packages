local content = require("content_logic")
local codex = require("workflow.codex")
local saga = require("workflow.saga")

-- Thin reactive marketing department: an OPEN `fkst-marketing` content-request
-- issue (surfaced by github-proxy's entity poll) drives one codex content draft,
-- posted back as a comment through github-proxy's comment seam. No gh/git; the
-- repo comes from the entity payload and the pure logic lives in `content_logic`,
-- required directly (not via ambient core).
local spec = {
  consumes = { "github-proxy.github_entity_changed" },
  produces = { "github-proxy.github_issue_comment_request" },
  fanout = { "github-proxy.github_entity_changed" },
  stall_window = "10m",
  retry = false,
}

local codex_timeout_seconds = 30 * 60

local function accept(event)
  return content.is_marketing_request(event.payload or {})
end

local function generate_done(_event)
  return false
end

local function run_draft(repo, request)
  local opts = codex.judgment_codex_opts(content.build_prompt(repo, request), ".")
  opts.timeout = codex_timeout_seconds
  local result = spawn_codex_sync(opts)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    local code = type(result) == "table" and tonumber(result.exit_code) or nil
    if code == 124 then
      error("chrono-marketing: codex-timeout: codex timeout", 0)
    end
    error("chrono-marketing: codex-nonzero: codex nonzero exit", 0)
  end
  return content.parse_content(result.stdout)
end

local function generate_act(event)
  local request = content.request_from_entity(event.payload or {})
  local drafted = run_draft(request.repo, request)
  raise("github-proxy.github_issue_comment_request", content.comment_request(request, drafted))
end

return saga.department(spec, {
  accept = accept,
  done = generate_done,
  act = generate_act,
  name = "generate",
})
