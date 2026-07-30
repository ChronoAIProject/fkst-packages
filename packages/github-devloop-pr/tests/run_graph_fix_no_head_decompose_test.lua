local devloop_base = require("devloop.base")
local payloads_builders = require("devloop.payloads.builders")
local requests_review = require("devloop.requests.review")
local config = require("devloop.config")
local m_builders = require("devloop.markers.builders")
local conv_reconcile = require("devloop.convergence.reconcile")
local decompose_lib = require("devloop.decompose")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local author_policy = require("testkit.github_author_policy")
local h = require("tests.devloop_helpers")

local t = h.t
local core = h.core
local pr_source_ref = { kind = "external", ref = "owner/repo#pr/7" }

local function fix_version(round)
  local version = h.reviewing().version
  for _ = 1, round do
    version = h.next_fix_version(version)
  end
  return version
end

local function fixing_event(version, review_proposal_id, review_dedup_key)
  return payloads_builders.build_devloop_fixing_payload({
    proposal_id = "github-devloop/issue/owner/repo/42",
    impl_version = version,
  }, 7, {
    review_proposal_id = review_proposal_id,
    review_dedup_key = review_dedup_key,
    reviewed_head_sha = "def456",
    blocking_gap = "missing regression guard",
  }, pr_source_ref)
end

local function rejected_fixing_event(version)
  local review_version = require("contract.transition_version").safe_version_segment(
    core._strip_latest_fix_version_suffix(version)
  )
  local review_proposal_id = devloop_base.pr_review_proposal_id(
    "owner/repo",
    7,
    review_version,
    "def456"
  )
  return fixing_event(
    version,
    review_proposal_id,
    devloop_base.pr_review_consensus_dedup_key(review_proposal_id)
  )
end

local function reject_comment(event)
  return requests_review.build_review_result_comment_request(core,
    "owner/repo",
    "42",
    event.proposal_id,
    event.version,
    {
      proposal_id = event.review_proposal_id,
      decision = "reject",
      body = "Review consensus rejects the diff.",
      blocking_gap = "missing regression guard",
      dedup_key = event.review_dedup_key,
      source_ref = pr_source_ref,
    },
    pr_source_ref
  ).body
end

local function run_no_new_head(event, feedback_comment, id, post_state)
  local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
  local origin_marker = m_builders.pr_origin_marker(
    event.proposal_id,
    "42",
    branch,
    event.version,
    "dev"
  )
  local comments = {
    core.state_marker(event.proposal_id, "fixing", event.version),
    feedback_comment,
  }

  h.mock_bot_env()
  for _ = 1, 3 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
  end
  h.mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, comments, branch, event.version)
  h.mock_pr_fix({ origin_marker }, branch, "def456")
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
    stderr = "",
    exit_code = 0,
  })
  h.mock_existing_fix_worktree(branch, "def456")
  h.mock_implement_codex(0, "Completed without publishing a new head.")
  h.mock_git_status(" M packages/github-devloop-pr/departments/fix/main.lua\n")
  h.mock_git_commit("def456", branch)
  local post_comments = comments
  if post_state ~= nil then
    post_comments = {
      core.state_marker(event.proposal_id, post_state.state, post_state.version),
      feedback_comment,
    }
  end
  local post_pr_comments = { origin_marker }
  for _, comment in ipairs(post_comments) do
    table.insert(post_pr_comments, comment)
  end
  entity_read_mocks.mock_pr_view_selector(t, {
    comments = post_pr_comments,
    head = branch,
    head_sha = "def456",
    state = "OPEN",
    head_repo = "owner/repo",
    cross_repo = false,
  }, entity_read_mocks.pr_fix_selector, 1)

  return h.run_fix(event, h.opts(id, { FKST_GITHUB_WRITE = "1" }))
end

