local ra = require("tests.receiver_activation_observation_helpers")
local config = require("devloop.config")
local context_bundle = require("devloop.context_bundle")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local dispatch_live_run = require("devloop.dispatch_live_run")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local merge_queue = require("devloop.merge_queue")
local payloads_builders = require("devloop.payloads.builders")
local requests_review = require("devloop.requests.review")
local testing = require("testkit_internal.testing")
local transition_version = require("contract.transition_version")
local _observation_support = require("testkit_internal.old_behavior_observation_support")
local workflow_codex = require("workflow_internal.codex")
local fix_module = require("departments.fix.main")

local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = h.fixing().version
local OLDER = VERSION:gsub("2026%-06%-03", "2026-06-02")
local HEAD_SHA = "def456"
local NEW_HEAD = "feedface"
local BRANCH = devloop_base.implement_branch(REPO, ISSUE_NUMBER, VERSION)
local PREFIX = "entry-fix-"
local SITE = {
  path = "packages/github-devloop-pr/departments/fix/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:devloop_fixing",
}

local CODEX = "codex.dispatch:fix"
local PUSH = "git.push:fix-branch"
local FIX_DISPATCH_ENTITLEMENT_ID = "github-devloop-pr/fixing/receiver_dispatch"
local FIX_PUBLISH_ENTITLEMENT_ID = "github-devloop-pr/fixing/autonomous/revision_published/apply"
local REVIEWING_COMMENT = "comment:pr:fix-reviewing"
local REVIEWING_LABEL = "label:issue:fix-reviewing"
local META_COMMENT = "comment:pr:fix-review-meta"
local META_LABEL = "label:issue:fix-review-meta"
local CI_ATTEMPT = "comment:pr:ci-repair-attempt"
local FIX_RECONCILE = "queue:github-devloop-pr.devloop_fix_reconcile"
local DECOMPOSE = "queue:github-devloop-decompose.devloop_decompose"

