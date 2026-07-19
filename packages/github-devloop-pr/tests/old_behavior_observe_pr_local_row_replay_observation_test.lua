local github_fake = require("forge.github_fake")
local git_fake = require("forge.git_fake")
local github_factory = require("devloop.github_factory")

local active_ports = nil
local production_github_handle = github_factory.production_handle
local github_port_proxy = setmetatable({}, {
  __index = function(_, key)
    return function(...)
      local handle = active_ports and active_ports.github or production_github_handle()
      local operation = handle[key]
      if type(operation) ~= "function" then
        error("observe_pr local row replay: missing GitHub port operation " .. tostring(key), 0)
      end
      return operation(...)
    end
  end,
})
github_factory.production_handle = function() return github_port_proxy end

local base_ids = require("devloop.base_ids")
local ci_repair_attempts = require("core.ci_repair_attempts")
local config = require("devloop.config")
local conv_rounds = require("devloop.convergence.rounds")
local convergence_shared = require("devloop.convergence.shared")
local decompose_lib = require("devloop.decompose")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local replayer = require("devloop.replayer")
local restart_sink_inventory = require("core.restart.sink_inventory")
local testing = require("testkit_internal.testing")
local transition_version = require("contract.transition_version")
local _workflow_codex = require("workflow_internal.codex")
local observe_pr_department = require("departments.observe_pr.main")

local t = h.t
local core = h.core
local JSON_NULL = observation_support.JSON_NULL
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local nullable = observation_support.nullable
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local OBSERVATION_PREFIX = "row-replay-observe-pr-local-"
local SITE = {
  path = "packages/github-devloop-pr/departments/observe_pr/main.lua",
  symbol = "replay_pr_local_state",
  ordinal = "row-replay/pr-local-state",
}

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7001
local PROPOSAL_ID = base_ids.proposal_id(REPO, ISSUE_NUMBER)
local BRANCH = "devloop-owner-repo-42-01HY"
local BASE_BRANCH = "dev"
local HEAD_SHA = "def456"
local OTHER_HEAD_SHA = "fed654"
local BASE_SHA = "abc123"
local BASE_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local SOURCE_REF = { kind = "external", ref = "owner/repo#pr/7001" }
local EXPECTED_ROW_COUNTS = {
  ["pr-open"] = 3,
  reviewing = 11,
  fixing = 13,
  ["review-meta"] = 7,
  ["merge-ready"] = 9,
  merging = 8,
  blocked = 3,
  ["closed-unmerged"] = 1,
  merged = 1,
}

