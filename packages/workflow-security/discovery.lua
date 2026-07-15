-- workflow-security: the platform.discovery + platform.lease seams.
--
-- All GitHub boundary reads for the reconcile loop live here, taken from the
-- injected github port (never _G). Review state is carried entirely by the
-- adapter's own marker namespace (fkst:workflow-security) on the review issue, so a
-- co-resident adapter's markers are never read. Marker parsing is delegated to the
-- kernel's namespace-bound marker table; this module only fetches issue text and
-- shapes the discovery scope handles the kernel reconcile expects.
--
-- Bounded-confidence note: the GitHub read wiring (issue_search / issue_view field
-- shapes) mirrors the archaudit + issue_reads production adapters and is exercised
-- in CI; every call is defensive (pcall + validate) so a transient read yields an
-- empty/again decision, never a crash.
local M = {}

local SEARCH_FIELDS = "number,title,state,author,body,url"
local VIEW_FIELDS = "number,title,state,body,comments,author,url"
local SEARCH_LIMIT = 30
local VIEW_TIMEOUT = 30

local function decode_json(text)
  local ok, decoded = pcall(json.decode, tostring(text or ""))
  if not ok then
    return nil
  end
  return decoded
end

local function trusted_comment_text(issue, bot_login)
  local parts = { tostring(issue.body or "") }
  local comments = issue.comments
  if type(comments) == "table" then
    for _, comment in ipairs(comments) do
      if type(comment) == "table" then
        local login = type(comment.author) == "table" and comment.author.login or comment.author_login
        if bot_login == nil or bot_login == "" or tostring(login or "") == tostring(bot_login) then
          table.insert(parts, tostring(comment.body or ""))
        end
      end
    end
  end
  return table.concat(parts, "\n")
end

local function open_state(value)
  return tostring(value or ""):upper() == "OPEN"
end

-- Attach a durable result descriptor to a created materialization fact so the
-- completion reader can map it. A created marker is only ever written by the
-- executor AFTER a codex step's output validated, so "created" == "ready".
local function decorate_created(fact)
  if type(fact) == "table" and fact.state == "created" then
    fact.child_ref = {
      kind = "analysis",
      slot = fact.slot,
      child_issue = fact.child_issue,
      result = { state = "ready" },
    }
  end
  return fact
end

-- deps = { github, repo, marker, bot_login }
function M.build(deps)
  local github = deps.github
  local repo = deps.repo
  local marker = deps.marker
  local bot_login = deps.bot_login

  local function fetch_issue(number)
    if type(github) ~= "table" or type(github.issue_view) ~= "function" then
      return nil
    end
    local ok, result = pcall(github.issue_view, repo, number, VIEW_FIELDS, VIEW_TIMEOUT)
    if not ok or type(result) ~= "table" or result.exit_code ~= 0 then
      return nil
    end
    return decode_json(result.stdout)
  end

  local discovery = {}

  function discovery.list_scopes(_ctx)
    if type(github) ~= "table" or type(github.issue_search) ~= "function" then
      return {}
    end
    local ok, result = pcall(github.issue_search, repo, "label:" .. tostring(deps.label or "fkst-security"), SEARCH_FIELDS, SEARCH_LIMIT)
    if not ok or type(result) ~= "table" or result.exit_code ~= 0 then
      return {}
    end
    local issues = decode_json(result.stdout)
    if type(issues) ~= "table" then
      return {}
    end
    local scopes = {}
    for _, issue in ipairs(issues) do
      if type(issue) == "table" and issue.number ~= nil and open_state(issue.state) then
        local full = fetch_issue(issue.number) or issue
        table.insert(scopes, {
          number = issue.number,
          repo = repo,
          origin = "issue/" .. tostring(issue.number),
          state = issue.state,
          text = trusted_comment_text(full, bot_login),
        })
      end
    end
    return scopes
  end

  function discovery.origin_of(scope)
    return scope.origin
  end

  function discovery.read_current(scope)
    return { state = scope.state }
  end

  function discovery.latest_terminal(scope, _current, origin)
    return marker.parse_terminal_marker(scope.text, origin)
  end

  function discovery.latest_blueprint(scope, _current, origin)
    return marker.parse_blueprint_marker(scope.text, origin)
  end

  function discovery.materialization_facts(scope, _current, origin)
    local facts = marker.parse_materialization_markers(scope.text, origin)
    for _, fact in ipairs(facts or {}) do
      decorate_created(fact)
    end
    return facts
  end

  function discovery.ledger_for_frontier(_scope, facts)
    return facts
  end

  function discovery.log_decision(scope, origin, from_state, to_state, outcome, reason)
    if type(log) == "table" and type(log.info) == "function" then
      log.info("workflow-security dept=discovery scope=" .. tostring(scope.origin or origin)
        .. " from=" .. tostring(from_state) .. " to=" .. tostring(to_state)
        .. " outcome=" .. tostring(outcome) .. " reason=" .. tostring(reason))
    end
  end

  -- The lease seam. This adapter files findings as fresh issues (never mutates a
  -- foreign artifact), so the claim is simply "the review issue carries our label";
  -- issue_search already filtered to that label, so a listed scope is self-held.
  local lease = {}
  function lease.verify_claim(_scope, _origin)
    return true
  end
  function lease.close_done_origin(_scope, _origin)
    return nil
  end

  return discovery, lease
end

return M
