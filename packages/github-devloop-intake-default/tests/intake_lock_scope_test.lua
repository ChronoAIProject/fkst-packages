local context_bundle = require("devloop.context_bundle")
local default_intake = require("devloop.intake.default")
local devloop_commands = require("devloop.commands")
local devloop_logging = require("devloop.logging")
local intake_class = require("core.intake_class")
local intake_service_class = require("core.intake_service_class")
local m_claims = require("devloop.claims")
local parsers_misc = require("devloop.parsers.misc")
local payloads_builders = require("devloop.payloads.builders")
local requests_lifecycle = require("devloop.requests.lifecycle")
local t = fkst.test

-- The SDK exposes json.decode only, so the gh issue view payload is spelled out here.
local function quoted(value)
  return '"' .. tostring(value or ""):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function named_array(field, values)
  local parts = {}
  for _, value in ipairs(values or {}) do
    parts[#parts + 1] = "{" .. quoted(field) .. ":" .. quoted(value) .. "}"
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function issue_stdout(current)
  return "{"
    .. quoted("title") .. ":" .. quoted(current.title) .. ","
    .. quoted("body") .. ":" .. quoted(current.body) .. ","
    .. quoted("updatedAt") .. ":" .. quoted(current.updated_at) .. ","
    .. quoted("state") .. ":" .. quoted(current.state) .. ","
    .. quoted("labels") .. ":" .. named_array("name", current.labels) .. ","
    .. quoted("comments") .. ":[],"
    .. quoted("assignees") .. ":" .. named_array("login", current.assignees) .. ","
    .. quoted("author") .. ":{" .. quoted("login") .. ":" .. quoted(current.author_login) .. "}"
    .. "}"
end

local function current(extra)
  local value = {
    title = "Implement bounded work",
    body = "Add the requested behavior and regression coverage.",
    updated_at = "2026-08-10T00:00:00Z",
    state = "OPEN",
    labels = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function index_of(events, expected)
  for index, event in ipairs(events) do
    if event == expected then
      return index
    end
  end
  return nil
end

local function assert_before(events, earlier, later)
  local first, second = index_of(events, earlier), index_of(events, later)
  t.is_true(first ~= nil and second ~= nil and first < second)
end

-- `currents` is the sequence observed by the prompt read, the post-codex planning
-- read, and the pre-lock commit read. The final read validates the buffered effects.
local function run_case(currents, action)
  local events = {}
  local raised = {}
  local applied = 0
  local read_index = 0
  local in_lock = false
  local old_with_lock = with_lock
  local old_spawn_codex_sync = spawn_codex_sync
  local old_issue_view = devloop_commands.gh_issue_view_intake_judge
  local old_claim = m_claims.claim_issue_for_management
  local old_claim_owner = m_claims.claim_owner
  local old_claim_state = m_claims.issue_claim_state
  local old_assert_trusted = parsers_misc.assert_trusted_bot_configured
  local old_context_fetch = context_bundle.context_fetch_from_bundle
  local old_log_raise = devloop_logging.log_raise
  local old_log_apply = devloop_logging.log_apply
  local old_comment_request = requests_lifecycle.build_intake_decision_comment_request
  local old_class_changes = intake_service_class.intake_service_class_label_changes
  local old_class_label = intake_service_class.build_intake_service_class_label_request
  local old_fetch_closed = intake_class.fetch_recent_closed_intake_class_issues
  local old_class_identity = intake_class.intake_class_identity
  local old_find_carrier = intake_class.find_open_intake_class_carrier
  local old_followup = intake_class.build_intake_class_followup_comment_request
  local old_folded = intake_class.build_intake_class_folded_label_request
  local old_create = intake_class.build_intake_class_issue_create_request

  with_lock = function(_key, fn)
    events[#events + 1] = "lock-enter"
    in_lock = true
    local ok, result = pcall(fn)
    in_lock = false
    events[#events + 1] = "lock-exit"
    if not ok then
      error(result, 0)
    end
    return result
  end
  devloop_commands.gh_issue_view_intake_judge = function()
    read_index = read_index + 1
    events[#events + 1] = "read-" .. tostring(read_index) .. (in_lock and "-inside" or "-outside")
    local snapshot = currents[read_index] or currents[#currents]
    return { exit_code = 0, stdout = issue_stdout(snapshot), stderr = "" }
  end
  m_claims.claim_issue_for_management = function()
    events[#events + 1] = in_lock and "claim-inside" or "claim-outside"
    return true
  end
  m_claims.claim_owner = function() return "fkst-test-bot" end
  m_claims.issue_claim_state = function() return "self" end
  parsers_misc.assert_trusted_bot_configured = function() end
  context_bundle.context_fetch_from_bundle = function() return "context" end
  spawn_codex_sync = function()
    events[#events + 1] = in_lock and "codex-inside" or "codex-outside"
    return { exit_code = 0, stdout = "decision", stderr = "" }
  end
  devloop_logging.log_raise = function(_dept, _proposal_id, queue, payload)
    events[#events + 1] = in_lock and "raise-inside" or "raise-outside"
    raised[#raised + 1] = { queue = queue, payload = payload }
  end
  devloop_logging.log_apply = function()
    events[#events + 1] = in_lock and "apply-inside" or "apply-outside"
    applied = applied + 1
  end
  requests_lifecycle.build_intake_decision_comment_request = function()
    return { schema = "test.comment" }
  end
  intake_service_class.intake_service_class_label_changes = function()
    return { "fkst-class:standard" }, {}
  end
  intake_service_class.build_intake_service_class_label_request = function()
    return { schema = "test.label" }
  end
  intake_class.fetch_recent_closed_intake_class_issues = function()
    events[#events + 1] = in_lock and "closed-scan-inside" or "closed-scan-outside"
    return {}
  end
  intake_class.intake_class_identity = function() return "recurring-class" end
  intake_class.find_open_intake_class_carrier = function()
    events[#events + 1] = in_lock and "carrier-scan-inside" or "carrier-scan-outside"
    return { number = 99 }
  end
  intake_class.build_intake_class_followup_comment_request = function()
    return { schema = "test.followup" }
  end
  intake_class.build_intake_class_folded_label_request = function()
    return { schema = "test.folded" }
  end
  intake_class.build_intake_class_issue_create_request = function()
    return { schema = "test.create" }
  end

  local payload = payloads_builders.build_devloop_intake_candidate_payload("owner/repo", 42, "2026-08-10T00:00:00Z")
  local ok, err = pcall(default_intake.act, intake_class, intake_service_class, {
    queue = "github-devloop-intake.devloop_intake_candidate",
    payload = payload,
    ts = "2026-08-10T00:00:00Z",
  }, {
    dept = "intake_lock_scope_test",
    prompts = {
      build_intake_prompt = function() return "prompt" end,
      parse_intake_action = function()
        return {
          action = action,
          service_class = "standard",
          reason = "Two prior instances establish a recurring class.",
        }
      end,
    },
  })

  with_lock = old_with_lock
  spawn_codex_sync = old_spawn_codex_sync
  devloop_commands.gh_issue_view_intake_judge = old_issue_view
  m_claims.claim_issue_for_management = old_claim
  m_claims.claim_owner = old_claim_owner
  m_claims.issue_claim_state = old_claim_state
  parsers_misc.assert_trusted_bot_configured = old_assert_trusted
  context_bundle.context_fetch_from_bundle = old_context_fetch
  devloop_logging.log_raise = old_log_raise
  devloop_logging.log_apply = old_log_apply
  requests_lifecycle.build_intake_decision_comment_request = old_comment_request
  intake_service_class.intake_service_class_label_changes = old_class_changes
  intake_service_class.build_intake_service_class_label_request = old_class_label
  intake_class.fetch_recent_closed_intake_class_issues = old_fetch_closed
  intake_class.intake_class_identity = old_class_identity
  intake_class.find_open_intake_class_carrier = old_find_carrier
  intake_class.build_intake_class_followup_comment_request = old_followup
  intake_class.build_intake_class_folded_label_request = old_folded
  intake_class.build_intake_class_issue_create_request = old_create
  if not ok then
    error(err, 0)
  end
  return events, raised, applied
end

return {
  -- The two repo-wide recurring-class searches used to run inside the commit lock on
  -- the same per-issue key that observe_issue / admission / implement contend for.
  -- They are reads-for-decision over repo-wide search results and protect nothing this
  -- lock owns, so they now precede it.
  test_intake_runs_recurring_class_scans_before_the_commit_lock = function()
    local events = run_case({ current(), current(), current() }, "escalate-to-class")
    assert_before(events, "codex-outside", "closed-scan-outside")
    assert_before(events, "closed-scan-outside", "carrier-scan-outside")
    assert_before(events, "carrier-scan-outside", "read-2-outside")
    assert_before(events, "read-2-outside", "read-3-outside")
    assert_before(events, "read-3-outside", "lock-enter")
    assert_before(events, "lock-enter", "apply-inside")
    assert_before(events, "apply-inside", "raise-inside")
    t.is_nil(index_of(events, "read-1-inside"))
    t.is_nil(index_of(events, "read-2-inside"))
    t.is_nil(index_of(events, "closed-scan-inside"))
    t.is_nil(index_of(events, "carrier-scan-inside"))
    t.is_nil(index_of(events, "read-3-inside"))
    t.is_nil(index_of(events, "apply-outside"))
    t.is_nil(index_of(events, "raise-outside"))
  end,

  -- Control: the escalation still publishes its full effect set, so hoisting the scans
  -- cannot be mistaken for suppressing the path.
  test_intake_escalation_still_publishes_its_effects = function()
    local _events, raised, applied = run_case({ current(), current(), current() }, "escalate-to-class")
    t.is_true(#raised > 0)
    t.is_true(applied > 0)
  end,

  -- A title edit while the codex was running changes the decision dedup key, so the
  -- commit re-read rejects the plan: nothing is raised and nothing is recorded as
  -- applied, including the class plan computed before the lock.
  test_intake_discards_plan_when_the_commit_read_shows_a_changed_decision_key = function()
    local _events, raised, applied = run_case(
      { current(), current({ title = "Implement bounded work, revised" }) },
      "escalate-to-class"
    )
    t.eq(#raised, 0)
    t.eq(applied, 0)
  end,

  test_intake_discards_plan_when_currency_changes_after_the_planning_read = function()
    local events, raised, applied = run_case({
      current(),
      current(),
      current({ updated_at = "2026-08-10T00:00:01Z" }),
    }, "escalate-to-class")
    t.is_true(index_of(events, "read-3-outside") ~= nil)
    t.eq(#raised, 0)
    t.eq(applied, 0)
  end,
}