local function run_successful_fix_at_cap(event, feedback_comment)
  local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
  local origin_marker = m_builders.pr_origin_marker(
    event.proposal_id,
    "42",
    branch,
    event.version,
    "dev"
  )
  local fixing_comments = {
    core.state_marker(event.proposal_id, "fixing", event.version),
    feedback_comment,
  }

  h.mock_bot_env()
  h.mock_write_env("1")
  h.mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, fixing_comments, branch, event.version)
  h.mock_pr_fix({ origin_marker }, branch, "def456")
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
    stderr = "",
    exit_code = 0,
  })
  h.mock_existing_fix_worktree(branch, "def456")
  h.mock_implement_codex(0, "fixed review feedback at the final allowed round")
  h.mock_git_status(" M packages/github-devloop-pr/departments/fix/main.lua\n")
  h.mock_git_commit("feedface", branch)
  h.mock_write_env("1")
  h.mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, fixing_comments, branch, event.version)
  local post_codex_comments = { origin_marker }
  for _, comment in ipairs(fixing_comments) do
    table.insert(post_codex_comments, comment)
  end
  entity_read_mocks.mock_pr_view_selector(t, {
    comments = post_codex_comments,
    head = branch,
    head_sha = "def456",
    state = "OPEN",
    head_repo = "owner/repo",
    cross_repo = false,
  }, entity_read_mocks.pr_fix_selector, 1)
  h.mock_git_push(branch)
  entity_read_mocks.mock_pr_view_selector(t, {
    comments = post_codex_comments,
    head = branch,
    head_sha = "feedface",
    state = "OPEN",
    head_repo = "owner/repo",
    cross_repo = false,
  }, entity_read_mocks.pr_fix_selector, 1)

  return h.run_fix(event, h.opts("successful-fix-at-cap", { FKST_GITHUB_WRITE = "1" }))
end

local function decompose_pr_comments(event, blocked_comment, extra)
  local comments = {
    m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev"),
    blocked_comment,
  }
  for _, comment in ipairs(extra or {}) do
    table.insert(comments, comment)
  end
  return comments
end

local function mock_decompose_pr(event, comments)
  entity_read_mocks.mock_pr_view_selector(t, {
    comments = comments,
    head = "devloop-owner-repo-42-01HY",
    head_sha = event.head_sha,
    base_branch = "dev",
    state = "OPEN",
    updated_at = "2026-06-03T02:03:04Z",
  }, entity_read_mocks.pr_fix_precheck_selector, 1)
end

