local h = require("tests.devloop_helpers")
local config = require("devloop.config")
local implement_department = require("departments.implement.main")
local m_claims = require("devloop.claims")
local payloads_builders = require("devloop.payloads.builders")
local testing = require("testkit_internal.testing")
local t = h.t
local core = h.core
local opts = h.opts
local ready = h.ready
local run_implement = h.run_implement
local run_observe = h.run_observe
local issue = h.issue
local mock_issue_implement = h.mock_issue_implement
local mock_issue_state = h.mock_issue_state
local deterministic_branch_for = h.deterministic_branch_for
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree = h.mock_existing_empty_implement_worktree
local mock_existing_empty_implement_worktree_reuse = h.mock_existing_empty_implement_worktree_reuse
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_branch_diff_paths = h.mock_branch_diff_paths
local mock_git_commit = h.mock_git_commit
local count_calls = h.count_calls
local find_raise = h.find_raise
local codex_status = require("tests.codex_status_helpers")
local m_builders = require("devloop.markers.builders")
local payloads_shared = require("devloop.payloads.shared")

local function run_implement_with_logs(payload)
  local previous_log = log
  local previous_branch_config = config.branch_config
  local previous_managed_bot_logins = m_claims.managed_bot_logins
  local captured = {}
  log = {
    info = function(message) table.insert(captured, tostring(message)) end,
    warn = function(message) table.insert(captured, tostring(message)) end,
    error = function(message) table.insert(captured, tostring(message)) end,
  }
  config.branch_config = function()
    return { upstream = "dev", integration = "dev" }
  end
  m_claims.managed_bot_logins = function()
    return {}
  end
  local ok, result = pcall(function()
    return testing.run_fake(implement_department, {
      queue = "devloop_ready",
      payload = payload,
    })
  end)
  log = previous_log
  config.branch_config = previous_branch_config
  m_claims.managed_bot_logins = previous_managed_bot_logins
  if not ok then
    error(result, 0)
  end
  return result, captured
end

local function find_version_mismatch_log(logs)
  for _, message in ipairs(logs) do
    if message:find("tag=STALE_VERSION_MISMATCH", 1, true) ~= nil then
      return message
    end
  end
  return nil
end

local function assert_version_mismatch_fact(message, attempt, terminal)
  local function require_field(field)
    if type(message) ~= "string" or message:find(field, 1, true) == nil then
      error("missing rendered error fact field " .. field .. ": " .. tostring(message), 2)
    end
  end

  require_field("error_class=stale-version-mismatch")
  require_field("source_ref=external:owner/repo#issue/42")
  require_field("attempt=" .. tostring(attempt))
  require_field("terminal=" .. tostring(terminal))
  require_field(
    "queue=devloop_ready error=ready event does not match current implementing version"
  )
  t.is_nil(message:find("error_class=devloop_ready", 1, true))
  t.is_nil(message:find("error=table:", 1, true))
end

local function stale_attempt_started_at()
  return tostring(now() - 7201)
end

local function recent_comment(body, seconds_ago)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (seconds_ago or 60)),
  }
end

local function implement_attempt_marker(event, attempt, started_at, exec_ref)
  return core.implement_attempt_marker(event.proposal_id, event.dedup_key, attempt, started_at, exec_ref)
end

local function implementing_comments(event, extra)
  local branch = deterministic_branch_for(event)
  local comments = {
    core.state_marker(event.proposal_id, "implementing", event.dedup_key),
  }
  for _, comment in ipairs(extra or {}) do
    table.insert(comments, comment)
  end
  return comments, branch
end

local function liveness_redrive_ready(event)
  local payload = payloads_builders.build_devloop_ready_payload({
    proposal_id = event.proposal_id,
    dedup_key = core.ready_payload_inner_version(event.dedup_key),
    source_ref = event.source_ref,
    impl_retry_attempt = core.implementation_retry_attempt(event.dedup_key),
    redrive_delivery = {
      generation_key = "restart-liveness-v2/implementing/implementing.active/codex_run-v1/codex-run-not-running/1783840000000",
      attempt = 1,
    },
  })
  t.eq(payload.dedup_key, payloads_shared.issue_redrive_delivery_dedup_key(
    payload.proposal_id, payload.implementation_version, payload.redrive_delivery
  ))
  return payload
end

local function mock_missing_remote_branch(branch)
  t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", {
    stdout = "",
    stderr = "fatal: couldn't find remote ref",
    exit_code = 128,
  })
end

