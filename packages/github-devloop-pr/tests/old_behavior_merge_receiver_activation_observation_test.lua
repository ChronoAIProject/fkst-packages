local check_runs = require("forge.github.check_runs")
local ra = require("tests.receiver_activation_observation_helpers")
local config = require("devloop.config")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local fix_rounds = require("core.fix_rounds")
local h = require("tests.devloop_helpers")
local high_risk_merge_gate = require("core.high_risk_merge_gate")
local ci_facts = require("tests.merge_receiver_activation_ci_facts_helpers")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local m_facts = require("devloop.markers.facts")
local m_mq = require("devloop.merge_queue")
local payloads_builders = require("devloop.payloads.builders")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local testing = require("testkit_internal.testing")
local _workflow_codex = require("workflow_internal.codex")
local merge_module = require("departments.merge.main")
local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local OTHER_VERSION = VERSION .. "/review-loop/2"
local FIX_VERSION = VERSION .. "/fix/1"
local HEAD_SHA = "def456"
local OTHER_HEAD = "fed789"
local BRANCH = "devloop-owner-repo-42-01HY"
local OBSERVATION_NOW = 1784311200
local PREFIX = "entry-merge-"
local SITE = {
  path = "packages/github-devloop-pr/departments/merge/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:devloop_merge_ready",
}

local function merge_payload(extra)
  local review_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, VERSION, HEAD_SHA)
  local payload = payloads_builders.build_devloop_merge_ready_payload(PROPOSAL_ID, PR_NUMBER, VERSION, {
    review_proposal_id = review_id,
    review_dedup_key = "consensus:" .. review_id .. "/review",
    reviewed_head_sha = HEAD_SHA,
  }, { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER })
  for key, value in pairs(extra or {}) do payload[key] = value end
  return payload
end

local function merge_payload_for_fix()
  local payload = merge_payload({ version = FIX_VERSION })
  local review_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, FIX_VERSION, HEAD_SHA)
  payload.review_proposal_id = review_id
  payload.review_dedup_key = "consensus:" .. review_id .. "/review"
  return payload
end

local DELEGATION_FIXTURES = ci_facts.delegation_fixtures({
  array = ra.json_array,
  version = VERSION,
  fix_version = FIX_VERSION,
  merge_payload_for_fix = merge_payload_for_fix,
})

