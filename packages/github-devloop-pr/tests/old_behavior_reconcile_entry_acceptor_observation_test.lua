local ra = require("tests.receiver_activation_observation_helpers")
local base_ids = require("devloop.base_ids")
local conv_attempts = require("devloop.convergence.attempts")
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_claims = require("devloop.claims")
local replay_fields = require("devloop.replay_fields")
local fix_rounds = require("core.fix_rounds")
local testing = require("testkit_internal.testing")
local _observation_support = require("testkit_internal.old_behavior_observation_support")
local _workflow_codex = require("workflow_internal.codex")
local reconcile_module = require("departments.reconcile.main")

local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local HEAD_SHA = "def456"
local REVIEW_VERSION = h.review_reconcile().issue_version
local FIX_VERSION = h.fix_reconcile().issue_version
local TIMEOUT_VERSION = FIX_VERSION .. "/timeout/fixing/3"
local PREFIX = "entry-pr-reconcile-"
local SITE = {
  path = "packages/github-devloop-pr/departments/reconcile/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:devloop_fix_reconcile|devloop_review_reconcile|devloop_timeout_reconcile",
}

local BLOCK_COMMENT = "comment:pr:reconcile-blocked"
local BLOCK_LABEL = "label:issue:reconcile-blocked"
local DECOMPOSE_PR = "comment:pr:decompose-exhausted"
local DECOMPOSE_ISSUE = "comment:issue:decompose-exhausted"