local function mock_decompose_environment()
  author_policy.mock_env(t, {
    env = {
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = "ElonSG",
      FKST_GITHUB_AUTHORIZED_LOGINS = "authorized-human",
    },
  }, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
    times = 8,
  })
  for _ = 1, 6 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 2 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_decompose_execution(event, blocked_comment)
  local blocked_comments = decompose_pr_comments(event, blocked_comment)
  local decomposed_comments = decompose_pr_comments(event, blocked_comment, {
    decompose_lib.decomposed_marker(event.proposal_id, event.version, event.pr_number, 2),
  })

  h.mock_default_issue_claim("owner/repo", 42)
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = "owner/repo",
    number = 42,
    title = "Original large issue",
    body = "Original body.",
    labels = { "fkst-dev:blocked" },
    comments = { blocked_comment },
    state = "OPEN",
    updated_at = "2026-06-03T01:02:03Z",
  }, "title,body,labels,comments,author", 1)
  mock_decompose_pr(event, blocked_comments)
  mock_decompose_pr(event, blocked_comments)
  mock_decompose_pr(event, blocked_comments)
  mock_decompose_pr(event, decomposed_comments)
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop-decompose-e2e/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 3 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("mktemp -d", {
    stdout = "/tmp/fkst-packages-test/github-devloop-decompose-e2e/context/.bundle-tmp.decompose\n",
    stderr = "",
    exit_code = 0,
  })
  entity_read_mocks.mock_issue_view_raw_selector(t, {}, "title,body,updatedAt,labels,comments,state,author", {
    stdout = '{"title":"Original large issue","body":"Original body.","updatedAt":"2026-06-03T01:02:03Z","state":"OPEN","labels":[{"name":"fkst-dev:blocked"}],"comments":[],"author":{"login":"fkst-test-bot"}}\n',
  })
  entity_read_mocks.mock_pr_view_raw_selector(t, {}, "title,body,headRefName,headRefOid,baseRefName,state,updatedAt,comments,labels,author", {
    stdout = '{"title":"PR title","body":"PR body","headRefName":"devloop-owner-repo-42-01HY","headRefOid":"def456","baseRefName":"dev","state":"OPEN","updatedAt":"2026-06-03T02:03:04Z","comments":[],"labels":[],"author":{"login":"fkst-test-bot"}}\n',
  })
  t.mock_command("gh pr diff", {
    stdout = "diff --git a/file.lua b/file.lua\n+return true\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr diff '7' --repo 'owner/repo' --name-only", {
    stdout = "file.lua\n",
    stderr = "",
    exit_code = 0,
  })
  entity_read_mocks.mock_issue_board_digest_list(t, "owner/repo", {})
  entity_read_mocks.mock_issue_list_command(t, core.gh_issue_list_recent_closed_cmd("owner/repo", 30), {})
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  for _ = 1, 12 do
    t.mock_command("touch ", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("printf %s '", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command(" > ", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("test -r", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("wc -c < ", { stdout = "1\n", stderr = "", exit_code = 0 })
  end
  for _ = 1, 3 do
    t.mock_command("test -e", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command("python3 -c", { stdout = "", stderr = "", exit_code = 0 })
  end
  t.mock_command(core.gh_issue_list_decompose_children_cmd("owner/repo", event.proposal_id), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr comment", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", {
    stdout = [[{"issues":[{"title":"Extract a minimal retry helper","body":"Smaller scope: implement only the retry helper.\nNon-goals: do not change the whole workflow.\nAcceptance: helper tests pass."},{"title":"Wire retry helper into one call site","body":"Smaller scope: apply the helper to one path.\nNon-goals: do not rewrite unrelated states.\nAcceptance: focused integration test passes."}]}]],
    stderr = "",
    exit_code = 0,
  })
end

local function run_fix_reconcile_exact(event, source_state)
  h.mock_default_issue_claim("owner/repo", 42)
  local view = {
    comments = {
      m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.issue_version, "dev"),
      core.state_marker(event.proposal_id, source_state or "fixing", event.issue_version),
    },
    head = "devloop-owner-repo-42-01HY",
    head_sha = event.head_sha,
    base_branch = "dev",
    state = "OPEN",
    head_repo = "owner/repo",
    cross_repo = false,
    updated_at = "2026-06-03T02:03:04Z",
  }
  entity_read_mocks.mock_pr_view_selector(t, view, entity_read_mocks.pr_fix_precheck_selector, 1)
  return h.run_department("departments/reconcile/main.lua", {
    queue = "devloop_fix_reconcile",
    payload = event,
  }, h.opts("no-new-head-e2e-reconcile"))
end

local function max_fix_round_merge_ready()
  local version = h.reviewing().version
  for _ = 1, config.max_fix_rounds() do
    version = h.next_fix_version(version)
  end
  local review_proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, version, "def456")
  return h.merge_ready({
    version = version,
    review_proposal_id = review_proposal_id,
    review_dedup_key = devloop_base.pr_review_consensus_dedup_key(review_proposal_id),
  })
end

local function entity_changed_event()
  return {
    queue = "github-devloop-pr.devloop_observe_pr",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = "owner/repo",
      number = 7,
      state = "OPEN",
      updated_at = "2026-06-03T02:03:04Z",
      dedup_key = "owner/repo#pr#7@2026-06-03T02:03:04Z",
      source_ref = pr_source_ref,
    },
    source_ref = {
      kind = "external",
      reference = "owner/repo#pr/7",
    },
  }
end

local function mock_merging_restart_at_cap(event)
  local comments = h.merge_comments_with_merging(event)
  h.mock_bot_env()
  t.mock_command(core.gh_issue_view_claim_cmd("owner/repo", 42), {
    stdout = '{"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(core.gh_issue_view_result_cmd("owner/repo", 42), {
    stdout = '{"labels":[{"name":"fkst-dev:merging"}],"comments":[]}\n',
    stderr = "",
    exit_code = 0,
  })
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = "owner/repo",
    number = 7,
    comments = comments,
    head = "devloop-owner-repo-42-01HY",
    head_sha = event.reviewed_head_sha,
    base_branch = "dev",
    base_sha = "abc123",
    state = "OPEN",
    head_repo = "owner/repo",
    cross_repo = false,
    labels = { "fkst-dev:merging" },
    mergeable = "CONFLICTING",
    merge_state = "DIRTY",
  }, entity_read_mocks.pr_origin_selector, 1)
  h.mock_default_issue_claim("owner/repo", 42)
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = "owner/repo",
    number = 7,
    comments = comments,
    head = "devloop-owner-repo-42-01HY",
    head_sha = "feedface",
    base_branch = "dev",
    state = "OPEN",
    head_repo = "owner/repo",
    cross_repo = false,
  }, entity_read_mocks.pr_fix_precheck_selector, 1)
end

