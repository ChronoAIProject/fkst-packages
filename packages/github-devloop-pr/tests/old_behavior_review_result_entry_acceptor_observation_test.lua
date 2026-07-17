local ra = require("tests.receiver_activation_observation_helpers")
local config = require("devloop.config")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local github_risk = require("devloop.github_risk")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local result_facts = require("devloop.markers.result_facts")
local testing = require("testkit_internal.testing")
local _observation_support = require("testkit_internal.old_behavior_observation_support")
local _workflow_codex = require("workflow_internal.codex")
local review_result_module = require("departments.review_result.main")

local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = h.reviewing().version
local ORDER_EQUAL_CURRENT = "v-loop-01"
local ORDER_EQUAL_EVENT = "v-loop-1"
local HEAD_SHA = "def456"
local BRANCH = "devloop-owner-repo-42-01HY"
local PREFIX = "entry-review-result-"
local SITE = {
  path = "packages/github-devloop-pr/departments/review_result/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:consensus.consensus_reached",
}

local RESULT_COMMENT = "comment:pr:review-result"
local RESULT_LABEL = "label:issue:review-result"
local EVIDENCE_COMMENT = "comment:pr:high-risk-review-evidence"
local DIVERGENCE_COMMENT = "comment:pr:review-result-divergence"
local FIX_RECONCILE = "queue:github-devloop-pr.devloop_fix_reconcile"
local DECOMPOSE = "queue:github-devloop-decompose.devloop_decompose"