local FIXTURES = ra.json_array({
  { disposition = "skip-foreign-payload", status = "rejected", reason = "unsupported-payload",
    cas = "skip-foreign(payload)", target = "reject", source_line = 724,
    payload = { schema = "unsupported.merge-ready.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" } },
  { disposition = "skip-not-owned", status = "rejected", reason = "backing-issue-absent",
    cas = "skip-not-owned", target = "reject", source_line = 331,
    payload = merge_payload({ proposal_id = "github-devloop/pr/owner/repo/7",
      dedup_key = "merge-ready/github-devloop/pr/owner/repo/7/7/def456" }) },
  { disposition = "skip-foreign-proposal", status = "rejected", reason = "proposal-entity-mismatch",
    cas = "skip-foreign(proposal_id)", decision_reason = "no transition lock key",
    target = "reject", source_line = 327, payload = merge_payload({
      proposal_id = "github-devloop/pr/owner/repo/8",
      dedup_key = "merge-ready/github-devloop/pr/owner/repo/8/7/def456",
      source_ref = { kind = "external", ref = REPO .. "#pr/8" } }) },
  { disposition = "skip-merged-idempotent", status = "rejected", reason = "already-merged",
    cas = "skip-idempotent(already at to_state)", target = "reject", source_line = 346,
    current_state = "merged", current_version = VERSION, merged_marker = true },
  { disposition = "skip-from-state-mismatch", status = "rejected", reason = "from-state-mismatch",
    cas = "skip-stale(from-state-mismatch)", target = "reject", source_line = 351,
    current_state = "fixing", current_version = VERSION },
  { disposition = "versioned-defer", status = "error", reason = "source-marker-not-visible",
    cas = "retry-pending(from-state marker not yet visible)", target = "retry", source_line = 355,
    current_state = "merge-ready", current_version = VERSION:gsub("2026%-06%-03", "2026-06-02"),
    expected_error = "merge-ready-marker-missing" },
  { disposition = "versioned-skip-stale", status = "rejected", reason = "state-advanced",
    cas = "skip-advanced-or-diverged", target = "reject", source_line = 359,
    current_state = "merged", current_version = VERSION },
  { disposition = "skip-version-mismatch", status = "rejected", reason = "version-mismatch",
    cas = "skip-stale(version-mismatch)", target = "reject", source_line = 375,
    current_state = "merge-ready", current_version = VERSION .. "/loop/01",
    payload = merge_payload({ version = VERSION .. "/loop/1" }) },
  { disposition = "retry-merge-ready-fact", status = "error", reason = "merge-ready-fact-missing",
    cas = "retry-pending(merge-ready fact marker not visible)", target = "retry", source_line = 380,
    current_state = "merge-ready", current_version = VERSION, omit_merge_ready_fact = true,
    expected_error = "merge-ready-fact-missing" },
  { disposition = "skip-approval-fact", status = "rejected", reason = "approval-fact-mismatch",
    cas = "skip-stale(merge-ready-approval-mismatch)", target = "reject", source_line = 385,
    current_state = "merge-ready", current_version = VERSION, approval_mismatch = true },
  { disposition = "skip-pr-origin", status = "rejected", reason = "pr-origin-mismatch",
    cas = "skip-foreign(pr-origin)", target = "reject", source_line = 396,
    current_state = "merge-ready", current_version = VERSION, origin_base = "other-base" },
  { disposition = "skip-external-merge", status = "rejected", reason = "external-merge",
    cas = "skip-external-merge(no-bot-merging-marker)", target = "reject", source_line = 408,
    current_state = "merge-ready", current_version = VERSION, pr_state = "MERGED" },
  { disposition = "skip-pr-fact", status = "rejected", reason = "pr-fact-write-time",
    cas = "skip-stale(pr-not-open)", target = "reject", source_line = 436,
    current_state = "merge-ready", current_version = VERSION, pr_state = "CLOSED" },
  { disposition = "carry-over-review", status = "admitted", reason = "review-carry-over",
    cas = "applied(review-carry-over)", target = "merge-ready", source_line = 427,
    current_state = "merge-ready", current_version = VERSION, current_head_sha = OTHER_HEAD,
    carry_over = true, effects = ra.json_array({ "comment:pr:review-carry-over" }) },
  { disposition = "applied-fixing", status = "admitted", reason = "merge-gate-routes-fixing",
    cas = "applied", target = "fixing", source_line = 107,
    current_state = "merging", current_version = VERSION, current_head_sha = OTHER_HEAD,
    effects = ra.json_array({ "comment:pr:merge-fixing", "label:issue:merge-fixing" }) },
  { disposition = "applied-reviewing", status = "admitted", reason = "head-advanced-routes-reviewing",
    cas = "applied", target = "reviewing", source_line = 149,
    current_state = "merge-ready", current_version = VERSION, current_head_sha = OTHER_HEAD,
    effects = ra.json_array({ "comment:pr:merge-head-reviewing", "label:issue:merge-head-reviewing" }) },
  { disposition = "skip-reviewing-idempotent", status = "rejected", reason = "already-reviewing",
    cas = "skip-idempotent(already at to_state)", target = "reject", source_line = 142,
    current_state = "merge-ready", current_version = VERSION, current_head_sha = OTHER_HEAD,
    reviewing_marker = true },
  { disposition = "applied-merged", status = "admitted", reason = "finalize-merged",
    cas = "applied", target = "merged", source_line = 309,
    current_state = "merging", current_version = VERSION, pr_state = "MERGED", merging_marker = true,
    effects = ra.json_array({ "comment:pr:merged-state" }) },
  { disposition = "hold-merge-queue", status = "rejected", reason = "merge-queue-hold",
    cas = "hold-merge-queue", target = "hold", source_line = 449,
    current_state = "merge-ready", current_version = VERSION, queue_empty = true },
  { disposition = "hold-wip-cap", status = "rejected", reason = "wip-capacity-exhausted",
    cas = "hold-wip-cap", target = "hold", source_line = 484,
    current_state = "merge-ready", current_version = VERSION, queue_non_head = true,
    not_mergeable = true, wip_capacity = false },
  { disposition = "fail-ready-recheck", status = "error", reason = "ready-recheck",
    cas = "fail-closed(ready-recheck)", target = "reject", source_line = 517,
    current_state = "merge-ready", current_version = VERSION, draft = true,
    ready_recheck_reason = "review-missing", expected_error = "pr-fact-changed",
    effects = ra.json_array({ "adapter:github.pr-ready" }) },
  { disposition = "skip-write-gate", status = "rejected", reason = "write-gate-stale",
    cas = "skip-stale(write-gate)", target = "reject", source_line = 603,
    current_state = "merge-ready", current_version = VERSION, write_gate_stale = true },
  { disposition = "versioned-apply", status = "admitted", reason = "all-gates-satisfied",
    cas = "applied", target = "merging", source_line = 615,
    current_state = "merge-ready", current_version = VERSION, merge_confirmation_pending = true,
    verified_return = "merge-confirmation-pending", expected_error = "merge-confirmation-pending",
    effects = ra.json_array({ "comment:pr:merging-state", "github.merge:verified-pr" }) },
  { disposition = "retry-merge-confirmation", status = "error", reason = "merge-confirmation-pending",
    cas = "retry-pending(merge-confirmation)", target = "retry", source_line = 652,
    current_state = "merge-ready", current_version = VERSION, merge_confirmation_pending = true,
    verified_return = "merge-confirmation-pending", expected_error = "merge-confirmation-pending",
    effects = ra.json_array({ "comment:pr:merging-state", "github.merge:verified-pr" }) },
  { disposition = "fail-merge-confirmation", status = "error", reason = "merge-confirmation-mismatch",
    cas = "fail-closed(merge-confirmation)", target = "reject", source_line = 656,
    current_state = "merge-ready", current_version = VERSION, merge_confirmation_mismatch = true,
    verified_return = "merge-confirmation-mismatch", expected_error = "merge-confirmation-mismatch",
    effects = ra.json_array({ "comment:pr:merging-state", "github.merge:verified-pr" }) },
  DELEGATION_FIXTURES[4],
  DELEGATION_FIXTURES[3],
})

