local h = require("tests.devloop_helpers")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")

local M = {}
local t = h.t
local core = h.core

local OWNER = "github-devloop-pr"
local EDGE_ID = OWNER .. "/reviewing/autonomous/changes_requested"
local CORPUS_PATH = "migration/intent_bounded_replay/corpus/pr-review-result.json"
local OUTPUT_PATH = ".fkst/run/r9-pr-review-result-new-trace.json"
local V_OLDER = "2026-06-02T01-02-03Z"
local V_EQUAL = "2026-06-03T01-02-03Z"

local FIXTURES = {
  {
    fixture_id = "newer-source-marker-missing-pending",
    name = "r9-pr-review-result-pending",
    current_state = nil,
    current_version = nil,
    incoming_version = V_EQUAL,
    target_state = "fixing",
    expected_exit_code = 1,
    legacy_log_outcome = "retry-pending(from-state marker not yet visible)",
  },
  {
    fixture_id = "source-equal-apply",
    name = "r9-pr-review-result-apply",
    current_state = "reviewing",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    target_state = "fixing",
    comment_builder_reached = true,
    effect_state = "fixing",
    post_admission_disposition = "effect-emitted(fixing)",
    expected_queues = {
      "github-proxy.github_pr_comment_request",
      "github-proxy.github_issue_label_request",
    },
    legacy_log_outcome = "applied",
  },
  {
    fixture_id = "source-older-stale",
    name = "r9-pr-review-result-stale",
    current_state = "reviewing",
    current_version = V_EQUAL,
    incoming_version = V_OLDER,
    target_state = "fixing",
    legacy_log_outcome = "skip-stale(incoming version < current marker version)",
  },
  {
    fixture_id = "target-idempotent",
    name = "r9-pr-review-result-idempotent",
    current_state = "fixing",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    target_state = "fixing",
    legacy_log_outcome = "skip-idempotent(already at to_state)",
  },
}

local function trace_artifact(corpus_hash, fixtures)
  return observation_support.admission_trace_artifact(
    "restart-pr-review-result-trace.v1", OWNER, "pr-review-result", corpus_hash, fixtures
  )
end

local function new_trace(fixture, old)
  local snapshot = restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "pr", repo = "owner/repo", number = 7 },
    proposal_id = "github-devloop/issue/owner/repo/42",
    current = { state = fixture.current_state, version = fixture.current_version },
    snapshot_fingerprint = "r9-pr-review-result:" .. fixture.fixture_id,
    lock_epoch = "r9-pr-review-result:lock",
    generation = "r9-pr-review-result:generation",
  })
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "changes_requested",
    target = "fixing",
    incoming_version = fixture.incoming_version,
    overlay_version = fixture.incoming_version,
  })
  local writes = observation_support.json_array()
  if decided.status == "apply" then
    local grant = restart_effects.mint_grant(snapshot, decided, "comment:pr:review-result")
    t.is_true(grant ~= nil, fixture.fixture_id .. ": NEW grant minted")
    local boundary = old.comment_builders[1]
    local facade = restart_effect_facade.make({
      family = "pr-review-result",
      verify_grant = restart_effects.verify_grant,
      sink_inventory = require("core.restart.sink_inventory"),
    })
    local args = {
      core = core,
      repo = boundary.repo,
      issue_number = boundary.issue_number,
      issue_proposal_id = boundary.issue_proposal_id,
      issue_version = boundary.issue_version,
      reached = boundary.reached,
      pr_source_ref = boundary.source_ref,
      issue_source_ref = { kind = "external", ref = "owner/repo#issue/42" },
      marker_target = { kind = "pr", number = 7 },
    }
    for ordinal, effect_id in ipairs(decided.granted_effect_ids) do
      local emitted = facade.emit(grant, effect_id, snapshot, args)
      t.is_true(emitted ~= nil, fixture.fixture_id .. ": NEW facade emitted " .. effect_id)
      table.insert(writes, observation_support.admission_trace_write(ordinal, effect_id, emitted))
    end
  end
  return decided, writes
end

function M.assert_equality(observe_old)
  local corpus = json.decode(file.read(CORPUS_PATH))
  local old_fixtures, new_fixtures = observation_support.json_array(), observation_support.json_array()
  for _, fixture in ipairs(FIXTURES) do
    local old = observe_old(fixture)
    local decided, writes = new_trace(fixture, old)
    local old_writes = old.observed.status == "apply"
      and observation_support.admission_trace_writes(
        old.result.raises,
        "R9 PR review-result trace"
      )
      or observation_support.json_array()
    table.insert(old_fixtures, observation_support.admission_trace_fixture(
      fixture,
      EDGE_ID,
      old.observed.status,
      old.observed.reason_code,
      old.decision.outcome,
      decided.effect_entitlement_id,
      decided.granted_effect_ids,
      old_writes
    ))
    table.insert(new_fixtures, observation_support.admission_trace_fixture(
      fixture,
      EDGE_ID,
      decided.status,
      decided.reason_code,
      decided.cas_outcome,
      decided.effect_entitlement_id,
      decided.granted_effect_ids,
      writes
    ))
  end

  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  local new_trace_artifact = trace_artifact(corpus.artifact_sha256, new_fixtures)
  local canonical_json = observation_support.canonical_json
  t.eq(canonical_json(old_trace), canonical_json(new_trace_artifact),
    "R9 PR review-result OLD and NEW semantic trace")
  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 PR review-result trace could not create its artifact directory", 0)
  end
  file.write(OUTPUT_PATH, canonical_json(new_trace_artifact) .. "\n")
  t.eq(canonical_json(old_trace), canonical_json(corpus),
    "R9 PR review-result OLD observation corpus")
  t.eq(canonical_json(new_trace_artifact), canonical_json(corpus),
    "R9 PR review-result NEW semantic trace")
end

return M
