local autonomy_ledger = require("devloop.autonomy_ledger")
local config = require("devloop.config")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local replay_fields = require("devloop.replay_fields")
local testing = require("testkit_internal.testing")

local t = h.t
local core = h.core
local canonical_json = observation_support.canonical_json
local awaiting_pr_replayer = require("awaiting_pr_replay")

local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local HEAD_SHA = "0123456789abcdef0123456789abcdef01234567"
local MERGE_COMMIT_SHA = "1111111111111111111111111111111111111111"
local DELEGATION = "g1"
local ORIGINAL_BRANCH = devloop_base.implement_branch(
  REPO,
  ISSUE_NUMBER,
  core.implementation_base_version(VERSION)
)

local FIXTURES = {
  {
    name = "child-pr-merged",
    target = "merged",
    child_state = "merged",
    pr_number = 9810,
    branch = ORIGINAL_BRANCH,
    base_branch = "dev",
    pr_state = "MERGED",
    closes_issue = true,
  },
  {
    name = "child-pr-closed-unmerged",
    target = "ready",
    child_state = "closed-unmerged",
    pr_number = 9811,
    branch = ORIGINAL_BRANCH,
    base_branch = "integration/dev",
    pr_state = "CLOSED",
  },
  {
    name = "child-pr-blocked",
    target = "blocked",
    child_state = "blocked",
    pr_number = 9813,
    branch = ORIGINAL_BRANCH,
    base_branch = "integration/dev",
    pr_state = "OPEN",
  },
}

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = core._test_bot_login,
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
end

local function pr_proposal_id(fixture)
  return entity_lib.pr_proposal_id(REPO, fixture.pr_number)
end

local function parent_issue(fixture)
  return {
    repo = REPO,
    number = ISSUE_NUMBER,
    source_ref = entity_lib.issue_source_ref(REPO, ISSUE_NUMBER),
    comments = {
      trusted_comment(core.state_marker(PROPOSAL_ID, "awaiting-pr", VERSION)),
      trusted_comment(m_builders.pr_delegation_marker(
        PROPOSAL_ID,
        pr_proposal_id(fixture),
        fixture.pr_number,
        VERSION,
        DELEGATION
      ), "2026-06-03T01:01:00Z"),
    },
  }
end

local function child_pr(fixture)
  return {
    force_fresh = true,
    number = fixture.pr_number,
    state = fixture.pr_state,
    merged_at = fixture.pr_state == "MERGED" and "2026-06-03T02:05:04Z" or nil,
    comments = {
      trusted_comment(m_builders.pr_origin_marker(
        PROPOSAL_ID,
        ISSUE_NUMBER,
        fixture.branch,
        VERSION,
        fixture.base_branch
      ), "2026-06-03T01:03:00Z"),
      trusted_comment(core.state_marker(
        PROPOSAL_ID,
        fixture.child_state,
        VERSION
      ), "2026-06-03T01:04:00Z"),
    },
    head_ref_name = fixture.branch,
    base_ref_name = fixture.base_branch,
    head_sha = HEAD_SHA,
    merge_commit_sha = MERGE_COMMIT_SHA,
    status_check_rollup = {},
  }
end

local function delegation(fixture)
  return {
    proposal_id = PROPOSAL_ID,
    pr_proposal_id = pr_proposal_id(fixture),
    pr_number = fixture.pr_number,
    version = VERSION,
    delegation = DELEGATION,
  }
end

local function fake_autonomy_record(merge_ready)
  return {
    schema = "github-devloop.autonomy-result.v1",
    proposal_id = tostring(merge_ready.proposal_id),
    repo = REPO,
    issue_number = tostring(ISSUE_NUMBER),
    pr_number = tostring(merge_ready.pr_number),
    version = tostring(merge_ready.version),
    head_sha = tostring(merge_ready.reviewed_head_sha),
    merged_at = "2026-06-03T02:05:04Z",
    task_class = "L1",
    human_touch_count = 0,
    pre_merge_ci = "pass",
    rounds = 0,
    retry_count = 0,
    codex_calls = nil,
    gates = {
      human_touch = "pass",
      pre_merge_ci = "pass",
      evidence_manifest = "pending",
      post_merge_probe = "pending",
      no_revert_reopen = "pending",
      cost_budget = "pending",
    },
    valid_autonomous_merge = "pending",
  }
end