local FIXTURES = ra.json_array({
  { disposition = "review-skip-foreign-payload", status = "rejected", reason = "unsupported-review-payload",
    cas = "skip-foreign(proposal_id)", target = "reject", source_line = 161, queue = "devloop_review_reconcile",
    payload = { schema = "github-devloop.review-reconcile.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" } },
  { disposition = "fix-skip-foreign-payload", status = "rejected", reason = "unsupported-fix-payload",
    cas = "skip-foreign(proposal_id)", target = "reject", source_line = 240, queue = "devloop_fix_reconcile",
    payload = { schema = "github-devloop.fix-reconcile.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" } },
  { disposition = "timeout-skip-foreign-payload", status = "rejected", reason = "unsupported-timeout-payload",
    cas = "skip-foreign(proposal_id)", target = "reject", source_line = 361, queue = "devloop_timeout_reconcile",
    payload = { schema = "github-devloop.timeout-reconcile.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" } },
  { disposition = "review-skip-result-marker-visible", status = "rejected", reason = "review-marker-visible",
    cas = "skip-idempotent(review reconcile marker already visible)", target = "reject", source_line = 199,
    queue = "devloop_review_reconcile", marker_visible = true },
  { disposition = "review-skip-already-terminal", status = "rejected", reason = "review-already-terminal",
    cas = "skip-idempotent(already terminal)", target = "reject", source_line = 203,
    queue = "devloop_review_reconcile", current_state = "blocked" },
  { disposition = "review-retry-marker-pending", status = "error", reason = "review-marker-pending",
    cas = "pending", target = "retry", source_line = 207, queue = "devloop_review_reconcile",
    no_state = true, error = "review-reconcile-marker-missing" },
  { disposition = "review-skip-state-advanced", status = "rejected", reason = "review-state-advanced",
    cas = "skip-stale(state-advanced)", target = "reject", source_line = 211,
    queue = "devloop_review_reconcile", current_state = "fixing" },
  { disposition = "review-admitted-drop-blocked", status = "admitted", reason = "review-terminal-drop",
    cas = "applied", target = "blocked", source_line = 229, queue = "devloop_review_reconcile",
    effects = ra.json_array({ BLOCK_COMMENT, BLOCK_LABEL }) },
  { disposition = "fix-skip-result-marker-visible", status = "rejected", reason = "fix-marker-visible",
    cas = "skip-idempotent(fix reconcile marker already visible)", target = "reject", source_line = 280,
    queue = "devloop_fix_reconcile", marker_visible = true },
  { disposition = "fix-skip-already-terminal", status = "rejected", reason = "fix-already-terminal",
    cas = "skip-idempotent(already terminal)", target = "reject", source_line = 284,
    queue = "devloop_fix_reconcile", current_state = "blocked" },
  { disposition = "fix-skip-head-advanced", status = "rejected", reason = "fix-head-advanced",
    cas = "skip-stale(head-advanced)", target = "reject", source_line = 289,
    queue = "devloop_fix_reconcile", head_sha = "feedface" },
  { disposition = "fix-retry-marker-pending", status = "error", reason = "fix-marker-pending",
    cas = "retry-pending(from-state marker not yet visible)", target = "retry", source_line = 295,
    queue = "devloop_fix_reconcile", no_state = true, error = "fix-reconcile-marker-missing" },
  { disposition = "fix-skip-version-mismatch", status = "rejected", reason = "fix-version-mismatch",
    cas = "skip-stale(version-mismatch)", target = "reject", source_line = 301,
    queue = "devloop_fix_reconcile", current_version = FIX_VERSION .. "/other" },
  { disposition = "fix-admitted-drop-blocked", status = "admitted", reason = "fix-terminal-drop",
    cas = "applied", target = "blocked", source_line = 330, queue = "devloop_fix_reconcile",
    effects = ra.json_array({ BLOCK_COMMENT, BLOCK_LABEL }) },
  { disposition = "own-ci-skip-pr-closed", status = "rejected", reason = "own-ci-pr-closed",
    cas = "skip-stale(pr-closed)", target = "reject", source_line = 311,
    queue = "devloop_fix_reconcile", reconcile_kind = "own-ci", current_state = "fixing",
    pr_state = "CLOSED" },
  { disposition = "own-ci-skip-head-advanced", status = "rejected", reason = "own-ci-head-advanced",
    cas = "skip-stale(head-advanced)", target = "reject", source_line = 345,
    queue = "devloop_fix_reconcile", reconcile_kind = "own-ci", current_state = "fixing",
    head_sha = "feedface" },
  { disposition = "own-ci-skip-cleared", status = "rejected", reason = "own-ci-cleared",
    cas = "skip-stale(own-ci-cleared)", target = "reject", source_line = 319,
    queue = "devloop_fix_reconcile", reconcile_kind = "own-ci", current_state = "fixing",
    ci_conclusion = "SUCCESS" },
  { disposition = "own-ci-admitted-drop-blocked", status = "admitted", reason = "own-ci-terminal-drop",
    cas = "applied", target = "blocked", source_line = 330,
    queue = "devloop_fix_reconcile", reconcile_kind = "own-ci", current_state = "fixing",
    effects = ra.json_array({ BLOCK_COMMENT, BLOCK_LABEL }) },
  { disposition = "merge-gate-admitted-drop-blocked", status = "admitted", reason = "merge-gate-terminal-drop",
    cas = "applied", target = "blocked", source_line = 330,
    queue = "devloop_fix_reconcile", reconcile_kind = "merge-gate", current_state = "merge-ready",
    effects = ra.json_array({ BLOCK_COMMENT, BLOCK_LABEL }) },
  { disposition = "timeout-pr-surface-fallback-issue-apply", status = "admitted", reason = "pr-surface-gone-fallback",
    cas = "applied", target = "blocked", source_line = 512, queue = "devloop_timeout_reconcile",
    pr_not_found = true, effects = ra.json_array({ BLOCK_COMMENT, BLOCK_LABEL }) },
  { disposition = "timeout-skip-result-marker-visible", status = "rejected", reason = "timeout-marker-visible",
    cas = "skip-idempotent(timeout reconcile marker already visible)", target = "reject", source_line = 405,
    queue = "devloop_timeout_reconcile", marker_visible = true },
  { disposition = "timeout-skip-already-terminal", status = "rejected", reason = "timeout-already-terminal",
    cas = "skip-idempotent(already terminal)", target = "reject", source_line = 410,
    queue = "devloop_timeout_reconcile", current_state = "merged" },
  { disposition = "timeout-retry-marker-pending", status = "error", reason = "timeout-marker-pending",
    cas = "pending", target = "retry", source_line = 414, queue = "devloop_timeout_reconcile",
    no_state = true, error = "timeout-reconcile-marker-missing" },
  { disposition = "timeout-skip-state-advanced", status = "rejected", reason = "timeout-state-advanced",
    cas = "skip-stale(state-advanced)", target = "reject", source_line = 418,
    queue = "devloop_timeout_reconcile", current_state = "review-meta" },
  { disposition = "timeout-skip-lineage-mismatch", status = "rejected", reason = "timeout-lineage-mismatch",
    cas = "skip-stale(lineage-mismatch)", target = "reject", source_line = 422,
    queue = "devloop_timeout_reconcile", current_version = "other/lineage/timeout/fixing/3" },
  { disposition = "timeout-skip-no-longer-over-budget", status = "rejected", reason = "timeout-not-due",
    cas = "skip-stale(no-longer-over-budget)", target = "reject", source_line = 457,
    queue = "devloop_timeout_reconcile", not_due = true },
  { disposition = "timeout-skip-decompose-exhausted-visible", status = "rejected", reason = "decompose-exhausted-visible",
    cas = "skip-idempotent(decompose-exhausted)", target = "reject", source_line = 462,
    queue = "devloop_timeout_reconcile", timeout_state = "blocked", current_state = "blocked",
    decompose_visible = true },
  { disposition = "timeout-admitted-decompose-exhausted-pr", status = "admitted", reason = "decompose-exhausted-pr",
    cas = "applied(decompose-exhausted)", target = "devloop_decompose", source_line = 470,
    queue = "devloop_timeout_reconcile", timeout_state = "blocked", current_state = "blocked",
    effects = ra.json_array({ DECOMPOSE_PR }) },
  { disposition = "timeout-admitted-decompose-exhausted-issue", status = "admitted", reason = "decompose-exhausted-issue",
    cas = "applied(decompose-exhausted)", target = "devloop_decompose", source_line = 470,
    queue = "devloop_timeout_reconcile", timeout_state = "blocked", current_state = "blocked",
    issue_surface = true, effects = ra.json_array({ DECOMPOSE_ISSUE }) },
  { disposition = "timeout-admitted-pr-drop-blocked", status = "admitted", reason = "timeout-pr-drop",
    cas = "applied", target = "blocked", source_line = 512, queue = "devloop_timeout_reconcile",
    effects = ra.json_array({ BLOCK_COMMENT, BLOCK_LABEL }) },
  { disposition = "timeout-admitted-issue-drop-blocked", status = "admitted", reason = "timeout-issue-drop",
    cas = "applied", target = "blocked", source_line = 512, queue = "devloop_timeout_reconcile",
    issue_surface = true, effects = ra.json_array({ BLOCK_COMMENT, BLOCK_LABEL }) },
})

