local ra = require("tests.receiver_activation_observation_helpers")
local check_runs = require("forge.github.check_runs")
local config = require("devloop.config")
local devloop_logging = require("devloop.logging")
local devloop_entity_view = require("devloop.github_proxy_entity_view")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local m_facts = require("devloop.markers.facts")
local operator_commands = require("devloop.operator_commands")
local parsers_pr = require("devloop.parsers.pr")
local replay = require("devloop.replayer")
local requests_review = require("devloop.requests.review")
local testing = require("testkit_internal.testing")
local observe_pr_module = require("departments.observe_pr.main")

local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local HEAD_SHA = "def456"
local BRANCH = "devloop-owner-repo-42-01HY"
local PREFIX = "receiver-activation-observe-pr-"
local SITE = {
  path = "packages/github-devloop-pr/departments/observe_pr/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:devloop_observe_pr",
}

local function pr_payload(extra)
  local payload = {
    schema = "github-proxy.v1", type = "pr", repo = REPO, number = PR_NUMBER,
    updated_at = "2026-06-03T02:03:04Z", dedup_key = REPO .. "#pr#7@2026-06-03T02:03:04Z",
    source_ref = { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER },
  }
  for key, value in pairs(extra or {}) do payload[key] = value end
  return payload
end

local FIXTURES = ra.json_array({
  {
    disposition = "skip-foreign-payload", status = "rejected", reason = "skip-foreign(pr)",
    cas = "skip-foreign(pr)", target = "reject", source_line = 500,
    payload = { schema = "unsupported.pr.v1", type = "pr", repo = REPO, number = PR_NUMBER, dedup_key = "bad" },
  },
  {
    disposition = "skip-branch-facts-missing", status = "rejected", reason = "branch-facts-missing",
    cas = "skip-foreign(pr)", target = "reject", source_line = 515, missing_branch = true,
  },
  {
    disposition = "skip-origin-head-mismatch", status = "rejected", reason = "origin-head-mismatch",
    cas = "skip-foreign(head)", target = "reject", source_line = 528, current_head = "other-branch",
  },
  {
    disposition = "skip-origin-base-mismatch", status = "rejected", reason = "origin-base-mismatch",
    cas = "skip-foreign(base)", target = "reject", source_line = 528, current_base = "other-base",
  },
  {
    disposition = "claim-not-acquired", status = "rejected", reason = "claim-not-acquired",
    cas = "skip-claimed-by-other", target = "reject", source_line = 545,
    current_state = "reviewing", current_version = VERSION, claim = false,
  },
  {
    disposition = "operator-refused-invalid-state", status = "rejected", reason = "operator-invalid-state",
    cas = "refused(invalid-state)", target = "reject", source_line = 210,
    current_state = "fixing", current_version = VERSION, operator = true,
    effects = ra.json_array({ "comment:pr:operator-refusal" }),
  },
  {
    disposition = "operator-refused-active-reviewing", status = "rejected", reason = "operator-active-reviewing",
    cas = "refused(active-reviewing)", target = "reject", source_line = 221,
    current_state = "reviewing", current_version = VERSION, operator = true, active_review = true,
    effects = ra.json_array({ "comment:pr:operator-refusal" }),
  },
  {
    disposition = "operator-refused-pr-closed", status = "rejected", reason = "operator-pr-closed",
    cas = "refused(pr-closed)", target = "reject", source_line = 233,
    current_state = "blocked", current_version = VERSION, operator = true, pr_state = "CLOSED",
    effects = ra.json_array({ "comment:pr:operator-refusal" }),
  },
  {
    disposition = "operator-refused-head-missing", status = "rejected", reason = "operator-head-missing",
    cas = "refused(head-missing)", target = "reject", source_line = 244,
    current_state = "blocked", current_version = VERSION, operator = true, head_sha = "missing",
    effects = ra.json_array({ "comment:pr:operator-refusal" }),
  },
  {
    disposition = "operator-rereview-applied", status = "admitted", reason = "operator-rereview",
    cas = "applied(operator-rereview)", target = "reviewing", source_line = 260,
    current_state = "blocked", current_version = VERSION, operator = true,
    effects = ra.json_array({ "comment:pr:operator-rereview" }),
  },
  {
    disposition = "not-mergeable-already-fixing", status = "rejected", reason = "already-fixing",
    cas = "skip-idempotent(already at to_state)", target = "reject", source_line = 330,
    current_state = "merge-ready", current_version = VERSION, not_mergeable = true, already_fixing = true,
  },
  {
    disposition = "not-mergeable-routes-fixing", status = "admitted", reason = "not-mergeable",
    cas = "applied(not-mergeable)", target = "fixing", source_line = 379,
    current_state = "reviewing", current_version = VERSION, not_mergeable = true,
    effects = ra.json_array({ "comment:pr:observe-merge-gate-fix", "label:issue:observe-merge-gate-fix" }),
  },
  {
    disposition = "base-unmanaged-blocked", status = "admitted", reason = "base-unmanaged",
    cas = "applied(pr-base-unmanaged)", target = "blocked", source_line = 488,
    current_state = "pr-open", current_version = VERSION, origin_base = "feature-base", current_base = "feature-base",
    effects = ra.json_array({ "comment:pr:base-unmanaged" }),
  },
  {
    disposition = "base-self-heal-reviewing", status = "admitted", reason = "base-self-heal",
    cas = "applied(pr-base-unmanaged-self-heal)", target = "reviewing", source_line = 435,
    current_state = "blocked", current_version = requests_review.pr_base_unmanaged_blocked_version(VERSION),
    effects = ra.json_array({ "comment:pr:observe-reviewing" }),
  },
  {
    disposition = "admitted-replay-dispatched", status = "admitted", reason = "admitted-replay-dispatched",
    cas = "dispatched(replay_from_table)", target = "replay", source_line = 577,
    current_state = "reviewing", current_version = VERSION, replay = true,
  },
})