local function frozen_old_writes(fixture)
  local observation_id_prefix = "writer:github-devloop:awaiting-pr-exit/" .. fixture.name .. "/"
  local inventory = json.decode(file.read(INVENTORY_PATH))
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if tostring(record.observation_id):sub(1, #observation_id_prefix) == observation_id_prefix then
      local writes = {}
      for _, write in ipairs(record.old_outcome.observable_writes or {}) do
        table.insert(writes, { queue = write.queue, payload = write.payload })
      end
      return writes
    end
  end
  error("frozen OLD awaiting-pr exit observation is missing for " .. fixture.name, 0)
end

local function run_apply(fixture)
  h.mock_bot_env()
  if fixture.closes_issue then
    t.mock_command("gh issue close", {
      stdout = "closed\n",
      stderr = "",
      exit_code = 0,
    })
  end

  local issue = parent_issue(fixture)
  local state = { state = "awaiting-pr", version = VERSION }
  local current_pr = child_pr(fixture)
  local row = replay_fields.restart_transition_row(core.restart_transition_table(), "awaiting-pr")
  local original_branch_config = config.branch_config
  local original_write_mode = config.write_mode
  local original_autonomy_result_record = autonomy_ledger.autonomy_result_record
  local original_versioned_transition_status = devloop_state.versioned_transition_status
  config.branch_config = function()
    return { integration = fixture.base_branch, upstream = fixture.base_branch }
  end
  config.write_mode = function()
    return fixture.closes_issue and "real" or "dry-run"
  end
  autonomy_ledger.autonomy_result_record = function(_, repo, issue_number, merge_ready)
    t.eq(repo, REPO)
    t.eq(issue_number, ISSUE_NUMBER)
    return fake_autonomy_record(merge_ready)
  end
  devloop_state.versioned_transition_status = function()
    error("awaiting-pr exit used retired direct CAS", 0)
  end

  local close_calls_before = h.count_calls("gh issue close 42 --repo owner/repo")
  local ok, result = pcall(function()
    return testing.run_fake({
      pipeline = function()
        return awaiting_pr_replayer["awaiting-pr"]("observe_issue", issue, state, row, {
          proposal_id = PROPOSAL_ID,
          current_pr = current_pr,
          child_state = { state = fixture.child_state, version = VERSION },
          ["pr-delegation"] = delegation(fixture),
        })
      end,
    }, { queue = "github-proxy.github_entity_changed", payload = issue })
  end)

  devloop_state.versioned_transition_status = original_versioned_transition_status
  autonomy_ledger.autonomy_result_record = original_autonomy_result_record
  config.write_mode = original_write_mode
  config.branch_config = original_branch_config
  if not ok then error(result, 0) end

  t.eq(#result.raises, 2, fixture.name .. ": comment then label")
  t.eq(
    h.count_calls("gh issue close 42 --repo owner/repo") - close_calls_before,
    fixture.closes_issue and 1 or 0,
    fixture.name .. ": merged close side effect"
  )
  return result.raises
end

local function assert_apply_fixture(fixture)
  local writes = run_apply(fixture)
  t.eq(
    canonical_json(writes),
    canonical_json(frozen_old_writes(fixture)),
    fixture.name .. ": production facade writes are byte-exact versus frozen OLD"
  )
end

local function assert_idempotent_fixture(fixture)
  local issue = parent_issue(fixture)
  local status, snapshot, decision = awaiting_pr_replayer.awaiting_pr_exit_transition_status(
    issue,
    PROPOSAL_ID,
    { state = fixture.target, version = VERSION },
    fixture.target
  )
  t.eq(status, "idempotent", fixture.name .. ": idempotent decision")
  t.eq(decision.cas_outcome, "skip-idempotent(already at to_state)", fixture.name .. ": OLD CAS outcome")
  t.eq(#decision.granted_effect_ids, 0, fixture.name .. ": idempotent grants no effects")
  t.eq(
    require("core.restart_effects").mint_grant(
      snapshot,
      decision,
      "comment:issue:awaiting-pr-terminal"
    ),
    nil,
    fixture.name .. ": idempotent cannot mint an effect grant"
  )
end

return {
  test_awaiting_pr_exit_all_targets_apply_via_facade_byte_exact = function()
    for _, fixture in ipairs(FIXTURES) do
      assert_apply_fixture(fixture)
    end
  end,

  test_awaiting_pr_exit_all_targets_preserve_idempotent_zero_effects = function()
    for _, fixture in ipairs(FIXTURES) do
      assert_idempotent_fixture(fixture)
    end
  end,
}
