local ra = require("tests.receiver_activation_observation_helpers")
local context_bundle = require("devloop.context_bundle")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local payloads_builders = require("devloop.payloads.builders")
local testing = require("testkit_internal.testing")
local workflow_codex = require("workflow_internal.codex")
local review_meta_module = require("departments.review_meta.main")

local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local ORDER_EQUAL_CURRENT = VERSION .. "/loop/01"
local ORDER_EQUAL_EVENT = VERSION .. "/loop/1"
local HEAD_SHA = "def456"
local REVIEW_META_DISPATCH_ENTITLEMENT_ID = "github-devloop-pr/review-meta/receiver_dispatch"
local PREFIX = "receiver-activation-review-meta-"
local SITE = {
  path = "packages/github-devloop-pr/departments/review_meta/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:devloop_review_meta",
}

local function payload_for(version)
  local review_id = require("devloop.base").pr_review_proposal_id(REPO, PR_NUMBER, version, HEAD_SHA)
  return payloads_builders.build_devloop_review_meta_payload({
    proposal_id = review_id,
    dedup_key = "consensus:" .. review_id .. "/review/loop/2",
    source_ref = { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER },
  }, PROPOSAL_ID, version, PR_NUMBER, 3, { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER })
end

local FIXTURES = ra.json_array({
  {
    disposition = "skip-foreign-payload", status = "rejected", reason = "skip-foreign(payload)",
    cas = "skip-foreign(payload)", target = "reject", source_line = 154,
    payload = { schema = "unsupported.review-meta.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" },
  },
  {
    disposition = "claim-not-acquired", status = "rejected", reason = "claim-not-acquired",
    cas = "skip-claimed-by-other", target = "reject", source_line = 166,
    current_state = "review-meta", current_version = VERSION, claim = false,
  },
  {
    disposition = "skip-result-marker-visible", status = "rejected", reason = "result-marker-visible",
    cas = "skip-idempotent(review-meta marker already visible)", target = "reject", source_line = 216,
    current_state = "fixing", current_version = VERSION, result_marker = true,
  },
  {
    disposition = "skip-advanced-or-diverged", status = "rejected", reason = "advanced-or-diverged",
    cas = "skip-advanced-or-diverged", target = "reject", source_line = 220,
    current_state = "blocked", current_version = VERSION,
  },
  {
    disposition = "skip-version-mismatch", status = "rejected", reason = "version-mismatch",
    cas = "skip-stale(version-mismatch)", target = "reject", source_line = 224,
    current_state = "review-meta", current_version = ORDER_EQUAL_CURRENT, event_version = ORDER_EQUAL_EVENT,
  },
  {
    disposition = "live-exec-deferred", status = "rejected", reason = "live-exec-ref",
    cas = "skip-idempotent(live-exec-ref)", target = "defer", source_line = 242,
    current_state = "review-meta", current_version = VERSION, live_run = true,
  },
  {
    disposition = "codex-deferred", status = "rejected", reason = "codex-deferred",
    cas = "applied", target = "defer", source_line = 247,
    current_state = "review-meta", current_version = VERSION, codex_deferred = true,
    effects = ra.json_array({ "codex.dispatch:review-meta" }),
  },
  {
    disposition = "admitted-fix", status = "admitted", reason = "admitted-fix",
    cas = "applied", target = "fixing", source_line = 249,
    current_state = "review-meta", current_version = VERSION, action = "fix",
    effects = ra.json_array({ "codex.dispatch:review-meta", "comment:pr:review-meta-result", "label:issue:review-meta-result" }),
  },
  {
    disposition = "admitted-block", status = "admitted", reason = "admitted-block",
    cas = "applied", target = "blocked", source_line = 249,
    current_state = "review-meta", current_version = VERSION, action = "block",
    effects = ra.json_array({ "codex.dispatch:review-meta", "comment:pr:review-meta-result", "label:issue:review-meta-result" }),
  },
})

local SINK_PROBES = ra.json_array({
  {
    id = "r9-shadow-review-meta-reviewing-needs-review-meta-idempotent",
    current_state = "review-meta", from_states = { "reviewing" }, target_state = "review-meta",
    version = VERSION, expected_status = "idempotent",
    fixture = {
      disposition = "shadow-reviewing-needs-review-meta", status = "admitted", reason = "admitted-fix",
      cas = "applied", target = "fixing", source_line = 249,
      current_state = "review-meta", current_version = VERSION, action = "fix",
      effects = ra.json_array({
        "codex.dispatch:review-meta", "comment:pr:review-meta-result", "label:issue:review-meta-result",
      }),
    },
    entitlements = {
      ["codex.dispatch:review-meta"] = {
        REVIEW_META_DISPATCH_ENTITLEMENT_ID,
      },
    },
  },
  {
    id = "r9-shadow-review-meta-fixing-revision-failed-idempotent",
    current_state = "review-meta", from_states = { "fixing" }, target_state = "review-meta",
    version = VERSION, expected_status = "idempotent",
    fixture = {
      disposition = "shadow-fixing-revision-failed", status = "admitted", reason = "admitted-fix",
      cas = "applied", target = "fixing", source_line = 249,
      current_state = "review-meta", current_version = VERSION, action = "fix",
      effects = ra.json_array({
        "codex.dispatch:review-meta", "comment:pr:review-meta-result", "label:issue:review-meta-result",
      }),
    },
    entitlements = {
      ["codex.dispatch:review-meta"] = {
        REVIEW_META_DISPATCH_ENTITLEMENT_ID,
      },
    },
  },
})

