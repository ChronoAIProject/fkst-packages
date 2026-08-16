local identity = require("contract.convergence_identity")
local consensus = require("consensus")
local workflow_codex = require("workflow_internal.codex")
local testing = require("testkit_internal.testing")
local t = fkst.test
local reach_test_helper = require("tests.reach_test_helpers")
require("tests.cache_seed_helpers")

local function nonce()
  return tostring({}):gsub("[^%w._-]", "_")
end

local function runtime_root(name)
  return "/tmp/fkst-packages-test/consensus-live-run/" .. tostring(now()) .. "/" .. nonce() .. "/" .. name
end

local function opts(name)
  local root = runtime_root(name)
  return {
    env = {
      FKST_RUNTIME_ROOT = root,
      FKST_RUNTIME_LOG_DIR = root .. "/logs",
    },
  }
end

local function proposal(extra)
  local value = {
    schema = "consensus.proposal.v1",
    proposal_id = "proposal-42",
    title = "Adopt consensus package",
    body = "Create a small flat package that asks several angles to judge a proposal.",
    content_fetch = "fetch-source --ref demo/consensus/42 --full",
    context = "The package must stay silent unless all angles agree.",
    angles = { "teleology", "parsimony", "fidelity" },
    dedup_key = "proposal-42-v1",
    source_ref = {
      kind = "proposal",
      ref = "demo/consensus/42",
    },
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function library_run_identity(value, angle_lane)
  local generation = value.generation or 0
  local round = value.round or 0
  return {
    role = "consensus",
    invocation_id = value.dedup_key,
    generation = generation,
    round = round,
    angle_lane = angle_lane,
    dedup_key = "convergence:consensus:" .. value.dedup_key
      .. ":g" .. tostring(generation)
      .. ":r" .. tostring(round)
      .. ":" .. tostring(angle_lane),
  }
end

local function running_codex_record(run_identity)
  return {
    role = run_identity.role,
    proposal_id = run_identity.invocation_id,
    dedup_key = run_identity.dedup_key,
    status = "running",
    started_at = "2026-06-03T00:30:00Z",
    started_at_ms = now() * 1000,
    timeout_seconds = 3600,
    log_path = "/tmp/fkst-packages-test/codex.log",
    cmd_line = "codex exec -",
  }
end

local function run_decide(event_payload, run_opts)
  return reach_test_helper.run(event_payload, run_opts)
end

local function mock_judgment_runtime()
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/consensus-live-run/runtime",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_judgment_dir()
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_angle(angle, verdict, reply)
  mock_judgment_dir()
  t.mock_command("consensus-angle-" .. tostring(angle), {
    stdout = "⟦FKST:VERDICT⟧ " .. verdict .. "\n⟦FKST:REPLY⟧ " .. reply .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local codex_calls = require("testkit_internal.command_calls").codex_calls

local with_codex_runs = require("testkit_internal.testing").with_codex_runs

local function dispatch_identity()
  return {
    role = "consensus",
    proposal_id = "proposal-42",
    dedup_key = "dedup-42",
  }
end

local role_timeout_env = {
  consensus = "FKST_CODEX_TIMEOUT_CONSENSUS",
  implement = "FKST_CODEX_TIMEOUT_IMPLEMENT",
  fix = "FKST_CODEX_TIMEOUT_FIX",
  ["review-meta"] = "FKST_CODEX_TIMEOUT_REVIEW_META",
  archaudit = "FKST_CODEX_TIMEOUT_ARCHAUDIT",
  ["release-notes"] = "FKST_CODEX_TIMEOUT_RELEASE_NOTES",
  judgment = "FKST_CODEX_TIMEOUT_JUDGMENT",
  decompose = "FKST_CODEX_TIMEOUT_DECOMPOSE",
  intake = "FKST_CODEX_TIMEOUT_INTAKE",
  ["workflow-select"] = "FKST_CODEX_TIMEOUT_WORKFLOW_SELECT",
  ["workflow-materialize"] = "FKST_CODEX_TIMEOUT_WORKFLOW_MATERIALIZE",
  ["sync-conflict"] = "FKST_CODEX_TIMEOUT_SYNC_CONFLICT",
}

local allowed_dispatch_env = {
  FKST_CODEX_REPOSITORY_ROOTS = true,
}
for _, env_name in pairs(role_timeout_env) do
  allowed_dispatch_env[env_name] = true
end

local function with_timeout_env(env_values, fn)
  local original_env_read = env_read
  local original_exec_sync = exec_sync
  if type(env_values) ~= "table" then
    env_values = { FKST_CODEX_TIMEOUT_CONSENSUS = env_values }
  end
  local function read_test_env(env_name)
    t.is_true(allowed_dispatch_env[env_name] == true,
      "unexpected env read: " .. tostring(env_name))
    return env_values[env_name] or ""
  end
  if type(original_env_read) == "function" then
    _G.env_read = read_test_env
  else
    _G.exec_sync = function(command)
      local env_name = tostring(command):match('^printf %%s "%$([A-Z0-9_]+)"$')
      t.is_true(env_name ~= nil, "unexpected env command: " .. tostring(command))
      return { stdout = read_test_env(env_name), stderr = "", exit_code = 0 }
    end
  end
  local ok, err = pcall(fn)
  _G.env_read = original_env_read
  _G.exec_sync = original_exec_sync
  if not ok then
    error(err)
  end
end

local function with_dispatch_fakes(env_value, fn)
  local original_spawn_codex = spawn_codex
  local original_spawn_codex_sync = spawn_codex_sync
  local calls = {}
  spawn_codex = function(spawn_opts)
    table.insert(calls, { kind = "async", opts = spawn_opts })
    return { kind = "async", opts = spawn_opts }
  end
  spawn_codex_sync = function(spawn_opts)
    table.insert(calls, { kind = "sync", opts = spawn_opts })
    return { kind = "sync", opts = spawn_opts }
  end
  local ok, err = pcall(function()
    with_timeout_env(env_value, function()
      with_codex_runs({}, function()
        fn(calls)
      end)
    end)
  end)
  spawn_codex = original_spawn_codex
  spawn_codex_sync = original_spawn_codex_sync
  if not ok then
    error(err)
  end
end

return {
  test_convergence_identity_uses_only_stable_proposal_fields = function()
    local built = identity.from_proposal("consensus", proposal({
      dedup_key = "proposal-42-v1/loop/2",
      generation = 7,
      round = 2,
      version = "volatile-version",
      source_ref = { kind = "proposal", ref = "volatile/ref" },
    }), { angle_lane = "teleology" })

    t.eq(built.process.role, "consensus")
    t.eq(built.process.proposal_id, "proposal-42")
    t.eq(built.role, "consensus")
    t.eq(built.proposal_id, "proposal-42")
    t.eq(built.generation, 7)
    t.eq(built.round, 2)
    t.eq(built.angle_lane, "teleology")
    t.eq(built.dedup_key, "convergence:consensus:proposal-42:g7:r2:teleology")
    t.eq(built.version, nil)
    t.eq(built.source_ref, nil)
  end,

  test_convergence_identity_defaults_are_explicit_not_hidden_in_dedup_key = function()
    local built = identity.from_proposal("consensus", proposal(), { angle_lane = "parsimony" })

    t.eq(built.generation, 0)
    t.eq(built.round, 0)
    t.eq(built.angle_lane, "parsimony")
    t.eq(built.dedup_key, "convergence:consensus:proposal-42:g0:r0:parsimony")
  end,

  test_live_run_active_matches_running_identity_only = function()
    local teleology = identity.from_proposal("consensus", proposal(), { angle_lane = "teleology" })
    local parsimony = identity.from_proposal("consensus", proposal(), { angle_lane = "parsimony" })
    with_codex_runs({
      { role = teleology.role, proposal_id = teleology.proposal_id, dedup_key = teleology.dedup_key, status = "running" },
      { role = "consensus", proposal_id = "proposal-99", dedup_key = teleology.dedup_key, status = "running" },
      { role = "fix", proposal_id = "proposal-42", dedup_key = teleology.dedup_key, status = "running" },
      { role = "consensus", proposal_id = "proposal-42", dedup_key = "malformed-missing-status" },
    }, function()
      t.eq(workflow_codex.live_run_active(teleology), true)
      t.eq(workflow_codex.live_run_active(parsimony), false)
      t.eq(workflow_codex.live_run_active("consensus", "proposal-42", "missing"), false)
      t.eq(workflow_codex.live_run_active("fix", "proposal-99", teleology.dedup_key), false)
      t.eq(workflow_codex.live_run_active("consensus", "proposal-42", "malformed-missing-status"), false)
    end)
  end,

  test_workflow_dispatch_sets_identity_fields_and_defers_without_spawn = function()
    local run_identity = library_run_identity(proposal(), "teleology")
    with_codex_runs({
      { role = run_identity.role, proposal_id = run_identity.invocation_id, dedup_key = run_identity.dedup_key, status = "running" },
    }, function()
      local result = workflow_codex.dispatch(run_identity, { prompt = "hello", worktree = "/tmp/worktree" })
      t.eq(result.deferred, true)
      t.eq(result.reason, "live-run-active")
      t.eq(#codex_calls(), 0)
    end)
  end,

  test_consensus_reach_returns_nil_when_same_identity_is_live = function()
    local run_identity = library_run_identity(proposal(), "teleology")
    with_codex_runs({ running_codex_record(run_identity) }, function()
      t.is_nil(consensus.reach(proposal()))
      t.eq(#codex_calls(), 0)
    end)
  end,

  test_workflow_dispatch_resolves_consensus_default_timeout = function()
    with_dispatch_fakes(nil, function(calls)
      local result = workflow_codex.dispatch(dispatch_identity(), { prompt = "hello", worktree = "/tmp/worktree" })

      t.eq(result.kind, "async")
      t.eq(#calls, 1)
      t.eq(calls[1].opts.timeout, 3600)
      t.eq(calls[1].opts.role, "consensus")
      t.eq(calls[1].opts.proposal_id, "proposal-42")
      t.eq(calls[1].opts.dedup_key, "dedup-42")
    end)
  end,

  test_workflow_dispatch_carries_launcher_resolved_repository_locations = function()
    with_dispatch_fakes({
      FKST_CODEX_REPOSITORY_ROOTS = "/srv/host-repository\n/srv/platform-repository\n",
    }, function(calls)
      workflow_codex.dispatch(dispatch_identity(), { prompt = "original prompt", worktree = "/tmp/worktree" })

      t.eq(#calls, 1)
      local prompt = calls[1].opts.prompt
      t.is_true(prompt:find("Repository locations resolved by the launcher:", 1, true) ~= nil)
      t.is_true(prompt:find("- active worktree: /tmp/worktree", 1, true) ~= nil)
      t.is_true(prompt:find("- repository root: /srv/host-repository", 1, true) ~= nil)
      t.is_true(prompt:find("- repository root: /srv/platform-repository", 1, true) ~= nil)
      t.is_true(prompt:find("Do not run `find`, `fd`, `locate`, or recursive directory walks to discover repository locations.", 1, true) ~= nil)
      t.is_true(prompt:find("original prompt", 1, true) ~= nil)
    end)
  end,

  test_workflow_dispatch_maps_source_agnostic_invocation_identity = function()
    local run_identity = {
      role = "consensus",
      invocation_id = "consensus-call-42",
      dedup_key = "dedup-42",
    }
    with_dispatch_fakes(nil, function(calls)
      local result = workflow_codex.dispatch(run_identity, { prompt = "hello", worktree = "/tmp/worktree" })

      t.eq(result.kind, "async")
      t.eq(run_identity.proposal_id, nil)
      t.eq(#calls, 1)
      t.eq(calls[1].opts.proposal_id, "consensus-call-42")
      t.eq(calls[1].opts.dedup_key, "dedup-42")
    end)
  end,

  test_workflow_dispatch_resolves_production_role_defaults = function()
    local expected = {
      implement = 18000,
      fix = 18000,
      ["review-meta"] = 3600,
    }
    for role, timeout in pairs(expected) do
      with_dispatch_fakes({}, function(calls)
        workflow_codex.dispatch({
          role = role,
          proposal_id = "proposal-" .. role,
          dedup_key = "dedup-" .. role,
        }, { prompt = "hello" })

        t.eq(#calls, 1)
        t.eq(calls[1].opts.timeout, timeout)
        t.eq(calls[1].opts.role, role)
      end)
    end
  end,

  test_workflow_raw_resolver_defaults_for_direct_production_roles = function()
    local expected = {
      archaudit = 3600,
      ["release-notes"] = 3600,
      judgment = 3600,
      decompose = 3600,
      intake = 3600,
      ["workflow-select"] = 3600,
      ["workflow-materialize"] = 3600,
      ["sync-conflict"] = 3600,
    }
    with_timeout_env({}, function()
      for role, timeout in pairs(expected) do
        local opts = workflow_codex.with_resolved_timeout(role, { prompt = "hello" })
        t.eq(opts.timeout, timeout)
      end
    end)
  end,

  test_workflow_raw_resolver_carries_launcher_resolved_repository_locations = function()
    with_timeout_env({
      FKST_CODEX_REPOSITORY_ROOTS = "/srv/host-repository\n/srv/platform-repository\n",
    }, function()
      local opts = workflow_codex.with_resolved_timeout("intake", {
        prompt = "original prompt",
        worktree = "/tmp/worktree",
      })

      t.is_true(opts.prompt:find("- active worktree: /tmp/worktree", 1, true) ~= nil)
      t.is_true(opts.prompt:find("- repository root: /srv/host-repository", 1, true) ~= nil)
      t.is_true(opts.prompt:find("- repository root: /srv/platform-repository", 1, true) ~= nil)
      t.is_true(opts.prompt:find("Do not run `find`, `fd`, `locate`, or recursive directory walks to discover repository locations.", 1, true) ~= nil)
      t.is_true(opts.prompt:find("original prompt", 1, true) ~= nil)
    end)
  end,

  test_workflow_raw_resolver_env_overrides_added_roles = function()
    local overrides = {
      FKST_CODEX_TIMEOUT_IMPLEMENT = "1234",
      FKST_CODEX_TIMEOUT_ARCHAUDIT = "2345",
      FKST_CODEX_TIMEOUT_RELEASE_NOTES = "3456",
      FKST_CODEX_TIMEOUT_JUDGMENT = "4567",
    }
    with_timeout_env(overrides, function()
      for role, env_name in pairs(role_timeout_env) do
        if overrides[env_name] ~= nil then
          local opts = workflow_codex.with_resolved_timeout(role, { prompt = "hello" })
          t.eq(opts.timeout, tonumber(overrides[env_name]))
        end
      end
    end)
  end,

  test_workflow_dispatch_uses_consensus_timeout_env_override = function()
    with_dispatch_fakes("1234", function(calls)
      local result = workflow_codex.dispatch(dispatch_identity(), { sync = true, prompt = "hello" })

      t.eq(result.kind, "sync")
      t.eq(#calls, 1)
      t.eq(calls[1].opts.timeout, 1234)
      t.eq(calls[1].opts.sync, nil)
    end)
  end,

  test_workflow_dispatch_invalid_consensus_timeout_env_fails_closed = function()
    with_dispatch_fakes("12x", function(calls)
      local ok, err = pcall(function()
        workflow_codex.dispatch(dispatch_identity(), { prompt = "hello" })
      end)

      t.eq(ok, false)
      t.is_true(tostring(err):find("invalid FKST_CODEX_TIMEOUT_CONSENSUS", 1, true) ~= nil)
      t.eq(#calls, 0)
    end)
  end,

  test_workflow_dispatch_invalid_non_consensus_timeout_env_fails_closed = function()
    with_dispatch_fakes({ FKST_CODEX_TIMEOUT_IMPLEMENT = "0" }, function(calls)
      local ok, err = pcall(function()
        workflow_codex.dispatch({
          role = "implement",
          proposal_id = "proposal-42",
          dedup_key = "dedup-42",
        }, { prompt = "hello" })
      end)

      t.eq(ok, false)
      t.is_true(tostring(err):find("invalid FKST_CODEX_TIMEOUT_IMPLEMENT", 1, true) ~= nil)
      t.eq(#calls, 0)
    end)
  end,

  test_workflow_dispatch_unknown_role_with_explicit_timeout_fails_closed = function()
    with_dispatch_fakes({}, function(calls)
      local ok, err = pcall(function()
        workflow_codex.dispatch({
          role = "unknown-role",
          proposal_id = "proposal-42",
          dedup_key = "dedup-42",
        }, { prompt = "hello", timeout = 77 })
      end)

      t.eq(ok, false)
      t.is_true(tostring(err):find("unknown timeout role: unknown-role", 1, true) ~= nil)
      t.eq(#calls, 0)
    end)
  end,

  test_workflow_raw_resolver_unknown_role_with_explicit_timeout_fails_closed = function()
    with_timeout_env({}, function()
      local ok, err = pcall(function()
        workflow_codex.with_resolved_timeout("unknown-role", { prompt = "hello", timeout = 77 })
      end)

      t.eq(ok, false)
      t.is_true(tostring(err):find("unknown timeout role: unknown-role", 1, true) ~= nil)
    end)
  end,

  test_workflow_dispatch_explicit_timeout_wins_over_non_consensus_env_override = function()
    with_dispatch_fakes({ FKST_CODEX_TIMEOUT_IMPLEMENT = "1234" }, function(calls)
      workflow_codex.dispatch({
        role = "implement",
        proposal_id = "proposal-42",
        dedup_key = "dedup-42",
      }, { prompt = "hello", timeout = 77 })

      t.eq(#calls, 1)
      t.eq(calls[1].opts.timeout, 77)
    end)
  end,

  test_workflow_dispatch_explicit_timeout_wins_over_consensus_env_override = function()
    with_dispatch_fakes("1234", function(calls)
      workflow_codex.dispatch(dispatch_identity(), { prompt = "hello", timeout = 77 })

      t.eq(#calls, 1)
      t.eq(calls[1].opts.timeout, 77)
    end)
  end,

  test_consensus_decide_dispatches_when_no_live_run_exists = function()
    mock_judgment_runtime()
    mock_angle("teleology", "approve", "Teleology approves.")
    mock_angle("parsimony", "approve", "Parsimony approves.")
    mock_angle("fidelity", "approve", "Fidelity approves.")

    with_codex_runs({}, function()
      local result = run_decide(proposal(), opts("no-live-run"))
      t.eq(result.exit_code, 0)
      t.eq(#codex_calls(), 3)
      t.eq(#result.raises, 1)
      t.eq(result.raises[1].queue, "consensus_reached")
    end)
  end,

  test_consensus_decide_acknowledges_more_than_retry_budget_while_same_proposal_run_is_live = function()
    mock_judgment_runtime()
    local run_opts = opts("matching-live-run")
    local run_identity = library_run_identity(proposal(), "teleology")
    local release_codex_run = testing.seed_running_codex_status(
      run_opts, running_codex_record(run_identity)
    )

    for _ = 1, 13 do
      local result = run_decide(proposal(), run_opts)
      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 0)
    end
    release_codex_run()
    t.eq(#codex_calls(), 0)
  end,

  test_live_run_drop_preserves_fresh_redrive_after_run_disappears = function()
    mock_judgment_runtime()
    mock_angle("teleology", "approve", "Teleology approves.")
    mock_angle("parsimony", "approve", "Parsimony approves.")
    mock_angle("fidelity", "approve", "Fidelity approves.")

    local run_opts = opts("defer-then-redrive")
    local run_identity = library_run_identity(proposal(), "teleology")
    local release_codex_run = testing.seed_running_codex_status(
      run_opts, running_codex_record(run_identity)
    )
    local deferred = run_decide(proposal(), run_opts)
    t.eq(deferred.exit_code, 0)
    t.eq(#deferred.raises, 0)
    t.eq(#codex_calls(), 0)
    release_codex_run()

    local retried = run_decide(proposal(), opts("redrive-after-live-run-missing"))
    t.eq(retried.exit_code, 0)
    t.eq(#codex_calls(), 3)
    t.eq(#retried.raises, 1)
    t.eq(retried.raises[1].queue, "consensus_reached")
  end,
}
