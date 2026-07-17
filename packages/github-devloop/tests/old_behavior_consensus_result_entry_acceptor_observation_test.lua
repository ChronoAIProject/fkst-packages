local ra = require("tests.entry_acceptor_observation_helpers")
local core = require("core")
local devloop_logging = require("devloop.logging")
local github_fake = require("forge.github_fake")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local testing = require("testkit_internal.testing")
local _workflow_codex = require("workflow_internal.codex")
local consensus_result_module = require("departments.consensus_result.main")

local t = h.t
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local OLDER = "consensus:github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local ORDER_EQUAL_CURRENT = VERSION .. "/loop/01"
local ORDER_EQUAL_EVENT = VERSION .. "/loop/1"
local SOURCE_REF = { kind = "external", ref = REPO .. "#issue/" .. ISSUE_NUMBER }
local PREFIX = "entry-consensus-result-"
local SITE = {
  path = "packages/github-devloop/departments/consensus_result/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:consensus.consensus_reached",
}

local RESULT_COMMENT = "comment:issue:consensus-result"
local RESULT_LABEL = "label:issue:consensus-result"
local HOLD_COMMENT = "comment:issue:dependency-hold"
local HOLD_LABEL = "label:issue:dependency-hold"
local RELEASE_COMMENT = "comment:issue:dependency-release"