local FIXTURES = ra.json_array({
  { disposition = "skip-foreign-payload", status = "rejected", reason = "unsupported-payload",
    cas = "skip-foreign(payload)", target = "reject", source_line = 485,
    payload = { schema = "unsupported.fixing.v1", proposal_id = PROPOSAL_ID, dedup_key = "bad" } },
  { disposition = "skip-already-reviewing", status = "rejected", reason = "already-reviewing-marker",
    cas = "skip-idempotent(already at to_state)", target = "reject", source_line = 520,
    current_state = "reviewing", target_marker = true },
  { disposition = "retry-fixing-marker-pending", status = "error", reason = "fixing-marker-pending",
    cas = "retry-pending(from-state marker not yet visible)", target = "retry", source_line = 526,
    no_state = true, no_feedback = true, error = "fixing-marker-missing" },
  { disposition = "skip-incoming-version-older", status = "rejected", reason = "incoming-version-older",
    cas = "skip-stale(incoming version < current marker version)", target = "reject", source_line = 534,
    current_state = "fixing", current_version = VERSION, event_version = OLDER },
  { disposition = "skip-state-advanced", status = "rejected", reason = "state-advanced",
    cas = "skip-advanced-or-diverged", target = "reject", source_line = 534,
    current_state = "blocked" },
  { disposition = "skip-version-mismatch", status = "rejected", reason = "raw-version-mismatch",
    cas = "skip-stale(version-mismatch)", target = "reject", source_line = 538,
    current_state = "fixing", current_version = VERSION .. "/loop/01", event_version = VERSION .. "/loop/1" },
  { disposition = "skip-superseded-merge-gate", status = "rejected", reason = "superseded-merge-gate",
    cas = "skip-stale(superseded-merge-gate-fact)", target = "reject", source_line = 562,
    merge_gate = "superseded" },
  { disposition = "skip-base-skewed-merge-gate", status = "rejected", reason = "base-skewed-merge-gate-fact",
    cas = "skip-stale(base-skewed-merge-gate-fact)", target = "reject", source_line = 601,
    merge_gate = "base-skewed" },
  { disposition = "fail-merge-gate-mismatch", status = "error", reason = "merge-gate-mismatch",
    cas = "fail-closed(merge-gate-fact-mismatch)", target = "reject", source_line = 605,
    merge_gate = "mismatch", error = "active-merge-gate-fact-mismatch" },
  { disposition = "applied-base-skewed-ci-recovery", status = "admitted", reason = "base-skewed-ci-recovery",
    cas = "applied(base-skewed-ci-recovery)", target = "fixing", source_line = 608,
    merge_gate = "base-skewed-ci", repair_input = "ci-failure", codex = "no-fix", ci_red = true,
    effects = ra.json_array({ CODEX, CI_ATTEMPT }) },
  { disposition = "retry-feedback-marker-pending", status = "error", reason = "feedback-marker-pending",
    cas = "retry-pending(fix feedback marker not visible)", target = "retry", source_line = 570,
    no_feedback = true, error = "fix-feedback-marker-missing" },
  { disposition = "skip-pr-origin", status = "rejected", reason = "pr-origin-mismatch",
    cas = "skip-foreign(pr-origin)", target = "reject", source_line = 601, foreign_branch = true },
  { disposition = "skip-pr-closed", status = "rejected", reason = "pr-closed",
    cas = "skip-stale(pr-closed)", target = "reject", source_line = 606, pr_state = "CLOSED" },
  { disposition = "fail-head-repository", status = "error", reason = "head-repository-invalid",
    cas = "fail-closed(head-repository)", target = "reject", source_line = 610,
    head_repo = "fork/repo", error = "pr-head-repository-invalid" },
  { disposition = "skip-head-advanced", status = "rejected", reason = "head-advanced",
    cas = "skip-stale(head-advanced)", target = "reject", source_line = 628,
    head_sha = "cafebabe", branch_head = "feedface" },
  { disposition = "admitted-head-self-heal-reviewing", status = "admitted", reason = "head-self-heal",
    cas = "applied", target = "reviewing", source_line = 625,
    head_sha = NEW_HEAD, branch_head = NEW_HEAD,
    effects = ra.json_array({ REVIEWING_COMMENT, REVIEWING_LABEL }) },
  { disposition = "skip-ci-repair-attempt-visible", status = "rejected", reason = "ci-repair-attempt-visible",
    cas = "skip-idempotent(ci-repair-attempt-visible)", target = "reject", source_line = 633,
    repair_input = "ci-failure", ci_attempt_visible = true },
  { disposition = "dry-run-write-disabled", status = "rejected", reason = "write-disabled",
    cas = "dry-run(write-disabled)", target = "reject", source_line = 637, dry_run = true },
  { disposition = "live-fix-deferred", status = "rejected", reason = "live-exec-ref",
    cas = "skip-idempotent(live-exec-ref)", target = "defer", source_line = 708, live_run = true },
  { disposition = "admitted-speculative-refix", status = "admitted", reason = "speculative-predecessor-set-changed",
    cas = "applied", target = "fixing", source_line = 659, speculative_refix = true,
    effects = ra.json_array({ "comment:pr:fix-speculative-refix", "label:issue:fix-speculative-refix" }) },
  { disposition = "skip-speculative-not-in-merge-queue", status = "rejected",
    reason = "speculative-not-in-merge-queue", cas = "skip-stale(not-in-merge-queue)",
    target = "reject", source_line = 190, not_in_merge_queue = true },
  { disposition = "codex-dispatch-deferred", status = "admitted", reason = "codex-deferred",
    cas = "admitted(dispatch-deferred)", target = "defer", source_line = 718, codex = "deferred",
    effects = ra.json_array({ CODEX }) },
  { disposition = "codex-failed-routes-review-meta", status = "admitted", reason = "codex-failed",
    cas = "applied", target = "review-meta", source_line = 449, codex = "failed",
    effects = ra.json_array({ CODEX, META_COMMENT, META_LABEL }) },
  { disposition = "no-fix-routes-review-meta", status = "admitted", reason = "no-fix",
    cas = "applied", target = "review-meta", source_line = 446, codex = "no-fix",
    effects = ra.json_array({ CODEX, META_COMMENT, META_LABEL }) },
  { disposition = "no-new-head-routes-review-meta", status = "admitted", reason = "no-new-head",
    cas = "applied", target = "review-meta", source_line = 312, codex = "no-new-head",
    effects = ra.json_array({ CODEX, META_COMMENT, META_LABEL }) },
  { disposition = "ci-no-repair-records-attempt", status = "admitted", reason = "ci-repair-attempt",
    cas = "admitted(ci-repair-attempt)", target = "fixing", source_line = 426,
    repair_input = "ci-failure", codex = "no-fix", ci_red = true,
    effects = ra.json_array({ CODEX, CI_ATTEMPT }) },
  { disposition = "own-ci-cleared-routes-reviewing", status = "admitted", reason = "own-ci-cleared",
    cas = "applied", target = "reviewing", source_line = 349,
    repair_input = "ci-failure", own_ci_cleared = true,
    effects = ra.json_array({ REVIEWING_COMMENT, REVIEWING_LABEL }) },
  { disposition = "max-round-no-new-head-routes-reconcile", status = "admitted",
    reason = "max-round-no-new-head", cas = "applied(fix-loop-max-rounds)", target = "blocked",
    source_line = 429, max_fix_rounds = true, codex = "no-new-head",
    effects = ra.json_array({ CODEX, FIX_RECONCILE, DECOMPOSE }) },
  { disposition = "max-round-no-fix-routes-reconcile", status = "admitted",
    reason = "max-round-no-fix", cas = "applied(fix-loop-max-rounds)", target = "blocked",
    source_line = 431, max_fix_rounds = true, codex = "no-fix",
    effects = ra.json_array({ CODEX, FIX_RECONCILE, DECOMPOSE }) },
  { disposition = "existing-head-routes-reviewing", status = "admitted", reason = "existing-head",
    cas = "applied", target = "reviewing", source_line = 478, codex = "existing-head",
    branch_head = NEW_HEAD, effects = ra.json_array({ CODEX, PUSH, REVIEWING_COMMENT, REVIEWING_LABEL }) },
  { disposition = "new-fix-push-routes-reviewing", status = "admitted", reason = "new-head",
    cas = "applied", target = "reviewing", source_line = 478, codex = "changed",
    effects = ra.json_array({ CODEX, PUSH, REVIEWING_COMMENT, REVIEWING_LABEL }) },
})

