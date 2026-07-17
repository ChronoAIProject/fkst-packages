local ra = require("tests.receiver_activation_observation_helpers")
local check_runs = require("forge.github.check_runs")
local config = require("devloop.config")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local fix_rounds = require("core.fix_rounds")
local h = require("tests.devloop_helpers")
local high_risk_merge_gate = require("core.high_risk_merge_gate")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local m_facts = require("devloop.markers.facts")
local m_mq = require("devloop.merge_queue")
local payloads_builders = require("devloop.payloads.builders")
local testing = require("testkit.testing")
local merge_module = require("departments.merge.main")

local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local OTHER_VERSION = VERSION .. "/review-loop/2"
local HEAD_SHA = "def456"
local OTHER_HEAD = "fed789"
local BRANCH = "devloop-owner-repo-42-01HY"
local PREFIX = "receiver-activation-merge-"
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

local FIXTURES = ra.json_array({
  {
    disposition = "skip-foreign-payload", status = "rejected", reason = "skip-foreign(payload)",
    cas = "skip-foreign(payload)", target = "reject", source_line = 725,
    payload = { schema = "unsupported.merge-ready.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" },
  },
  {
    disposition = "claim-not-acquired", status = "rejected", reason = "claim-not-acquired",
    cas = "skip-claimed-by-other", target = "reject", source_line = 335,
    current_state = "merge-ready", current_version = VERSION, claim = false,
  },
  {
    disposition = "skip-merged-idempotent", status = "rejected", reason = "merged-marker-visible",
    cas = "skip-idempotent(already at to_state)", target = "reject", source_line = 347,
    current_state = "merged", current_version = VERSION, merged_marker = true,
  },
  {
    disposition = "skip-from-state-mismatch", status = "rejected", reason = "from-state-mismatch",
    cas = "skip-stale(from-state-mismatch)", target = "reject", source_line = 352,
    current_state = "fixing", current_version = VERSION,
  },
  {
    disposition = "skip-version-mismatch", status = "rejected", reason = "version-mismatch",
    cas = "skip-stale(version-mismatch)", target = "reject", source_line = 376,
    current_state = "merge-ready", current_version = VERSION .. "/loop/01",
    payload = merge_payload({ version = VERSION .. "/loop/1" }),
  },
  {
    disposition = "skip-approval-mismatch", status = "rejected", reason = "approval-mismatch",
    cas = "skip-stale(merge-ready-approval-mismatch)", target = "reject", source_line = 386,
    current_state = "merge-ready", current_version = VERSION, approval_mismatch = true,
  },
  {
    disposition = "skip-pr-origin-mismatch", status = "rejected", reason = "pr-origin-mismatch",
    cas = "skip-foreign(pr-origin)", target = "reject", source_line = 397,
    current_state = "merge-ready", current_version = VERSION, origin_base = "other-base",
  },
  {
    disposition = "skip-external-merge", status = "rejected", reason = "external-merge-no-marker",
    cas = "skip-external-merge(no-bot-merging-marker)", target = "reject", source_line = 409,
    current_state = "merge-ready", current_version = VERSION, pr_state = "MERGED",
  },
  {
    disposition = "head-mismatch-merging-routes-fixing", status = "admitted", reason = "head-mismatch-merging",
    cas = "applied", target = "fixing", source_line = 425,
    current_state = "merging", current_version = VERSION, current_head_sha = OTHER_HEAD,
    effects = ra.json_array({ "comment:pr:merge-fixing", "label:issue:merge-fixing" }),
  },
  {
    disposition = "head-mismatch-merge-ready-routes-reviewing", status = "admitted", reason = "head-mismatch-reviewing",
    cas = "applied", target = "reviewing", source_line = 434,
    current_state = "merge-ready", current_version = VERSION, current_head_sha = OTHER_HEAD,
    effects = ra.json_array({ "comment:pr:merge-head-reviewing", "label:issue:merge-head-reviewing" }),
  },
  {
    disposition = "hold-merge-queue-empty", status = "rejected", reason = "merge-queue-empty",
    cas = "hold-merge-queue", target = "hold", source_line = 451,
    current_state = "merge-ready", current_version = VERSION, queue_empty = true,
  },
  {
    disposition = "hold-merge-queue-non-head", status = "rejected", reason = "merge-queue-non-head",
    cas = "hold-merge-queue", target = "hold", source_line = 494,
    current_state = "merge-ready", current_version = VERSION, queue_non_head = true,
  },
  {
    disposition = "dry-run-write-disabled", status = "rejected", reason = "write-disabled",
    cas = "dry-run", target = "hold", source_line = 507,
    current_state = "merge-ready", current_version = VERSION, write_mode = "dry-run",
  },
  {
    disposition = "missing-review-approval", status = "rejected", reason = "review-approval-missing",
    cas = "dry-run", target = "reject", source_line = 510,
    current_state = "merge-ready", current_version = VERSION, missing_review = true,
  },
  {
    disposition = "not-mergeable-routes-fixing", status = "admitted", reason = "not-mergeable",
    cas = "applied", target = "fixing", source_line = 548,
    current_state = "merge-ready", current_version = VERSION, not_mergeable = true,
    effects = ra.json_array({ "comment:pr:merge-fixing", "label:issue:merge-fixing" }),
  },
  {
    disposition = "admitted-merge", status = "admitted", reason = "verified-merge",
    cas = "applied", target = "merged", source_line = 705,
    current_state = "merge-ready", current_version = VERSION, merge = true,
    effects = ra.json_array({ "comment:pr:merging-state", "github.merge:verified-pr", "comment:pr:merged-state" }),
  },
  {
    disposition = "admitted-draft-ready-merge", status = "admitted", reason = "draft-ready-verified-merge",
    cas = "applied", target = "merged", source_line = 705,
    current_state = "merge-ready", current_version = VERSION, merge = true, draft = true,
    effects = ra.json_array({ "adapter:github.pr-ready", "comment:pr:merging-state", "github.merge:verified-pr", "comment:pr:merged-state" }),
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
    m_builders.merge_ready_marker(PROPOSAL_ID, PR_NUMBER, event.payload.version or VERSION,
      fixture.approval_mismatch and alternate_review_id or review_id, review_dedup, HEAD_SHA),
  })
  if not fixture.missing_review then
    table.insert(comments, m_builders.review_result_marker(review_id, PROPOSAL_ID, "approve", review_dedup))
  end
  if fixture.merged_marker then
    table.insert(comments, m_builders.merged_marker(core, PROPOSAL_ID, PR_NUMBER, VERSION, HEAD_SHA))
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
    return { stdout = "", stderr = "", exit_code = 1 }
  end
  local function pr_fields()
    local state = merged and "MERGED" or (fixture.pr_state or "OPEN")
    return {
      repo = REPO, number = PR_NUMBER, comments = comments, head = BRANCH,
      head_sha = fixture.current_head_sha or HEAD_SHA, base_branch = origin_base, base_sha = "abc123",
      state = state, merged_at = state == "MERGED" and "2026-06-03T02:05:04Z" or nil,
      is_draft = draft and not merged, mergeable = fixture.not_mergeable and "CONFLICTING" or "MERGEABLE",
      merge_state = fixture.not_mergeable and "DIRTY" or "CLEAN",
      status_check_rollup_json = '[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS","headSha":"' .. (fixture.current_head_sha or HEAD_SHA) .. '"}]',
    }
  end
  function ports.github.issue_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "issue_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.issue_view_stdout({ repo = REPO, number = ISSUE_NUMBER,
      assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot" }), stderr = "", exit_code = 0 }
  end
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.pr_view_stdout(pr_fields()), stderr = "", exit_code = 0 }
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
  ra.replace(entity_lib, "current_entity_state", function()
    return { state = fixture.current_state, version = fixture.current_version,
      stage_rank = fixture.current_state and core.stage_rank(fixture.current_state) or nil }
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
    return { proposal_id = PROPOSAL_ID, version = VERSION, pr_number = PR_NUMBER, head_sha = HEAD_SHA }, {}
  end, restorations)
  ra.replace(m_mq, "merge_queue_position", function()
    return { is_head = false, predecessors = { 8 }, predecessor_set = "8:abc123" }, "ok"
  end, restorations)
  ra.replace(check_runs, "pr_mergeable", function()
    if fixture.not_mergeable then return false, "merge-state-dirty" end
    return true, "mergeable"
  end, restorations)
  ra.replace(check_runs, "is_not_mergeable_reason", function(reason) return reason == "merge-state-dirty" end, restorations)
  ra.replace(fix_rounds, "admit_merge_failure", function(_, _, current_pr, _, reason)
    return { kind = "admit", version = VERSION .. "/fix/1", reason = reason,
      current_pr = current_pr, ci_failure_key = nil }
  end, restorations)
  ra.replace(core, "raise_review_carry_over", function() return nil end, restorations)
  ra.replace(core, "evaluate_ci_status_gate", function() return true, "rollup-green", {} end, restorations)
  ra.replace(core, "evaluate_ci_merge_gate", function() return true, "merge-gate-green", {} end, restorations)
  ra.replace(high_risk_merge_gate, "assert_evidence", function() return true end, restorations)
  ra.replace(config, "branch_config", function() return { upstream = "dev", integration = "dev" } end, restorations)
  ra.replace(config, "write_mode", function() return fixture.write_mode or "real" end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  local department = ra.make_department(merge_module, ports, core)
  local ok, result = pcall(testing.run_fake, department, event)
  ra.restore_all(restorations)
  if not ok then error(fixture.disposition .. ": " .. tostring(result), 0) end
  local selected = nil
  for _, decision in ipairs(captured.decisions) do
    if decision.outcome == fixture.cas then selected = decision break end
  end
  if fixture.cas == "dry-run" then selected = { outcome = "dry-run" } end
  t.is_true(selected ~= nil, fixture.disposition .. ": observable admission decision")
  return ra.record({ dept = "merge", fixture = fixture, result = result, captured = captured, event = event,
    prefix = PREFIX, site = SITE, source_state = "merge-ready",
    evidence_path = "packages/github-devloop-pr/core/merge_executor.lua",
  })
end

return {
  test_merge_receiver_activation_old_behavior_is_real_dispatch_and_bidirectional = function()
    ra.assert_site(t, { dept = "merge", fixtures = FIXTURES, capture = capture, prefix = PREFIX, site = SITE })
  end,
}