local FIXTURES = json_array({
  -- Comprehensive row-local decision lattice.
  { name = "route-reviewing-rejected", state = "reviewing", marker = "review-result-reject", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "fixing", expected_effect_ids = json_array({ "comment:pr:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:190-212" },
  { name = "route-reviewing-converge-terminal", state = "reviewing", marker = "review-converge-budget", terminal_cause = "evidence-continuation-budget-exhausted", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "blocked", expected_effect_ids = json_array({ "queue:github-devloop-pr.devloop_review_reconcile" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:241-252" },
  { name = "route-reviewing-merged", state = "reviewing", pr_state = "MERGED", expected_status = "routed", expected_decision = "applied(linked-pr-merged)", expected_target = "merged", expected_effect_ids = json_array({ "comment:issue:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:52-65,637-677" },
  { name = "route-reviewing-merged-head-missing", state = "reviewing", pr_state = "MERGED", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(head)", expected_target = "merged", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:52-65,637-640" },
  { name = "route-reviewing-open-head-missing", state = "reviewing", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(pr-head)", expected_target = "reviewing", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:52-71,770-773" },
  { name = "route-fixing-head-advanced-reviewing", state = "fixing", suffix = "/fix/1", marker = "fix-feedback-head-advanced", branch_head_sha = HEAD_SHA, expected_status = "routed", expected_decision = "applied(replay)", expected_target = "reviewing", expected_effect_ids = json_array({ "comment:pr:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:275-280" },
  { name = "route-fixing-closed", state = "fixing", suffix = "/fix/1", pr_state = "CLOSED", expected_status = "routed", expected_decision = "applied(orphaned-pr-closed)", expected_target = "closed-unmerged", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:261-264,687-697" },
  { name = "route-fixing-merged", state = "fixing", suffix = "/fix/1", pr_state = "MERGED", expected_status = "routed", expected_decision = "applied(linked-pr-merged)", expected_target = "merged", expected_effect_ids = json_array({ "comment:issue:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:261-264,637-677" },
  { name = "route-fixing-merged-head-missing", state = "fixing", suffix = "/fix/1", pr_state = "MERGED", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(head)", expected_target = "merged", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:261-264,637-640" },
  { name = "route-fixing-open-head-missing", state = "fixing", suffix = "/fix/1", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(pr-head)", expected_target = "fixing|reviewing", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:261-264,52-71" },
  { name = "route-review-meta-fix", state = "review-meta", suffix = "/fix/1/meta-fix", marker = "review-meta-fix", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "fixing", expected_effect_ids = json_array({ "comment:pr:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:343-374" },
  { name = "route-review-meta-closed", state = "review-meta", suffix = "/fix/1/meta-closed", pr_state = "CLOSED", expected_status = "routed", expected_decision = "applied(orphaned-pr-closed)", expected_target = "closed-unmerged", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:343-346,687-697" },
  { name = "route-review-meta-merged", state = "review-meta", suffix = "/fix/1/meta-merged", pr_state = "MERGED", expected_status = "routed", expected_decision = "applied(linked-pr-merged)", expected_target = "merged", expected_effect_ids = json_array({ "comment:issue:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:343-346,637-677" },
  { name = "route-review-meta-merged-head-missing", state = "review-meta", suffix = "/fix/1/meta-merged-no-head", pr_state = "MERGED", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(head)", expected_target = "merged", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:343-346,637-640" },
  { name = "route-merge-ready-without-approval", state = "merge-ready", suffix = "/without-approval", marker = "merge-ready-only", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "blocked", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:431-443" },
  { name = "route-merge-ready-approval-stale", state = "merge-ready", suffix = "/approval-stale", marker = "merge-ready-stale", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "reviewing", expected_effect_ids = json_array({ "comment:pr:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:408-429,460-495" },
  { name = "route-merge-ready-closed", state = "merge-ready", suffix = "/closed", pr_state = "CLOSED", expected_status = "routed", expected_decision = "applied(orphaned-pr-closed)", expected_target = "closed-unmerged", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:398-401,687-697" },
  { name = "route-merge-ready-merged", state = "merge-ready", suffix = "/merged", pr_state = "MERGED", expected_status = "routed", expected_decision = "applied(linked-pr-merged)", expected_target = "merged", expected_effect_ids = json_array({ "comment:issue:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:398-401,637-677" },
  { name = "route-merge-ready-merged-head-missing", state = "merge-ready", suffix = "/merged-no-head", pr_state = "MERGED", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(head)", expected_target = "merged", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:398-401,637-640" },
  { name = "route-merge-ready-open-head-missing", state = "merge-ready", suffix = "/open-no-head", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(pr-head)", expected_target = "merging|blocked", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:398-401,52-71" },
  { name = "route-merging-merged", state = "merging", marker = "merging", pr_state = "MERGED", expected_status = "routed", expected_decision = "applied(linked-pr-merged)", expected_target = "merged", expected_effect_ids = json_array({ "comment:issue:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:513-515,637-677" },
  { name = "route-merging-merged-head-missing", state = "merging", marker = "merging", pr_state = "MERGED", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(head)", expected_target = "merged", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:513-515,637-640" },
  { name = "route-merging-closed", state = "merging", marker = "merging", pr_state = "CLOSED", expected_status = "routed", expected_decision = "applied(orphaned-pr-closed)", expected_target = "closed-unmerged", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:517-519" },
  { name = "route-merging-authorization-stale", state = "merging", marker = "merging-stale", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "reviewing", expected_effect_ids = json_array({ "comment:pr:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:520-525,460-495" },
  { name = "route-merging-not-mergeable", state = "merging", marker = "merging", mergeable = false, mergeable_state = "dirty", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "fixing", expected_effect_ids = json_array({ "comment:pr:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:526-555" },
  { name = "route-merging-ci-pending", state = "merging", marker = "merging", ci = "unknown", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "blocked", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:557-602" },
  { name = "route-reviewing-approved", state = "reviewing", marker = "review-result", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "merge-ready", expected_effect_ids = json_array({ "queue:github-devloop-pr.devloop_merge_ready" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:164-189" },
  -- Collapse only fixtures with the same row, outcome, target route, and effect set.
  { name = "route-pr-open-closed", state = "pr-open", pr_state = "CLOSED", expected_status = "routed", expected_decision = "applied(orphaned-pr-closed)", expected_target = "closed-unmerged", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:695-696" },
  { name = "route-reviewing-no-result", state = "reviewing", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "reviewing", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:167-169,241-245,782-831" },
  { name = "route-reviewing-current-redrive-result-visible", state = "reviewing", marker = "review-result-redrive-visible", expected_status = "routed-noop", expected_decision = "skip-idempotent(review result visible)", expected_target = "reviewing", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:782-797" },
  { name = "route-reviewing-foreign-result-binding", state = "reviewing", marker = "review-result-foreign-binding", expected_status = "routed-noop", expected_decision = "skip-foreign(review-result-binding)", expected_target = "review-result", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:164-174" },
  { name = "route-reviewing-approve-without-merge-ready", state = "reviewing", marker = "review-result-approve-only", expected_status = "routed-noop", expected_decision = "skip-foreign(merge-ready)", expected_target = "merge-ready", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:175-179,770-776" },
  { name = "route-reviewing-closed", state = "reviewing", pr_state = "CLOSED", expected_status = "routed", expected_decision = "applied(orphaned-pr-closed)", expected_target = "closed-unmerged", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:52-65,695-696,770-773" },
  { name = "route-fixing", state = "fixing", suffix = "/fix/1", marker = "fix-feedback", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "fixing", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:261-337" },
  { name = "route-fixing-no-feedback", state = "fixing", suffix = "/fix/1", expected_status = "routed-noop", expected_decision = "skip-foreign(fix-feedback)", expected_target = "fixing|reviewing", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:268-271" },
  { name = "route-fixing-head-advanced-stale", state = "fixing", suffix = "/fix/1", marker = "fix-feedback-head-advanced", branch_head_sha = "cab123", expected_status = "routed-noop", expected_decision = "skip-stale(head-advanced)", expected_target = "fixing", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:275-279" },
  { name = "route-fixing-version-binding-mismatch", state = "fixing", version = "unrelated-lineage/fix/1", expected_status = "routed-noop", expected_decision = "skip-foreign(pr-link)", expected_target = "fixing|reviewing", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:261-267" },
  { name = "route-fixing-ci-repair-backoff", state = "fixing", suffix = "/fix/1", marker = "ci-repair-attempt", now_seconds = 1780419725, expected_status = "routed-noop", expected_decision = "skip-pending(ci-repair-backoff)", expected_target = "fixing", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:282-306" },
  { name = "route-fixing-ci-repair-policy-invalid", state = "fixing", suffix = "/fix/1", marker = "ci-repair-attempt-invalid-time", expected_status = "routed", expected_decision = "applied(fix-loop-max-rounds)", expected_target = "blocked", expected_effect_ids = json_array({ "queue:github-devloop-pr.devloop_fix_reconcile", "queue:github-devloop-decompose.devloop_decompose" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:282-309;packages/github-devloop-pr/core/ci_repair_retry.lua:103-120" },
  { name = "route-fixing-ci-repair-due-own-ci", state = "fixing", suffix = "/fix/1", marker = "ci-repair-attempt", ci = "red", expected_status = "routed", expected_decision = "applied(ci-repair-next-round)", expected_target = "fixing", expected_effect_ids = json_array({ "comment:pr:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/ci_repair_retry.lua:131-156,332-389;packages/github-devloop-pr/core/pr_review_replayer.lua:316-318" },
  { name = "route-fixing-ci-repair-head-advanced-closed", state = "fixing", suffix = "/fix/1", marker = "ci-repair-attempt", reobserve_head_sha = OTHER_HEAD_SHA, reobserve_state = "CLOSED", expected_status = "routed-noop", expected_decision = "skip-stale(pr-closed)", expected_target = "reviewing", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/ci_repair_retry.lua:164-169;packages/github-devloop-pr/core/pr_review_replayer.lua:310-313" },
  { name = "route-review-meta-block", state = "review-meta", suffix = "/fix/1", marker = "review-meta", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "blocked", expected_effect_ids = json_array({ "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:343-388" },
  { name = "route-review-meta-no-result", state = "review-meta", suffix = "/fix/1/meta-none", expected_status = "routed-noop", expected_decision = "skip-foreign(review-meta)", expected_target = "fixing|blocked", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:343-350" },
  { name = "route-review-meta-open-head-missing", state = "review-meta", suffix = "/fix/1/meta-no-head", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(pr-head)", expected_target = "fixing|blocked", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:41-45,69-70,343-346" },
  { name = "route-merge-ready", state = "merge-ready", marker = "merge-ready", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "merging", expected_effect_ids = json_array({ "queue:github-devloop-pr.devloop_merge_ready" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:398-454" },
  { name = "route-merge-ready-carry-over", state = "merge-ready", suffix = "/carry", marker = "merge-ready-stale", carry_success = true, expected_status = "routed", expected_decision = "applied(review-carry-over)", expected_target = "merge-ready", expected_effect_ids = json_array({ "comment:pr:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:408-428" },
  { name = "route-merge-ready-without-marker", state = "merge-ready", suffix = "/without-marker", expected_status = "routed-noop", expected_decision = "skip-foreign(merge-ready)", expected_target = "merging|blocked", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:398-406" },
  { name = "route-merging", state = "merging", marker = "merging", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "merging", expected_effect_ids = json_array({ "queue:github-devloop-pr.devloop_merge_ready" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:498-603" },
  { name = "route-merging-no-authorization", state = "merging", suffix = "/no-auth", expected_status = "routed-noop", expected_decision = "skip-foreign(merge-ready)", expected_target = "merged|reviewing|fixing|blocked", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:498-512" },
  { name = "route-blocked", state = "blocked", suffix = "/fix/3/blocked", marker = "decomposed", expected_status = "routed", expected_decision = "applied(decomposed-children-missing)", expected_target = "decomposed", expected_effect_ids = json_array({ "queue:github-devloop-decompose.devloop_decompose" }) },
  { name = "route-blocked-children-complete", state = "blocked", suffix = "/fix/3/blocked-complete", marker = "decomposed", children_complete = true, expected_status = "routed-noop", expected_decision = "skip-idempotent(decomposed children already visible)", expected_target = "decomposed", expected_effect_ids = json_array(), evidence_ref = "libraries/devloop/replayer.lua:478-493" },
  { name = "route-blocked-without-decomposed", state = "blocked", suffix = "/fix/3/blocked-no-decomposed", before_replayer = true, expected_status = "routed-noop", expected_decision = "skip-foreign(decomposed)", expected_target = "decomposed", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/departments/observe_pr/main.lua:143-145" },
  { name = "route-closed-unmerged", state = "closed-unmerged", suffix = "/closed-unmerged", expected_status = "routed-noop", expected_decision = "skip-foreign(replayer)", expected_target = "none", expected_effect_ids = json_array() },
  { name = "route-merged", state = "merged", suffix = "/merged", expected_status = "routed-noop", expected_decision = "skip-foreign(replayer)", expected_target = "none", expected_effect_ids = json_array() },
  { name = "route-pr-open-merged", state = "pr-open", pr_state = "MERGED", expected_status = "routed", expected_decision = "applied(linked-pr-merged)", expected_target = "merged", expected_effect_ids = json_array({ "comment:issue:row-replay", "label:issue:row-replay" }), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:692-693" },
  { name = "route-pr-open-merged-head-missing", state = "pr-open", pr_state = "MERGED", head_sha = "", expected_status = "routed-noop", expected_decision = "skip-foreign(head)", expected_target = "merged", expected_effect_ids = json_array(), evidence_ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:637-640,692-693" },
})

local function fixture_version(fixture)
  if fixture.version ~= nil then return fixture.version end
  if fixture.state == "fixing" or fixture.state == "review-meta" then return BASE_VERSION .. "/fix/1" end
  if fixture.state == "merge-ready" or fixture.state == "merging" then return BASE_VERSION end
  if fixture.state == "blocked" then return BASE_VERSION .. "/fix/3/blocked" end
  return BASE_VERSION .. tostring(fixture.suffix or "")
end
local function fixture_updated_at(fixture)
  for index, value in ipairs(FIXTURES) do
    if value == fixture then return string.format("2026-06-04T01:%02d:%02dZ", math.floor(index / 50), 10 + (index % 50)) end
  end
  error("observe_pr local row replay: fixture is outside the production lattice", 0)
end

local function review_ids(version, head_sha, pr_number)
  local proposal = devloop_base.pr_review_proposal_id(REPO, pr_number or PR_NUMBER, version, head_sha or HEAD_SHA)
  return proposal, "consensus:" .. proposal .. "/review"
end

local function trusted_comment(body, created_at)
  return { body = body, author_login = "fkst-test-bot", created_at = created_at or "2026-06-03T01:00:00Z" }
end

local function review_converge_comments(fixture, version, review_proposal, review_dedup)
  local count = fixture.marker == "review-converge-stall" and 3 or (fixture.marker == "review-converge-budget" and 1 or 0)
  local same = fixture.marker == "review-converge-stall"
  for round = count == 0 and 0 or 1, count do
    local angles = {
      { perspective = "one", verdict = "comment", digest = same and "stable-a" or ("a-" .. tostring(round)) },
      { perspective = "two", verdict = "abstain", digest = same and "stable-b" or ("b-" .. tostring(round)) },
      { perspective = "three", verdict = "abstain", digest = same and "stable-c" or ("c-" .. tostring(round)) },
    }
    local marker = conv_rounds.review_converge_round_marker(core, review_proposal, PROPOSAL_ID, version, HEAD_SHA,
      convergence_shared.source_ref_digest(SOURCE_REF), round, transition_version.review_loop_at(version, round),
      same and "Same review question" or ("Review question " .. tostring(round)), angles, nil,
      fixture.marker == "review-converge-external")
    table.insert(fixture._comments, trusted_comment(marker, "2026-06-03T01:00:2" .. tostring(round) .. "Z"))
  end
end

local function comments_for(fixture)
  local version = fixture_version(fixture)
  local review_proposal, review_dedup = review_ids(version)
  local comments = json_array({
    trusted_comment(m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH, BASE_VERSION, BASE_BRANCH)),
    trusted_comment(core.state_marker(PROPOSAL_ID, fixture.state, version), "2026-06-03T01:00:01Z"),
  })
  fixture._comments = comments
  if fixture.marker == "fix-feedback" then
    table.insert(comments, trusted_comment(m_builders.merge_gate_marker(PROPOSAL_ID, PR_NUMBER, version, review_proposal, review_dedup, HEAD_SHA, BASE_SHA, "review-rejected")))
  elseif fixture.marker == "review-meta" or fixture.marker == "review-meta-fix" then
    local action = fixture.marker == "review-meta-fix" and "fix" or "block"
    table.insert(comments, trusted_comment(m_builders.review_meta_marker(PROPOSAL_ID, review_dedup, action, version, action == "fix" and "fix the remaining gap" or nil, "review-meta-" .. action)))
  elseif fixture.marker == "review-result-reject" then
    table.insert(comments, trusted_comment(m_builders.review_result_marker(review_proposal, PROPOSAL_ID, "reject", review_dedup, devloop_state.version_fix_round(version), "missing row replay regression guard")))
  elseif fixture.marker == "fix-feedback-head-advanced" then
    local old_proposal, old_dedup = review_ids(version, OTHER_HEAD_SHA)
    table.insert(comments, trusted_comment(m_builders.merge_gate_marker(PROPOSAL_ID, PR_NUMBER, version, old_proposal, old_dedup, OTHER_HEAD_SHA, BASE_SHA, "review-rejected")))
  elseif fixture.marker == "ci-repair-attempt" or fixture.marker == "ci-repair-attempt-invalid-time" or fixture.marker == "ci-repair-no-attempt" then
    local ci_failure_key = "head:def456/checks:digest-0000000101"
    table.insert(comments, trusted_comment(m_builders.merge_gate_marker(PROPOSAL_ID, PR_NUMBER, version, review_proposal, review_dedup, HEAD_SHA, BASE_SHA, "own-ci-red", nil, ci_failure_key)))
    if fixture.marker ~= "ci-repair-no-attempt" then
      local created_at = fixture.marker == "ci-repair-attempt-invalid-time" and "invalid-time" or "2026-06-03T01:02:04Z"
      table.insert(comments, trusted_comment(ci_repair_attempts.marker({ proposal_id = PROPOSAL_ID, pr_number = PR_NUMBER, version = version, reviewed_head_sha = HEAD_SHA, ci_failure_key = ci_failure_key }, "completed"), created_at))
    end
  elseif fixture.marker == "review-result-untrusted" then
    local comment = trusted_comment(m_builders.review_result_marker(review_proposal, PROPOSAL_ID, "approve", review_dedup))
    comment.author_login = "untrusted-user"
    table.insert(comments, comment)
  elseif fixture.marker == "review-result-stale" then
    local stale_proposal, stale_dedup = review_ids(version .. "/fix/9")
    table.insert(comments, trusted_comment(m_builders.review_result_marker(stale_proposal, PROPOSAL_ID, "approve", stale_dedup)))
  elseif fixture.marker == "review-result-redrive-visible" then
    local redrive_version = core.review_redrive_version({ state = "reviewing", version = version }, { repo = REPO, number = PR_NUMBER, head_sha = HEAD_SHA })
    local redrive_proposal, redrive_dedup = review_ids(redrive_version)
    table.insert(comments, trusted_comment(m_builders.review_result_marker(redrive_proposal, PROPOSAL_ID, "approve", redrive_dedup)))
  elseif fixture.marker == "review-result-foreign-binding" then
    local foreign_proposal, foreign_dedup = review_ids(version, OTHER_HEAD_SHA)
    table.insert(comments, trusted_comment(m_builders.review_result_marker(foreign_proposal, PROPOSAL_ID, "approve", foreign_dedup)))
  elseif fixture.marker == "review-result-approve-only" then
    table.insert(comments, trusted_comment(m_builders.review_result_marker(review_proposal, PROPOSAL_ID, "approve", review_dedup)))
  elseif fixture.marker == "review-converge-budget" or fixture.marker == "review-converge-external" or fixture.marker == "review-converge-stall" or fixture.marker == "review-converge-nonterminal" then
    review_converge_comments(fixture, version, review_proposal, review_dedup)
  elseif fixture.marker == "merge-ready-only" then
    table.insert(comments, trusted_comment(m_builders.merge_ready_marker(PROPOSAL_ID, PR_NUMBER, version, review_proposal, review_dedup, HEAD_SHA)))
  elseif fixture.marker == "merge-ready-stale" or fixture.marker == "merging-stale" then
    local old_proposal, old_dedup = review_ids(version, OTHER_HEAD_SHA)
    table.insert(comments, trusted_comment(m_builders.review_result_marker(old_proposal, PROPOSAL_ID, "approve", old_dedup)))
    table.insert(comments, trusted_comment(m_builders.merge_ready_marker(PROPOSAL_ID, PR_NUMBER, version, old_proposal, old_dedup, OTHER_HEAD_SHA)))
    if fixture.marker == "merging-stale" then table.insert(comments, trusted_comment(m_builders.merging_marker(PROPOSAL_ID, PR_NUMBER, version, OTHER_HEAD_SHA))) end
  elseif fixture.marker == "review-result" or fixture.marker == "merge-ready" or fixture.marker == "merging" then
    table.insert(comments, trusted_comment(m_builders.review_result_marker(review_proposal, PROPOSAL_ID, "approve", review_dedup)))
    table.insert(comments, trusted_comment(m_builders.merge_ready_marker(PROPOSAL_ID, PR_NUMBER, version, review_proposal, review_dedup, HEAD_SHA)))
    if fixture.marker == "merging" then
      table.insert(comments, trusted_comment(m_builders.merging_marker(PROPOSAL_ID, PR_NUMBER, version, HEAD_SHA)))
    end
  elseif fixture.marker == "decomposed" then
    table.insert(comments, trusted_comment(m_builders.merge_gate_marker(PROPOSAL_ID, PR_NUMBER, version, review_proposal, review_dedup, HEAD_SHA, BASE_SHA, "fix-loop-max-rounds")))
    table.insert(comments, trusted_comment(decompose_lib.decomposed_marker(PROPOSAL_ID, version, PR_NUMBER, 1)))
  end
  fixture._comments = nil
  return comments
end

local function pr_event(fixture)
  local updated_at = fixture_updated_at(fixture)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1", type = "pr", repo = REPO, number = PR_NUMBER,
      state = fixture.pr_state or "OPEN", updated_at = updated_at,
      dedup_key = "owner/repo#pr#7001@" .. updated_at .. "/" .. fixture.name,
      source_ref = copy_value(SOURCE_REF),
    },
    now_seconds = fixture.now_seconds or 1784048400,
  }
end

local function rest_comment_json(comment, index)
  local rendered = entity_read_mocks.view_comment_json(comment)
    :gsub('"author"', '"user"')
    :gsub('"createdAt"', '"created_at"')
  if not rendered:find('"id"', 1, true) then rendered = rendered:gsub("^{", '{"id":' .. tostring(index) .. ",", 1) end
  return rendered
end

local function comments_stdout(comments)
  local rendered = {}
  for index, comment in ipairs(comments) do table.insert(rendered, rest_comment_json(comment, index)) end
  return "[" .. table.concat(rendered, ",") .. "]\n"
end

local function pr_rest_stdout(fixture)
  local state = tostring(fixture.pr_state or "OPEN")
  local rest_state = state == "MERGED" and "closed" or state:lower()
  local merged_at = state == "MERGED" and '"2026-06-03T02:05:04Z"' or "null"
  return string.format(
    '{"number":%d,"state":"%s","updated_at":"%s","merged_at":%s,"draft":false,"labels":[{"name":"fkst-dev:%s"}],"user":{"login":"fkst-test-bot"},"mergeable":%s,"mergeable_state":"%s","head":{"ref":"%s","sha":"%s","repo":{"full_name":"%s","owner":{"login":"owner"}}},"base":{"ref":"%s","sha":"%s","repo":{"full_name":"%s","owner":{"login":"owner"}}}}\n',
    PR_NUMBER, rest_state, fixture_updated_at(fixture), merged_at, fixture.state, fixture.mergeable == false and "false" or "true", fixture.mergeable_state or "clean", BRANCH, fixture.head_sha == nil and HEAD_SHA or fixture.head_sha, REPO, BASE_BRANCH, BASE_SHA, REPO
  )
end

local function record(model, kind, fields)
  local value = fields or {}; value.kind = kind; table.insert(model.writes, value)
end

local function write_count(model, kind)
  local count = 0
  for _, entry in ipairs(model.writes) do if entry.kind == kind then count = count + 1 end end
  return count
end

local function make_github_fake(fixture)
  local model = github_fake.model()
  local github = github_fake.new(model)
  local comments = comments_for(fixture)
  local head_sha = fixture.head_sha == nil and HEAD_SHA or fixture.head_sha
  local reobserve_head_sha = fixture.reobserve_head_sha or head_sha
  local reobserve_ci = fixture.reobserve_ci or fixture.ci
  local status_rollup = "[]"
  if reobserve_ci ~= "unknown" then
    local conclusion = reobserve_ci == "red" and "FAILURE" or "SUCCESS"
    status_rollup = '[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"' .. conclusion .. '","headSha":"' .. reobserve_head_sha .. '"}]'
  end
  local pr_view = entity_read_mocks.pr_view_stdout({ repo = REPO, number = PR_NUMBER, comments = comments, head = fixture.reobserve_branch or BRANCH, head_sha = reobserve_head_sha, state = fixture.reobserve_state or fixture.pr_state or "OPEN", updated_at = fixture_updated_at(fixture), base_branch = fixture.reobserve_base_branch or BASE_BRANCH, base_sha = BASE_SHA, mergeable = fixture.reobserve_mergeable == false and "CONFLICTING" or "MERGEABLE", merge_state = fixture.reobserve_mergeable_state and fixture.reobserve_mergeable_state:upper() or "CLEAN", labels = { "fkst-dev:" .. fixture.state }, status_check_rollup_json = status_rollup })
  function github._exec(argv) error("observe_pr local row replay: unexpected GitHub adapter call " .. canonical_json(argv), 0) end
  function github.pr_rest_view(repo, number, timeout) record(model, "pr_rest_view", { repo = repo, number = number, timeout = timeout }); return { stdout = pr_rest_stdout(fixture), stderr = "", exit_code = 0 } end
  function github.pr_comments(repo, number, timeout) record(model, "pr_comments", { repo = repo, number = number, timeout = timeout }); return { stdout = comments_stdout(comments), stderr = "", exit_code = 0 } end
  function github.pr_updated_at(repo, number, timeout) record(model, "pr_updated_at", { repo = repo, number = number, timeout = timeout }); return { stdout = fixture_updated_at(fixture) .. "\n", stderr = "", exit_code = 0 } end
  function github.pr_cli_view(repo, number, fields, timeout) record(model, "pr_cli_view", { repo = repo, number = number, fields = fields, timeout = timeout }); return { stdout = pr_view, stderr = "", exit_code = 0 } end
  function github.issue_view(repo, number, fields, timeout) record(model, "issue_view", { repo = repo, number = number, fields = fields, timeout = timeout }); return { stdout = entity_read_mocks.issue_view_stdout({ repo = repo, number = number, assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot", comments = {} }), stderr = "", exit_code = 0 } end
  function github.issue_search(repo, query, fields, timeout)
    record(model, "issue_search", { repo = repo, query = query, fields = fields, timeout = timeout })
    local stdout = "[]\n"
    if fixture.children_complete then
      stdout = '[{"number":9001,"title":"child","state":"OPEN","body":' .. canonical_json(decompose_lib.decompose_child_marker(PROPOSAL_ID, fixture_version(fixture), PR_NUMBER, 1)) .. ',"author":{"login":"fkst-test-bot"}}]\n'
    end
    return { stdout = stdout, stderr = "", exit_code = 0 }
  end
  function github.pr_diff_name_only(repo, number, timeout) record(model, "pr_diff_name_only", { repo = repo, number = number, timeout = timeout }); return { stdout = "src/main.lua\n", stderr = "", exit_code = 0 } end
  function github.gh_commit_check_runs(repo, head_sha, timeout)
    record(model, "commit_check_runs", { repo = repo, head_sha = head_sha, timeout = timeout })
    if fixture.ci == "unknown" then return { stdout = '{"total_count":0,"check_runs":[]}\n', stderr = "", exit_code = 0 } end
    local conclusion = fixture.ci == "red" and "failure" or "success"
    return { stdout = '{"total_count":1,"check_runs":[{"name":"test","status":"completed","conclusion":"' .. conclusion .. '","head_sha":"' .. tostring(head_sha) .. '"}]}\n', stderr = "", exit_code = 0 }
  end
  return github, model
end

local function make_git_fake(fixture)
  local model = git_fake.model(); local git = git_fake.new(model)
  function git._exec(argv) error("observe_pr local row replay: unexpected Git adapter call " .. canonical_json(argv), 0) end
  if fixture.carry_success then
    function git.is_ancestor() return { stdout = "", stderr = "", exit_code = 0 } end
    function git.fetch_branch() return { stdout = "", stderr = "", exit_code = 0 } end
    function git.remote_branch_head() return { stdout = BASE_SHA .. "\n", stderr = "", exit_code = 0 } end
    function git.merge_tree() return { stdout = "aaa111\n", stderr = "", exit_code = 0 } end
    function git.trees_equal_quiet() return { stdout = "", stderr = "", exit_code = 0 } end
  elseif fixture.branch_head_sha ~= nil then
    function git.fetch_branch() return { stdout = "", stderr = "", exit_code = 0 } end
    function git.fetch_head_commit() return { stdout = fixture.branch_head_sha .. "\n", stderr = "", exit_code = 0 } end
  elseif fixture.marker == "fix-feedback-head-advanced" then
    function git.fetch_branch() return { stdout = "", stderr = "branch unavailable", exit_code = 1 } end
  elseif fixture.marker == "merge-ready-stale" then
    function git.is_ancestor() return { stdout = "", stderr = "not ancestor", exit_code = 1 } end
  end
  return git, model
end

local function make_department(fixture)
  local github, github_model = make_github_fake(fixture)
  local git, git_model = make_git_fake(fixture)
  local ports = { github = github, git = git }
  return {
    spec = observe_pr_department.spec,
    github_model = github_model,
    git_model = git_model,
    pipeline = function(event)
      local previous_ports, previous_git = active_ports, core.git
      active_ports, core.git = ports, ports.git
      local ok, result = pcall(observe_pr_department.pipeline, event)
      core.git, active_ports = previous_git, previous_ports
      if not ok then error(result, 0) end
      return result
    end,
  }
end

local EFFECTS = {
  ["github-proxy.github_issue_comment_request"] = "comment:issue:row-replay",
  ["github-proxy.github_pr_comment_request"] = "comment:pr:row-replay",
  ["github-proxy.github_issue_label_request"] = "label:issue:row-replay",
  ["devloop_merge_ready"] = "queue:github-devloop-pr.devloop_merge_ready",
  ["devloop_review_reconcile"] = "queue:github-devloop-pr.devloop_review_reconcile",
  ["devloop_fix_reconcile"] = "queue:github-devloop-pr.devloop_fix_reconcile",
  ["github-devloop-decompose.devloop_decompose"] = "queue:github-devloop-decompose.devloop_decompose",
}

local SINK_SHAPES = {}
for _, sink in ipairs(restart_sink_inventory) do
  local previous = SINK_SHAPES[sink.id]
  local shape = { sink_kind = sink.effect_kind, authority_class = sink.authority_class }
  if previous ~= nil and canonical_json(previous) ~= canonical_json(shape) then
    error("conflicting restart sink inventory metadata for " .. tostring(sink.id), 0)
  end
  SINK_SHAPES[sink.id] = shape
end

local function effect_observations(raises)
  local emitted, writes = json_array(), json_array()
  for ordinal, raised in ipairs(raises) do
    local effect_id = EFFECTS[raised.queue]
    if effect_id == nil then error("unclassified observe_pr local row replay raise: " .. tostring(raised.queue), 0) end
    local shape = SINK_SHAPES[effect_id]
    if shape == nil then error("missing restart sink inventory metadata for " .. tostring(effect_id), 0) end
    table.insert(emitted, { effect_id = effect_id, sink_kind = shape.sink_kind, authority_class = shape.authority_class, ordinal = ordinal })
    table.insert(writes, { effect_id = effect_id, queue = raised.queue })
  end
  return emitted, writes
end

local function effect_ids(effects)
  local ids = json_array(); for _, effect in ipairs(effects or {}) do table.insert(ids, tostring(effect.effect_id)) end; return ids
end

local function capture_runtime(fixture)
  h.mock_bot_env()
  local event, department = pr_event(fixture), make_department(fixture)
  local original = replayer.replay_from_table
  local calls = json_array()
  replayer.replay_from_table = function(M, dept, issue, state, row, facts)
    local call = { dept = dept, state = state.state, version = state.version, row_from_state = row and row.from_state, driving_queue = row and row.driving_queue, decisions = json_array(), raises = json_array(), applies = json_array() }
    local old_decision, old_raise, old_apply = devloop_logging.log_cas_decision, devloop_logging.log_raise, devloop_logging.log_apply
    devloop_logging.log_cas_decision = function(log_dept, proposal_id, current, from_state, to_state, outcome, reason) table.insert(call.decisions, { proposal_id = proposal_id, from_state = from_state, to_state = to_state, outcome = outcome, reason = reason }); return old_decision(log_dept, proposal_id, current, from_state, to_state, outcome, reason) end
    devloop_logging.log_raise = function(log_dept, proposal_id, queue, payload) table.insert(call.raises, { proposal_id = proposal_id, queue = queue, payload = copy_value(payload) }); return old_raise(log_dept, proposal_id, queue, payload) end
    devloop_logging.log_apply = function(log_dept, proposal_id, to_state, version, labels, queues) table.insert(call.applies, { proposal_id = proposal_id, to_state = to_state, version = version, labels = copy_value(labels), queues = copy_value(queues) }); return old_apply(log_dept, proposal_id, to_state, version, labels, queues) end
    local ok, issued = pcall(original, M, dept, issue, state, row, facts)
    devloop_logging.log_apply, devloop_logging.log_raise, devloop_logging.log_cas_decision = old_apply, old_raise, old_decision
    if not ok then error(issued, 0) end
    call.issued = issued == true; table.insert(calls, call); return issued
  end
  local ok, result, captured = pcall(function()
    return observation_support.observe_department({ config = config, devloop_logging = devloop_logging, devloop_state = devloop_state, dept = "observe_pr", from_state = fixture.state, transition_kind = "versioned_transition_status", run = function() return testing.run_fake(department, event) end, codex_runs_for_read = json_array(), write_mode = "real" })
  end)
  replayer.replay_from_table = original
  if not ok then error(result, 0) end
  if fixture.before_replayer then
    t.eq(#calls, 0, fixture.name .. ": production guard resolves before generic row replay")
    table.insert(calls, {
      dept = "observe_pr",
      state = fixture.state,
      version = fixture_version(fixture),
      row_from_state = fixture.state,
      decisions = captured.decisions,
      raises = captured.raises,
      applies = captured.applies,
      issued = false,
    })
  else
    t.eq(#calls, 1, fixture.name .. ": real observe_pr dispatch reaches row replay once")
  end
  local call = calls[1]
  t.eq(call.dept, "observe_pr", fixture.name .. ": replay department")
  t.eq(call.state, fixture.state, fixture.name .. ": production-derived state")
  t.eq(call.version, fixture_version(fixture), fixture.name .. ": production-derived version")
  t.eq(call.row_from_state, fixture.state, fixture.name .. ": production row")
  t.eq(#call.decisions, 1, fixture.name .. ": one row-local disposition")
  t.eq(call.decisions[1].outcome, fixture.expected_decision, fixture.name .. ": exact decision")
  if fixture.terminal_cause ~= nil then
    t.eq(call.raises[1].payload.terminal_cause, fixture.terminal_cause, fixture.name .. ": exact review terminal cause")
  end
  t.is_true(write_count(department.github_model, "pr_rest_view") > 0, fixture.name .. ": PR read uses GitHub fake")
  t.is_true(write_count(department.github_model, "pr_comments") > 0, fixture.name .. ": PR comments use GitHub fake")
  t.is_true(write_count(department.github_model, "issue_view") > 0, fixture.name .. ": claim read uses GitHub fake")
  if fixture.expected_target == "none" then
    t.eq(call.decisions[1].to_state, nil, fixture.name .. ": terminal row has no replay target")
  else
    t.eq(call.decisions[1].to_state, fixture.expected_target, fixture.name .. ": exact target")
  end
  return event, captured, call
end

local function build_record(fixture)
  local event, captured, call = capture_runtime(fixture)
  local emitted, writes = effect_observations(call.raises)
  t.eq(canonical_json(effect_ids(emitted)), canonical_json(fixture.expected_effect_ids), fixture.name .. ": exact row effects")
  local replay_version = call.applies[1] and call.applies[1].version or nil
  return {
    schema = "restart-old-behavior-observation.v2", observation_id = OBSERVATION_PREFIX .. fixture.name, owner = "github-devloop-pr", site = copy_value(SITE), boundary = "row_replay",
    typed_intent = { kind = "row_replay", source_state = fixture.state, source_boundary = event.queue, target = fixture.expected_target, cause_schema_id = event.payload.schema, generation_epoch = { state_version = call.version, replay_version = nullable(replay_version), terminal = fixture.state == "closed-unmerged" or fixture.state == "merged" }, lineage = { proposal_id = PROPOSAL_ID, issue_number = ISSUE_NUMBER, pr_number = PR_NUMBER, source_ref = copy_value(SOURCE_REF), state_version = call.version } },
    old_inputs = { current_fact = { state = call.state, version = call.version, stage_rank = devloop_state.stage_rank(call.state) }, caller_from_states = json_array({ fixture.state }), incoming_version = call.version, target_version = nullable(replay_version), handoff_reference = JSON_NULL },
    old_outcome = { status = fixture.expected_status, reason_code = fixture.expected_decision, cas_outcome = call.decisions[1].outcome, emitted_effects = emitted, observable_writes = writes, handoff_direct_lookup_count = captured.handoff_direct_lookup_count, timeout_evidence_source = JSON_NULL },
    evidence_refs = json_array({ { kind = "runtime-row-replay-router", ref = "packages/github-devloop-pr/departments/observe_pr/main.lua:142-170" }, { kind = "runtime-row-replay-dispatch", ref = fixture.state == "pr-open" and "packages/github-devloop-pr/departments/observe_pr/main.lua:595-597" or "packages/github-devloop-pr/departments/observe_pr/main.lua:569-583" }, { kind = "runtime-disposition", ref = fixture.evidence_ref or ("devloop.logging.log_cas_decision:observe_pr:" .. fixture.expected_decision) }, { kind = "runtime-event-source", ref = SOURCE_REF.ref } }),
  }
end

local function tuple(variant, status, reason, target, effects) return table.concat({ variant, status, reason, target, table.concat(effects, ",") }, "|") end
local function fixture_tuples()
  local values = {}; for _, fixture in ipairs(FIXTURES) do local value = tuple(fixture.name, fixture.expected_status, fixture.expected_decision, fixture.expected_target, fixture.expected_effect_ids); if values[value] then error("duplicate production fixture tuple: " .. value, 0) end; values[value] = true end; return values
end
local function record_tuples(records, label)
  local values = {}; for _, record in ipairs(records) do local id = tostring(record.observation_id or ""); if id:sub(1, #OBSERVATION_PREFIX) ~= OBSERVATION_PREFIX then error(label .. " has unexpected observation_id " .. id, 0) end; local value = tuple(id:sub(#OBSERVATION_PREFIX + 1), record.old_outcome.status, record.old_outcome.reason_code, record.typed_intent.target, effect_ids(record.old_outcome.emitted_effects)); if values[value] then error(label .. " contains duplicate tuple: " .. value, 0) end; values[value] = true end; return values
end
local function assert_bidirectional(actual, expected, actual_label, expected_label, records)
  for value in pairs(actual) do if not expected[value] then error(actual_label .. " tuple absent from " .. expected_label .. ": " .. value .. "; records=" .. canonical_json(records), 0) end end
  for value in pairs(expected) do if not actual[value] then error(expected_label .. " tuple absent from " .. actual_label .. ": " .. value .. "; records=" .. canonical_json(records), 0) end end
end
local function capture_records() local records = json_array(); for _, fixture in ipairs(FIXTURES) do table.insert(records, build_record(fixture)) end; table.sort(records, function(a, b) return a.observation_id < b.observation_id end); return records end
local function committed_records()
  local selected = json_array(); local inventory = json.decode(file.read(INVENTORY_PATH)); for _, record in ipairs(inventory.old_behavior_observations or {}) do local site = record.site; if type(site) == "table" and site.path == SITE.path and site.symbol == SITE.symbol and site.ordinal == SITE.ordinal then table.insert(selected, record) end end; table.sort(selected, function(a, b) return a.observation_id < b.observation_id end); return selected
end
local function assert_row_universe()
  local declared, covered, counts, decisions, reason_codes, covered_count, reason_count = {}, {}, {}, {}, {}, 0, 0
  for _, row in ipairs(core.restart_transition_table()) do declared[row.from_state] = row end
  for _, fixture in ipairs(FIXTURES) do
    t.is_true(declared[fixture.state] ~= nil, fixture.name .. ": production row declared")
    local decision_key = table.concat({
      fixture.state,
      fixture.expected_decision,
      fixture.expected_target,
      table.concat(fixture.expected_effect_ids, ","),
    }, "|")
    t.is_true(decisions[decision_key] == nil, fixture.name .. ": row-state decision class is unique")
    decisions[decision_key] = fixture.name
    if reason_codes[fixture.expected_decision] == nil then
      reason_codes[fixture.expected_decision], reason_count = true, reason_count + 1
    end
    counts[fixture.state] = (counts[fixture.state] or 0) + 1
    if not covered[fixture.state] then covered[fixture.state], covered_count = true, covered_count + 1 end
  end
  t.eq(covered_count, #core.restart_transition_table(), "observe_pr local fixtures cover every production PR row")
  for state, expected in pairs(EXPECTED_ROW_COUNTS) do
    t.eq(counts[state], expected, state .. ": complete production-reachable row disposition count")
  end
  t.eq(reason_count, 21, "collapsed distinct decision reason-code count")
  t.eq(#FIXTURES, 56, "collapsed production-reachable observe_pr local row decision-class count")
end

return {
  test_observe_pr_local_row_replay_old_behavior_is_real_dispatch_and_bidirectional = function()
    assert_row_universe()
    local fixtures, first, second = fixture_tuples(), capture_records(), capture_records()
    t.eq(#first, 56, "collapsed production-reachable observe_pr local row replay count")
    local repeat_difference = first_difference(second, first, "old_behavior_observations[observe-pr-local-row-replay][repeat]")
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then error("second OLD observe_pr local row replay capture differs at " .. tostring(repeat_difference or "canonical-json"), 0) end
    local runtime = record_tuples(first, "runtime records")
    assert_bidirectional(runtime, fixtures, "runtime records", "production fixture lattice", first)
    local expected = committed_records()
    assert_bidirectional(runtime, record_tuples(expected, "inventory records"), "runtime records", "inventory records", first)
    local difference = first_difference(first, expected, "old_behavior_observations[observe-pr-local-row-replay]")
    if difference ~= nil or canonical_json(first) ~= canonical_json(expected) then error("runtime-bound OLD observe_pr local row replay observation differs at " .. tostring(difference or "canonical-json") .. "; runtime_records=" .. canonical_json(first), 0) end
  end,
}