local FIXTURES = ra.json_array({
  { disposition = "skip-foreign-payload", status = "rejected", reason = "skip-foreign(proposal_id)",
    cas = "skip-foreign(proposal_id)", target = "reject", source_line = 143,
    payload = { schema = "unsupported.result.v1", proposal_id = PROPOSAL_ID, dedup_key = VERSION } },
  { disposition = "fail-owned-malformed-proposal", status = "error", reason = "owned-proposal-malformed",
    cas = "fail-closed(consensus-result-invalid)", target = "reject", source_line = 149, error = "owned proposal_id is malformed",
    payload = h.reached({ proposal_id = "github-devloop/issue/not-round-trippable", dedup_key = VERSION }) },
  { disposition = "fail-owned-result-contract", status = "error", reason = "owned-result-contract-invalid",
    cas = "fail-closed(consensus-result-invalid)", target = "reject", source_line = 152, error = "violates the consumer contract",
    payload = h.reached({ decision = "reject", decision_reason = "not-premise-refuted" }) },
  { disposition = "fail-source-ref-mismatch", status = "error", reason = "source-ref-mismatch",
    cas = "fail-closed(consensus-result-invalid)", target = "reject", source_line = 157, error = "source_ref does not match proposal_id",
    payload = h.reached({ source_ref = { kind = "external", ref = "owner/repo#issue/41" } }) },
  { disposition = "skip-non-whitelisted-author", status = "rejected", reason = "non-whitelisted-author",
    cas = "skip-non-whitelisted-author", target = "reject", source_line = 181, author_login = "ordinary-user",
    current_state = "thinking", current_version = VERSION },
  { disposition = "skip-first-result-same", status = "rejected", reason = "first-result-same-decision",
    cas = "skip-idempotent(first-result)", target = "reject", source_line = 191,
    current_state = "ready", current_version = VERSION, first_decision = "approve" },
  { disposition = "suppress-first-result-divergent", status = "rejected", reason = "first-result-divergent",
    cas = "suppress-divergent-result", target = "reject", source_line = 200,
    current_state = "ready", current_version = VERSION, first_decision = "reject",
    effects = ra.json_array({ "comment:issue:result-divergence" }) },
  { disposition = "skip-idempotent-effects-complete-dependency-wait", status = "rejected",
    reason = "result-effects-complete", cas = "skip-idempotent(result effects complete)", target = "dependency_wait",
    source_line = 218, current_state = "dependency_wait", current_version = VERSION, gate_kind = "waiting",
    labels = { "fkst-dev:ready", "fkst-dev:blocked-on-dependency" }, dependency_fact = true },
  { disposition = "repair-ready-comment-only", status = "admitted", reason = "result-effects-incomplete",
    cas = "applied(result effects incomplete)", target = "ready", source_line = 228,
    current_state = "ready", current_version = VERSION, labels = { "fkst-dev:ready" },
    effects = ra.json_array({ RESULT_COMMENT }) },
  { disposition = "repair-ready-comment-and-label", status = "admitted", reason = "result-effects-incomplete",
    cas = "applied(result effects incomplete)", target = "ready", source_line = 228,
    current_state = "ready", current_version = VERSION, labels = {}, effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "repair-declined-comment-only", status = "admitted", reason = "result-effects-incomplete",
    cas = "applied(result effects incomplete)", target = "declined", source_line = 228,
    decision = "reject", current_state = "declined", current_version = VERSION, labels = { "fkst-dev:declined" },
    effects = ra.json_array({ RESULT_COMMENT }) },
  { disposition = "repair-dependency-wait-hold-effects", status = "admitted", reason = "result-effects-incomplete",
    cas = "hold-dependency", target = "dependency_wait", source_line = 228,
    current_state = "dependency_wait", current_version = VERSION, gate_kind = "waiting", labels = {},
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL, HOLD_COMMENT, HOLD_LABEL }) },
  { disposition = "skip-incoming-version-older", status = "rejected", reason = "incoming-version-older",
    cas = "skip-stale(incoming version < current marker version)", target = "reject", source_line = 234,
    current_state = "thinking", current_version = VERSION, event_version = OLDER },
  { disposition = "skip-advanced-or-diverged", status = "rejected", reason = "advanced-or-diverged",
    cas = "skip-advanced-or-diverged", target = "reject", source_line = 234,
    current_state = "blocked", current_version = VERSION },
  { disposition = "skip-idempotent-raw-version-mismatch", status = "rejected", reason = "raw-version-mismatch",
    cas = "skip-idempotent(already at to_state)", target = "reject", source_line = 234,
    current_state = "ready", current_version = ORDER_EQUAL_CURRENT, event_version = ORDER_EQUAL_EVENT },
  { disposition = "retry-thinking-marker-pending", status = "error", reason = "thinking-marker-pending",
    cas = "retry-pending(from-state marker not yet visible)", target = "retry", source_line = 239,
    current_state = nil, current_version = nil, error = "state-marker-pending" },
  { disposition = "admitted-ready", status = "admitted", reason = "approve-dependency-satisfied",
    cas = "applied", target = "ready", source_line = 243, current_state = "thinking", current_version = VERSION,
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "admitted-ready-with-dependency-release", status = "admitted", reason = "dependency-notes-released",
    cas = "applied", target = "ready", source_line = 243, current_state = "thinking", current_version = VERSION,
    gate_kind = "release", effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL, RELEASE_COMMENT }) },
  { disposition = "admitted-declined", status = "admitted", reason = "premise-refuted",
    cas = "applied", target = "declined", source_line = 243, decision = "reject",
    current_state = "thinking", current_version = VERSION, effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "admitted-dependency-wait", status = "admitted", reason = "dependency-waiting",
    cas = "hold-dependency", target = "dependency_wait", source_line = 243, gate_kind = "waiting",
    current_state = "thinking", current_version = VERSION,
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL, HOLD_COMMENT, HOLD_LABEL }) },
  { disposition = "admitted-dependency-cycle", status = "admitted", reason = "dependency-cycle",
    cas = "hold-dependency", target = "dependency_wait", source_line = 243, gate_kind = "cycle",
    current_state = "thinking", current_version = VERSION,
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL, HOLD_COMMENT, HOLD_LABEL }) },
  { disposition = "admitted-dependency-unresolvable", status = "admitted", reason = "dependency-unresolvable",
    cas = "hold-dependency", target = "dependency_wait", source_line = 243, gate_kind = "unresolvable",
    current_state = "thinking", current_version = VERSION,
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL, HOLD_COMMENT, HOLD_LABEL }) },
})