local function sink_probe_fixture(disposition, feedback)
  return {
    disposition = disposition,
    status = "admitted",
    reason = "new-head",
    cas = "applied",
    target = "reviewing",
    source_line = 478,
    codex = "changed",
    feedback = feedback,
    merge_gate = feedback == "merge-gate" and "matching" or nil,
    effects = ra.json_array({ CODEX, PUSH, REVIEWING_COMMENT, REVIEWING_LABEL }),
  }
end

local SINK_PROBES = ra.json_array({
  {
    id = "r9-shadow-fix-reviewing-changes-requested-idempotent",
    current_state = "fixing", from_states = { "reviewing" }, target_state = "fixing",
    version = VERSION, expected_status = "idempotent",
    fixture = sink_probe_fixture("shadow-reviewing-changes-requested", "review-reject"),
    entitlements = {
      [CODEX] = { FIX_DISPATCH_ENTITLEMENT_ID },
      [PUSH] = { FIX_PUBLISH_ENTITLEMENT_ID },
    },
  },
  {
    id = "r9-shadow-fix-review-meta-fix-idempotent",
    current_state = "fixing", from_states = { "review-meta" }, target_state = "fixing",
    version = VERSION, expected_status = "idempotent",
    fixture = sink_probe_fixture("shadow-review-meta-fix", "review-meta"),
    entitlements = {
      [CODEX] = { FIX_DISPATCH_ENTITLEMENT_ID },
      [PUSH] = { FIX_PUBLISH_ENTITLEMENT_ID },
    },
  },
  {
    id = "r9-shadow-fix-pr-open-not-mergeable-idempotent",
    current_state = "fixing", from_states = { "pr-open" }, target_state = "fixing",
    version = VERSION, expected_status = "idempotent",
    fixture = sink_probe_fixture("shadow-pr-open-not-mergeable", "merge-gate"),
    entitlements = {
      [CODEX] = { FIX_DISPATCH_ENTITLEMENT_ID },
      [PUSH] = { FIX_PUBLISH_ENTITLEMENT_ID },
    },
  },
  {
    id = "r9-shadow-fix-merge-ready-code-repair-apply",
    current_state = "merge-ready", from_states = { "merge-ready" }, target_state = "fixing",
    version = VERSION, expected_status = "apply",
    fixture = sink_probe_fixture("shadow-merge-ready-code-repair", "merge-gate"),
    entitlements = {
      [CODEX] = { FIX_DISPATCH_ENTITLEMENT_ID },
      [PUSH] = { FIX_PUBLISH_ENTITLEMENT_ID },
    },
  },
  {
    id = "r9-shadow-fix-merging-merge-needs-fix-apply",
    current_state = "merging", from_states = { "merging" }, target_state = "fixing",
    version = VERSION, expected_status = "apply",
    fixture = sink_probe_fixture("shadow-merging-merge-needs-fix", "merge-gate"),
    entitlements = {
      [CODEX] = { FIX_DISPATCH_ENTITLEMENT_ID },
      [PUSH] = { FIX_PUBLISH_ENTITLEMENT_ID },
    },
  },
})

