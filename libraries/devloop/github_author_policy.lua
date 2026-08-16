local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local content_filter = require("forge.github.content_filter")
local config = require("devloop.config")
local entity_list_cache = require("devloop.entity_list_cache")
local marker_shared = require("devloop.markers.shared")
local parsers_misc = require("devloop.parsers.misc")
local restart_metadata = require("devloop.restart_metadata")

local M = {}

local function resolve_github_handle(github_handle)
  if type(github_handle) == "function" then
    local ok, resolved = pcall(github_handle)
    if ok then
      return resolved
    end
    return nil
  end
  return github_handle
end

-- Single source for the claim owner: normalize every configured bot transport
-- spelling to the bare slug before it enters ownership decisions.
function M.claim_owner()
  return parsers_misc.canonical_login(parsers_misc.assert_trusted_bot_configured() or parsers_misc.trusted_bot_login())
end

function M.managed_bot_logins(exec)
  local raw = devloop_base.read_env("FKST_DEVLOOP_MANAGED_BOT_LOGINS", exec)
  local logins = {}
  for entry in tostring(raw or ""):gmatch("[^,%s]+") do
    local login = parsers_misc.canonical_login(entry)
    if login ~= nil and login ~= "" then
      logins[login] = true
    end
  end
  return logins
end

function M.is_managed_bot_login(login, managed)
  local normalized = parsers_misc.canonical_login(login)
  return normalized ~= nil and normalized ~= "" and type(managed) == "table" and managed[normalized] == true
end

function M.from_logins(logins)
  return content_filter.author_policy_from_logins(logins or {})
end

local function from_env(exec, github_handle)
  local resolved_handle = resolve_github_handle(github_handle)
  local bot_login = nil
  if type(parsers_misc.configured_trusted_bot_login) == "function" then
    bot_login = parsers_misc.configured_trusted_bot_login()
  end
  if bot_login == nil or tostring(bot_login or "") == "" then
    local ok_bot = true
    ok_bot, bot_login = pcall(devloop_base.read_env, "FKST_GITHUB_BOT_LOGIN", exec)
    bot_login = ok_bot and strings.trim(bot_login or "") or ""
  end
  if bot_login == "" then
    error("devloop.github_author_policy: bot-login-missing: FKST_GITHUB_BOT_LOGIN is required for authored GitHub reads")
  end
  return content_filter.author_policy_from_options({
    owner = "devloop.github_author_policy",
    read_env = function(name)
      return devloop_base.read_env(name, exec)
    end,
    bot_login = bot_login,
    bot_login_env = "FKST_GITHUB_BOT_LOGIN",
    extra_login_envs = {
      "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
      "FKST_GITHUB_AUTHORIZED_LOGINS",
    },
    github_handle = resolved_handle,
  })
end

function M.from_handle_policy(github_handle)
  local resolved_handle = resolve_github_handle(github_handle)
  if type(resolved_handle) == "table" and type(resolved_handle._trusted_author_policy) == "function" then
    return resolved_handle._trusted_author_policy()
  end
  return from_env(nil, resolved_handle)
end

function M.is_authorized(policy, login)
  return content_filter.is_authorized(login, content_filter.policy_whitelist(policy))
end

local state_marker_pattern = marker_shared.STATE_MARKER_PATTERN
local marker_attr = marker_shared.marker_attr
local json_array_tag = nil
local json_object_tag = nil
local json_tags_initialized = false
local peer_activity_scan_limit = 100
local peer_activity_queries = {
  issue = {
    scope = "peer-activity-v1-all-limit-100-number-comments-author",
    fields = "number,comments,author",
  },
  pr = {
    scope = "peer-activity-v1-all-limit-100-number-headRefName-baseRefName-comments-author",
    fields = "number,headRefName,baseRefName,comments,author",
  },
}

local function initialize_json_tags()
  if not json_tags_initialized then
    json_array_tag = getmetatable(json.decode("[]"))
    json_object_tag = getmetatable(json.decode("{}"))
    json_tags_initialized = true
  end