local FIXTURES = ra.json_array({
  { disposition = "skip-foreign-payload", status = "rejected", reason = "unsupported-payload",
    cas = "skip-foreign(proposal_id)", target = "reject", source_line = 52,
    payload = { schema = "unsupported.review-result.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" } },
  { disposition = "fail-owned-malformed-proposal", status = "error", reason = "owned-proposal-malformed",
    cas = "fail-closed(review-result-invalid)", target = "reject", source_line = 58,
    malformed_proposal = true, error = "owned review proposal_id is malformed" },
  { disposition = "fail-owned-result-contract", status = "error", reason = "owned-result-contract-invalid",
    cas = "fail-closed(review-result-invalid)", target = "reject", source_line = 61,
    mutate = function(payload) payload.decision = "unknown" end,
    error = "violates the consumer contract" },
  { disposition = "fail-source-ref-mismatch", status = "error", reason = "source-ref-mismatch",
    cas = "fail-closed(review-result-invalid)", target = "reject", source_line = 68,
    mutate = function(payload) payload.source_ref = { kind = "external", ref = REPO .. "#pr/8" } end,
    error = "source_ref does not match proposal_id" },
  { disposition = "fail-dedup-mismatch", status = "error", reason = "dedup-mismatch",
    cas = "fail-closed(review-result-invalid)", target = "reject", source_line = 75,
    mutate = function(payload) payload.dedup_key = "consensus:foreign/review" end,
    error = "dedup does not match proposal_id" },
  { disposition = "fail-reject-gap-missing", status = "error", reason = "reject-gap-missing",
    cas = "fail-closed(review-result-invalid)", target = "reject", source_line = 79,
    decision = "reject", mutate = function(payload) payload.blocking_gap = nil end,
    error = "missing a bounded blocking_gap" },
  { disposition = "skip-origin-repo", status = "rejected", reason = "origin-repo-mismatch",
    cas = "skip-foreign(repo)", target = "reject", source_line = 96, origin_repo = "other/repo" },
  { disposition = "skip-origin-head", status = "rejected", reason = "origin-head-mismatch",
    cas = "skip-foreign(head)", target = "reject", source_line = 100, current_head = "other-branch" },
  { disposition = "skip-origin-base", status = "rejected", reason = "origin-base-mismatch",
    cas = "skip-foreign(base)", target = "reject", source_line = 105, current_base = "other-base" },
  { disposition = "skip-pr-closed", status = "rejected", reason = "pr-closed",
    cas = "skip-stale(pr-closed)", target = "reject", source_line = 109, pr_state = "CLOSED" },
  { disposition = "skip-head-advanced", status = "rejected", reason = "head-advanced",
    cas = "skip-stale(head-advanced)", target = "reject", source_line = 113, head_sha = "feedface" },
  { disposition = "skip-first-result-same", status = "rejected", reason = "first-result-same",
    cas = "skip-idempotent(first-result)", target = "reject", source_line = 130, first_decision = "approve" },
  { disposition = "suppress-first-result-divergent", status = "rejected", reason = "first-result-divergent",
    cas = "suppress-divergent-result", target = "reject", source_line = 140, first_decision = "reject",
    effects = ra.json_array({ DIVERGENCE_COMMENT }) },
  { disposition = "retry-high-risk-undecidable", status = "error", reason = "high-risk-undecidable",
    cas = "retry-pending(high-risk-review-evidence:diff-name-only-failed)", target = "retry", source_line = 161,
    risk = "unknown", error = "review-diff-risk-undecidable" },
  { disposition = "skip-idempotent-target", status = "rejected", reason = "already-at-target",
    cas = "skip-idempotent(already at to_state)", target = "reject", source_line = 205,
    current_state = "merge-ready", current_version = VERSION },
  { disposition = "skip-incoming-version-older", status = "rejected", reason = "incoming-version-older",
    cas = "skip-stale(incoming version < current marker version)", target = "reject", source_line = 205,
    current_state = "reviewing", current_version = VERSION .. "/fix/1", event_version = VERSION },
  { disposition = "retry-reviewing-marker-pending", status = "error", reason = "reviewing-marker-pending",
    cas = "retry-pending(from-state marker not yet visible)", target = "retry", source_line = 210,
    current_state = nil, error = "review-result-marker-missing" },
  { disposition = "skip-version-mismatch", status = "rejected", reason = "version-mismatch",
    cas = "skip-stale(version-mismatch)", target = "reject", source_line = 214,
    current_state = "reviewing", current_version = ORDER_EQUAL_CURRENT, event_version = ORDER_EQUAL_EVENT },
  { disposition = "admitted-fix-loop-terminal", status = "admitted", reason = "fix-loop-max-rounds",
    cas = "applied(fix-loop-max-rounds)", target = "blocked", source_line = 232,
    decision = "reject", max_fix_rounds = true, effects = ra.json_array({ FIX_RECONCILE, DECOMPOSE }) },
  { disposition = "admitted-approve-merge-ready", status = "admitted", reason = "approve",
    cas = "applied", target = "merge-ready", source_line = 241,
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "admitted-advisory-reject-merge-ready", status = "admitted", reason = "gate-owned-advisory",
    cas = "applied", target = "merge-ready", source_line = 241, decision = "reject",
    blocking_gap = "CI green evidence is missing for the current head.",
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "admitted-out-of-contract-reject-merge-ready", status = "admitted",
    reason = "out-of-contract-advisory", cas = "applied", target = "merge-ready", source_line = 147,
    decision = "reject",
    blocking_gap = "New requirement outside the stated issue acceptance bounds: prove API immutability.",
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "admitted-reject-fixing", status = "admitted", reason = "reject",
    cas = "applied", target = "fixing", source_line = 241, decision = "reject",
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "admitted-reject-review-meta", status = "admitted", reason = "reflection-checkpoint",
    cas = "applied", target = "review-meta", source_line = 241, decision = "reject", reflection = true,
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "admitted-high-risk-missing-angle-fixing", status = "admitted", reason = "high-risk-angle-missing",
    cas = "applied(high-risk-angle-not-approved)", target = "fixing", source_line = 239, risk = "high",
    effects = ra.json_array({ RESULT_COMMENT, RESULT_LABEL }) },
  { disposition = "admitted-high-risk-approve-with-evidence", status = "admitted", reason = "high-risk-approved",
    cas = "applied", target = "merge-ready", source_line = 241, risk = "high", high_risk_approve = true,
    effects = ra.json_array({ RESULT_COMMENT, EVIDENCE_COMMENT, RESULT_LABEL }) },
})

local function review_payload(fixture)
  if fixture.payload then return ra.copy_value(fixture.payload) end
  local event = h.review_reached({
    decision = fixture.decision or "approve",
    body = fixture.decision == "reject" and "Review consensus rejects the diff." or "Review consensus approves the diff.",
    blocking_gap = fixture.blocking_gap or (fixture.decision == "reject" and "missing OLD entry observation evidence" or nil),
    angle_results = fixture.high_risk_approve and {
      { angle = "teleology", verdict = "approve" }, { angle = "high-risk", verdict = "approve" },
    } or nil,
  })
  local version = fixture.event_version or VERSION
  if fixture.max_fix_rounds then
    for _ = 1, config.max_fix_rounds() do version = devloop_state.next_fix_version(version) end
  end
  event.proposal_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, version, HEAD_SHA)
  event.dedup_key = "consensus:" .. event.proposal_id .. "/review"
  event.source_ref = entity_lib.pr_source_ref(REPO, PR_NUMBER)
  if fixture.malformed_proposal then
    event.proposal_id = "github-devloop/pr-review/not-round-trippable"
    event.dedup_key = "consensus:" .. event.proposal_id .. "/review"
  end
  if fixture.mutate then fixture.mutate(event) end
  return event
