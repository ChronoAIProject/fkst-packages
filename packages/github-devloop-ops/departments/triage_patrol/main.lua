local base_ids = require("devloop.base_ids")
local core = require("core")
local devloop_base = require("devloop.base")
local github_author_policy = require("devloop.github_author_policy")
local github_issue_create = require("contract.github_issue_create")
local parsers_issue = require("devloop.parsers.issue")
local parsers_misc = require("devloop.parsers.misc")
local ports = require("forge.ports")
local request_shared = require("devloop.requests.shared")
local saga = require("workflow.saga")
local strings = require("contract.strings")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")

local spec = {
  consumes = { "devloop_triage_patrol_tick" },
  produces = { "github-proxy.github_issue_create_request" },
  stall_window = "10m",
}

local admitted_states = {
  declined = true,
  dependency_wait = true,
}

local function require_repo()
  local repo = devloop_base.read_env("FKST_GITHUB_REPO")
  if repo == nil or base_ids.safe_repo(repo) ~= tostring(repo) then
    error("github-devloop-ops: triage-patrol-repo-invalid: FKST_GITHUB_REPO is required")
  end
  return tostring(repo)
end

local function require_host_login()
  local login = parsers_misc.canonical_login(parsers_misc.assert_trusted_bot_configured())
  if login == nil then
    error("github-devloop-ops: triage-patrol-bot-login-missing: FKST_GITHUB_BOT_LOGIN is required")
  end
  return login
end

local function candidate_labels()
  local labels = {}
  local seen = {}
  local function add(label)
    if label ~= nil and not seen[label] then
      seen[label] = true
      table.insert(labels, label)
    end
  end
  add(core._enabled_label)
  add(core._hold_label)
  for _, state in ipairs(devloop_state.lifecycle_state_order()) do
    add(devloop_state.state_label(state))
  end
  return labels
end

local function list_candidates(github, repo, limits, rotation_seed, candidate_cap)
  local listed = {}
  for _, label in ipairs(candidate_labels()) do
    local result = github.issue_list_observe(repo, label, 1, false, limits.call_timeout)
    if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
      error("github-devloop-ops: triage-patrol-candidate-list-failed: GitHub issue candidate list failed")
    end
    for _, issue in ipairs(parsers_issue.parse_issue_list_observe(result.stdout)) do
      table.insert(listed, issue)
    end
  end
  local numbers = core.observability_sorted_numbers(listed)
  local candidates, deferred = core.observability_entity_candidates(
    numbers,
    {},
    rotation_seed,
    candidate_cap
  )
  return candidates, deferred, #numbers
end

local function authorized_marker_trust_set(comments, policy)
  local trust_set = {}
  for _, comment in ipairs(comments or {}) do
    local login = parsers_misc.canonical_login(parsers_misc._comment_author_login(comment))
    if login ~= nil and github_author_policy.is_authorized(policy, login) then
      trust_set[login] = true
    end
  end
  return trust_set
end

local function admitted_row(github, policy, repo, host_login, candidate, limits)
  local issue_number = tonumber(candidate and candidate.number)
  if issue_number == nil or issue_number < 1 or issue_number % 1 ~= 0 then
    error("github-devloop-ops: triage-patrol-candidate-invalid: candidate issue number is invalid")
  end
  local proposal_id = base_ids.proposal_id(repo, issue_number)
  local issue = github.read_issue(base_ids.issue_source_ref(repo, issue_number), {
    consumer = "triage_patrol",
    force_fresh = true,
    cache_write = false,
    timeout = limits.call_timeout,
  })
  local current = devloop_state.current_state_fact(
    issue.comments,
    proposal_id,
    authorized_marker_trust_set(issue.comments, policy)
  )
  if parsers_misc.canonical_login(current.author_login) ~= parsers_misc.canonical_login(host_login)
    or not admitted_states[current.state] then
    return nil
  end
  if not strings.is_bounded_string(current.version, base_ids.max_dedup_len) then
    error("github-devloop-ops: triage-patrol-marker-version-invalid: admitted marker version is missing or unbounded")
  end
  if not strings.is_bounded_string(current.author_login, base_ids.max_key_len) then
    error("github-devloop-ops: triage-patrol-marker-author-invalid: admitted marker author is missing or unbounded")
  end
  return {
    proposal_id = proposal_id,
    issue_number = issue_number,
    state = current.state,
    version = current.version,
    marker_author = current.author_login,
    verdict = "abstain",
  }
end

