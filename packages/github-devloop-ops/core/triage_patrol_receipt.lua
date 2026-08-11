local base_ids = require("devloop.base_ids")
local dashboard_contract = require("devloop.dashboard")
local devloop_base = require("devloop.base")
local entity_view = require("devloop.github_proxy_entity_view")
local marker_shared = require("devloop.markers.shared")
local parsers_misc = require("devloop.parsers.misc")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}

local receipt_schema = "github-devloop-ops.triage-patrol-receipt.v1"
local receipt_title = "Triage patrol audit receipt"
local receipt_marker_pattern = "<!%-%- fkst:github%-devloop%-ops:triage%-patrol%-receipt:v1.-%-%->"
local receipt_body_prefix = receipt_title .. ".\n\n"

local function is_nonnegative_integer(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function is_snapshot_digest(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function is_retirable_snapshot(value)
  local snapshot = tostring(value or "")
  return is_snapshot_digest(snapshot) or snapshot:match("^%d+$") ~= nil
end

local function receipt_marker_fact(body, repo)
  local text = tostring(body or "")
  if text:sub(1, #receipt_body_prefix) ~= receipt_body_prefix then
    return nil
  end
  for marker in text:gmatch(receipt_marker_pattern) do
    local marker_repo = marker_shared.marker_attr(marker, "repo")
    local snapshot = marker_shared.marker_attr(marker, "snapshot")
    local entries = marker_shared.marker_attr(marker, "entries")
    local entry_count = tostring(entries or ""):match("^%d+$") ~= nil and tonumber(entries) or nil
    if marker_repo == base_ids.safe_repo(repo)
      and strings.is_bounded_string(snapshot, base_ids.max_dedup_len)
      and is_retirable_snapshot(snapshot)
      and is_nonnegative_integer(entry_count) then
      return {
        snapshot = snapshot,
        entries = entry_count,
      }
    end
  end
  return nil
end

local function validated_request(payload, repo)
  if type(payload) ~= "table"
    or payload.schema ~= receipt_schema
    or payload.repo ~= repo
    or base_ids.safe_repo(payload.repo) ~= payload.repo
    or payload.title ~= receipt_title
    or not is_nonnegative_integer(payload.entries) then
    error("github-devloop-ops: triage-patrol-receipt-request-invalid: invalid receipt request")
  end
  local entries = payload.entries
  if entries == 0 then
    if payload.snapshot ~= "" or payload.body ~= "" then
      error("github-devloop-ops: triage-patrol-receipt-request-invalid: empty receipt request carries content")
    end
    return payload
  end
  if not is_snapshot_digest(payload.snapshot)
    or type(payload.body) ~= "string" then
    error("github-devloop-ops: triage-patrol-receipt-request-invalid: populated receipt request is invalid")
  end
  local fact = receipt_marker_fact(payload.body, repo)
  if fact == nil or fact.snapshot ~= payload.snapshot or fact.entries ~= entries then
    error("github-devloop-ops: triage-patrol-receipt-request-invalid: receipt body marker does not match request")
  end
  return payload
end

local function list_open_receipt_state(github, repo, host_login, timeout)
  if type(github) ~= "table" or type(github.api_paginate_slurp) ~= "function" then
    error("github-devloop-ops: triage-patrol-receipt-list-port-missing: receipt reconciliation requires paginated issue listing")
  end
  local listed = github.api_paginate_slurp(
    "repos/" .. tostring(repo) .. "/issues?state=open&per_page=100",
    timeout
  )
  if type(listed) ~= "table" or listed.exit_code ~= 0 then
    error("github-devloop-ops: triage-patrol-receipt-list-failed: receipt listing failed: "
      .. tostring(listed and listed.stderr or "missing result"))
  end
  if tostring(listed.stdout or ""):match("^%s*$") then
    error("github-devloop-ops: triage-patrol-receipt-list-invalid: receipt listing returned empty output")
  end
  local ok, issues = pcall(parsers_misc.parse_dashboard_issue_list, listed.stdout)
  if not ok or type(issues) ~= "table" then
    error("github-devloop-ops: triage-patrol-receipt-list-invalid: receipt listing returned invalid JSON")
  end
  local receipts = {}
  local dashboard = nil
  local seen = {}
  for _, issue in ipairs(issues) do
    local issue_number = tonumber(issue.number)
    local fact = receipt_marker_fact(issue.body, repo)
    local trusted = parsers_misc.canonical_login(issue.author_login)
      == parsers_misc.canonical_login(host_login)
    if issue_number ~= nil
      and issue_number >= 1
      and issue_number % 1 == 0
      and trusted
      and tostring(issue.title or "") == dashboard_contract.title
      and dashboard_contract.is_anchor_body(issue.body)
      and (dashboard == nil or issue_number < dashboard.number) then
      dashboard = { number = issue_number }
    end
    if issue_number ~= nil
      and issue_number >= 1
      and issue_number % 1 == 0
      and not seen[issue_number]
      and trusted
      and fact ~= nil then
      seen[issue_number] = true
      table.insert(receipts, {
        number = issue_number,
        fact = fact,
      })
    end
  end
  table.sort(receipts, function(left, right)
    return left.number < right.number
  end)
  return dashboard, receipts
end

local function retire_receipt(github, repo, receipt, timeout)
  local closed = github.issue_close(repo, receipt.number, { kind = "not_planned" }, timeout)
  if type(closed) ~= "table" or closed.exit_code ~= 0 then
    error("github-devloop-ops: triage-patrol-receipt-close-failed: receipt close failed: "
      .. tostring(closed and closed.stderr or "missing result"))
  end
  entity_view.invalidate_entity_after_write(repo, "issue", receipt.number)
  log.info("github-devloop-ops dept=triage_patrol_receipt tag=TRIAGE_RECEIPT_RETIRED"
    .. " issue=" .. tostring(receipt.number)
    .. " snapshot=" .. tostring(receipt.fact.snapshot)
    .. " entries=" .. tostring(receipt.fact.entries))
end

local function receipt_comment_request(repo, dashboard, payload)
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = dashboard.number,
    body = payload.body,
    dedup_key = base_ids.dedup_key({
      "triage-patrol-receipt",
      repo,
      payload.snapshot,
    }),
    source_ref = base_ids.issue_source_ref(repo, dashboard.number),
  }
end

function M.install(core)
  function core.require_triage_patrol_repo()
    local repo = devloop_base.read_env("FKST_GITHUB_REPO")
    if repo == nil or base_ids.safe_repo(repo) ~= tostring(repo) then
      error("github-devloop-ops: triage-patrol-repo-invalid: FKST_GITHUB_REPO is required")
    end
    return tostring(repo)
  end

  function core.require_triage_patrol_host_login()
    local login = parsers_misc.canonical_login(parsers_misc.assert_trusted_bot_configured())
    if login == nil then
      error("github-devloop-ops: triage-patrol-bot-login-missing: FKST_GITHUB_BOT_LOGIN is required")
    end
    return login
  end

  function core.triage_patrol_snapshot_digest(identity)
    return sha256.hex(tostring(identity or ""))
  end

  function core.triage_patrol_receipt_marker(repo, snapshot, entries)
    if base_ids.safe_repo(repo) ~= repo
      or not is_snapshot_digest(snapshot)
      or not is_nonnegative_integer(entries) then
      error("github-devloop-ops: triage-patrol-receipt-marker-invalid: invalid receipt marker fields")
    end
    return '<!-- fkst:github-devloop-ops:triage-patrol-receipt:v1 repo="'
      .. repo .. '" snapshot="' .. snapshot .. '" entries="' .. tostring(entries) .. '" -->'
  end

  function core.build_triage_patrol_receipt_request(repo, rows, body)
    local entries = #(rows or {})
    if entries == 0 then
      return {
        schema = receipt_schema,
        repo = repo,
        title = receipt_title,
        snapshot = "",
        entries = 0,
        body = "",
      }
    end
    local snapshot = core.triage_patrol_snapshot_digest(body and body.identity or "")
    return validated_request({
      schema = receipt_schema,
      repo = repo,
      title = receipt_title,
      snapshot = snapshot,
      entries = entries,
      body = body and body.rendered or nil,
    }, repo)
  end

  function core.validate_triage_patrol_receipt_request(payload, repo)
    return validated_request(payload, repo)
  end

  function core.reconcile_triage_patrol_receipt(github, repo, host_login, payload, mode, timeout)
    validated_request(payload, repo)
    local dashboard, receipts = list_open_receipt_state(github, repo, host_login, timeout)
    if payload.entries > 0 and dashboard == nil then
      error("github-devloop-ops: triage-patrol-dashboard-missing: nonempty receipt requires the trusted dashboard")
    end
    if mode == "real" then
      for _, receipt in ipairs(receipts) do
        retire_receipt(github, repo, receipt, timeout)
      end
    end
    if payload.entries == 0 then
      return nil
    end
    return receipt_comment_request(repo, dashboard, payload)
  end
end

return M
