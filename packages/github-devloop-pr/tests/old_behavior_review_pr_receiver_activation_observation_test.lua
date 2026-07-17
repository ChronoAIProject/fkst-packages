local ra = require("tests.receiver_activation_observation_helpers")
local config = require("devloop.config")
local context_bundle = require("devloop.context_bundle")
local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local payloads_builders = require("devloop.payloads.builders")
local testing = require("testkit_internal.testing")
local validate_proposal = require("devloop.validators.validate_proposal")
local review_pr_module = require("departments.review_pr.main")

local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local OTHER_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local HEAD_SHA = "def456"
local HANDOFF_ID = "IC_receiver_activation_review_pr"
local PREFIX = "receiver-activation-review-pr-"
local SITE = {
  path = "packages/github-devloop-pr/departments/review_pr/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:devloop_reviewing",
}

local function event_for(fixture)
  if fixture.payload then
    return { queue = "github-devloop-pr.devloop_reviewing", payload = ra.copy_value(fixture.payload) }
  end
  local payload = payloads_builders.build_devloop_reviewing_payload({
    proposal_id = PROPOSAL_ID,
    impl_version = fixture.event_version or VERSION,
  }, PR_NUMBER, { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER }, fixture.event_version or VERSION)
  if fixture.handoff then
    payload.reviewing_hand_off = {
      kind = "own-state-marker",
      proposal_id = PROPOSAL_ID,
      state = "reviewing",
      marker_version = payload.version,
      event_version = payload.version,
      stage_rank = core.stage_rank("reviewing"),
      comment_id = HANDOFF_ID,
    }
  end
  return { queue = "github-devloop-pr.devloop_reviewing", ts = "2026-06-03T02:03:04Z", payload = payload }
end

local FIXTURES = ra.json_array({
  {
    disposition = "skip-foreign-payload", status = "rejected", reason = "skip-foreign(payload)",
    cas = "skip-foreign(payload)", target = "reject", source_line = 58,
    payload = { schema = "unsupported.reviewing.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" },
  },
  {
    disposition = "skip-version-mismatch", status = "rejected", reason = "version-mismatch",
    cas = "skip-stale(version-mismatch)", target = "reject", source_line = 113,
    current_state = "reviewing", current_version = VERSION, event_version = OTHER_VERSION,
  },
  {
    disposition = "skip-version-mismatch-invalid-handoff", status = "rejected", reason = "version-mismatch-invalid-handoff",
    cas = "skip-stale(version-mismatch)", target = "reject", source_line = 113,
    current_state = "reviewing", current_version = VERSION, event_version = OTHER_VERSION, handoff = "invalid",
    handoff_lookup_count = 1,
  },
  {
    disposition = "skip-advanced-or-diverged", status = "rejected", reason = "advanced-or-diverged",
    cas = "skip-stale/diverged", target = "reject", source_line = 121,
    current_state = "merge-ready", current_version = VERSION,
  },
  {
    disposition = "skip-pr-closed", status = "rejected", reason = "pr-closed",
    cas = "skip-stale(pr-closed)", target = "reject", source_line = 134,
    current_state = "reviewing", current_version = VERSION, pr_state = "CLOSED",
  },
  {
    disposition = "claim-not-acquired", status = "rejected", reason = "claim-not-acquired",
    cas = "skip-claimed-by-other", target = "reject", source_line = 151,
    current_state = "reviewing", current_version = VERSION, claim = false,
  },
  {
    disposition = "cannot-build-valid-proposal", status = "rejected", reason = "cannot-build-valid-review-proposal",
    cas = "cannot-build-valid-review-proposal", target = "reject", source_line = 181,
    current_state = "reviewing", current_version = VERSION, invalid_proposal = true,
  },
  {
    disposition = "admitted-visible-marker", status = "admitted", reason = "admitted-proceed",
    cas = "applied", target = "consensus.proposal", source_line = 187,
    current_state = "reviewing", current_version = VERSION,
    effects = ra.json_array({ "queue:consensus.proposal" }),
  },
  {
    disposition = "admitted-verified-handoff-from-version-mismatch", status = "admitted",
    reason = "verified-own-reviewing-hand-off", cas = "apply(verified-own-reviewing-hand-off)",
    target = "consensus.proposal", source_line = 102,
    current_state = "reviewing", current_version = VERSION, event_version = OTHER_VERSION, handoff = "valid",
    handoff_lookup_count = 1, effects = ra.json_array({ "queue:consensus.proposal" }),
  },
  {
    disposition = "admitted-verified-handoff-from-earlier-state", status = "admitted",
    reason = "verified-own-reviewing-hand-off-earlier-state", cas = "apply(verified-own-reviewing-hand-off)",
    target = "consensus.proposal", source_line = 102,
    current_state = "pr-open", current_version = VERSION, handoff = "valid",
    handoff_lookup_count = 1, effects = ra.json_array({ "queue:consensus.proposal" }),
  },
})