local function timeout_payload(fixture)
  local state_name = fixture.timeout_state or "fixing"
  local row = replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
  local source_ref = fixture.issue_surface and entity_lib.issue_source_ref(REPO, ISSUE_NUMBER)
    or entity_lib.pr_source_ref(REPO, PR_NUMBER)
  local version = state_name == "blocked" and FIX_VERSION .. "/blocked" or TIMEOUT_VERSION
  return conv_reconcile.build_devloop_timeout_reconcile_payload(row,
    { state = state_name, version = version }, PROPOSAL_ID, source_ref, 3)
end

local function event_for(fixture)
  if fixture.payload then
    return { queue = "github-devloop-pr." .. fixture.queue, ts = "2026-06-03T02:03:04Z",
      payload = ra.copy_value(fixture.payload) }
  end
  local payload = fixture.queue == "devloop_review_reconcile" and h.review_reconcile()
    or fixture.queue == "devloop_fix_reconcile" and h.fix_reconcile()
    or timeout_payload(fixture)
  if fixture.reconcile_kind ~= nil then
    local schema = fixture.reconcile_kind == "own-ci" and fix_rounds.OWN_CI_SCHEMA
      or fix_rounds.MERGE_GATE_SCHEMA
    payload.schema = schema
    payload.reason_class = fix_rounds.FIX_LOOP_MAX_ROUNDS
    payload.bound_head_sha = payload.head_sha
    payload.round = devloop_state.version_fix_round(payload.issue_version)
    payload.dedup_key = base_ids.dedup_key({ schema, payload.issue_version, payload.reason_class })
  end
  return { queue = "github-devloop-pr." .. fixture.queue, ts = "2026-06-03T02:03:04Z", payload = payload }
end

