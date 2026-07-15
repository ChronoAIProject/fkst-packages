-- workflow-writer: the platform.discovery + platform.lease seams.
--
-- All GitHub boundary reads for the reconcile loop live here, taken from the injected
-- github port (never _G). Authoring state is carried entirely by the adapter's own
-- marker namespace (fkst:workflow-writer) on the request issue, so a co-resident
-- adapter's markers are never read. Marker parsing is delegated to the kernel's
-- namespace-bound marker table; this module only fetches issue text + the delivered
-- PR's lifecycle state and shapes the discovery scope handles the kernel reconcile
-- expects.
--
-- Bounded-confidence note: the GitHub read wiring (issue_search / issue_view / pr_cli_view
-- field shapes) mirrors the security + archaudit production adapters and is exercised in
-- CI; every call is defensive (pcall + validate) so a transient read yields an
-- empty/again decision (a safe wait), never a crash.
local M = {}

local SEARCH_FIELDS = "number,title,state,author,body,url"
local VIEW_FIELDS = "number,title,state,body,comments,author,url"
local PR_FIELDS = "state,mergedAt,merged"
local SEARCH_LIMIT = 30
local VIEW_TIMEOUT = 30

local function parse_json_text(text)
  local ok, decoded = pcall(json.decode, tostring(text or ""))
  if ok then
    return decoded
  end
  return nil
end

local function collect_trusted_text(issue, bot_login)
  local segments = {}
  segments[#segments + 1] = tostring(issue.body or "")
  local comments = issue.comments
  if type(comments) == "table" then
    for _, comment in ipairs(comments) do
      if type(comment) == "table" then
        local login = type(comment.author) == "table" and comment.author.login or comment.author_login
        local trusted = bot_login == nil or bot_login == "" or tostring(login or "") == tostring(bot_login)
        if trusted then
          segments[#segments + 1] = tostring(comment.body or "")
        end
      end
    end
  end
  return table.concat(segments, "\n")
end

local function open_issue(value)
  return tostring(value or ""):upper() == "OPEN"
end

-- Map a decoded PR-view payload to the durable result.state the completion reader maps.
-- A merged PR means the authored template landed (result_ready); an open PR is still
-- running; a closed-unmerged PR is a fatal dead end. A nil payload is a transient read.
local function pr_state_of(payload)
  if type(payload) ~= "table" then
    return "transient"
  end
  local merged_at = payload.mergedAt or payload.merged_at
  if payload.merged == true or (type(merged_at) == "string" and merged_at ~= "") then
    return "merged"
  end
  local state = tostring(payload.state or ""):upper()
  if state == "OPEN" then
    return "open"
  end
  return "invalid"
end

-- deps = { github, repo, marker, bot_login }
function M.build(deps)
  local github = deps.github
  local repo = deps.repo
  local marker = deps.marker
  local bot_login = deps.bot_login

  local function read_issue(number)
    if type(github) ~= "table" or type(github.issue_view) ~= "function" then
      return nil
    end
    local ok, result = pcall(github.issue_view, repo, number, VIEW_FIELDS, VIEW_TIMEOUT)
    if not ok or type(result) ~= "table" or result.exit_code ~= 0 then
      return nil
    end
    return parse_json_text(result.stdout)
  end

  local function read_pr_state(pr_ref)
    local pr_number = tonumber(pr_ref)
    if pr_number == nil or type(github) ~= "table" or type(github.pr_cli_view) ~= "function" then
      return "transient"
    end
    local ok, result = pcall(github.pr_cli_view, repo, pr_number, PR_FIELDS, VIEW_TIMEOUT)
    if not ok or type(result) ~= "table" or result.exit_code ~= 0 then
      return "transient"
    end
    return pr_state_of(parse_json_text(result.stdout))
  end

  -- A created marker records the delivered PR (its number in child_issue). The child_ref
  -- result is resolved live from the PR's lifecycle so the completion reader reflects
  -- whether the template actually landed, not merely that a PR was opened.
  local function attach_pr_result(fact)
    if type(fact) == "table" and fact.state == "created" then
      fact.child_ref = {
        kind = "authoring-pr",
        slot = fact.slot,
        child_issue = fact.child_issue,
        result = { state = read_pr_state(fact.child_issue) },
      }
    end
    return fact
  end

  local discovery = {}

  function discovery.list_scopes(_ctx)
    if type(github) ~= "table" or type(github.issue_search) ~= "function" then
      return {}
    end
    local ok, result = pcall(github.issue_search, repo, "label:" .. tostring(deps.label or "fkst-workflow"), SEARCH_FIELDS, SEARCH_LIMIT)
    if not ok or type(result) ~= "table" or result.exit_code ~= 0 then
      return {}
    end
    local issues = parse_json_text(result.stdout)
    if type(issues) ~= "table" then
      return {}
    end
    local scopes = {}
    for _, issue in ipairs(issues) do
      if type(issue) == "table" and issue.number ~= nil and open_issue(issue.state) then
        local full = read_issue(issue.number) or issue
        scopes[#scopes + 1] = {
          number = issue.number,
          repo = repo,
          origin = "issue/" .. tostring(issue.number),
          state = issue.state,
          text = collect_trusted_text(full, bot_login),
        }
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
      attach_pr_result(fact)
    end
    return facts
  end

  function discovery.ledger_for_frontier(_scope, facts)
    return facts
  end

  function discovery.log_decision(scope, origin, from_state, to_state, outcome, reason)
    if type(log) == "table" and type(log.info) == "function" then
      log.info("workflow-writer dept=discovery scope=" .. tostring(scope.origin or origin)
        .. " from=" .. tostring(from_state) .. " to=" .. tostring(to_state)
        .. " outcome=" .. tostring(outcome) .. " reason=" .. tostring(reason))
    end
  end

  -- The lease seam. This adapter delivers a fresh PR (never mutates a foreign artifact),
  -- so the claim is simply "the request issue carries our label"; issue_search already
  -- filtered to that label, so a listed scope is self-held.
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
