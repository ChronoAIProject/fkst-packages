-- OLD is the real observe_pr not-mergeable admission. Later PR-label
-- reconciliation remains covered by integration_observe_pr_mergeability_test.
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")

local t = h.t
local core = h.core
local OWNER = core.restart_package_name
local FAMILY = "observe-pr-fix"
local SCHEMA = "restart-observe-pr-fix-trace.v1"
local EDGE_ID = OWNER .. "/pr-open/autonomous/not_mergeable_repair"
local CORPUS_PATH = "migration/intent_bounded_replay/corpus/observe-pr-fix.json"
local NEW_TRACE_PATH = ".fkst/run/r9-observe-pr-fix-new-trace.json"

local COMMENT_EFFECT_ID = "github-proxy.github_pr_comment_request"
local LABEL_EFFECT_ID = "github-proxy.github_issue_label_request"
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 731
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local BRANCH = "devloop-owner-repo-42-01HY"

local HEAD_SHA = "def456"
local REASON = "mergeable-conflicting"
local FIXTURE = {
  fixture_id = "pr-open-conflict-apply",
  name = "r9-observe-pr-fix-pr-open-conflict",
  current_state = "pr-open",
  current_version = VERSION,
}

local function pr_event()
  return {
    schema = "github-proxy.v1",
    type = "pr",
    repo = REPO,

    number = PR_NUMBER,
    state = "OPEN",
    updated_at = "2026-06-04T01:02:03Z",

    dedup_key = REPO .. "#pr#" .. tostring(PR_NUMBER) .. "@2026-06-04T01:02:03Z",
    source_ref = entity_lib.pr_source_ref(REPO, PR_NUMBER),
  }
end

local function observe_old(fixture)
  local comments = {
    m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH, VERSION, "dev"),
    core.state_marker(PROPOSAL_ID, fixture.current_state, fixture.current_version),
  }

  h.mock_bot_env()
  h.mock_default_issue_claim(REPO, ISSUE_NUMBER)
  h.mock_pr_origin_for({ repo = REPO, number = PR_NUMBER, comments = comments,
    head = BRANCH, head_sha = HEAD_SHA, base_branch = "dev",
    labels = { "fkst-dev:fixing" }, mergeable = "CONFLICTING",
    merge_state = "DIRTY", times = 2 })

  local ok, result = pcall(t.run_department, "departments/observe_pr/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = pr_event(),
  }, h.opts(fixture.name))
  if not ok then error(result, 0) end
  t.eq(result.exit_code, 0, fixture.name .. ": OLD department exit")
  t.eq(#result.raises, 2, fixture.name .. ": OLD admission effect count")
  t.eq(result.raises[1].queue, COMMENT_EFFECT_ID, fixture.name .. ": OLD comment first")
  t.eq(result.raises[2].queue, LABEL_EFFECT_ID, fixture.name .. ": OLD label second")

  return { event = pr_event(), result = result, status = "apply" }
end

local function facade_args(event)
  local review_proposal_id = devloop_base.pr_review_proposal_id(
    REPO, PR_NUMBER, VERSION, HEAD_SHA)
  return {
    core = core,
    repo = REPO,
    issue_number = ISSUE_NUMBER,

    pr_number = PR_NUMBER,
    source_ref = event.source_ref,
    issue_source_ref = entity_lib.issue_source_ref(REPO, ISSUE_NUMBER),
    fix_version = core.next_fix_version(VERSION),
    reason = REASON,
    comment_origin = {
      proposal_id = PROPOSAL_ID,

      pr_number = PR_NUMBER,
      version = VERSION,
      review_proposal_id = review_proposal_id,

      review_dedup_key = "observe-pr-conflict/" .. PROPOSAL_ID
        .. "/" .. VERSION .. "/" .. tostring(PR_NUMBER),
      reviewed_head_sha = HEAD_SHA,
      dedup_key = VERSION .. "/observe-pr-conflict",

    },
  }
end

local function observe_new(fixture, old)
  local snapshot = restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "pr", repo = REPO, number = PR_NUMBER },
    proposal_id = PROPOSAL_ID,
    current = { state = fixture.current_state, version = fixture.current_version },

    snapshot_fingerprint = "r9-observe-pr-fix:" .. fixture.fixture_id,
    lock_epoch = "r9-observe-pr-fix:lock",
    generation = "r9-observe-pr-fix:generation",
  })

  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "not_mergeable_repair", target = "fixing" })
  local writes = observation_support.json_array()
  if decided.status == "apply" then

    local grant = restart_effects.mint_grant(
      snapshot, decided, "comment:pr:observe-merge-gate-fix")
    t.is_true(grant ~= nil, fixture.fixture_id .. ": NEW grant minted")
    local facade = restart_effect_facade.make({
      family = FAMILY,
      verify_grant = restart_effects.verify_grant,

      sink_inventory = require("core.restart.sink_inventory"),
    })
    for ordinal, effect_id in ipairs(decided.granted_effect_ids) do

      local emitted = facade.emit(grant, effect_id, snapshot, facade_args(old.event))
      t.is_true(emitted ~= nil, fixture.fixture_id .. ": NEW emitted " .. effect_id)
      table.insert(writes, observation_support.admission_trace_write(ordinal, effect_id, emitted))

    end
  end
  return decided, writes
end

local function trace_artifact(hash, fixtures)
  return observation_support.admission_trace_artifact(
    SCHEMA, OWNER, FAMILY, hash, fixtures)
end

local function trace_fixture(fixture, status, reason, outcome, entitlement, ids, writes)
  return observation_support.admission_trace_fixture(
    fixture, EDGE_ID, status, reason, outcome, entitlement, ids, writes)
end

local function assert_trace_equality()
  local corpus = json.decode(file.read(CORPUS_PATH))
  local old = observe_old(FIXTURE)
  local decided, new_writes = observe_new(FIXTURE, old)
  local ids = decided.granted_effect_ids
  local entitlement = decided.effect_entitlement_id

  local old_writes = observation_support.admission_trace_writes(
    old.result.raises, "R9 observe_pr fix trace")
  local old_fixtures = observation_support.json_array({
    trace_fixture(FIXTURE, "apply", "apply", "applied", entitlement, ids, old_writes),
  })

  local new_fixtures = observation_support.json_array({
    trace_fixture(FIXTURE, decided.status, decided.reason_code,
      decided.cas_outcome, entitlement, ids, new_writes),
  })

  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  local new_trace = trace_artifact(corpus.artifact_sha256, new_fixtures)
  local canonical_json = observation_support.canonical_json
  t.eq(canonical_json(old_trace), canonical_json(new_trace),
    "R9 observe_pr fix OLD and NEW semantic trace")

  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 observe_pr fix trace could not create its artifact directory", 0)
  end

  file.write(NEW_TRACE_PATH, canonical_json(new_trace) .. "\n")
  t.eq(canonical_json(old_trace), canonical_json(corpus),
    "R9 observe_pr fix OLD observation corpus")
  t.eq(canonical_json(new_trace), canonical_json(corpus),
    "R9 observe_pr fix NEW semantic trace")
end

return {
  test_observe_pr_fix_r9_old_equals_new_trace = function()
    assert_trace_equality()
  end,
}