local function capture(fixture)
  h.mock_bot_env()
  local event = event_for(fixture)
  local ports = ra.fake_ports()
  local restorations = {}
  local captured = ra.capture_logging("reconcile", devloop_logging, restorations)
  local source_state = fixture.queue == "devloop_review_reconcile" and "reviewing"
    or fixture.reconcile_kind == "own-ci" and "fixing"
    or fixture.reconcile_kind == "merge-gate" and "merge-ready"
    or fixture.queue == "devloop_fix_reconcile" and "reviewing"
    or fixture.timeout_state or "fixing"
  local current_state = fixture.current_state or source_state
  if fixture.no_state then current_state = nil end
  local current_version = fixture.current_version or event.payload.issue_version
  local comments = ra.json_array()
  if current_state then table.insert(comments, core.state_marker(PROPOSAL_ID, current_state, current_version)) end
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    if fixture.pr_not_found then return { stdout = "", stderr = "HTTP 404: Not Found", exit_code = 1 } end
    return { stdout = entity_read_mocks.pr_view_stdout({ repo = REPO, number = PR_NUMBER, comments = comments,
      head = "devloop-owner-repo-42-01HY", head_sha = fixture.head_sha or HEAD_SHA,
      base_branch = "dev", state = fixture.pr_state or "OPEN",
      status_check_rollup_json = fixture.reconcile_kind == "own-ci"
        and ('[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"'
          .. (fixture.ci_conclusion or "FAILURE") .. '","headSha":"' .. (fixture.head_sha or HEAD_SHA) .. '"}]')
        or nil }), stderr = "", exit_code = 0 }
  end
  function ports.github.gh_commit_check_runs(repo, head_sha, timeout)
    ra.record_write(ports.github_model, "commit_check_runs", {
      repo = repo, head_sha = head_sha, timeout = timeout,
    })
    return {
      stdout = '{"check_runs":[{"id":101,"name":"test","status":"completed",'
        .. '"conclusion":"' .. ((fixture.ci_conclusion or "FAILURE"):lower())
        .. '","head_sha":"' .. tostring(fixture.head_sha or HEAD_SHA) .. '"}]}',
      stderr = "",
      exit_code = 0,
    }
  end
  function ports.github.issue_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "issue_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.issue_view_stdout({ repo = REPO, number = ISSUE_NUMBER,
      comments = comments, assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot" }),
      stderr = "", exit_code = 0 }
  end
  ra.replace(m_claims, "verify_pr_review_issue_claim", function() return true end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  if fixture.marker_visible then
    if fixture.queue == "devloop_review_reconcile" then
      ra.replace(conv_reconcile, "has_review_reconcile_marker", function() return true end, restorations)
    elseif fixture.queue == "devloop_fix_reconcile" then
      ra.replace(conv_reconcile, "has_fix_reconcile_marker", function() return true end, restorations)
    else
      ra.replace(conv_reconcile, "has_timeout_reconcile_marker", function() return true end, restorations)
    end
  end
  ra.replace(core, "liveness_timeout_due_with_facts", function() return not fixture.not_due, 181 end, restorations)
  ra.replace(core, "liveness_timeout_decision_with_facts", function()
    return fixture.not_due and { action = "wait", attempt = 2 } or { action = "escalate", attempt = 3 }
  end, restorations)
  ra.replace(core, "restart_row_liveness_signal", function() return { age_minutes = 181 } end, restorations)
  ra.replace(core, "dependency_gate", function()
    return { ok = true, kind = "satisfied", reason = "no-open-blockers", unmet = {}, notes = {} }
  end, restorations)
  if fixture.issue_surface or fixture.pr_not_found then
    ra.replace(core, "linked_pr_surface_snapshot", function()
      return { comments = comments, prs = ra.json_array() }
    end, restorations)
  end
  ra.replace(conv_attempts, "has_decompose_exhausted_marker", function()
    return fixture.decompose_visible == true
  end, restorations)
  local department = ra.make_department(reconcile_module, ports, core)
  local result = fixture.error and testing.run_fake_expecting_failure(department, event)
    or testing.run_fake(department, event)
  ra.restore_all(restorations)
  if fixture.error then
    t.is_true(tostring(result.failure.error):find(fixture.error, 1, true) ~= nil,
      fixture.disposition .. ": exact fail-closed error")
  else
    local selected = nil
    for _, decision in ipairs(captured.decisions) do
      if decision.outcome == fixture.cas then selected = decision break end
    end
    t.is_true(selected ~= nil, fixture.disposition .. ": observable entry disposition " .. ra.canonical_json(captured.decisions))
  end
  fixture.current_state = current_state
  fixture.current_version = current_state and current_version or nil
  fixture.current_fact = { state = ra.nullable(current_state), version = ra.nullable(fixture.current_version),
    queue_kind = fixture.queue, surface = fixture.issue_surface and "issue" or "pr" }
  fixture.effect_version = captured.applies[#captured.applies] and captured.applies[#captured.applies].version or nil
  fixture.issue_number = ISSUE_NUMBER
  return ra.record({ dept = "reconcile", fixture = fixture, result = result, captured = captured,
    event = event, prefix = PREFIX, site = SITE, source_state = source_state, boundary = "entry_acceptor" })
end

return {
  test_reconcile_entry_acceptor_old_behavior_is_real_dispatch_and_bidirectional = function()
    ra.assert_site(t, { dept = "reconcile", fixtures = FIXTURES, capture = capture,
      prefix = PREFIX, site = SITE, boundary = "entry_acceptor" })
  end,
}
