local M = {}

local transition_version = require("contract.transition_version")
local gh_argv = require("testkit_internal.gh_argv_mock")
local testing = require("testkit_internal.testing")
local run_fake = testing.run_fake
local run_fake_expecting_failure = testing.run_fake_expecting_failure
local run_fake_outcome = testing.run_fake_outcome
local gh_fake = require("forge.github_fake")
local git_fake = require("forge.git_fake")
local mocks_factory = require("testkit_internal.devloop_fixtures.mocks")
local author_policy = require("testkit_internal.github_author_policy")

local function nonce()
  return tostring({}):gsub("[^%w._-]", "_")
end

local function has_value(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then
      return true
    end
  end
  return false
end

function M.new(deps)
  deps = deps or {}
  local t = deps.t or fkst.test
  local core = deps.core or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.core is required")
  local entity_read_mocks = deps.entity_read_mocks
    or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.entity_read_mocks is required")
  local devloop_base = deps.devloop_base or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.devloop_base is required")
  local parsers_misc = deps.parsers_misc
    or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.parsers_misc is required")
  local payloads_builders = deps.payloads_builders
    or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.payloads_builders is required")
  local conv_reconcile = deps.conv_reconcile
    or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.conv_reconcile is required")
  local m_builders = deps.m_builders or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.m_builders is required")
  local pr_safety = deps.pr_safety or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.pr_safety is required")
  local consensus_call = deps.consensus_call
    or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.consensus_call is required")
  local consensus_result_department = deps.consensus_result_department
  local loop_department = deps.loop_department
  local review_loop_department = deps.review_loop_department
  local review_result_department = deps.review_result_department
  local claim_label_spec = deps.claim_label_spec
    or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.claim_label_spec is required")
  local claim_label_is_family = deps.claim_label_is_family
    or error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.claim_label_is_family is required")
  local decompose_queue = deps.decompose_queue or "devloop_decompose"
  local runtime_package_name = deps.runtime_package_name or "github-devloop"
  local mock_merge_pr_diff_name_only = deps.mock_merge_pr_diff_name_only == true

  gh_argv.install(t, core)
  parsers_misc.configure_trusted_bot_login("fkst-test-bot")

  local ctx = {
    t = t,
    core = core,
    entity_read_mocks = entity_read_mocks,
    m_builders = m_builders,
    pr_safety = pr_safety,
    has_value = has_value, projected_state_comment = deps.projected_state_comment,
    default_pr_origin_times = deps.default_pr_origin_times,
    pr_origin_view_times_enabled = deps.pr_origin_view_times_enabled == true,
    pending_result_issue = nil,
    pending_result_read_failure = nil,
    pr_phase_comments = nil,
    pending_pr_origin = nil,
    next_consensus_result = nil,
    last_consensus_proposal = nil,
  }

  local function default_converge_result(proposal)
    return {
      status = "converge",
      schema = "consensus.consensus_converge.v1",
      proposal_id = proposal.proposal_id,
      dedup_key = "consensus:" .. tostring(proposal.dedup_key),
      source_ref = proposal.source_ref,
      round = tonumber(proposal.round) or 0,
      narrowed_question = "Resolve the remaining review disagreement.",
      angle_digests = {},
      effect_version = proposal.effect_version,
    }
  end

  local function mock_next_consensus_result(result)
    ctx.next_consensus_result = result
  end

  local function take_consensus_proposal()
    local proposal = ctx.last_consensus_proposal
    ctx.last_consensus_proposal = nil
    return proposal
  end

  local function with_consensus_call_mock(fn)
    ctx.last_consensus_proposal = nil
    local original_reach = consensus_call.reach
    consensus_call.reach = function(proposal)
      ctx.last_consensus_proposal = proposal
      local configured = ctx.next_consensus_result
      ctx.next_consensus_result = nil
      local result
      if type(configured) == "function" then
        result = configured(proposal)
      elseif configured ~= nil then
        result = configured
      else
        result = default_converge_result(proposal)
      end
      local caller_result = {}
      for key, value in pairs(result) do
        caller_result[key] = value
      end
      caller_result.proposal_id = proposal.proposal_id
      return caller_result
    end
    local ok, result = pcall(fn)
    consensus_call.reach = original_reach
    if not ok then
      error(result, 0)
    end
    return result
  end

  local function runtime_root(name)
    return "/tmp/fkst-packages-test/" .. runtime_package_name .. "/" .. tostring(now()) .. "/" .. nonce() .. "/" .. name
  end

  local function opts(name, extra)
    local root = runtime_root(name)
    local result = {
      env = {
        FKST_RUNTIME_ROOT = root,
        FKST_RUNTIME_LOG_DIR = root .. "/logs",
        FKST_CANDIDATE_PREFIX = "candidate",
        FKST_CANDIDATE_FROM_SEP = "-from-",
        FKST_DEVLOOP_UPSTREAM_BRANCH = "dev",
        FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
      },
    }
    for key, value in pairs((extra and extra.env) or extra or {}) do
      result.env[key] = value
    end
    return result
  end

  local function source_ref()
    return {
      kind = "external",
      ref = "owner/repo#issue/42",
    }
  end

  local function pr_source_ref()
    return {
      kind = "external",
      ref = "owner/repo#pr/7",
    }
  end

  local function issue(extra)
    local value = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = 42,
      title = "Implement decision recorder",
      url = "https://github.example/owner/repo/issues/42",
      state = "OPEN",
      updated_at = "2026-06-03T01:02:03Z",
      labels = { "fkst-dev:enabled" },
      dedup_key = "owner/repo#issue#42@2026-06-03T01:02:03Z",
      source_ref = source_ref(),
    }
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    if value.decision == "reject" and value.blocking_gap == nil then value.blocking_gap = "missing regression guard" end
    return value
  end

  local function reached(extra)
    local value = {
      schema = "consensus.consensus_reached.v1",
      proposal_id = "github-devloop/issue/owner/repo/42",
      decision = "approve",
      body = "All angles approve.",
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
      source_ref = source_ref(),
    }
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function unresolved(extra)
    local value = {
      schema = "consensus.consensus_converge.v1",
      proposal_id = "github-devloop/issue/owner/repo/42",
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
      source_ref = source_ref(),
    }
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function reconcile(extra)
    local value = conv_reconcile.build_devloop_reconcile_payload(unresolved({
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/3",
    }), 3, "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z", "no-semantic-progress")
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function ready(extra)
    local value = {
      schema = "github-devloop.ready.v1",
      proposal_id = "github-devloop/issue/owner/repo/42",
      dedup_key = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
      source_ref = source_ref(),
    }
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function reviewing(extra)
    local value = {
      schema = "github-devloop.reviewing.v1",
      proposal_id = "github-devloop/issue/owner/repo/42",
      pr_number = 7,
      version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
      dedup_key = "reviewing/github-devloop/issue/owner/repo/42/ready-consensus-github-devloop-issue-owner-repo-42-2026-06-03T01-02-03Z/7",
      source_ref = pr_source_ref(),
    }
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function review_reached(extra)
    local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, version, "def456")
    local value = {
      schema = "consensus.consensus_reached.v1",
      proposal_id = proposal_id,
      decision = "approve",
      body = "Review consensus approves the diff.",
      dedup_key = "consensus:" .. proposal_id .. "/review",
      source_ref = {
        kind = "external",
        ref = "owner/repo#pr/7",
      },
    }
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function review_unresolved(extra)
    local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, version, "def456")
    local value = {
      schema = "consensus.consensus_converge.v1",
      proposal_id = proposal_id,
      dedup_key = "consensus:" .. proposal_id .. "/review",
      source_ref = {
        kind = "external",
        ref = "owner/repo#pr/7",
      },
    }
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function fixing(extra)
    local event = review_reached({ decision = "reject", body = "Review consensus rejects the diff." })
    local review_version = reviewing().version
    local value = payloads_builders.build_devloop_fixing_payload({
      proposal_id = "github-devloop/issue/owner/repo/42",
      impl_version = core.fix_version_from_review_version(review_version),
    }, 7, {
      review_proposal_id = event.proposal_id,
      review_dedup_key = event.dedup_key,
      reviewed_head_sha = "def456",
      blocking_gap = "missing regression guard",
    }, pr_source_ref())
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function pr_link_marker_for_fix(fix, branch, impl_version)
    return m_builders.pr_link_marker(fix.proposal_id, fix.pr_number, branch, impl_version or fix.version, "dev")
  end

  local function review_meta_event(extra)
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, reviewing().version, "def456")
    local unresolved_event = review_unresolved({
      dedup_key = transition_version.review_loop_at("consensus:" .. proposal_id .. "/review", 2),
    })
    local value = payloads_builders.build_devloop_review_meta_payload(unresolved_event, "github-devloop/issue/owner/repo/42", reviewing().version, 7, 3)
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function review_reconcile(extra)
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, reviewing().version, "def456")
    local event = review_unresolved({
      dedup_key = transition_version.review_loop_at("consensus:" .. proposal_id .. "/review", 3),
      round = 3,
    })
    local value = conv_reconcile.build_devloop_review_reconcile_payload(event, 3, "github-devloop/issue/owner/repo/42", reviewing().version, "def456", "no-semantic-progress")
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function fix_reconcile(extra)
    local issue_version = core.next_fix_version(core.next_fix_version(core.next_fix_version(reviewing().version)))
    local value = conv_reconcile.build_devloop_fix_reconcile_payload({
      proposal_id = "github-devloop/issue/owner/repo/42",
      review_proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, issue_version, "def456"),
      review_dedup_key = "consensus:" .. devloop_base.pr_review_proposal_id("owner/repo", 7, issue_version, "def456") .. "/review",
      reviewed_head_sha = "def456",
      pr_number = 7,
      source_ref = pr_source_ref(),
    }, issue_version)
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function decompose_event(extra)
    local value = payloads_builders.build_devloop_decompose_payload(fix_reconcile())
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local function merge_ready(extra)
    local event = review_reached()
    local value = payloads_builders.build_devloop_merge_ready_payload("github-devloop/issue/owner/repo/42",
      7,
      reviewing().version,
      {
        review_proposal_id = event.proposal_id,
        review_dedup_key = event.dedup_key,
        reviewed_head_sha = "def456",
      },
      pr_source_ref()
    )
    for key, field in pairs(extra or {}) do
      value[key] = field
    end
    return value
  end

  local mocks = mocks_factory.new(ctx, {
    reviewing = reviewing,
    pr_link_marker_for_fix = pr_link_marker_for_fix,
  })

  local mock_unclaimed_issue_state = mocks.mock_issue_state

  local function with_default_claim_label(labels, default_label)
    local selected = {}
    local has_claim = false
    for _, label in ipairs(labels or { default_label }) do
      if label ~= nil then
        table.insert(selected, label)
        has_claim = has_claim or claim_label_is_family(label)
      end
    end
    if not has_claim then
      table.insert(selected, claim_label_spec("fkst-test-bot").name)
    end
    return selected
  end

  local function wrap_claimed_issue_fixture(name, label_index, default_label)
    local base_fixture = mocks[name]
    mocks[name] = function(...)
      local args = table.pack(...)
      args[label_index] = with_default_claim_label(args[label_index], default_label)
      return base_fixture(table.unpack(args, 1, args.n))
    end
  end

  for _, fixture in ipairs({
    { "mock_issue_state", 1, "fkst-dev:enabled" },
    { "mock_issue_result", 1, "fkst-dev:thinking" },
    { "mock_issue_loop", 1, "fkst-dev:thinking" },
    { "mock_issue_reconcile", 1, "fkst-dev:thinking" },
    { "mock_issue_implement", 1, "fkst-dev:ready" },
    { "mock_issue_implement_raw", 1, "fkst-dev:ready" },
    { "mock_issue_reviewing", 1, "fkst-dev:pr-open" },
    { "mock_issue_review", 1, "fkst-dev:reviewing" },
    { "mock_issue_decompose", 1, "fkst-dev:blocked" },
    { "mock_issue_fix", 1, "fkst-dev:fixing" },
    { "mock_issue_fix_for_event", 2, "fkst-dev:fixing" },
    { "mock_issue_review_meta", 1, "fkst-dev:review-meta" },
    { "mock_issue_merge", 1, "fkst-dev:merge-ready" },
  }) do
    wrap_claimed_issue_fixture(fixture[1], fixture[2], fixture[3])
  end

  local function mock_claim_label_binding(event, run_opts)
    local payload = event and event.payload or {}
    local source_ref = payload.source_ref and payload.source_ref.ref
    local repo = payload.repo
      or (run_opts and run_opts.env and run_opts.env.FKST_GITHUB_REPO)
      or tostring(source_ref or ""):match("^(.+)#issue/%d+$")
      or "owner/repo"
    local login = run_opts
      and run_opts.env
      and run_opts.env.FKST_GITHUB_BOT_LOGIN
      or "fkst-test-bot"
    local claim_spec = claim_label_spec(login)
    for _ = 1, 16 do
      t.mock_command("gh api repos/" .. repo .. "/labels/" .. claim_spec.name, {
        stdout = '{"name":"' .. claim_spec.name .. '","description":"'
          .. claim_spec.description .. '"}\n',
        stderr = "",
        exit_code = 0,
      })
    end
  end

  local function mock_branch_config_env()
    t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end

  local function install_author_policy_env(run_opts)
    return author_policy.mock_env(t, run_opts, {
      configure_trusted_bot_login = parsers_misc.configure_trusted_bot_login,
      times = 8,
    })
  end

  local function run_department(path, event, run_opts)
    install_author_policy_env(run_opts)
    mock_claim_label_binding(event, run_opts)
    return t.run_department(path, event, run_opts)
  end

  local function run_observe(payload, run_opts, event_ts)
    return run_department("departments/observe_issue/main.lua", {
      queue = "github-proxy.github_entity_changed",
      payload = payload,
      ts = event_ts,
    }, run_opts)
  end

  local function build_result_dept(missing_issue)
    if consensus_result_department == nil then
      error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.consensus_result_department is required for run_result")
    end
    local model = gh_fake.model({
      issues = missing_issue and {} or {
        ["owner/repo#issue/42"] = ctx.pending_result_issue or mocks.mock_result_issue_value(),
      },
    })
    local dept = consensus_result_department.make_department({
      github = gh_fake.new(model),
      git = git_fake.new(git_fake.model({})),
    })
    dept.model = model
    return dept, model
  end

  local function proposal_request_for_result(result, fallback_proposal_id)
    local proposal_id = type(result) == "table" and result.proposal_id or nil
    proposal_id = proposal_id or fallback_proposal_id or "github-devloop/issue/owner/repo/42"
    local dedup_key = type(result) == "table" and tostring(result.dedup_key or "") or ""
    dedup_key = dedup_key:gsub("^consensus:", "")
    if dedup_key == "" then
      dedup_key = proposal_id .. "/request"
    end
    return {
      schema = "consensus.proposal.v1",
      proposal_id = proposal_id,
      dedup_key = dedup_key,
      source_ref = type(result) == "table" and result.source_ref or source_ref(),
    }
  end

  local function run_result(payload, run_opts)
    local is_request = type(payload) == "table" and payload.schema == "consensus.proposal.v1"
    local request = is_request and payload or proposal_request_for_result(payload)
    if not is_request then
      mock_next_consensus_result(payload)
    end
    if ctx.pending_result_read_failure ~= nil then
      ctx.pending_result_read_failure = nil
      local dept, model = build_result_dept(true)
      return with_consensus_call_mock(function()
        local result = run_fake_outcome(dept, {
          queue = "devloop_consensus_request",
          payload = request,
        })
        result.model = model
        return result
      end)
    end

    local function run()
      local dept, model = build_result_dept()
      local result = run_fake(dept, {
        queue = "devloop_consensus_request",
        payload = request,
      })
      result.exit_code = 0
      result.model = model
      return result
    end
    return with_consensus_call_mock(run)
  end

  local function run_result_expecting_failure(payload, _run_opts)
    local request = proposal_request_for_result(payload)
    mock_next_consensus_result(payload)
    local dept, model = build_result_dept()
    local result = with_consensus_call_mock(function()
      return run_fake_expecting_failure(dept, {
        queue = "devloop_consensus_request",
        payload = request,
      })
    end)
    result.exit_code = 1
    result.model = model
    return result
  end

  local function mark_result_read_failure()
    ctx.pending_result_read_failure = true
  end

  local function run_loop(payload, run_opts)
    if loop_department == nil then
      error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.loop_department is required for run_loop")
    end
    install_author_policy_env(run_opts)
    ctx.last_consensus_proposal = nil
    local result = run_fake_outcome(loop_department, {
      queue = "devloop_consensus_continue",
      payload = payload,
    })
    for _, raised in ipairs(result.raises or {}) do
      if raised.queue == "devloop_consensus_request" then
        ctx.last_consensus_proposal = raised.payload
      end
    end
    return result
  end

  local function run_reconcile(payload, run_opts)
    return run_department("departments/reconcile/main.lua", {
      queue = "devloop_reconcile",
      payload = payload,
    }, run_opts)
  end

  local function run_review_reconcile(payload, run_opts)
    local cached = mocks.take_pr_phase_comments()
    if cached ~= nil then
      local comments = { m_builders.pr_origin_marker(payload.proposal_id, "42", "devloop-owner-repo-42-01HY", payload.issue_version, "dev") }
      for _, comment in ipairs(cached) do
        table.insert(comments, comment)
      end
      entity_read_mocks.mock_default_pr_read(t, comments)
    end
    return run_department("departments/reconcile/main.lua", {
      queue = "devloop_review_reconcile",
      payload = payload,
    }, run_opts)
  end

  local function run_fix_reconcile(payload, run_opts)
    local cached = mocks.take_pr_phase_comments()
    if cached ~= nil then
      local comments = { m_builders.pr_origin_marker(payload.proposal_id, "42", "devloop-owner-repo-42-01HY", payload.issue_version, "dev") }
      for _, comment in ipairs(cached) do
        table.insert(comments, comment)
      end
      entity_read_mocks.mock_default_pr_read(t, comments)
    end
    return run_department("departments/reconcile/main.lua", {
      queue = "devloop_fix_reconcile",
      payload = payload,
    }, run_opts)
  end

  local function run_decompose(payload, run_opts)
    mocks.mock_pr_origin_from_cached(payload, payload and payload.head_sha or "def456")
    return run_department("departments/decompose/main.lua", {
      queue = decompose_queue,
      payload = payload,
    }, run_opts)
  end

  local function run_implement(payload, run_opts, queue, event_extra)
    mock_branch_config_env()
    local event = {
      queue = queue or "devloop_ready",
      payload = payload,
    }
    for key, value in pairs(event_extra or {}) do
      event[key] = value
    end
    return run_department("departments/implement/main.lua", {
      queue = event.queue,
      payload = event.payload,
      attempt = event.attempt,
      terminal = event.terminal,
      ts = event.ts,
    }, run_opts)
  end

  local function run_observe_pr(payload, run_opts, now_seconds)
    mock_branch_config_env()
    mocks.mock_pr_origin_from_cached({
      proposal_id = "github-devloop/issue/owner/repo/42",
      version = reviewing().version,
    }, "def456")
    return run_department("departments/observe_pr/main.lua", {
      queue = "github-proxy.github_entity_changed",
      payload = payload,
      now_seconds = now_seconds,
    }, run_opts)
  end

  local function run_review_pr(payload, run_opts)
    mocks.mock_pr_origin_from_cached(payload, payload and (payload.head_sha or payload.reviewed_head_sha) or "def456")
    return run_department("departments/review_pr/main.lua", {
      queue = "devloop_reviewing",
      payload = payload,
    }, run_opts)
  end

  local function run_review_result(payload, run_opts)
    mock_branch_config_env()
    local is_request = type(payload) == "table" and payload.schema == "consensus.proposal.v1"
    local fallback = review_reached().proposal_id
    local request = is_request and payload or proposal_request_for_result(payload, fallback)
    if not is_request then
      mock_next_consensus_result(payload)
    end
    local _, _, _, head_sha = devloop_base.parse_pr_review_proposal_id(request.proposal_id)
    mocks.mock_pr_origin_from_cached({ proposal_id = "github-devloop/issue/owner/repo/42", version = reviewing().version }, head_sha)
    local function run()
      if review_result_department == nil then
        error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.review_result_department is required for run_review_result")
      end
      install_author_policy_env(run_opts)
      return run_fake_outcome(review_result_department, {
        queue = "devloop_review_request",
        payload = request,
      })
    end
    return with_consensus_call_mock(run)
  end

  local function run_fix(payload, run_opts)
    mock_branch_config_env()
    local cached = mocks.take_pr_phase_comments()
    local pending = mocks.take_pending_pr_origin()
    if cached ~= nil or pending ~= nil then
      local comments = {}
      local head = pending and pending.head or "devloop-owner-repo-42-01HY"
      local base_branch = pending and pending.base_branch or "dev"
      local state = pending and pending.state or "OPEN"
      for _, comment in ipairs(pending and pending.comments or { m_builders.pr_origin_marker(payload.proposal_id, "42", head, payload.version, base_branch) }) do
        table.insert(comments, comment)
      end
      for _, comment in ipairs(cached or {}) do
        table.insert(comments, comment)
      end
      entity_read_mocks.mock_pr_read_forms(t, { comments = comments, head = head, head_sha = payload.reviewed_head_sha or pending and pending.head_sha or "def456", state = state, base_branch = base_branch, labels = pending and pending.labels or {} })
      entity_read_mocks.mock_pr_view_selector(t, {
        comments = comments,
        head = head,
        head_sha = payload.reviewed_head_sha or pending and pending.head_sha or "def456",
        state = state,
        base_branch = base_branch,
        labels = pending and pending.labels or {},
      }, "headRefName,headRefOid,baseRefName,state,comments,headRepository,headRepositoryOwner,isCrossRepository")
    end
    return run_department("departments/fix/main.lua", {
      queue = "devloop_fixing",
      payload = payload,
    }, run_opts)
  end

  local function run_review_loop(payload, run_opts)
    if review_loop_department == nil then
      error("testkit_internal.devloop_fixtures: fixture-dependency-missing: deps.review_loop_department is required for run_review_loop")
    end
    mock_branch_config_env()
    install_author_policy_env(run_opts)
    local _, _, _, head_sha = devloop_base.parse_pr_review_proposal_id(payload.proposal_id)
    mocks.mock_pr_origin_from_cached({ proposal_id = "github-devloop/issue/owner/repo/42", version = reviewing().version }, head_sha)
    ctx.last_consensus_proposal = nil
    local result = run_fake_outcome(review_loop_department, {
      queue = "devloop_review_continue",
      payload = payload,
    })
    for _, raised in ipairs(result.raises or {}) do
      if raised.queue == "devloop_review_request" then
        ctx.last_consensus_proposal = raised.payload
      end
    end
    return result
  end

  local function run_review_meta(payload, run_opts)
    mocks.mock_pr_origin_from_cached(payload, "def456")
    return run_department("departments/review_meta/main.lua", {
      queue = "devloop_review_meta",
      payload = payload,
    }, run_opts)
  end

  local function run_merge(payload, run_opts)
    mock_branch_config_env()
    t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&base=dev&per_page=100'", {
      stdout = string.format('[{"number":%d,"state":"open","base":{"ref":"dev"}}]\n', tonumber(payload and payload.pr_number) or 7),
      stderr = "",
      exit_code = 0,
    })
    if mock_merge_pr_diff_name_only then
      local skip_default_risk_mock = type(run_opts) == "table"
        and type(run_opts.env) == "table"
        and run_opts.env.FKST_TEST_SKIP_DEFAULT_RISK_MOCK == "1"
      for _ = 1, skip_default_risk_mock and 0 or 2 do
        t.mock_command("gh pr diff '" .. tostring(tonumber(payload and payload.pr_number) or 7) .. "' --repo 'owner/repo' --name-only", {
          stdout = "file.lua\n",
          stderr = "",
          exit_code = 0,
        })
      end
    end
    return run_department("departments/merge/main.lua", {
      queue = "devloop_merge_ready",
      payload = payload,
    }, run_opts)
  end

  return {
    t = t,
    core = core,
    projected_state_comment = deps.projected_state_comment,
    state_comment = deps.state_comment,
    action_label = deps.action_label or "⟦FKST:ACTION⟧",
    reason_label = deps.reason_label or "⟦FKST:REASON⟧",
    has_value = has_value,
    opts = opts,
    source_ref = source_ref,
    pr_source_ref = pr_source_ref,
    issue = issue,
    reached = reached,
    unresolved = unresolved,
    reconcile = reconcile,
    ready = ready,
    reviewing = reviewing,
    review_reached = review_reached,
    review_unresolved = review_unresolved,
    fixing = fixing,
    pr_link_marker_for_fix = pr_link_marker_for_fix,
    review_meta_event = review_meta_event,
    review_reconcile = review_reconcile,
    fix_reconcile = fix_reconcile,
    decompose_event = decompose_event,
    merge_ready = merge_ready,
    run_observe = run_observe,
    run_department = run_department,
    mock_author_policy_configure = parsers_misc.configure_trusted_bot_login,
    run_result = run_result,
    run_result_expecting_failure = run_result_expecting_failure,
    mark_result_read_failure = mark_result_read_failure,
    run_loop = run_loop,
    run_reconcile = run_reconcile,
    run_review_reconcile = run_review_reconcile,
    run_fix_reconcile = run_fix_reconcile,
    run_decompose = run_decompose,
    run_implement = run_implement,
    run_observe_pr = run_observe_pr,
    run_review_pr = run_review_pr,
    run_review_result = run_review_result,
    run_fix = run_fix,
    run_review_loop = run_review_loop,
    mock_next_consensus_result = mock_next_consensus_result,
    take_consensus_proposal = take_consensus_proposal,
    run_review_meta = run_review_meta,
    run_merge = run_merge,
    json_string = mocks.json_string,
    encode_json_string = mocks.json_string,
    render_comment = mocks.render_comment,
    default_marker_version = mocks.default_marker_version,
    mock_issue_state = mocks.mock_issue_state,
    mock_unclaimed_issue_state = mock_unclaimed_issue_state,
    state_from_labels = mocks.state_from_labels,
    with_default_state_marker = mocks.with_default_state_marker,
    set_pr_phase_comments = mocks.set_pr_phase_comments,
    take_pr_phase_comments = mocks.take_pr_phase_comments,
    set_pending_pr_origin = mocks.set_pending_pr_origin,
    take_pending_pr_origin = mocks.take_pending_pr_origin,
    mock_issue_body = mocks.mock_issue_body,
    mock_issue_result = mocks.mock_issue_result,
    mock_issue_loop = mocks.mock_issue_loop,
    mock_issue_reconcile = mocks.mock_issue_reconcile,
    mock_issue_implement = mocks.mock_issue_implement,
    mock_issue_implement_raw = mocks.mock_issue_implement_raw,
    mock_issue_reviewing = mocks.mock_issue_reviewing,
    mock_issue_review = mocks.mock_issue_review,
    mock_issue_decompose = mocks.mock_issue_decompose,
    mock_issue_fix = mocks.mock_issue_fix,
    mock_issue_fix_for_event = mocks.mock_issue_fix_for_event,
    mock_issue_review_meta = mocks.mock_issue_review_meta,
    mock_issue_merge = mocks.mock_issue_merge,
    argv_rendered = gh_argv.argv_rendered,
  }
end

return M