end

local function max_round_version()
  local version = VERSION
  for _ = 1, config.max_fix_rounds() do version = devloop_state.next_fix_version(version) end
  return version
end

local function capture(fixture)
  h.mock_bot_env()
  local event = { queue = "consensus.consensus_reached", ts = "2026-06-03T02:03:04Z", payload = review_payload(fixture) }
  local ports = ra.fake_ports()
  local restorations = {}
  local captured = ra.capture_logging("review_result", devloop_logging, restorations)
  local current_version = fixture.max_fix_rounds and max_round_version() or fixture.current_version or VERSION
  local current_state = fixture.current_state
  if current_state == nil and not fixture.error and fixture.payload == nil then current_state = "reviewing" end
  if fixture.disposition == "retry-reviewing-marker-pending" then current_state = nil end
  local origin_repo = fixture.origin_repo or REPO
  local comments = ra.json_array({
    m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH, VERSION, "dev"),
  })
  if current_state then table.insert(comments, core.state_marker(PROPOSAL_ID, current_state, current_version)) end
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.pr_view_stdout({
      repo = origin_repo, number = PR_NUMBER, comments = comments,
      head = fixture.current_head or BRANCH, head_sha = fixture.head_sha or HEAD_SHA,
      base_branch = fixture.current_base or "dev", state = fixture.pr_state or "OPEN",
    }), stderr = "", exit_code = 0 }
  end
  function ports.github.pr_diff_name_only(repo, number, timeout)
    ra.record_write(ports.github_model, "pr_diff_name_only", { repo = repo, number = number, timeout = timeout })
    if fixture.risk == "unknown" then return { stdout = "", stderr = "diff failed", exit_code = 1 } end
    local stdout = fixture.risk == "high" and ".github/workflows/ci.yml\n" or "packages/github-devloop-pr/tests/example.lua\n"
    return { stdout = stdout, stderr = "", exit_code = 0 }
  end
  ra.replace(config, "branch_config", function() return { integration = "dev", upstream = "dev" } end, restorations)
  ra.replace(m_claims, "verify_pr_review_issue_claim", function() return true end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  if fixture.origin_repo then
    ra.replace(require("devloop.markers.facts"), "pr_origin_fact", function()
      return { repo = fixture.origin_repo, issue_number = ISSUE_NUMBER, proposal_id = PROPOSAL_ID,
        branch = BRANCH, base_branch = "dev", impl_version = VERSION }
    end, restorations)
  end
  if fixture.first_decision then
    ra.replace(result_facts, "first_review_result_fact", function()
      return { decision = fixture.first_decision }
    end, restorations)
  end
  if fixture.risk then
    ra.replace(github_risk, "github_diff_name_risk", function(result)
      if fixture.risk == "unknown" then return { known = false, reason = "diff-name-only-failed" } end
      return { known = true, high_risk = true, paths = { ".github/workflows/ci.yml" },
        high_risk_paths = { ".github/workflows/ci.yml" }, result = result }
    end, restorations)
  end
  local department = ra.make_department(review_result_module, ports, core)
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
    pr_state = fixture.pr_state or "OPEN", head_sha = fixture.head_sha or HEAD_SHA }
  fixture.effect_version = captured.applies[1] and captured.applies[1].version or nil
  fixture.issue_number = ISSUE_NUMBER
  return ra.record({ dept = "review_result", fixture = fixture, result = result, captured = captured,
    event = event, prefix = PREFIX, site = SITE, source_state = "reviewing", boundary = "entry_acceptor" })
end

return {
  test_review_result_entry_acceptor_old_behavior_is_real_dispatch_and_bidirectional = function()
    ra.assert_site(t, { dept = "review_result", fixtures = FIXTURES, capture = capture,
      prefix = PREFIX, site = SITE, boundary = "entry_acceptor" })
  end,
}