local function capture(fixture)
  h.mock_bot_env()
  local event = event_for(fixture)
  local ports = ra.fake_ports()
  local restorations = {}
  local captured = ra.capture_logging("review_pr", devloop_logging, restorations)
  local handoff_reads = 0
  local current = {
    state = fixture.current_state,
    version = fixture.current_version,
    stage_rank = fixture.current_state and core.stage_rank(fixture.current_state) or nil,
  }
  local comments = ra.json_array({
    m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), "devloop-owner-repo-42-01HY", VERSION, "dev"),
  })
  if fixture.current_state then table.insert(comments, core.state_marker(PROPOSAL_ID, fixture.current_state, fixture.current_version)) end
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.pr_view_stdout({
      repo = REPO, number = PR_NUMBER, comments = comments, head = "devloop-owner-repo-42-01HY",
      head_sha = HEAD_SHA, base_branch = "dev", state = fixture.pr_state or "OPEN",
    }), stderr = "", exit_code = 0 }
  end
  function ports.github.issue_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "issue_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.issue_view_stdout({
      repo = REPO, number = ISSUE_NUMBER, comments = comments, labels = { "fkst-dev:reviewing" },
      assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot",
    }), stderr = "", exit_code = 0 }
  end
  function ports.github.comment_get(repo, comment_id, timeout)
    handoff_reads = handoff_reads + 1
    ra.record_write(ports.github_model, "comment_get", { repo = repo, comment_id = comment_id, timeout = timeout })
    local author = fixture.handoff == "invalid" and "not-the-devloop-bot" or "fkst-test-bot"
    return { stdout = '{"id":"' .. HANDOFF_ID .. '","body":' .. ra.canonical_json(core.state_marker(
      PROPOSAL_ID, "reviewing", event.payload.version)) .. ',"user":{"login":"' .. author .. '"}}', stderr = "", exit_code = 0 }
  end
  ra.replace(entity_lib, "current_entity_state", function() return ra.copy_value(current) end, restorations)
  ra.replace(m_claims, "verify_pr_review_issue_claim", function(_, _, _, _, proposal_id)
    if fixture.claim == false then
      devloop_logging.log_cas_decision("review_pr", proposal_id, { state = nil, version = nil }, "claim", "claim", "skip-claimed-by-other", "backing issue assignee claim is held by another login")
      return false
    end
    return true
  end, restorations)
  ra.replace(context_bundle, "context_fetch_ref_from_bundle", function()
    return { kind = "context-bundle", ref = "receiver-activation-review-pr" }, false
  end, restorations)
  ra.replace(devloop_commands, "existing_implementation_worktree", function() return nil end, restorations)
  ra.replace(validate_proposal, "validate_proposal", function() return not fixture.invalid_proposal end, restorations)
  ra.replace(config, "branch_config", function() return { upstream = "dev", integration = "dev" } end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  local department = ra.make_department(review_pr_module, ports, core)
  local ok, result = pcall(testing.run_fake, department, event)
  ra.restore_all(restorations)
  if not ok then error(fixture.disposition .. ": " .. tostring(result), 0) end
  t.eq(handoff_reads, fixture.handoff_lookup_count or 0, fixture.disposition .. ": direct handoff lookup count")
  local selected = nil
  for _, decision in ipairs(captured.decisions) do
    if decision.outcome == fixture.cas then selected = decision break end
  end
  if fixture.invalid_proposal then
    t.eq(#captured.decisions, 0, fixture.disposition .. ": warning-only build rejection")
  else
    t.is_true(selected ~= nil, fixture.disposition .. ": observable admission decision")
    t.eq(selected.outcome, fixture.cas, fixture.disposition .. ": exact admission mapping")
  end
  return ra.record({
    dept = "review_pr", fixture = fixture, result = result, captured = captured, event = event,
    prefix = PREFIX, site = SITE, source_state = "reviewing",
  })
end

return {
  test_review_pr_receiver_activation_old_behavior_is_real_dispatch_and_bidirectional = function()
    ra.assert_site(t, {
      dept = "review_pr", fixtures = FIXTURES, capture = capture, prefix = PREFIX, site = SITE,
    })
  end,
}