end

local function is_dense_json_array(value)
  initialize_json_tags()
  if type(value) ~= "table" or getmetatable(value) ~= json_array_tag then
    return false
  end
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return count == maximum
end

local function is_json_object(value)
  initialize_json_tags()
  return type(value) == "table" and getmetatable(value) == json_object_tag
end

local function is_positive_integer(value)
  return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function valid_actor(value)
  return is_json_object(value) and type(value.login) == "string" and value.login ~= ""
end

local function valid_optional_actor(value)
  return value == nil or type(value) == "userdata" or valid_actor(value)
end

local function valid_comments(value)
  if not is_dense_json_array(value) then
    return false
  end
  for _, comment in ipairs(value) do
    if not is_json_object(comment) or type(comment.body) ~= "string" or not valid_optional_actor(comment.author) then
      return false
    end
  end
  return true
end

local function valid_peer_activity_row(row, kind)
  if not is_json_object(row) or not is_positive_integer(row.number)
    or not valid_comments(row.comments) or not valid_optional_actor(row.author) then
    return false
  end
  if kind == "pr" then
    return type(row.headRefName) == "string" and row.headRefName ~= ""
      and type(row.baseRefName) == "string" and row.baseRefName ~= ""
  end
  return kind == "issue"
end

local function decode_json_array(result, kind)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return nil, "command-result-unavailable"
  end
  if type(result.stdout) ~= "string" then
    return nil, "stdout-not-string"
  end
  local ok, decoded = pcall(json.decode, result.stdout)
  if not ok then
    return nil, "malformed-json"
  end
  if not is_dense_json_array(decoded) then
    return nil, "top-level-not-dense-array"
  end
  for _, row in ipairs(decoded) do
    if not valid_peer_activity_row(row, kind) then
      return nil, "invalid-" .. tostring(kind) .. "-row"
    end
  end
  return decoded, nil
end

local function comment_body(comment)
  if type(comment) == "table" and comment.body ~= nil then
    return tostring(comment.body)
  end
  return nil
end

local function github_actor_login(value)
  if type(value) ~= "table" then
    return nil
  end
  local seen = {}
  local only = nil
  local function add(login)
    local normalized = parsers_misc.canonical_login(login)
    if normalized == nil or normalized == "" then
      return
    end
    seen[normalized] = true
    only = normalized
  end
  add(value.author_login)
  if type(value.author) == "table" then
    add(value.author.login)
  end
  if type(value.user) == "table" then
    add(value.user.login)
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  if count ~= 1 then
    return nil
  end
  return only
end

local function has_state_marker_comment(body)
  if type(body) ~= "string" then
    return false
  end
  for marker in body:gmatch(state_marker_pattern) do
    if marker_attr(marker, "proposal") ~= nil
      and restart_metadata.is_state(marker_attr(marker, "state"))
      and marker_attr(marker, "version") ~= nil then
      return true
    end
  end
  return false
end

local function add_authorized_candidate(logins, login, trusted_author_policy, owner)
  if type(logins) ~= "table" or type(trusted_author_policy) ~= "table" then
    return
  end
  local normalized = parsers_misc.canonical_login(login)
  local normalized_owner = parsers_misc.canonical_login(owner)
  if normalized ~= nil and normalized ~= "" and normalized ~= normalized_owner
    and M.is_authorized(trusted_author_policy, normalized) then
    logins[normalized] = true
  end
end

local function add_state_marker_comment_candidates(logins, comments, trusted_author_policy, owner)
  if type(comments) ~= "table" then
    return
  end
  for _, comment in ipairs(comments) do
    local body = comment_body(comment)
    if has_state_marker_comment(body) then
      add_authorized_candidate(logins, github_actor_login(comment), trusted_author_policy, owner)
    end
  end
end

function M.observed_state_marker_managed_bot_logins(current, trusted_author_policy, owner)
  local logins = {}
  if type(current) ~= "table" or type(current.comments) ~= "table" or type(trusted_author_policy) ~= "table" then
    return logins
  end
  add_state_marker_comment_candidates(logins, current.comments, trusted_author_policy, owner)
  return logins
