local base_ids = require("devloop.base_ids")
local core = require("core")
local devloop_base = require("devloop.base")
local github_author_policy = require("devloop.github_author_policy")
local transition_version = require("contract.transition_version")
local parsers_misc = require("devloop.parsers.misc")
local ports = require("forge.ports")
local saga = require("workflow.saga")
local strings = require("contract.strings")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")

local spec = {
  consumes = { "devloop_triage_patrol_tick" },
  produces = {},
  stall_window = "10m",
}

local admitted_states = {
  blocked = true,
  declined = true,
  dependency_wait = true,
}

local blocked_verdicts = {
  ["child-pr-blocked"] = "derived",
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
  local listed, _, deferred_reason = core.observability_list_issue_candidates(
    repo,
    candidate_labels(),
    limits,
    core.observability_deadline(now(), limits),
    rotation_seed,
    nil,
    github.issue_list_observe
  )
  if deferred_reason ~= nil then
    error("github-devloop-ops: triage-patrol-candidate-list-failed: GitHub issue candidate list failed")
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

local function classify_marker(state, marker_version)
  if state ~= "blocked" then
    return "", "abstain"
  end
  local suffixes = transition_version.parse(marker_version).suffixes or {}
  local final_suffix = suffixes[#suffixes]
  if final_suffix == nil or final_suffix.kind ~= "blocked" then
    return "", "abstain"
  end
  local why = tostring(final_suffix.reason or "")
  return why, blocked_verdicts[why] or "abstain"
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
  local why, verdict = classify_marker(current.state, current.version)
  return {
    proposal_id = proposal_id,
    issue_number = issue_number,
    state = current.state,
    marker_version = current.version,
    marker_author = current.author_login,
    why = why,
    verdict = verdict,
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
    encoded_field(row.marker_version),
    encoded_field(row.why),
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

local function log_deferred_candidates(listed, selected, deferred, entity_cap)
  if deferred < 1 then
    return
  end
  log.warn(table.concat({
    "github-devloop-ops",
    "dept=triage_patrol",
    "tag=OBSERVE_DEFERRED",
    "reason=entity-cap",
    "listed_issues=" .. tostring(listed),
    "processed_issues=" .. tostring(selected),
    "deferred_issues=" .. tostring(deferred),
    "entity_cap=" .. tostring(entity_cap),
  }, " "))
end

local function audit_field(name, value)
  return name .. "=" .. strings.json_string(value)
end

local function log_audit_row(row)
  devloop_logging.log_line("info", "triage_patrol", row.proposal_id, "TRIAGE_PATROL_AUDIT", {
    "issue=" .. tostring(row.issue_number),
    audit_field("state", row.state),
    audit_field("marker_version", row.marker_version),
    audit_field("marker_author", row.marker_author),
    audit_field("why", row.why),
    audit_field("verdict", row.verdict),
  })
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
      local candidates, deferred_candidates, listed_candidates = list_candidates(
        handles.github,
        repo,
        limits,
        core.observability_rotation_seed(event),
        limits.entity_cap
      )
      log_deferred_candidates(
        listed_candidates,
        #candidates,
        deferred_candidates,
        limits.entity_cap
      )
      local rows = collect_snapshot(handles.github, repo, host_login, candidates, limits)
      for _, row in ipairs(rows) do
        log_audit_row(row)
      end
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