local function event_for(fixture)
  local payload = fixture.payload and ra.copy_value(fixture.payload) or h.reached({
    decision = fixture.decision or "approve",
    decision_reason = fixture.decision == "reject" and "premise-refuted" or nil,
    effect_version = fixture.event_version,
  })
  return { queue = "consensus.consensus_reached", ts = "2026-06-03T02:03:04Z", payload = payload }
end

local function trusted(body)
  return { body = body, author_login = "fkst-test-bot", created_at = "2026-06-03T01:02:03Z" }
end

local function gate_for(fixture)
  if fixture.gate_kind == "waiting" then
    return { ok = false, kind = "waiting", reason = "waiting-on-dependency", unmet = { 53 }, notes = {} }
  elseif fixture.gate_kind == "cycle" then
    return { ok = false, kind = "cycle", reason = "dependency-cycle", unmet = { 42, 53 }, notes = {} }
  elseif fixture.gate_kind == "unresolvable" then
    return { ok = false, kind = "unresolvable", reason = "dependency-read-failed", unmet = { 53 }, notes = {} }
  elseif fixture.gate_kind == "release" then
    return { ok = true, kind = "satisfied", reason = "dependency-void", unmet = {},
      notes = { { kind = "dependency-void", blocker_number = 53, reason = "blocker-closed-unmerged" } } }
  end
  return { ok = true, kind = "satisfied", reason = "no-open-blockers", unmet = {}, notes = {} }
end

local function capture(fixture)
  h.mock_bot_env()
  local event = event_for(fixture)
  local comments = ra.json_array()
  if fixture.current_state then
    table.insert(comments, trusted(core.state_marker(PROPOSAL_ID, fixture.current_state, fixture.current_version)))
  end
  if fixture.first_decision then
    table.insert(comments, trusted(m_builders.result_marker(PROPOSAL_ID, fixture.first_decision, event.payload.dedup_key,
      fixture.first_decision == "reject" and "premise-refuted" or nil)))
  end
  if fixture.dependency_fact then
    table.insert(comments, trusted(core.dependency_wait_marker(PROPOSAL_ID, fixture.current_version, { 53 }, "waiting", "waiting-on-dependency")))
  end
  local model = github_fake.model({
    author_policy = { mode = "whitelist", logins = { "fkst-test-bot" } },
    issues = {
      [SOURCE_REF.ref] = {
        repo = REPO, number = ISSUE_NUMBER, title = "Consensus result entry fixture", body = "Entry fixture",
        state = "OPEN", labels = fixture.labels or (fixture.current_state and { "fkst-dev:" .. fixture.current_state } or {}),
        comments = comments, assignees = { "fkst-test-bot" }, author_login = fixture.author_login or "fkst-test-bot",
      },
    },
  })
  local github = github_fake.new(model)
  local department = consensus_result_module.make_department({ github = github, git = {} })
  department.ports = { github = github }
  department.model = model
  local restorations = {}
  local captured = ra.capture_logging("consensus_result", devloop_logging, restorations)
  ra.replace(core, "dependency_gate", function() return gate_for(fixture) end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
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
    t.is_true(selected ~= nil, fixture.disposition .. ": observable admission decision")
  end
  fixture.current_fact = {
    state = ra.nullable(fixture.current_state), version = ra.nullable(fixture.current_version),
    labels = ra.json_array(fixture.labels or {}), author_login = fixture.author_login or "fkst-test-bot",
  }
  fixture.effect_version = fixture.event_version or event.payload.effect_version or event.payload.dedup_key
  fixture.issue_number = ISSUE_NUMBER
  return ra.record({ dept = "consensus_result", fixture = fixture, result = result, captured = captured,
    event = event, prefix = PREFIX, site = SITE, source_state = "thinking" })
end

return {
  test_consensus_result_entry_acceptor_old_behavior_is_real_dispatch_and_bidirectional = function()
    ra.assert_site(t, { dept = "consensus_result", fixtures = FIXTURES, capture = capture, prefix = PREFIX, site = SITE })
  end,
}