local function capture(fixture)
  h.mock_bot_env()
  local event = { queue = "github-devloop-pr.devloop_observe_pr", ts = "2026-06-03T02:03:04Z",
    payload = fixture.payload and ra.copy_value(fixture.payload) or pr_payload() }
  local ports = ra.fake_ports()
  local restorations = {}
  local captured = ra.capture_logging("observe_pr", devloop_logging, restorations)
  local origin_base = fixture.origin_base or "dev"
  local comments = ra.json_array({
    m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH, VERSION, origin_base),
  })
  if fixture.operator then
    table.insert(comments, { id = "IC_operator_rereview", body = "fkst: rereview",
      author_login = "fkst-test-bot", created_at = "2026-06-03T02:00:00Z" })
  end
  local current_pr = {
    comments = comments, labels = fixture.not_mergeable and { "fkst-dev:fixing" } or {},
    head_ref_name = fixture.current_head or BRANCH, head_sha = fixture.head_sha or HEAD_SHA,
    base_ref_name = fixture.current_base or "dev", state = fixture.pr_state or "OPEN",
    mergeable = fixture.not_mergeable and "CONFLICTING" or "MERGEABLE",
    merge_state_status = fixture.not_mergeable and "DIRTY" or "CLEAN",
  }
  ra.replace(devloop_entity_view, "fetch_pr_view_origin", function()
    return { stdout = "{}", stderr = "", exit_code = 0 }
  end, restorations)
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.pr_view_stdout({ repo = REPO, number = PR_NUMBER,
      comments = comments, head = current_pr.head_ref_name, head_sha = current_pr.head_sha,
      base_branch = current_pr.base_ref_name, state = current_pr.state,
      mergeable = current_pr.mergeable, merge_state = current_pr.merge_state_status,
    }), stderr = "", exit_code = 0 }
  end
  function ports.github.pr_updated_at(repo, number, timeout)
    ra.record_write(ports.github_model, "pr_updated_at", { repo = repo, number = number, timeout = timeout })
    return { stdout = "2026-06-03T02:03:04Z\n", stderr = "", exit_code = 0 }
  end
  function ports.github.pr_rest_view(repo, number, timeout)
    ra.record_write(ports.github_model, "pr_rest_view", { repo = repo, number = number, timeout = timeout })
    return { stdout = entity_read_mocks.pr_view_stdout({ repo = REPO, number = PR_NUMBER,
      comments = comments, head = current_pr.head_ref_name, head_sha = current_pr.head_sha,
      base_branch = current_pr.base_ref_name, state = current_pr.state }), stderr = "", exit_code = 0 }
  end
  ra.replace(parsers_pr, "parse_pr_view_origin", function() return current_pr end, restorations)
  if fixture.missing_branch then
    ra.replace(m_facts, "pr_origin_fact", function()
      return { proposal_id = PROPOSAL_ID, repo = REPO, issue_number = ISSUE_NUMBER,
        branch = nil, base_branch = nil, impl_version = VERSION }
    end, restorations)
  end
  ra.replace(entity_lib, "current_entity_state", function()
    if fixture.already_fixing then
      return { state = "fixing", version = require("devloop.state").next_fix_version(VERSION), stage_rank = core.stage_rank("fixing") }
    end
    return { state = fixture.current_state, version = fixture.current_version,
      stage_rank = fixture.current_state and core.stage_rank(fixture.current_state) or nil }
  end, restorations)
  ra.replace(m_claims, "read_current_issue_ownership", function()
    return { assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot", labels = {} }
  end, restorations)
  ra.replace(m_claims, "verify_pr_review_issue_claim", function(dept, _, _, _, proposal_id)
    if fixture.claim == false then
      devloop_logging.log_cas_decision(dept, proposal_id, { state = nil, version = nil }, "claim", "claim", "skip-claimed-by-other", "backing issue assignee claim is held by another login")
      return false
    end
    return true
  end, restorations)
  ra.replace(check_runs, "pr_mergeable", function()
    if fixture.not_mergeable then return false, "merge-state-dirty" end
    return true, "mergeable"
  end, restorations)
  ra.replace(check_runs, "is_not_mergeable_reason", function(reason) return reason == "merge-state-dirty" end, restorations)
  ra.replace(core, "fixing_replay_feedback_fact", function() return nil end, restorations)
  ra.replace(replay, "replay_from_table", function() return true end, restorations)
  if fixture.active_review then
    ra.replace(require("devloop.convergence.rounds"), "is_true_stall", function() return false end, restorations)
  end
  ra.replace(config, "branch_config", function() return { upstream = "dev", integration = "dev" } end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  local department = ra.make_department(observe_pr_module, ports, core)
  local ok, result = pcall(testing.run_fake, department, event)
  ra.restore_all(restorations)
  if not ok then error(fixture.disposition .. ": " .. tostring(result), 0) end
  local selected = nil
  if fixture.replay then
    selected = { outcome = fixture.cas }
  else
    for _, decision in ipairs(captured.decisions) do
      if decision.outcome == fixture.cas then selected = decision break end
    end
  end
  t.is_true(selected ~= nil, fixture.disposition .. ": observable admission decision")
  return ra.record({ dept = "observe_pr", fixture = fixture, result = result, captured = captured, event = event,
    prefix = PREFIX, site = SITE, source_state = "observed-pr" })
end

return {
  test_observe_pr_receiver_activation_old_behavior_is_real_dispatch_and_bidirectional = function()
    ra.assert_site(t, { dept = "observe_pr", fixtures = FIXTURES, capture = capture, prefix = PREFIX, site = SITE })
  end,
}