local function fixing_payload(fixture)
  if fixture.payload then return ra.copy_value(fixture.payload) end
  local base = h.fixing()
  local version = fixture.max_fix_rounds and h.reviewing().version or fixture.event_version or VERSION
  if fixture.max_fix_rounds then
    for _ = 1, config.max_fix_rounds() do
      version = devloop_state.next_fix_version(version)
    end
  end
  local review_proposal_id = base.review_proposal_id
  local review_dedup_key = base.review_dedup_key
  if fixture.max_fix_rounds then
    local review_version = transition_version.safe_version_segment(core._strip_latest_fix_version_suffix(version))
    review_proposal_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, review_version, HEAD_SHA)
    review_dedup_key = devloop_base.pr_review_consensus_dedup_key(review_proposal_id)
  end
  local payload = payloads_builders.build_devloop_fixing_payload({
    proposal_id = PROPOSAL_ID,
    impl_version = version,
  }, PR_NUMBER, {
    review_proposal_id = review_proposal_id,
    review_dedup_key = review_dedup_key,
    reviewed_head_sha = HEAD_SHA,
    blocking_gap = "missing OLD entry observation evidence",
    predecessor_set = (fixture.speculative_refix or fixture.not_in_merge_queue)
      and "recorded-predecessor-set" or nil,
    ci_failure_key = fixture.repair_input == "ci-failure"
      and "head:def456/checks:digest-0000000101" or nil,
  }, entity_lib.pr_source_ref(REPO, PR_NUMBER))
  payload.repair_input = fixture.repair_input
  if fixture.merge_gate then
    payload.gate_baseline_sha = "abc123"
    payload.gate_failure_excerpt = "mergeable-conflicting"
  end
  return payload
end

local function reject_comment(fix)
  return requests_review.build_review_result_comment_request(core, REPO, ISSUE_NUMBER, fix.proposal_id,
    fix.version, { proposal_id = fix.review_proposal_id, decision = "reject",
      body = "Review consensus rejects the diff.", blocking_gap = "missing OLD entry observation evidence",
      dedup_key = fix.review_dedup_key, source_ref = fix.source_ref }, fix.source_ref).body
end