local function merge_sink_fixture(disposition, current_state)
  return {
    disposition = disposition,
    status = "admitted",
    reason = "all-gates-satisfied",
    cas = "applied",
    target = "merging",
    source_line = 615,
    current_state = current_state,
    current_version = VERSION,
    merge_confirmation_pending = true,
    verified_return = "merge-confirmation-pending",
    expected_error = "merge-confirmation-pending",
    effects = ra.json_array({ "comment:pr:merging-state", "github.merge:verified-pr" }),
  }
end

local SINK_PROBES = ra.json_array({
  {
    id = "entry-merge-versioned-apply",
    current_state = "merge-ready", from_states = { "merge-ready", "merging" }, target_state = "merging",
    version = VERSION, expected_status = "apply",
    fixture = merge_sink_fixture("versioned-apply", "merge-ready"),
    owns = {
      ["github.merge:verified-pr"] = {
        "github-devloop-pr/merge-ready/entry/handoff_to_merge_gate/apply",
        "github-devloop-pr/merge-ready/guard_boundary/merge_gate/eligible_now/apply",
      },
    },
  },
  {
    id = "entry-merge-versioned-idempotent",
    current_state = "merging", from_states = { "merge-ready", "merging" }, target_state = "merging",
    version = VERSION, expected_status = "idempotent",
    fixture = merge_sink_fixture("versioned-idempotent", "merging"),
    owns = {
      ["github.merge:verified-pr"] = {
        "github-devloop-pr/merge-ready/entry/handoff_to_merge_gate/idempotent",
        "github-devloop-pr/merge-ready/guard_boundary/merge_gate/eligible_now/idempotent",
      },
    },
  },
})