local function encoded_field(value)
  local text = tostring(value or "")
  return tostring(#text) .. ":" .. text
end

local function snapshot_tuple(row)
  return table.concat({
    encoded_field(row.proposal_id),
    encoded_field(row.state),
    encoded_field(row.version),
    encoded_field(row.verdict),
  }, "|")
end

local function collect_snapshot(github, repo, host_login, candidates, limits)
  local rows = {}
  local policy = github_author_policy.from_handle_policy(github)
  for _, candidate in ipairs(candidates or {}) do
    local row = admitted_row(github, policy, repo, host_login, candidate, limits)
    if row ~= nil then
      table.insert(rows, row)
    end
  end
  table.sort(rows, function(left, right)
    return snapshot_tuple(left) < snapshot_tuple(right)
  end)
  return rows
end

local function snapshot_identity(rows)
  local tuples = {}
  for _, row in ipairs(rows or {}) do
    table.insert(tuples, snapshot_tuple(row))
  end
  return table.concat(tuples, "\n")
end

local function display_field(value)
  return devloop_base.neutralize_untrusted_comment_text(tostring(value or ""))
    :gsub("`", "'")
    :gsub("[\r\n]+", " ")
end

local function render_receipt_body(repo, rows, snapshot_digest)
  local lines = {
    "Triage patrol audit receipt.",
    "",
    '<!-- fkst:github-devloop-ops:triage-patrol-receipt:v1 repo="'
      .. base_ids.safe_repo(repo)
      .. '" snapshot="' .. snapshot_digest
      .. '" entries="' .. tostring(#rows) .. '" -->',
    "",
    "Entries:",
    "Fields: p=proposal_id i=issue s=state v=version a=marker_author",
  }
  if #rows == 0 then
    table.insert(lines, "- none")
  else
    for _, row in ipairs(rows) do
      table.insert(lines, "- `p=" .. display_field(row.proposal_id)
        .. " i=" .. tostring(row.issue_number)
        .. " s=" .. tostring(row.state)
        .. " v=" .. display_field(row.version)
        .. " a=" .. display_field(row.marker_author)
        .. " verdict=" .. tostring(row.verdict) .. "`")
    end
  end
  table.insert(lines, "")
  table.insert(lines, request_shared.ai_sentinel)
  return table.concat(lines, "\n")
end

local function receipt_body(repo, rows, snapshot_digest)
  local body = render_receipt_body(repo, rows, snapshot_digest)
  if #body > github_issue_create.limits().body then
    error("github-devloop-ops: triage-patrol-receipt-too-large: bounded patrol receipt exceeds issue-create contract")
  end
  return body
end

local function longest_admitted_state()
  local longest = ""
  for state in pairs(admitted_states) do
    if #state > #longest then
      longest = state
    end
  end
  return longest
end

local function maximally_expanding_display_input(limit)
  local marker_prefix = "<!-- fkst:"
  local repeats = math.floor(limit / #marker_prefix)
  return marker_prefix:rep(repeats) .. string.rep("x", limit % #marker_prefix)
end

local function worst_case_receipt_row(repo)
  local max_issue = string.rep("9", base_ids.max_issue_key_len)
  return {
    proposal_id = base_ids.proposal_id(repo, max_issue),
    issue_number = max_issue,
    state = longest_admitted_state(),
    version = maximally_expanding_display_input(base_ids.max_dedup_len),
    marker_author = string.rep("a", base_ids.max_key_len),
    verdict = "abstain",
  }
end

local function receipt_candidate_cap(repo, entity_cap)
  local rows = {}
  local worst_case_row = worst_case_receipt_row(repo)
  for _ = 1, entity_cap do
    table.insert(rows, worst_case_row)
    local digest = strings.decimal_checksum(snapshot_identity(rows))
    if #render_receipt_body(repo, rows, digest) > github_issue_create.limits().body then
      local cap = #rows - 1
      if cap < 1 then
        error("github-devloop-ops: triage-patrol-receipt-contract-impossible: one bounded row exceeds issue-create contract")
      end
      return cap
    end
  end
  return entity_cap
end

local function log_deferred_candidates(listed, selected, deferred, entity_cap, receipt_cap)
  if deferred < 1 then
    return
  end
  log.warn(table.concat({
    "github-devloop-ops",
    "dept=triage_patrol",
    "tag=OBSERVE_DEFERRED",
    "reason=receipt-body-cap",
    "listed_issues=" .. tostring(listed),
    "processed_issues=" .. tostring(selected),
    "deferred_issues=" .. tostring(deferred),
    "entity_cap=" .. tostring(entity_cap),
    "receipt_cap=" .. tostring(receipt_cap),
  }, " "))
end

local function receipt_request(repo, rows)
  local snapshot_digest = strings.decimal_checksum(snapshot_identity(rows))
  local receipt_key = base_ids.dedup_key({
    "triage-patrol-receipt",
    base_ids.safe_repo(repo),
    snapshot_digest,
  })
  return {
    schema = "github-proxy.issue-create.v1",
    repo = repo,
    title = "Triage patrol abstain receipt",
    body = receipt_body(repo, rows, snapshot_digest),
    labels = json.decode("[]"),
    dedup_key = receipt_key,
    source_ref = {
      kind = "repo-site",
      ref = base_ids.dedup_key({
        "github-devloop-ops",
        "triage-patrol",
        base_ids.safe_repo(repo),
        snapshot_digest,
      }),
    },
  }
end

local function make_department(handles)
  local department = saga.department(spec, {
    done = function()
      return false
    end,
    act = function(event)
      devloop_logging.log_entry("triage_patrol", event, "github-devloop/triage-patrol", "tick")
      local repo = require_repo()
      local host_login = require_host_login()
      local limits = core.observability_limits()
      local receipt_cap = receipt_candidate_cap(repo, limits.entity_cap)
      local candidates, deferred_candidates, listed_candidates = list_candidates(
        handles.github,
        repo,
        limits,
        core.observability_rotation_seed(event),
        receipt_cap
      )
      log_deferred_candidates(
        listed_candidates,
        #candidates,
        deferred_candidates,
        limits.entity_cap,
        receipt_cap
      )
      local rows = collect_snapshot(handles.github, repo, host_login, candidates, limits)
      local request = receipt_request(repo, rows)
      devloop_logging.log_raise(
        "triage_patrol",
        "triage-patrol/" .. strings.decimal_checksum(snapshot_identity(rows)),
        "github-proxy.github_issue_create_request",
        request
      )
    end,
    wrap = devloop_logging.wrap_pipeline_failure,
    name = "triage_patrol",
  })
  department.ports = handles
  return department
end

return ports.install(make_department, ports.github_author_options(
  devloop_base.read_env,
  "github-devloop-ops.triage_patrol",
  { bot_login_env = "FKST_GITHUB_BOT_LOGIN" }
))