local function mock_remote_branch(branch, head)
  t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'" .. tostring(branch) .. "'^{commit}", {
    stdout = tostring(head or "def456") .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_invalid_implementation_result_logs_exact_error_class = function()
    local event = ready()
    local run_opts = opts("implement-invalid-result-error-class")
    mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(event.proposal_id, "ready", event.dedup_key),
    })
    mock_existing_empty_implement_worktree({ impl_version = event.dedup_key })
    mock_implement_codex(0, '{"schema":"github-devloop.implementation-result.v1",'
      .. '"proposal_id":"' .. event.proposal_id .. '",'
      .. '"implementation_version":"' .. event.dedup_key .. '","attempt":1}')
    mock_git_status("")
    t.mock_command("rev-list --count", {
      stdout = "0\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh api graphql", {
      stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
      stderr = "",
      exit_code = 0,
    })
    h.mock_context_bundle(event, run_opts)

    local result, logs = run_implement_with_logs(event)

    t.is_nil(result.failure)
    local codex_failure_log
    for _, message in ipairs(logs) do
      if message:find("tag=CODEX", 1, true) ~= nil
        and message:find("failure=Invalid typed result envelope:", 1, true) ~= nil then
        codex_failure_log = message
      end
    end
    t.eq(codex_failure_log:match(" error_class=([^ ]+)"), "invalid-implementation-result")
  end,

  test_implementing_redelivery_reruns_when_no_progress_and_attempt_budget_remains = function()
    local event = ready()
    local comments, branch = implementing_comments(event, {
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_attempt_started_at()),
    })
    mock_issue_implement({ "fkst-dev:implementing" }, comments)
    mock_missing_remote_branch(branch)
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })
    mock_fresh_implement_worktree()
    mock_implement_codex(0, "implemented after retry")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("def456", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, comments)

    local result = run_implement(event, opts("implement-liveness-rerun"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('attempt="2"', 1, true) ~= nil
    end).payload.body
    t.eq(core.implement_attempt_count({ comment }, event.proposal_id, event.dedup_key), 2)
  end,

  test_implementing_redelivery_sees_remote_branch_without_direct_open_pr = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local fact = m_builders.implementing_marker(event.proposal_id, event.dedup_key, branch, "abc123", "dev", "abc123")
    local comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_attempt_started_at()),
      fact,
    }
    mock_issue_implement({ "fkst-dev:implementing" }, comments)
    mock_remote_branch(branch, "abc123")

    local result = run_implement(event, opts("implement-liveness-remote-progress"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_implementing_redelivery_skips_when_pr_link_exists = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_attempt_started_at()),
      m_builders.pr_link_marker(event.proposal_id, 7, branch, event.dedup_key, "dev"),
    }
    mock_issue_implement({ "fkst-dev:implementing" }, comments)

    local result = run_implement(event, opts("implement-liveness-pr-link"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_ready_redelivery_skips_after_worktree_ready_implementing_state = function()
    local event = ready()
    local run_opts = opts("implement-ready-redelivery-after-state")
    local release_codex_run = codex_status.seed_implement_codex_run(
      run_opts, event.proposal_id, event.dedup_key
    )
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      implement_attempt_marker(event, 1, stale_attempt_started_at(), exec_ref),
    }
    mock_issue_implement({ "fkst-dev:implementing" }, comments)

    local result = run_implement(event, run_opts)
    release_codex_run()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git fetch"), 0)
    t.eq(count_calls("git worktree add"), 0)
  end,

  test_implementing_redelivery_marks_failed_after_attempt_budget = function()
    local event = ready()
    local comments, branch = implementing_comments(event, {
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 2, stale_attempt_started_at()),
    })
    mock_issue_implement({ "fkst-dev:implementing" }, comments)
    mock_missing_remote_branch(branch)
    t.mock_command("git fetch 'origin' 'dev'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("refs/remotes/'origin'/'dev'^{commit}", {
      stdout = "abc123\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })

    local result = run_implement(event, opts("implement-liveness-exhausted"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:impl-failed")
  end,

  test_implementing_liveness_redrive_uses_current_marker_version = function()
    local current = ready()
    local event = liveness_redrive_ready(current)
    t.is_true(event.dedup_key ~= current.dedup_key)
    t.eq(event.implementation_version, current.dedup_key)
    local comments, branch = implementing_comments(current, {
      core.implement_attempt_marker(current.proposal_id, current.dedup_key, 2, stale_attempt_started_at()),
    })
    mock_issue_implement({ "fkst-dev:implementing" }, comments)
    mock_missing_remote_branch(branch)
    t.mock_command("git fetch 'origin' 'dev'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("refs/remotes/'origin'/'dev'^{commit}", {
      stdout = "abc123\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })

    local result = run_implement(event, opts("implement-liveness-redrive-current-marker"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 0)
    local label = find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.eq(label.payload.add_labels[1], "fkst-dev:impl-failed")
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment.payload.body:find(core.state_marker(current.proposal_id, "impl-failed", current.dedup_key), 1, true) ~= nil)
  end,

  test_implementing_liveness_redrive_rejects_tampered_delivery_identity = function()
    local event = liveness_redrive_ready(ready())
    event.dedup_key = event.dedup_key .. "/tampered"

    local result = run_implement(event, opts("implement-liveness-redrive-tampered-delivery"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh "), 0)
    t.eq(count_calls("git "), 0)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_implementing_liveness_redrive_takes_over_orphaned_owner_marker = function()
    local current = ready()
    local event = liveness_redrive_ready(current)
    local branch = deterministic_branch_for(current)
    local comments = {
      core.state_marker(current.proposal_id, "implementing", current.dedup_key),
      m_builders.implementing_marker(current.proposal_id, current.dedup_key, branch, "abc123", "dev", "abc123"),
    }
    mock_issue_implement({ "fkst-dev:implementing" }, comments)
    mock_missing_remote_branch(branch)
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })
    mock_fresh_implement_worktree()
    mock_implement_codex(0, "implemented after orphan takeover")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("def456", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, comments)

    local result = run_implement(event, opts("implement-liveness-redrive-orphaned-owner"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request").payload.body
    t.eq(core.implement_attempt_count({ comment }, current.proposal_id, current.dedup_key), 1)
  end,

  test_liveness_replayer_skips_live_implement_attempt_before_receiver = function()
    local current = ready()
    local run_opts = opts("observe-implement-live-attempt-budget-owner")
    local release_codex_run = codex_status.seed_implement_codex_run(
      run_opts, current.proposal_id, current.dedup_key
    )
    local exec_ref = core.implement_exec_ref(current.proposal_id, current.dedup_key)
    local comments = {
      recent_comment(core.state_marker(current.proposal_id, "implementing", current.dedup_key)),
      implement_attempt_marker(current, 1, stale_attempt_started_at(), exec_ref),
    }

    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", comments)
    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), run_opts)
    release_codex_run()
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_implementing_redelivery_recovers_local_branch_before_attempt_budget = function()
    local event = ready()
    local comments, branch = implementing_comments(event, {
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_attempt_started_at()),
    })
    mock_issue_implement({ "fkst-dev:implementing" }, comments)
    mock_missing_remote_branch(branch)
    mock_existing_empty_implement_worktree_reuse(nil, branch, "1")
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "def456\n",
      stderr = "",
      exit_code = 0,
    })
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "def456\n",
      stderr = "",
      exit_code = 0,
    })
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git show " .. branch .. ":.fkst/substrate-ref", {
      stdout = "1111111111111111111111111111111111111111\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse HEAD", {
      stdout = "def456\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("cat-file -p", {
      stdout = "tree aaaaaaa\nparent bbbbbbb\n\nordinary implementation progress\n",
      stderr = "",
      exit_code = 0,
    })
    mock_implement_codex(0, "finished from local progress")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("fed456", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, comments)

    local result = run_implement(event, opts("implement-liveness-local-progress-at-budget"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    local final = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil)
  end,

  test_second_retry_death_exhausts_after_observe_reraises = function()
    local event = ready()
    local comments, branch = implementing_comments(event, {
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 2, tostring(now() - 7201)),
    })
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", comments)

    local observed = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-implement-second-attempt-expired"))
    t.eq(observed.exit_code, 0)
    t.eq(find_raise(observed.raises, "devloop_ready").payload.proposal_id, event.proposal_id)

    mock_issue_implement({ "fkst-dev:implementing" }, comments)
    mock_missing_remote_branch(branch)
    t.mock_command("git fetch 'origin' 'dev'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("refs/remotes/'origin'/'dev'^{commit}", {
      stdout = "abc123\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })

    local retried = run_implement(event, opts("implement-second-attempt-exhausted"))
    t.eq(retried.exit_code, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(find_raise(retried.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:impl-failed")
  end,

  test_observe_reraises_implement_after_attempt_liveness_expires = function()
    local event = ready()
    local comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 7201)),
    }
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", comments)

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-implement-expired"))
    t.eq(result.exit_code, 0)
    local raised = find_raise(result.raises, "devloop_ready")
    t.eq(raised.payload.proposal_id, event.proposal_id)
    -- The re-raised ready reproduces the frozen implementing marker version
    -- EXACTLY (build_devloop_ready_payload re-wraps the inner version), so the
    -- implement receiver's recomputed marker version matches and the re-drive is
    -- accepted -- not double-wrapped to "ready/ready/..." which skip-staled
    -- forever (#718).
    t.eq(raised.payload.dedup_key, event.dedup_key)
  end,

  test_observe_skips_live_implement_attempt = function()
    local event = ready()
    local run_opts = opts("observe-implement-live")
    local release_codex_run = codex_status.seed_implement_codex_run(
      run_opts, event.proposal_id, event.dedup_key
    )
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local comments = {
      recent_comment(core.state_marker(event.proposal_id, "implementing", event.dedup_key)),
      implement_attempt_marker(event, 1, stale_attempt_started_at(), exec_ref),
    }
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", comments)

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), run_opts)
    release_codex_run()
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_observe_reraises_old_implementing_marker_without_attempt_marker = function()
    local event = ready({
      dedup_key = "ready/consensus-github-devloop/issue/owner/repo/42/2026-01-01T00-00-00Z",
    })
    local branch = deterministic_branch_for(event)
    local comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      m_builders.implementing_marker(event.proposal_id, event.dedup_key, branch, "abc123", "dev", "abc123"),
    }
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", comments)

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-implement-old-no-attempt"))
    t.eq(result.exit_code, 0)
    local raised = find_raise(result.raises, "devloop_ready")
    t.eq(raised.payload.proposal_id, event.proposal_id)
    -- The re-raised ready reproduces the frozen implementing marker version
    -- EXACTLY (build_devloop_ready_payload re-wraps the inner version), so the
    -- implement receiver's recomputed marker version matches and the re-drive is
    -- accepted -- not double-wrapped to "ready/ready/..." which skip-staled
    -- forever (#718).
    t.eq(raised.payload.dedup_key, event.dedup_key)
  end,

  -- Production-shaped round-trip (#718): the payload observe's liveness re-drive
  -- actually delivers must be ACCEPTED by the implement receiver, not skip-staled
  -- forever. The other tests feed a hand-built ready() straight into
  -- run_implement and never exercise the observe->implement chain production runs,
  -- so the double-wrap defect was invisible (the #550/#551 harness lesson).
  test_observe_reraised_ready_round_trips_into_implement_without_skip_stale = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local stuck = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 7201)),
    }
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", stuck)
    local observed = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-718-roundtrip"))
    t.eq(observed.exit_code, 0)
    local reraised = find_raise(observed.raises, "devloop_ready")
    t.eq(reraised ~= nil, true)

    -- Feed the EXACT re-raised payload back into implement on the same stuck
    -- implementing marker. With the fix it advances (re-runs codex, opens a PR);
    -- before the fix it skip-staled (codex never runs, zero progress, forever).
    local rerun = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_attempt_started_at()),
    }
    mock_issue_implement({ "fkst-dev:implementing" }, rerun)
    mock_missing_remote_branch(branch)
    t.mock_command("show-ref --verify --quiet", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command("show-ref --verify --quiet", { stdout = "", stderr = "", exit_code = 1 })
    mock_fresh_implement_worktree()
    mock_implement_codex(0, "implemented after liveness re-drive")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("def456", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, rerun)

    local result = run_implement(reraised.payload, opts("implement-718-roundtrip"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1, "re-raised ready must re-run implement, not skip-stale forever")
  end,

  test_observe_reraises_reimplement_attempt_preserving_suffix = function()
    local event = ready()
    local retry_version = core.implementation_attempt_version(event.dedup_key, 2)
    local stuck = {
      core.state_marker(event.proposal_id, "implementing", retry_version),
      core.implement_attempt_marker(event.proposal_id, retry_version, 2, tostring(now() - 7201)),
    }
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", stuck)

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-721-reimplement-redrive"))
    t.eq(result.exit_code, 0)
    local raised = find_raise(result.raises, "devloop_ready")
    t.eq(raised.payload.proposal_id, event.proposal_id)
    t.eq(raised.payload.dedup_key, retry_version)
    t.eq(raised.payload.impl_retry_attempt, 2)
  end,

  test_observe_reraised_reimplement_ready_round_trips_into_implement_without_skip_stale = function()
    local event = ready()
    local retry_version = core.implementation_attempt_version(event.dedup_key, 2)
    local branch = deterministic_branch_for(event)
    local stuck = {
      core.state_marker(event.proposal_id, "implementing", retry_version),
      core.implement_attempt_marker(event.proposal_id, retry_version, 2, tostring(now() - 7201)),
    }
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", stuck)
    local observed = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-721-roundtrip"))
    t.eq(observed.exit_code, 0)
    local reraised = find_raise(observed.raises, "devloop_ready")
    t.eq(reraised ~= nil, true)

    local progress = {
      core.state_marker(event.proposal_id, "implementing", retry_version),
      core.implement_attempt_marker(event.proposal_id, retry_version, 2, stale_attempt_started_at()),
      m_builders.implementing_marker(event.proposal_id, retry_version, branch, "abc123", "dev", "abc123"),
    }
    mock_issue_implement({ "fkst-dev:implementing" }, progress)
    mock_remote_branch(branch, "abc123")

    local result = run_implement(reraised.payload, opts("implement-721-roundtrip"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_double_wrapped_liveness_redrive_is_not_recovered = function()
    local event = ready()
    local double_wrapped = payloads_builders.build_devloop_ready_payload({
      proposal_id = event.proposal_id,
      dedup_key = event.dedup_key,
      source_ref = event.source_ref,
    })
    local comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_attempt_started_at()),
    }
    mock_issue_implement({ "fkst-dev:implementing" }, comments)

    local result = run_implement(double_wrapped, opts("implement-726-double-wrapped-redrive"))
    -- #2908: a version mismatch must be skipped gracefully (exit 0), never error()
    -- out of the pipeline, which dead-letters and crash-loops the queue.
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 0)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.eq(comment ~= nil, true)
    t.eq(core.implement_version_mismatch_attempt_count({ comment.payload.body }, event.proposal_id, double_wrapped.dedup_key, event.dedup_key), 1)
  end,

  test_implementing_version_mismatch_fails_closed_after_delivery_budget = function()
    local event = ready()
    local retry_version = core.implementation_attempt_version(event.dedup_key, 2)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", retry_version),
      core.implement_attempt_marker(event.proposal_id, retry_version, 2, stale_attempt_started_at()),
      core.implement_version_mismatch_marker(event.proposal_id, event.dedup_key, retry_version, 1),
      core.implement_version_mismatch_marker(event.proposal_id, event.dedup_key, retry_version, 2),
    })

    local result, logs = run_implement_with_logs(event)
    -- #2908: budget exhausted -> fail-closed skip-stale, but return cleanly
    -- (exit 0) with no further raises, never a fatal error() / dead-letter.
    t.is_nil(result.failure)
    t.eq(#result.raises, 0)
    assert_version_mismatch_fact(find_version_mismatch_log(logs), 3, true)
  end,

  test_implementing_version_mismatch_persists_skip_stale_attempt = function()
    local event = ready()
    local retry_version = core.implementation_attempt_version(event.dedup_key, 2)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", retry_version),
      core.implement_attempt_marker(event.proposal_id, retry_version, 2, stale_attempt_started_at()),
    })

    local result, logs = run_implement_with_logs(event)
    -- #2908: within budget -> persist the mismatch attempt marker and skip
    -- gracefully (exit 0), never error() out of the pipeline.
    t.is_nil(result.failure)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.eq(comment ~= nil, true)
    t.eq(core.implement_version_mismatch_attempt_count({ comment.payload.body }, event.proposal_id, event.dedup_key, retry_version), 1)
    assert_version_mismatch_fact(find_version_mismatch_log(logs), 1, false)
  end,

  test_observe_skips_implementing_state_marker_without_progress_facts = function()
    local event = ready({
      dedup_key = "ready/consensus-github-devloop/issue/owner/repo/42/2026-01-01T00-00-00Z",
    })
    local comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
    }
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", comments)

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-implement-no-progress-facts"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_observe_skips_recent_implementing_marker_without_attempt_marker = function()
    local event = ready({
      dedup_key = "ready/consensus-github-devloop/issue/owner/repo/42/2999-01-01T00-00-00Z",
    })
    local branch = deterministic_branch_for(event)
    local comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      m_builders.implementing_marker(event.proposal_id, event.dedup_key, branch, "abc123", "dev", "abc123"),
    }
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", comments)

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-implement-recent-no-attempt"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready").payload.proposal_id, event.proposal_id)
  end,
}