local function event_for(fixture)
  return { queue = "github-devloop-pr.devloop_merge_ready", ts = "2026-06-03T02:03:04Z",
    payload = fixture.payload and ra.copy_value(fixture.payload) or merge_payload() }
end

local function capture(fixture)
  h.mock_bot_env()
  local event = event_for(fixture)
  local canonical_payload = merge_payload()
  local ports = ra.fake_ports()
  local restorations = {}
  local captured = ra.capture_logging("merge", devloop_logging, restorations)
  local review_id = event.payload.review_proposal_id or canonical_payload.review_proposal_id
  local review_dedup = event.payload.review_dedup_key or canonical_payload.review_dedup_key
  local alternate_review_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, VERSION, OTHER_HEAD)
  local origin_base = fixture.origin_base or "dev"
  local comments = ra.json_array({
    m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH, VERSION, origin_base),
    core.state_marker(PROPOSAL_ID, fixture.current_state or "merge-ready", fixture.current_version or event.payload.version or VERSION),
  })
  if not fixture.omit_merge_ready_fact then
    table.insert(comments, m_builders.merge_ready_marker(PROPOSAL_ID, PR_NUMBER,
      event.payload.version or VERSION,
      fixture.approval_mismatch and alternate_review_id or review_id, review_dedup, HEAD_SHA))
  end
  if not fixture.missing_review then
    table.insert(comments, m_builders.review_result_marker(review_id, PROPOSAL_ID, "approve", review_dedup))
  end
  if fixture.merged_marker then
    table.insert(comments, m_builders.merged_marker(core, PROPOSAL_ID, PR_NUMBER, VERSION, HEAD_SHA))
  end
  if fixture.merging_marker then
    table.insert(comments, m_builders.merging_marker(PROPOSAL_ID, PR_NUMBER, VERSION, HEAD_SHA))
  end
  if fixture.speculative_predecessor then
    local speculative_review_id = review_id
    local speculative_review_dedup = review_dedup
    if fixture.speculative_old_head then
      speculative_review_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, VERSION,
        fixture.speculative_old_head)
      speculative_review_dedup = "consensus:" .. speculative_review_id .. "/review"
    end
    table.insert(comments, m_builders.merge_gate_marker(PROPOSAL_ID, PR_NUMBER, VERSION,
      speculative_review_id, speculative_review_dedup, fixture.speculative_old_head or HEAD_SHA,
      string.rep("a", 40), "mergeable-conflicting",
      fixture.speculative_predecessor_set or "pred-a"))
  end
  if fixture.speculative_fix_marker then
    local speculative_review_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, VERSION,
      fixture.speculative_old_head)
    local speculative_review_dedup = "consensus:" .. speculative_review_id .. "/review"
    table.insert(comments, m_builders.fix_marker(PROPOSAL_ID, speculative_review_id, speculative_review_dedup,
      fixture.speculative_old_head or HEAD_SHA, HEAD_SHA))
  end
  if fixture.reviewing_marker then
    table.insert(comments, core.state_marker(PROPOSAL_ID, "reviewing", core.next_review_loop_version(VERSION)))
  end
  local merged = false
  local draft = fixture.draft == true
  function ports.git.fetch_branch(remote, branch, timeout)
    ra.record_write(ports.git_model, "fetch_branch", { remote = remote, branch = branch, timeout = timeout })
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  function ports.git.remote_branch_head(remote, branch, timeout)
    ra.record_write(ports.git_model, "remote_branch_head", { remote = remote, branch = branch, timeout = timeout })
    return { stdout = string.rep("a", 40) .. "\n", stderr = "", exit_code = 0 }
  end
  function ports.git.is_ancestor(ancestor_sha, descendant_sha, timeout)
    ra.record_write(ports.git_model, "is_ancestor", {
      ancestor_sha = ancestor_sha, descendant_sha = descendant_sha, timeout = timeout,
    })
    return { stdout = "", stderr = "", exit_code = fixture.carry_over and 0 or 1 }
  end
  function ports.git.merge_tree(approved_head_sha, base_head_sha, timeout)
    ra.record_write(ports.git_model, "merge_tree", {
      approved_head_sha = approved_head_sha, base_head_sha = base_head_sha, timeout = timeout,
    })
    return { stdout = string.rep("b", 40) .. "\n", stderr = "", exit_code = 0 }
  end
  function ports.git.trees_equal_quiet(sha_a, sha_b, timeout)
    ra.record_write(ports.git_model, "trees_equal_quiet", {
      sha_a = sha_a, sha_b = sha_b, timeout = timeout,
    })
    return { stdout = "", stderr = "", exit_code = fixture.carry_over and 0 or 1 }
  end
  local function pr_fields(read_count)
    local confirmation_pending = fixture.merge_confirmation_pending and (read_count or 0) >= 4
    local state = merged and not confirmation_pending and "MERGED" or (fixture.pr_state or "OPEN")
    if fixture.reclassification_pr_state ~= nil and (read_count or 0) >= 2 then
      state = fixture.reclassification_pr_state
    end
    local head_sha = fixture.current_head_sha or HEAD_SHA
    local head_branch = BRANCH
    if fixture.verified_identity_mismatch and (read_count or 0) >= 3 then head_branch = BRANCH .. "-changed" end
    local active_comments = comments
    local change = fixture.ready_recheck_reason
    if change ~= nil and (read_count or 0) >= 2 then
      active_comments = ra.json_array()
      for _, body in ipairs(comments) do
        local keep = true
        if change == "review-missing" and tostring(body):find("review-result:v1", 1, true) then keep = false end
        if change == "approval-changed" and tostring(body):find("merge-ready:v1", 1, true) then keep = false end
        if change == "origin-changed" and tostring(body):find("pr-origin:v1", 1, true) then keep = false end
        if keep then table.insert(active_comments, body) end
      end
      if change == "approval-changed" then
        table.insert(active_comments, m_builders.merge_ready_marker(PROPOSAL_ID, PR_NUMBER, event.payload.version,
          alternate_review_id, review_dedup, HEAD_SHA))
      elseif change == "origin-changed" then
        table.insert(active_comments, m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH,
          VERSION, "other-base"))
      elseif change == "head-changed" then
        head_sha = OTHER_HEAD
      end
    end
    if fixture.verified_origin_changed and (read_count or 0) >= 3 then
      active_comments = ra.json_array()
      for _, body in ipairs(comments) do
        if not tostring(body):find("pr-origin:v1", 1, true) then table.insert(active_comments, body) end
      end
      table.insert(active_comments, m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH,
        VERSION, "other-base"))
    end
    if merged and fixture.merge_confirmation_mismatch then head_sha = OTHER_HEAD end
    fixture.other_head = OTHER_HEAD
    local rollup_status, rollup_conclusion, rollup_name, rollup_head_sha =
      ci_facts.rollup(fixture, read_count, head_sha)
    return {
      repo = REPO, number = PR_NUMBER, comments = active_comments, head = head_branch,
      head_sha = head_sha, base_branch = origin_base, base_sha = string.rep("a", 40),
      state = state, merged_at = state == "MERGED" and "2026-06-03T02:05:04Z" or nil,
      is_draft = draft and not merged,
      mergeable = (fixture.not_mergeable or (fixture.verified_not_mergeable and (read_count or 0) >= 3))
        and "CONFLICTING" or "MERGEABLE",
      merge_state = (fixture.not_mergeable or (fixture.verified_not_mergeable and (read_count or 0) >= 3))
        and "DIRTY" or (fixture.status_gate_red and "UNSTABLE" or "CLEAN"),
      status_check_rollup_json = '[{"__typename":"CheckRun","name":"' .. rollup_name
        .. '","status":"' .. rollup_status .. '","conclusion":' .. rollup_conclusion
        .. ',"headSha":"' .. rollup_head_sha .. '"}]',
    }
  end
  function ports.github.issue_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "issue_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.issue_view_stdout({ repo = REPO, number = ISSUE_NUMBER,
      assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot" }), stderr = "", exit_code = 0 }
  end
  local pr_read_count = 0
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    pr_read_count = pr_read_count + 1
    local fields_value = pr_fields(pr_read_count)
    if fixture.recheck_head_mismatch and pr_read_count >= 2 then fields_value.head_sha = OTHER_HEAD end
    if fixture.own_ci_head_mismatch and pr_read_count >= 2 then fields_value.head_sha = OTHER_HEAD end
    if fixture.verified_head_mismatch and pr_read_count >= 3 then fields_value.head_sha = OTHER_HEAD end
    if fixture.verified_own_ci_head_mismatch and pr_read_count >= 4 then fields_value.head_sha = OTHER_HEAD end
    return { stdout = entity_read_mocks.pr_view_stdout(fields_value), stderr = "", exit_code = 0 }
  end
  function ports.github.pr_ready(repo, number, timeout)
    local call = { kind = "exec", context = "gh pr ready", argv = { "gh", "pr", "ready", tostring(number), "--repo", repo }, timeout = timeout }
    table.insert(ports.github_model.writes, call)
    table.insert(captured.effect_sequence, { kind = "adapter", call = call })
    draft = false
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  function ports.github.pr_diff_name_only(repo, number, timeout)
    ra.record_write(ports.github_model, "pr_diff_name_only", { repo = repo, number = number, timeout = timeout })
    return { stdout = "file.lua\n", stderr = "", exit_code = 0 }
  end
  function ports.github.gh_commit_check_runs(repo, head_sha, timeout)
    ra.record_write(ports.github_model, "commit_check_runs", {
      repo = repo, head_sha = head_sha, timeout = timeout,
    })
    return { stdout = ci_facts.commit_check_runs(fixture, pr_read_count, head_sha), stderr = "", exit_code = 0 }
  end
  function ports.github.pr_comment(repo, number, body_file, timeout)
    local call = { kind = "exec", context = "gh pr comment", argv = { "gh", "pr", "comment", tostring(number), "--repo", repo, "--body-file", body_file }, timeout = timeout }
    table.insert(ports.github_model.writes, call)
    table.insert(captured.effect_sequence, { kind = "adapter", call = call })
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  function ports.github.pr_merge(repo, number, head_sha, timeout)
    local call = { kind = "exec", context = "gh pr merge", argv = { "gh", "pr", "merge", tostring(number), "--repo", repo, "--merge", "--match-head-commit", head_sha }, timeout = timeout }
    table.insert(ports.github_model.writes, call)
    table.insert(captured.effect_sequence, { kind = "adapter", call = call })
    merged = true
    return { stdout = "merged\n", stderr = "", exit_code = 0 }
  end
  local state_read_count = 0
  ra.replace(entity_lib, "current_entity_state", function()
    state_read_count = state_read_count + 1
    local state = fixture.current_state
    local version = fixture.current_version
    if fixture.write_gate_stale and state_read_count >= 3 then
      state = "fixing"
    end
    return { state = state, version = version,
      stage_rank = state and core.stage_rank(state) or nil }
  end, restorations)
  ra.replace(m_claims, "verify_pr_review_issue_claim", function(dept, _, _, _, proposal_id)
    if fixture.claim == false then
      devloop_logging.log_cas_decision(dept, proposal_id, { state = nil, version = nil }, "claim", "claim", "skip-claimed-by-other", "backing issue assignee claim is held by another login")
      return false
    end
    return true
  end, restorations)
  ra.replace(m_mq, "merge_queue_head", function()
    if fixture.queue_empty then return nil, {} end
    if fixture.queue_non_head then return { proposal_id = "other", version = VERSION, pr_number = 8, head_sha = "abc123" }, {} end
    local version = fixture.fix_terminate and event.payload.version or VERSION
    return { proposal_id = PROPOSAL_ID, version = version, pr_number = PR_NUMBER, head_sha = HEAD_SHA }, {}
  end, restorations)
  local queue_position_reads = 0
  ra.replace(m_mq, "merge_queue_position", function()
    queue_position_reads = queue_position_reads + 1
    if fixture.queue_recheck_unavailable and queue_position_reads >= 1 then
      return nil, "not-in-merge-queue"
    end
    if fixture.queue_position_unavailable then return nil, "not-in-merge-queue" end
    return { is_head = false, predecessors = { 8 }, predecessor_set = "pred-current" }, "ok"
  end, restorations)
  ra.replace(m_mq, "wip_capacity_allows_start", function()
    if fixture.wip_capacity == false then return false, "wip-capacity-exhausted" end
    return true, "wip-capacity-available"
  end, restorations)
  if fixture.speculative_match then
    ra.replace(m_mq, "merge_queue_predecessor_set_matches_current_base", function()
      return true, "predecessor-set-match"
    end, restorations)
  end
  local production_pr_mergeable = check_runs.pr_mergeable
  ra.replace(check_runs, "pr_mergeable", function(pr)
    if fixture.status_gate_red or fixture.verified_ci_red then
      return production_pr_mergeable(pr)
    end
    if fixture.mergeable_reason then return false, fixture.mergeable_reason end
    if fixture.not_mergeable then return false, "merge-state-dirty" end
    return true, "mergeable"
  end, restorations)
  local admissions = observation_support.json_array()
  if fixture.reclassification_outcome ~= nil or fixture.capture_classification then
    local admit_merge_failure = fix_rounds.admit_merge_failure
    ra.replace(fix_rounds, "admit_merge_failure", function(...)
      local args = { ... }
      local classification = args[6]
      local admission = admit_merge_failure(...)
      table.insert(admissions, {
        kind = admission.kind,
        classification = classification and classification.kind or nil,
        reason = classification and classification.reason or nil,
        ci_failure_key = classification and classification.ci_failure_key or nil,
      })
      return admission
    end, restorations)
  elseif not fixture.fix_terminate then
    ra.replace(fix_rounds, "admit_merge_failure", function(_, _, current_pr, _, reason, classification)
      current_pr = current_pr or (classification and classification.current_pr)
      return { kind = "admit", version = VERSION .. "/fix/1", reason = reason,
        current_pr = current_pr, ci_failure_key = nil }
    end, restorations)
  end
  if fixture.fix_terminate then
    ra.replace(config, "max_fix_rounds", function() return 1 end, restorations)
  end
  local production_evaluate_ci_status_gate = core.evaluate_ci_status_gate
  ra.replace(core, "evaluate_ci_status_gate", function(pr, opts)
    if fixture.status_gate_red or fixture.verified_ci_red then
      return production_evaluate_ci_status_gate(pr, opts)
    end
    if fixture.rollup_reason then return false, fixture.rollup_reason, {} end
    return true, "rollup-green", {}
  end, restorations)
  local production_evaluate_ci_merge_gate = core.evaluate_ci_merge_gate
  ra.replace(core, "evaluate_ci_merge_gate", function(pr, opts)
    if fixture.verified_ci_red then
      return production_evaluate_ci_merge_gate(pr, opts)
    end
    if fixture.ci_merge_reason then return false, fixture.ci_merge_reason, {} end
    return true, "merge-gate-green", {}
  end, restorations)
  local verified_returns = ra.json_array()
  local run_verified_pr_merge = core.run_verified_pr_merge
  ra.replace(core, "run_verified_pr_merge", function(request)
    local merge_ok, reason, current_pr, classification = run_verified_pr_merge(request)
    table.insert(verified_returns, {
      merge_ok = merge_ok,
      reason = reason,
      classification = classification and classification.kind or nil,
    })
    return merge_ok, reason, current_pr, classification
  end, restorations)
  ra.replace(high_risk_merge_gate, "assert_evidence", function() return true end, restorations)
  ra.replace(high_risk_merge_gate, "require_evidence", function()
    if fixture.verified_evidence_missing then
      return false, "retry-pending(high-risk-review-evidence-missing)"
    end
    return true, "evidence-ok"
  end, restorations)
  ra.replace(config, "branch_config", function() return { upstream = "dev", integration = "dev" } end, restorations)
  ra.replace(config, "write_mode", function() return fixture.write_mode or "real" end, restorations)
  ra.replace(_G, "now", function() return OBSERVATION_NOW end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  local department = ra.make_department(merge_module, ports, core)
  local runner = fixture.expected_error and testing.run_fake_expecting_failure or testing.run_fake
  local ok, result = pcall(runner, department, event)
  ra.restore_all(restorations)
  if not ok then error(fixture.disposition .. ": " .. tostring(result), 0) end
  if fixture.verified_return ~= nil then
    t.eq(#verified_returns, 1, fixture.disposition .. ": one delegated verified-merge return")
    t.eq(verified_returns[1].reason, fixture.verified_return,
      fixture.disposition .. ": exact delegated verified-merge return")
    if fixture.expected_verified_classification ~= nil then
      t.eq(verified_returns[1].classification, fixture.expected_verified_classification,
        fixture.disposition .. ": exact verified-merge classification")
    end
  else
    t.eq(#verified_returns, 0, fixture.disposition .. ": verified merge not reached")
  end
  if fixture.expected_error then
    t.is_true(tostring(result.failure and result.failure.error or ""):find(fixture.expected_error, 1, true) ~= nil,
      fixture.disposition .. ": expected failure")
  end
  if fixture.reclassification_outcome ~= nil or fixture.capture_classification then
    local expected_count = fixture.expected_admission == false and 0 or 1
    t.eq(#admissions, expected_count, fixture.disposition .. ": production reclassification admission count")
    if expected_count == 1 then
      t.eq(admissions[1].kind, fixture.expected_admission,
        fixture.disposition .. ": exact production own-CI admission")
      t.eq(admissions[1].classification, fixture.expected_classification,
        fixture.disposition .. ": exact fresh production classification")
      t.eq(admissions[1].reason, fixture.expected_classification_reason or fixture.reason,
        fixture.disposition .. ": exact fresh production classification reason")
      if fixture.expected_classification == "OWN_CI_RED" then
        t.is_true(tostring(admissions[1].ci_failure_key or "") ~= "",
          fixture.disposition .. ": production own-CI failure key")
      end
    end
  end
  local selected = nil
  for _, decision in ipairs(captured.decisions) do
    if decision.outcome == fixture.cas
      and (fixture.decision_reason == nil or decision.reason == fixture.decision_reason) then
      selected = decision
      break
    end
  end
  if selected == nil then
    for _, gate in ipairs(captured.gates) do
      if gate.outcome == fixture.cas
        and (fixture.decision_reason == nil or gate.reason == fixture.decision_reason) then
        selected = gate
        break
      end
    end
  end
  t.is_true(selected ~= nil, fixture.disposition .. ": observable admission decision; decisions="
    .. ra.canonical_json(captured.decisions))
  return ra.record({ dept = "merge", fixture = fixture, result = result, captured = captured, event = event,
    prefix = PREFIX, site = SITE, source_state = "merge-ready", boundary = "entry_acceptor",
    evidence_path = fixture.evidence_path or "packages/github-devloop-pr/core/merge_executor.lua",
  })
end

return {
  test_merge_entry_acceptor_old_behavior_is_real_dispatch_and_bidirectional = function()
    local shadow_sink_records = ra.capture_shadow_sink_probes(t, {
      probes = SINK_PROBES,
      capture = capture,
      devloop_state = devloop_state,
    })
    ra.assert_site(t, { dept = "merge", fixtures = FIXTURES, capture = capture, prefix = PREFIX,
      site = SITE, boundary = "entry_acceptor",
      shadow_corpus_path = "migration/intent_bounded_replay/corpus/pr-merge.json",
      shadow_sink_records = shadow_sink_records })
  end,
}
