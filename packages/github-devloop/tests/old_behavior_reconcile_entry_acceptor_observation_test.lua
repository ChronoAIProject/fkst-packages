local ra = require("tests.entry_acceptor_observation_helpers")
local conv_attempts = require("devloop.convergence.attempts")
local conv_reconcile = require("devloop.convergence.reconcile")
local core = require("core")
local devloop_config = require("devloop.config")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local github_fake = require("forge.github_fake")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local _workflow_codex = require("workflow_internal.codex")
local reconcile_department = require("departments.reconcile.main")

local t = h.t
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local SOURCE_REF = { kind = "external", ref = REPO .. "#issue/" .. ISSUE_NUMBER }
local THINKING_VERSION = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local READY_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/ready/3"
local IMPLEMENTING_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/implementing/3"
local PREFIX = "entry-reconcile-"
local SITE = {
  path = "packages/github-devloop/departments/reconcile/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:devloop_reconcile|devloop_timeout_reconcile",
}
local RECONCILE_COMMENT = "comment:issue:reconcile-blocked"
local RECONCILE_LABEL = "label:issue:reconcile-blocked"
local TIMEOUT_COMMENT = "comment:issue:timeout-reconcile"

local FIXTURES = ra.json_array({
  { disposition = "thinking-skip-foreign-payload", status = "rejected", reason = "unsupported-thinking-payload",
    cas = "skip-foreign(proposal_id)", target = "reject", source_line = 92, queue = "devloop_reconcile",
    payload = { schema = "unsupported.reconcile.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" } },
  { disposition = "timeout-skip-foreign-payload", status = "rejected", reason = "unsupported-timeout-payload",
    cas = "skip-foreign(proposal_id)", target = "reject", source_line = 161, queue = "devloop_timeout_reconcile",
    payload = { schema = "github-devloop.timeout-reconcile.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" } },
  { disposition = "thinking-skip-reconcile-marker-visible", status = "rejected", reason = "reconcile-marker-visible",
    cas = "skip-idempotent(reconcile marker already visible)", target = "reject", source_line = 121,
    queue = "devloop_reconcile", current_state = "thinking", current_version = THINKING_VERSION, reconcile_marker = true },
  { disposition = "thinking-skip-already-terminal", status = "rejected", reason = "already-terminal",
    cas = "skip-idempotent(already terminal)", target = "reject", source_line = 125,
    queue = "devloop_reconcile", current_state = "blocked", current_version = THINKING_VERSION .. "/loop/3" },
  { disposition = "thinking-retry-marker-pending", status = "error", reason = "thinking-marker-pending",
    cas = "pending", target = "retry", source_line = 130, queue = "devloop_reconcile", error = "state-marker-pending" },
  { disposition = "thinking-skip-state-advanced", status = "rejected", reason = "state-advanced",
    cas = "skip-stale(state-advanced)", target = "reject", source_line = 133,
    queue = "devloop_reconcile", current_state = "ready", current_version = THINKING_VERSION .. "/ready/1" },
  { disposition = "thinking-admitted-drop-blocked", status = "admitted", reason = "deterministic-drop",
    cas = "applied", target = "blocked", source_line = 153, queue = "devloop_reconcile",
    current_state = "thinking", current_version = THINKING_VERSION,
    effects = ra.json_array({ RECONCILE_COMMENT, RECONCILE_LABEL }) },
  { disposition = "timeout-skip-marker-visible", status = "rejected", reason = "timeout-marker-visible",
    cas = "skip-idempotent(timeout reconcile marker already visible)", target = "reject", source_line = 186,
    queue = "devloop_timeout_reconcile", timeout_state = "ready", current_state = "ready",
    current_version = READY_VERSION, timeout_marker = true },
  { disposition = "timeout-skip-already-terminal", status = "rejected", reason = "already-terminal",
    cas = "skip-idempotent(already terminal)", target = "reject", source_line = 191,
    queue = "devloop_timeout_reconcile", timeout_state = "ready", current_state = "merged", current_version = READY_VERSION },
  { disposition = "timeout-retry-marker-pending", status = "error", reason = "timeout-marker-pending",
    cas = "pending", target = "retry", source_line = 196, queue = "devloop_timeout_reconcile",
    timeout_state = "ready", error = "state-marker-pending" },
  { disposition = "timeout-skip-state-advanced", status = "rejected", reason = "state-advanced",
    cas = "skip-stale(state-advanced)", target = "reject", source_line = 199,
    queue = "devloop_timeout_reconcile", timeout_state = "ready", current_state = "implementing",
    current_version = READY_VERSION },
  { disposition = "timeout-skip-lineage-mismatch", status = "rejected", reason = "lineage-mismatch",
    cas = "skip-stale(lineage-mismatch)", target = "reject", source_line = 203,
    queue = "devloop_timeout_reconcile", timeout_state = "ready", current_state = "ready",
    current_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/timeout/ready/3" },
  { disposition = "timeout-skip-no-longer-over-budget", status = "rejected", reason = "no-longer-over-budget",
    cas = "skip-stale(no-longer-over-budget)", target = "reject", source_line = 233,
    queue = "devloop_timeout_reconcile", timeout_state = "ready", current_state = "ready",
    current_version = READY_VERSION, no_longer_due = true },
  { disposition = "timeout-admitted-open-pr-ground-truth", status = "admitted", reason = "open-pr-ground-truth",
    cas = "applied(open-pr-ground-truth)", target = "awaiting-pr", source_line = 236,
    queue = "devloop_timeout_reconcile", timeout_state = "implementing", current_state = "implementing",
    current_version = IMPLEMENTING_VERSION, adopt_open_pr = true,
    effects = ra.json_array({ "comment:pr:timeout-adopt-open-pr", "comment:issue:timeout-adopt-pr-delegation",
      "comment:issue:timeout-adopt-open-pr", "label:issue:timeout-adopt-open-pr" }) },
  { disposition = "timeout-skip-decompose-exhausted-visible", status = "rejected", reason = "decompose-exhausted-visible",
    cas = "skip-idempotent(decompose-exhausted)", target = "reject", source_line = 241,
    queue = "devloop_timeout_reconcile", timeout_state = "blocked", current_state = "blocked",
    current_version = THINKING_VERSION .. "/loop/3", decompose_exhausted = true },
  { disposition = "timeout-admitted-decompose-exhausted", status = "admitted", reason = "decompose-output-exhausted",
    cas = "applied(decompose-exhausted)", target = "devloop_decompose", source_line = 251,
    queue = "devloop_timeout_reconcile", timeout_state = "blocked", current_state = "blocked",
    current_version = THINKING_VERSION .. "/loop/3", effects = ra.json_array({ "comment:issue:decompose-exhausted" }) },
  { disposition = "timeout-admitted-drop-blocked", status = "admitted", reason = "timeout-escalation-drop",
    cas = "applied", target = "blocked", source_line = 288,
    queue = "devloop_timeout_reconcile", timeout_state = "ready", current_state = "ready",
    current_version = READY_VERSION, effects = ra.json_array({ TIMEOUT_COMMENT, RECONCILE_LABEL }) },
})

local function timeout_payload(state_name, version)
  local round = 3
  return {
    schema = "github-devloop.timeout-reconcile.v1", proposal_id = PROPOSAL_ID, state = state_name,
    issue_version = version, round = round,
    dedup_key = "timeout-reconcile:" .. tostring(version) .. "/timeout-reconcile/" .. tostring(state_name) .. "/" .. round,
    source_ref = ra.copy_value(SOURCE_REF),
  }
end

local function event_for(fixture)
  local payload
  if fixture.payload then
    payload = ra.copy_value(fixture.payload)
  elseif fixture.queue == "devloop_timeout_reconcile" then
    local version = fixture.event_version or fixture.current_version or READY_VERSION
    if fixture.disposition == "timeout-skip-lineage-mismatch" then version = READY_VERSION end
    payload = timeout_payload(fixture.timeout_state or "ready", version)
  else
    payload = h.reconcile()
  end
  return { queue = "github-devloop." .. fixture.queue, ts = "2026-06-03T02:03:04Z", payload = payload }
end

local function trusted(body)
  return { body = body, author_login = "fkst-test-bot", created_at = "2026-06-03T01:02:03Z" }
end

local function capture(fixture)
  h.mock_bot_env()
  local event = event_for(fixture)
  local comments = ra.json_array()
  if fixture.current_state then
    table.insert(comments, trusted(core.state_marker(PROPOSAL_ID, fixture.current_state, fixture.current_version)))
  end
  if fixture.reconcile_marker then
    local version = conv_reconcile.reconcile_terminal_state_version(THINKING_VERSION, event.payload.round)
    local request = core.build_reconcile_comment_request(REPO, ISSUE_NUMBER, event.payload, "drop", "already done", version)
    table.insert(comments, trusted(request.body))
  end
  if fixture.timeout_marker then
    table.insert(comments, trusted(conv_reconcile.timeout_reconcile_marker(PROPOSAL_ID, event.payload.issue_version,
      event.payload.state, event.payload.round, "drop", { source_ref = SOURCE_REF })))
  end
  local model = github_fake.model({ author_policy = { mode = "whitelist", logins = { "fkst-test-bot" } } })
  local github = github_fake.new(model)
  function github.issue_view(repo, number, fields, timeout)
    table.insert(model.writes, { kind = "issue_view", repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.issue_view_stdout({ repo = repo, number = number,
      labels = { "fkst-dev:" .. tostring(fixture.current_state or "thinking") }, comments = comments,
      author_login = "fkst-test-bot" }), stderr = "", exit_code = 0 }
  end
  local restorations = {}
  local captured = ra.capture_logging("reconcile", devloop_logging, restorations)
  ra.replace(devloop_commands, "gh_issue_view_loop", function(repo, number, timeout)
    return github.issue_view(repo, number, "title,updatedAt,labels,comments,state,author", timeout)
  end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  ra.replace(core, "liveness_timeout_due_with_facts", function() return not fixture.no_longer_due, 181 end, restorations)
  ra.replace(core, "liveness_timeout_decision_with_facts", function()
    return fixture.no_longer_due and { action = "wait", attempt = 2 } or { action = "escalate", attempt = 3 }
  end, restorations)
  ra.replace(core, "restart_row_liveness_signal", function() return { age_minutes = 181 } end, restorations)
  ra.replace(core, "dependency_gate", function()
    return { ok = true, kind = "satisfied", reason = "no-open-blockers", unmet = {}, notes = {} }
  end, restorations)
  if fixture.adopt_open_pr then
    ra.replace(devloop_config, "branch_config", function() return { integration = "dev", upstream = "dev" } end,
      restorations)
    ra.replace(devloop_commands, "gh_pr_list_head_base", function(_, branch, base_branch)
      return {
        stdout = '[[{"number":7,"head":{"ref":"' .. branch
          .. '","sha":"0123456789abcdef0123456789abcdef01234567"},"base":{"ref":"'
          .. base_branch .. '"},"state":"open"}]]\n',
        stderr = "",
        exit_code = 0,
      }
    end, restorations)
  else
    ra.replace(core, "adopt_existing_pr_child", function() return nil end, restorations)
  end
  ra.replace(conv_attempts, "has_decompose_exhausted_marker", function() return fixture.decompose_exhausted == true end,
    restorations)
  local result = fixture.error and testing.run_fake_expecting_failure(reconcile_department, event)
    or testing.run_fake(reconcile_department, event)
  ra.restore_all(restorations)
  if fixture.error then
    t.is_true(tostring(result.failure.error):find(fixture.error, 1, true) ~= nil,
      fixture.disposition .. ": exact fail-closed error")
  else
    local selected = nil
    for _, decision in ipairs(captured.decisions) do
      if decision.outcome == fixture.cas then selected = decision break end
    end
    t.is_true(selected ~= nil, fixture.disposition .. ": observable admission decision " .. ra.canonical_json(captured.decisions))
  end
  fixture.current_fact = { state = ra.nullable(fixture.current_state), version = ra.nullable(fixture.current_version),
    queue_kind = fixture.queue, timeout_state = ra.nullable(fixture.timeout_state) }
  fixture.effect_version = fixture.target == "blocked" and (captured.applies[1] and captured.applies[1].version) or nil
  fixture.issue_number = ISSUE_NUMBER
  return ra.record({ dept = "reconcile", fixture = fixture, result = result, captured = captured,
    event = event, prefix = PREFIX, site = SITE, source_state = fixture.timeout_state or "thinking" })
end

return {
  test_reconcile_entry_acceptor_old_behavior_is_real_dispatch_and_bidirectional = function()
    ra.assert_site(t, { dept = "reconcile", fixtures = FIXTURES, capture = capture, prefix = PREFIX, site = SITE })
  end,
}