local function run_merge_ci_failure_at_cap(event)
  local origin = m_builders.pr_origin_marker(
    event.proposal_id,
    "42",
    "devloop-owner-repo-42-01HY",
    event.version,
    "dev"
  )
  local rollup = '[{"__typename":"CheckRun","completedAt":"2026-06-03T02:04:04Z","conclusion":"FAILURE","detailsUrl":"https://example.invalid/checks/test","name":"test","startedAt":"2026-06-03T02:03:04Z","status":"COMPLETED","workflowName":"test"}]'
  h.mock_bot_env()
  h.mock_write_env("1")
  h.mock_write_env("1")
  h.mock_issue_merge({ "fkst-dev:merge-ready" }, h.merge_comments(event))
  h.mock_pr_merge_rollup(
    { origin },
    rollup,
    "devloop-owner-repo-42-01HY",
    "def456",
    "OPEN",
    "owner/repo",
    false,
    "MERGEABLE",
    "UNSTABLE"
  )
  t.mock_command("gh api 'repos/owner/repo/commits/def456/check-runs'", {
    stdout = '{"total_count":1,"check_runs":[{"id":101,"name":"test","status":"completed","conclusion":"failure","head_sha":"def456"}]}\n',
    stderr = "",
    exit_code = 0,
  })
  return h.run_merge(event, h.opts("merge-ci-failure-at-fix-cap", { FKST_GITHUB_WRITE = "1" }))
end

local function find_raise(result, queue)
  return h.find_raise(result.raises, queue)
    or (queue:find(".", 1, true) == nil and h.find_raise(result.raises, "github-devloop-pr." .. queue) or nil)
end

local function require_raise(result, queue, context)
  local raised = find_raise(result, queue)
  if raised ~= nil then
    return raised
  end
  local calls = {}
  for _, call in ipairs(t.command_calls()) do
    table.insert(calls, tostring(call.rendered))
  end
  error(tostring(context) .. " missing raise " .. tostring(queue)
    .. "; exit_code=" .. tostring(result.exit_code)
    .. " error=" .. tostring(result.error)
    .. " calls=" .. table.concat(calls, " | "))
end