local function capture(fixture)
  h.mock_bot_env()
  local event = { queue = "github-devloop-pr.devloop_fixing", ts = "2026-06-03T02:03:04Z",
    payload = fixing_payload(fixture) }
  local fix = event.payload
  local ports = ra.fake_ports()
  local restorations = {}
  local captured = ra.capture_logging("fix", devloop_logging, restorations)
  local current_state = fixture.current_state or "fixing"
  if fixture.no_state then current_state = nil end
  local current_version = fixture.current_version or fix.version
  local comments = ra.json_array({
    m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), fixture.foreign_branch and BRANCH .. "-other" or BRANCH,
      VERSION, "dev"),
  })
  if current_state then table.insert(comments, core.state_marker(PROPOSAL_ID, current_state, current_version)) end
  if fixture.target_marker then
    table.insert(comments, core.state_marker(PROPOSAL_ID, "reviewing", devloop_state.next_fix_version(fix.version)))
  end
  if fixture.payload == nil and not fixture.no_feedback and not fixture.foreign_proposal then
    if fixture.feedback == "review-meta" then
      table.insert(comments, m_builders.review_meta_marker(
        PROPOSAL_ID, fix.review_dedup_key, "fix", fix.version,
        "missing OLD entry observation evidence"
      ))
    else
      table.insert(comments, reject_comment(fix))
    end
  end
  if fixture.merge_gate then
    local canonical_review = fix.review_proposal_id
    local canonical_dedup = fix.review_dedup_key
    local canonical_head = HEAD_SHA
    if fixture.merge_gate == "mismatch" then
      canonical_review = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, fix.version, NEW_HEAD)
      canonical_dedup = devloop_base.pr_review_consensus_dedup_key(canonical_review)
      canonical_head = NEW_HEAD
    end
    if fixture.merge_gate == "superseded" then
      comments[#comments] = m_builders.merge_gate_marker(PROPOSAL_ID, PR_NUMBER, fix.version,
        fix.review_proposal_id, fix.review_dedup_key, HEAD_SHA, fix.gate_baseline_sha,
        "mergeable-conflicting", fix.predecessor_set, fix.ci_failure_key)
    end
    local canonical_baseline = fixture.merge_gate == "matching" and fix.gate_baseline_sha or "abcdef2"
    local canonical_marker = m_builders.merge_gate_marker(PROPOSAL_ID, PR_NUMBER, fix.version,
      canonical_review, canonical_dedup, canonical_head, canonical_baseline, "mergeable-conflicting",
      fix.predecessor_set, fix.ci_failure_key)
    if fixture.merge_gate == "superseded" then
      table.insert(comments, canonical_marker)
    else
      comments[#comments] = canonical_marker
    end
  end
  if fixture.ci_attempt_visible then
    table.insert(comments, require("core.ci_repair_attempts").marker(fix, "no-fix"))
  end
  local pr_reads = 0
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    pr_reads = pr_reads + 1
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    local head_sha = fixture.head_sha or HEAD_SHA
    if (fixture.codex == "changed" or fixture.codex == "existing-head") and pr_reads >= 4 then
      head_sha = NEW_HEAD
    end
    return { stdout = entity_read_mocks.pr_view_stdout({ repo = REPO, number = PR_NUMBER, comments = comments,
      head = BRANCH, head_sha = head_sha, base_branch = "dev", state = fixture.pr_state or "OPEN",
      head_repo = fixture.head_repo or REPO,
      status_check_rollup_json = fixture.repair_input == "ci-failure"
        and ('[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"'
          .. (fixture.own_ci_cleared and "SUCCESS" or "FAILURE") .. '","headSha":"def456"}]')
        or nil }), stderr = "", exit_code = 0 }
  end
  function ports.github.issue_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "issue_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.issue_view_stdout({ repo = REPO, number = ISSUE_NUMBER,
      comments = comments, assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot" }),
      stderr = "", exit_code = 0 }
  end
  function ports.github.gh_commit_check_runs(repo, head_sha, timeout)
    ra.record_write(ports.github_model, "commit_check_runs", {
      repo = repo, head_sha = head_sha, timeout = timeout,
    })
    return {
      stdout = '{"check_runs":[{"id":101,"name":"test","status":"completed",'
        .. '"conclusion":"' .. (fixture.own_ci_cleared and "success" or "failure")
        .. '","head_sha":"def456"}]}',
      stderr = "",
      exit_code = 0,
    }
  end
  local function git_result(kind, fields, stdout)
    local entry = fields or {}
    entry.kind = kind
    table.insert(ports.git_model.writes, entry)
    return { stdout = stdout or "", stderr = "", exit_code = 0 }
  end
  function ports.git.worktree_list() return git_result("worktree_list", nil,
    "worktree /tmp/fkst-observe/worktree\nbranch refs/heads/" .. BRANCH .. "\n\n") end
  function ports.git.fetch_branch(_, branch) return git_result("fetch_branch", { branch = branch }) end
  function ports.git.remote_branch_head() return git_result("remote_branch_head", nil, "abc123\n") end
  function ports.git.merge_no_edit() return git_result("merge_no_edit") end
  function ports.git.unmerged_paths() return git_result("unmerged_paths") end
  function ports.git.status_porcelain()
    return git_result("status", nil,
      (fixture.codex == "changed" or fixture.codex == "no-new-head") and " M changed.lua\n" or "")
  end
  function ports.git.branch_ahead_count() return git_result("branch_ahead_count", nil,
    fixture.codex == "existing-head" and "1\n" or "0\n") end
  function ports.git.branch_head() return git_result("branch_head", nil, (fixture.branch_head or HEAD_SHA) .. "\n") end
  function ports.git.diff_check_range() return git_result("diff_check_range") end
  function ports.git.diff_check() return git_result("diff_check") end
  function ports.git.add_all() return git_result("add_all") end
  function ports.git.commit_message() return git_result("commit") end
  function ports.git.current_branch_worktree() return git_result("current_branch", nil, BRANCH .. "\n") end
  function ports.git.head_sha()
    return git_result("head_sha", nil, (fixture.codex == "no-new-head" and HEAD_SHA or NEW_HEAD) .. "\n")
  end
  function ports.git.push_ref_update(remote, sha, ref)
    table.insert(captured.effect_sequence, { kind = "adapter", call = { kind = "git.push", remote = remote, sha = sha, ref = ref } })
    return git_result("push_ref_update", { remote = remote, sha = sha, ref = ref })
  end
  ra.replace(config, "branch_config", function() return { integration = "dev", upstream = "dev" } end, restorations)
  ra.replace(config, "write_mode", function() return fixture.dry_run and "dry-run" or "real" end, restorations)
  ra.replace(m_claims, "verify_pr_review_issue_claim", function() return true end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  ra.replace(_G, "exec_sync", function(opts)
    if tostring(opts.cmd):find("FKST_RUNTIME_ROOT", 1, true) then
      return { stdout = "/tmp/fkst-observe", stderr = "", exit_code = 0 }
    end
    return { stdout = "", stderr = "", exit_code = 0 }
  end, restorations)
  ra.replace(context_bundle, "context_fetch_from_bundle", function()
    return { kind = "context-bundle", ref = "entry-fix" }
  end, restorations)
  ra.replace(dispatch_live_run, "dispatch_live_run_dedup", function() return fixture.live_run == true end, restorations)
  if fixture.speculative_refix then
    ra.replace(merge_queue, "merge_queue_predecessors", function()
      return {{
        pr_number = 6,
        proposal_id = "github-devloop/issue/owner/repo/41",
        version = VERSION,
        head_sha = "abc123",
      }}, "ok"
    end, restorations)
  end
  if fixture.not_in_merge_queue then
    ra.replace(merge_queue, "merge_queue_predecessors", function()
      return nil, "not-in-merge-queue"
    end, restorations)
  end
  ra.replace(workflow_codex, "dispatch", function()
    table.insert(captured.effect_sequence, { kind = "adapter", call = { kind = "codex", role = "fix",
      proposal_id = fix.proposal_id, work_unit_key = fix.work_unit_key } })
    if fixture.codex == "deferred" then return { deferred = true, reason = "live-exec-ref" } end
    if fixture.codex == "failed" then return { stdout = "", stderr = "codex failed", exit_code = 1 } end
    return { stdout = "OLD entry fix result", stderr = "", exit_code = 0 }
  end, restorations)
  local department = ra.make_department(fix_module, ports, core)
  local result = fixture.error and testing.run_fake_expecting_failure(department, event)
    or testing.run_fake(department, event)
  ra.restore_all(restorations)
  if fixture.error then
    t.is_true(tostring(result.failure.error):find(fixture.error, 1, true) ~= nil,
      fixture.disposition .. ": exact fail-closed error")
  elseif fixture.dry_run or fixture.codex == "deferred" or fixture.codex == "failed" or fixture.codex == "no-fix" or fixture.codex == "no-new-head"
      or fixture.codex == "changed" or fixture.codex == "existing-head" then
    -- These dispositions are defined by the dispatch/apply branch; their exact effects make the route observable.
  else
    local selected = nil
    for _, decision in ipairs(captured.decisions) do
      if decision.outcome == fixture.cas then selected = decision break end
    end
    t.is_true(selected ~= nil, fixture.disposition .. ": observable entry disposition " .. ra.canonical_json(captured.decisions))
  end
  if fixture.dry_run then fixture.cas = "dry-run(write-disabled)" end
  if fixture.codex == "deferred" then fixture.cas = "admitted(dispatch-deferred)" end
  if fixture.repair_input == "ci-failure" and fixture.codex == "no-fix"
      and fixture.merge_gate ~= "base-skewed-ci" then
    fixture.cas = "admitted(ci-repair-attempt)"
  end
  fixture.current_state = current_state
  fixture.current_version = current_state and current_version or nil
  fixture.current_fact = { state = ra.nullable(current_state), version = ra.nullable(fixture.current_version),
    pr_state = fixture.pr_state or "OPEN", head_sha = fixture.head_sha or HEAD_SHA,
    repair_input = ra.nullable(fixture.repair_input) }
  fixture.effect_version = captured.applies[#captured.applies] and captured.applies[#captured.applies].version or nil
  fixture.issue_number = ISSUE_NUMBER
  return ra.record({ dept = "fix", fixture = fixture, result = result, captured = captured,
    event = event, prefix = PREFIX, site = SITE, source_state = "fixing", boundary = "entry_acceptor" })
end

return {
  test_fix_entry_acceptor_old_behavior_is_real_dispatch_and_bidirectional = function()
    local shadow_sink_records = ra.capture_shadow_sink_probes(t, {
      probes = SINK_PROBES,
      capture = capture,
      devloop_state = devloop_state,
    })
    ra.assert_site(t, { dept = "fix", fixtures = FIXTURES, capture = capture,
      prefix = PREFIX, site = SITE, boundary = "entry_acceptor",
      shadow_corpus_path = "migration/intent_bounded_replay/corpus/pr-fix.json",
      shadow_sink_records = shadow_sink_records })
  end,
}