end

local function issue_row_comments(row)
  if type(row) ~= "table" or type(row.comments) ~= "table" then
    return {}
  end
  return row.comments
end

local function pr_head_branch(row)
  if type(row) ~= "table" then
    return nil
  end
  if row.headRefName ~= nil then
    return tostring(row.headRefName)
  end
  if type(row.head) == "table" and row.head.ref ~= nil then
    return tostring(row.head.ref)
  end
  return nil
end

local function pr_base_branch(row)
  if type(row) ~= "table" then
    return nil
  end
  if row.baseRefName ~= nil then
    return tostring(row.baseRefName)
  end
  if type(row.base) == "table" and row.base.ref ~= nil then
    return tostring(row.base.ref)
  end
  return nil
end

function M.repo_scoped_observed_managed_bot_logins(repo, trusted_author_policy, owner, github_handle, poll_key)
  local logins = {}
  if not entity_list_cache.poll_epoch_is_current(repo, poll_key) then
    return nil, "peer-activity-stale-poll-epoch"
  end
  local issue_query = peer_activity_queries.issue
  local issues = entity_list_cache.fetch_shared_settled_list(
    repo,
    "issue",
    issue_query.scope,
    poll_key,
    function()
      return github_handle.issue_list_cli(repo, "all", peer_activity_scan_limit, issue_query.fields, 30)
    end,
    function(result)
      local rows, reason = decode_json_array(result, "issue")
      return rows ~= nil, reason
    end
  )
  local issue_rows = issues.tag == "available" and decode_json_array({
    stdout = issues.stdout,
    exit_code = 0,
  }, "issue") or nil
  if issue_rows == nil then
    return nil, "issue-peer-activity-unavailable"
  end
  if not entity_list_cache.poll_epoch_is_current(repo, poll_key) then
    return nil, "peer-activity-stale-poll-epoch"
  end
  for _, row in ipairs(issue_rows) do
    add_state_marker_comment_candidates(logins, issue_row_comments(row), trusted_author_policy, owner)
  end

  local ok_config, branches = pcall(config.branch_config)
  local upstream = ok_config and branches and branches.upstream or nil
  local integration = ok_config and branches and branches.integration or nil
  if upstream == nil or tostring(upstream) == "" or integration == nil or tostring(integration) == "" then
    return logins
  end
  local pr_query = peer_activity_queries.pr
  local prs = entity_list_cache.fetch_shared_settled_list(
    repo,
    "pr",
    pr_query.scope,
    poll_key,
    function()
      return github_handle.pr_list_cli(repo, "all", peer_activity_scan_limit, pr_query.fields, 30)
    end,
    function(result)
      local rows, reason = decode_json_array(result, "pr")
      return rows ~= nil, reason
    end
  )
  local pr_rows = prs.tag == "available" and decode_json_array({
    stdout = prs.stdout,
    exit_code = 0,
  }, "pr") or nil
  if pr_rows == nil then
    return nil, "pr-peer-activity-unavailable"
  end
  if not entity_list_cache.poll_epoch_is_current(repo, poll_key) then
    return nil, "peer-activity-stale-poll-epoch"
  end
  for _, row in ipairs(pr_rows) do
    add_state_marker_comment_candidates(logins, issue_row_comments(row), trusted_author_policy, owner)
    if pr_base_branch(row) == tostring(upstream) and pr_head_branch(row) == tostring(integration) then
      add_authorized_candidate(logins, github_actor_login(row), trusted_author_policy, owner)
    end
  end
  return logins
end

local function for_exec(exec, github_handle)
  return from_env(exec, github_handle)
end

function M.github_options(exec)
  local policy = nil
  return {
    trusted_author_policy = function(github_handle)
      if policy == nil then
        policy = for_exec(exec, github_handle)
      end
      return policy
    end,
  }
end

return M