return {
  test_restart_replay_merging_at_fix_cap_escalates_without_minting_fix = function()
    local event = max_fix_round_merge_ready()
    mock_merging_restart_at_cap(event)

    local trace = graph.require_quiescent(graph.run(entity_changed_event(), { max_steps = 3 }))
    graph.assert_covers(trace, {
      "github-devloop-pr.devloop_observe_pr -> github-devloop-pr.observe_pr",
      "github-devloop-pr.devloop_fix_reconcile -> github-devloop-pr.reconcile",
    })
    local step = graph.require_delivery(trace, {
      queue = "github-devloop-pr.devloop_observe_pr",
      consumer = "github-devloop-pr.observe_pr",
    })
    t.eq(step.exit_code, 0)
    t.eq(find_raise(step, "devloop_fixing"), nil)
    t.eq(find_raise(step, "github-proxy.github_pr_comment_request"), nil)
    local reconcile = require_raise(step, "devloop_fix_reconcile", "merging restart at cap").payload
    t.eq(reconcile.issue_version, event.version)
    t.eq(reconcile.round, config.max_fix_rounds())
    t.eq(reconcile.head_sha, event.reviewed_head_sha)
  end,

  test_no_new_head_attempt_advances_fix_round_below_cap = function()
    local below_cap = rejected_fixing_event(fix_version(config.max_fix_rounds() - 1))
    local first = run_no_new_head(below_cap, reject_comment(below_cap), "no-new-head-below-cap")

    t.eq(first.exit_code, 0)
    local advanced = require_raise(first, "devloop_review_meta", "below-cap fix").payload
    t.eq(advanced.version, h.next_fix_version(below_cap.version))
    t.eq(core.version_fix_round(advanced.version), config.max_fix_rounds())
    t.eq(advanced.review_dedup_key, below_cap.review_dedup_key)
    t.is_true(advanced.dedup_key ~= below_cap.dedup_key)
    t.eq(find_raise(first, "github-devloop-decompose.devloop_decompose"), nil)
  end,

  test_no_new_head_attempt_at_max_fix_rounds_decomposes = function()
    local below_cap = rejected_fixing_event(fix_version(config.max_fix_rounds() - 1))
    local first = run_no_new_head(below_cap, reject_comment(below_cap), "no-new-head-e2e-below-cap")
    if first.exit_code ~= 0 then
      error("below-cap fix failed: " .. tostring(first.error))
    end
    local advanced = require_raise(first, "devloop_review_meta", "e2e below-cap fix").payload
    local at_cap = rejected_fixing_event(advanced.version)
    t.eq(core.version_fix_round(at_cap.version), config.max_fix_rounds())
    local capped = run_no_new_head(at_cap, reject_comment(at_cap), "no-new-head-at-cap")

    if capped.exit_code ~= 0 then
      error("at-cap fix failed: " .. tostring(capped.error))
    end
    t.eq(find_raise(capped, "devloop_review_meta"), nil)
    local reconcile_raise = find_raise(capped, "devloop_fix_reconcile")
    if reconcile_raise == nil then
      local queues = {}
      for _, raised in ipairs(capped.raises) do
        table.insert(queues, tostring(raised.queue))
      end
      error("at-cap fix did not raise reconcile; raises=" .. table.concat(queues, ","))
    end
    local reconcile = reconcile_raise.payload
    t.eq(h.find_raise(capped.raises, "github-devloop-decompose.devloop_decompose"), nil)
    t.eq(reconcile.issue_version, at_cap.version)
    t.eq(reconcile.round, config.max_fix_rounds())
    t.eq(reconcile.review_dedup_key, at_cap.review_dedup_key)

    local reconciled = run_fix_reconcile_exact(reconcile)
    if reconciled.exit_code ~= 0 then
      error("fix reconcile failed: " .. tostring(reconciled.error))
    end
    local blocked_request = find_raise(reconciled, "github-proxy.github_pr_comment_request").payload
    local blocked_comment = blocked_request.body
    t.is_true(blocked_comment:find(core.state_marker(reconcile.proposal_id, "blocked", reconcile.issue_version), 1, true) ~= nil)
    t.is_true(blocked_comment:find(conv_reconcile.fix_reconcile_marker(reconcile.proposal_id, reconcile.issue_version, "drop"), 1, true) ~= nil)
    local handed_off = h.run_comment_handoff_from_request(
      blocked_request,
      "IC_no_new_head_fix_reconcile_1",
      "no-new-head-fix-reconcile-decompose-handoff"
    )
    t.eq(handed_off.exit_code, 0)
    local decompose = require_raise(
      handed_off,
      "github-devloop-decompose.devloop_decompose",
      "no-new-head handoff"
    ).payload
    t.eq(decompose.version, reconcile.issue_version)
    t.eq(decompose.round, reconcile.round)
    t.eq(decompose.review_dedup_key, reconcile.review_dedup_key)

    mock_decompose_environment()
    mock_decompose_execution(decompose, blocked_comment)
    local trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-decompose.devloop_decompose",
      payload = decompose,
      source_ref = { kind = "external", reference = "owner/repo#pr/7" },
    }, { max_steps = 3 }))
    graph.assert_covers(trace, {
      "github-devloop-decompose.devloop_decompose -> github-devloop-decompose.decompose",
      "github-proxy.github_issue_create_request -> github-proxy.github_issue_create",
    })
    local child_deliveries = 0
    for _, delivery in ipairs(trace.steps) do
      if delivery.queue == "github-proxy.github_issue_create_request"
        and delivery.consumer == "github-proxy.github_issue_create" then
        child_deliveries = child_deliveries + 1
      end
    end
    t.eq(child_deliveries, 2)
    local step = graph.require_delivery(trace, {
      queue = "github-devloop-decompose.devloop_decompose",
      consumer = "github-devloop-decompose.decompose",
    })
    if step.exit_code ~= 0 then
      error("decompose delivery failed: " .. tostring(step.error))
    end
    t.eq(#step.raises, 2)
    t.eq(step.raises[1].queue, "github-proxy.github_issue_create_request")
    t.eq(step.raises[2].queue, "github-proxy.github_issue_create_request")
    t.eq(step.raises[1].payload.title, "Extract a minimal retry helper")
    t.eq(step.raises[2].payload.title, "Wire retry helper into one call site")
  end,

  test_successful_fix_at_cap_reconciles_and_decomposes_the_pushed_head = function()
    local at_cap = rejected_fixing_event(fix_version(config.max_fix_rounds()))
    local fixed = run_successful_fix_at_cap(at_cap, reject_comment(at_cap))

    t.eq(fixed.exit_code, 0)
    t.eq(find_raise(fixed, "devloop_reviewing"), nil)
    local reconcile = require_raise(fixed, "devloop_fix_reconcile", "successful fix at cap").payload
    t.eq(reconcile.issue_version, at_cap.version)
    t.eq(reconcile.round, config.max_fix_rounds())
    t.eq(reconcile.head_sha, "feedface")

    local reconciled = run_fix_reconcile_exact(reconcile, "fixing")
    t.eq(reconciled.exit_code, 0)
    local blocked_request = require_raise(
      reconciled,
      "github-proxy.github_pr_comment_request",
      "successful fix reconcile"
    ).payload
    t.eq(blocked_request.handoff.kind, "github-devloop.fix_reconcile")
    t.eq(blocked_request.handoff.fix_reconcile.head_sha, "feedface")

    local handed_off = h.run_comment_handoff_from_request(
      blocked_request,
      "IC_successful_fix_at_cap_reconcile_1",
      "successful-fix-at-cap-decompose-handoff"
    )
    t.eq(handed_off.exit_code, 0)
    local decompose = require_raise(
      handed_off,
      "github-devloop-decompose.devloop_decompose",
      "successful fix at cap handoff"
    ).payload
    t.eq(decompose.head_sha, "feedface")
    t.eq(decompose.version, at_cap.version)

    mock_decompose_environment()
    mock_decompose_execution(decompose, blocked_request.body)
    local trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-decompose.devloop_decompose",
      payload = decompose,
      source_ref = { kind = "external", reference = "owner/repo#pr/7" },
    }, { max_steps = 3 }))
    graph.assert_covers(trace, {
      "github-devloop-decompose.devloop_decompose -> github-devloop-decompose.decompose",
      "github-proxy.github_issue_create_request -> github-proxy.github_issue_create",
    })
    local child_deliveries = 0
    for _, delivery in ipairs(trace.steps) do
      if delivery.queue == "github-proxy.github_issue_create_request"
        and delivery.consumer == "github-proxy.github_issue_create" then
        child_deliveries = child_deliveries + 1
      end
    end
    t.eq(child_deliveries, 2)
  end,

  test_merge_ci_failure_at_fix_cap_reconciles_before_decompose_children = function()
    local merge_ready = max_fix_round_merge_ready()
    local merge_result = run_merge_ci_failure_at_cap(merge_ready)
    t.eq(merge_result.exit_code, 0)
    t.eq(find_raise(merge_result, "devloop_fixing"), nil)
    t.eq(find_raise(merge_result, "github-devloop-decompose.devloop_decompose"), nil)
    local reconcile = require_raise(merge_result, "devloop_fix_reconcile", "merge-origin cap").payload
    local reconciled = run_fix_reconcile_exact(reconcile, "merge-ready")
    t.eq(reconciled.exit_code, 0)
    local blocked_request = require_raise(
      reconciled,
      "github-proxy.github_pr_comment_request",
      "merge-origin reconcile"
    ).payload
    t.eq(blocked_request.handoff.kind, "github-devloop.fix_reconcile")
    local handed_off = h.run_comment_handoff_from_request(
      blocked_request,
      "IC_merge_fix_reconcile_1",
      "merge-fix-reconcile-decompose-handoff"
    )
    t.eq(handed_off.exit_code, 0)
    local decompose = require_raise(
      handed_off,
      "github-devloop-decompose.devloop_decompose",
      "merge-origin handoff"
    ).payload
    t.eq(decompose.version, merge_ready.version)
    t.eq(decompose.review_dedup_key, merge_ready.review_dedup_key)
    t.eq(decompose.head_sha, merge_ready.reviewed_head_sha)

    mock_decompose_environment()
    mock_decompose_execution(decompose, blocked_request.body)
    local trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-decompose.devloop_decompose",
      payload = decompose,
      source_ref = { kind = "external", reference = "owner/repo#pr/7" },
    }, { max_steps = 3 }))
    graph.assert_covers(trace, {
      "github-devloop-decompose.devloop_decompose -> github-devloop-decompose.decompose",
      "github-proxy.github_issue_create_request -> github-proxy.github_issue_create",
    })
    local child_deliveries = 0
    for _, delivery in ipairs(trace.steps) do
      if delivery.queue == "github-proxy.github_issue_create_request"
        and delivery.consumer == "github-proxy.github_issue_create" then
        child_deliveries = child_deliveries + 1
      end
    end
    t.eq(child_deliveries, 2)
  end,

  test_no_new_head_drops_outcome_when_post_codex_state_is_stale = function()
    local event = rejected_fixing_event(fix_version(1))
    local result = run_no_new_head(event, reject_comment(event), "no-new-head-post-codex-stale", {
      state = "reviewing",
      version = h.next_fix_version(event.version),
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