local function event_for(fixture)
  return {
    queue = "github-devloop-pr.devloop_review_meta",
    ts = "2026-06-03T02:03:04Z",
    payload = fixture.payload and ra.copy_value(fixture.payload) or payload_for(fixture.event_version or VERSION),
  }
end

local function capture(fixture)
  h.mock_bot_env()
  local event = event_for(fixture)
  local ports = ra.fake_ports()
  local restorations = {}
  local captured = ra.capture_logging("review_meta", devloop_logging, restorations)
  local comments = ra.json_array()
  if fixture.current_state then
    table.insert(comments, core.state_marker(PROPOSAL_ID, fixture.current_state, fixture.current_version))
  end
  if fixture.result_marker then
    table.insert(comments, m_builders.review_meta_marker(PROPOSAL_ID, event.payload.dedup_key, "block",
      core.next_review_meta_action_version(event.payload.version)))
  end
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.pr_view_stdout({
      repo = REPO, number = PR_NUMBER, comments = comments, head_sha = HEAD_SHA,
      head = "devloop-owner-repo-42-01HY", base_branch = "dev", state = "OPEN",
    }), stderr = "", exit_code = 0 }
  end
  function ports.github.issue_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "issue_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.issue_view_stdout({ repo = REPO, number = ISSUE_NUMBER,
      assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot" }), stderr = "", exit_code = 0 }
  end
  ra.replace(entity_lib, "current_entity_state", function()
    return { state = fixture.current_state, version = fixture.current_version,
      stage_rank = fixture.current_state and core.stage_rank(fixture.current_state) or nil }
  end, restorations)
  ra.replace(m_claims, "verify_pr_review_issue_claim", function(_, _, _, _, proposal_id)
    if fixture.claim == false then
      devloop_logging.log_cas_decision("review_meta", proposal_id, { state = nil, version = nil }, "claim", "claim", "skip-claimed-by-other", "backing issue assignee claim is held by another login")
      return false
    end
    return true
  end, restorations)
  ra.replace(context_bundle, "context_fetch_from_bundle", function()
    return { kind = "context-bundle", ref = "receiver-activation-review-meta" }
  end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  local codex_reads = 0
  ra.replace(fkst, "codex_runs", function()
    codex_reads = codex_reads + 1
    local running = ra.json_array()
    if fixture.live_run then
      table.insert(running, { role = "review-meta", proposal_id = PROPOSAL_ID,
        dedup_key = event.payload.version, status = "running" })
    end
    return { running = running }
  end, restorations)
  ra.replace(workflow_codex, "dispatch", function(_, _)
    table.insert(captured.effect_sequence, {
      kind = "adapter",
      call = { kind = "codex", role = "review-meta", proposal_id = PROPOSAL_ID, version = event.payload.version },
    })
    if fixture.codex_deferred then return { deferred = true, reason = "live-exec-ref" } end
    local action = fixture.action or "block"
    local stdout = core._action_label .. " " .. action .. "\n" .. core._reason_label .. " Receiver activation decision."
    if action == "fix" then stdout = stdout .. "\nBlocking gap: missing receiver activation evidence" end
    return { stdout = stdout, stderr = "", exit_code = 0 }
  end, restorations)
  local department = ra.make_department(review_meta_module, ports, core)
  local ok, result = pcall(testing.run_fake, department, event)
  ra.restore_all(restorations)
  if not ok then error(fixture.disposition .. ": " .. tostring(result), 0) end
  local selected = nil
  for _, decision in ipairs(captured.decisions) do
    if decision.outcome == fixture.cas then selected = decision break end
  end
  t.is_true(selected ~= nil, fixture.disposition .. ": observable admission decision")
  t.eq(selected.outcome, fixture.cas, fixture.disposition .. ": exact admission mapping")
  return ra.record({
    dept = "review_meta", fixture = fixture, result = result, captured = captured, event = event,
    prefix = PREFIX, site = SITE, source_state = "review-meta",
  })
end

return {
  test_review_meta_receiver_activation_old_behavior_is_real_dispatch_and_bidirectional = function()
    local shadow_sink_records = ra.capture_shadow_sink_probes(t, {
      probes = SINK_PROBES,
      capture = capture,
      devloop_state = devloop_state,
    })
    ra.assert_site(t, {
      dept = "review_meta", fixtures = FIXTURES, capture = capture, prefix = PREFIX, site = SITE,
      shadow_corpus_path = "migration/intent_bounded_replay/corpus/pr-review-meta.json",
      shadow_sink_records = shadow_sink_records,
    })
  end,
}
