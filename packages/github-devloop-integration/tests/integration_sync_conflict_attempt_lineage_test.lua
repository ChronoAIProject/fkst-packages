local git_fake = require("forge.git_fake")
local github_fake = require("forge.github_fake")
local testing = require("testkit_internal.testing")
local sync_conflict = require("departments.sync_conflict.main")
local h = require("tests.devloop_helpers")

local t = h.t
local core = h.core

local REPO = "owner/repo"
local UPSTREAM_BRANCH = "dev"
local INTEGRATION_BRANCH = "integration/dev"
local INTEGRATION_SHA = "1111111111111111111111111111111111111111"
local TREE_SHA = "2222222222222222222222222222222222222222"

local function conflict_event(overrides)
  local event = {
    schema = "github-devloop.v1",
    repo = REPO,
    upstream_branch = UPSTREAM_BRANCH,
    integration_branch = INTEGRATION_BRANCH,
    upstream_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    integration_sha = INTEGRATION_SHA,
    dedup_key = core.branch_sync_dedup_key(
      REPO,
      UPSTREAM_BRANCH,
      INTEGRATION_BRANCH,
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ),
    source_ref = core.branch_sync_source_ref(REPO, UPSTREAM_BRANCH, INTEGRATION_BRANCH),
  }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function success(stdout)
  return { stdout = stdout or "", stderr = "", exit_code = 0 }
end

local function record(model, kind, fields)
  local row = fields or {}
  row.kind = kind
  table.insert(model.writes, row)
end

local function new_model()
  local model = git_fake.model({})
  model.codex_calls = 0
  model.commit_serial = 100
  model.objects = {}
  model.ref_heads = {}
  return model
end

local function ledger_for(model, conflict)
  local ref = core.sync_conflict_attempt_ref(conflict)
  local sha = model.ref_heads[ref]
  if sha == nil then
    return nil
  end
  return core.decode_sync_conflict_attempt_ledger(model.objects[sha].body, conflict)
end

local function make_git(model, conflict, remaining_unmerged)
  local git = git_fake.new(model)
  local unmerged_reads = 0

  function git.fetch_branch(remote, branch, timeout)
    record(model, "fetch_branch", { remote = remote, branch = branch, timeout = timeout })
    return success()
  end

  function git.remote_branch_head(_remote, branch, _timeout)
    if branch == conflict.upstream_branch then
      return success(model.upstream_sha .. "\n")
    end
    return success(conflict.integration_sha .. "\n")
  end

  function git.worktree_add_detached(worktree, sha, timeout)
    record(model, "worktree_add", { worktree = worktree, sha = sha, timeout = timeout })
    return success()
  end

  function git.merge_no_ff(worktree, sha, timeout)
    record(model, "merge", { worktree = worktree, sha = sha, timeout = timeout })
    return { stdout = "", stderr = "conflict", exit_code = 1 }
  end

  function git.unmerged_paths()
    unmerged_reads = unmerged_reads + 1
    if unmerged_reads == 1 then
      return success("100644 abcdef 1\tinitial.lua\n")
    end
    return success(remaining_unmerged)
  end

  function git.worktree_remove(worktree, timeout)
    record(model, "worktree_remove", { worktree = worktree, timeout = timeout })
    return success()
  end

  function git.ls_remote_ref(_remote, ref, _timeout)
    t.eq(ref, core.sync_conflict_attempt_ref(conflict))
    local sha = model.ref_heads[ref]
    if sha == nil then
      return success()
    end
    return success(sha .. "\t" .. ref .. "\n")
  end

  function git.fetch_ref()
    return success()
  end

  function git.cat_file_pretty(sha)
    local object = model.objects[sha]
    t.is_true(object ~= nil)
    return success("tree " .. TREE_SHA .. "\n\n" .. object.body .. "\n")
  end

  function git.rev_parse_ref_tree(ref)
    t.eq(ref, conflict.integration_sha)
    return success(TREE_SHA .. "\n")
  end

  function git.commit_tree(tree_sha, parent_sha, message_file)
    t.eq(tree_sha, TREE_SHA)
    local decoded = core.decode_sync_conflict_attempt_ledger(file.read(message_file), conflict)
    t.is_true(decoded ~= nil)
    model.commit_serial = model.commit_serial + 1
    local sha = string.format("%040x", model.commit_serial)
    model.objects[sha] = {
      body = file.read(message_file),
      parent_sha = parent_sha,
    }
    return success(sha .. "\n")
  end

  function git.push_ref_update(_remote, sha, ref, force_with_lease)
    t.eq(ref, core.sync_conflict_attempt_ref(conflict))
    t.is_true(model.objects[sha] ~= nil)
    t.eq(force_with_lease, model.ref_heads[ref] or "")
    model.ref_heads[ref] = sha
    record(model, "push_ref_update", {
      ref = ref,
      sha = sha,
      force_with_lease = force_with_lease,
    })
    if model.lose_push_ack_once == true then
      model.lose_push_ack_once = false
      return { stdout = "", stderr = "connection closed before acknowledgement", exit_code = 1 }
    end
    return success()
  end

  function git.is_ancestor(maybe_ancestor_sha, descendant_sha)
    local sha = descendant_sha
    while sha ~= nil and sha ~= "" do
      if sha == maybe_ancestor_sha then
        return success()
      end
      local object = model.objects[sha]
      sha = object and object.parent_sha or nil
    end
    return { stdout = "", stderr = "", exit_code = 1 }
  end

  return git
end

local function run_unresolved(model, github, conflict, remaining_unmerged, upstream_sha)
  model.upstream_sha = upstream_sha or conflict.upstream_sha
  return testing.run_fake_outcome(sync_conflict.make_department({
    github = github,
    git = make_git(model, conflict, remaining_unmerged),
  }), {
    queue = "devloop_sync_conflict",
    payload = conflict,
  })
end

local function with_runtime(model, fn)
  local previous_env_read = env_read
  local previous_exec_sync = exec_sync
  local previous_spawn_codex_sync = spawn_codex_sync
  local previous_with_lock = with_lock

  local function read_test_env(name)
    if name == "FKST_RUNTIME_ROOT" then
      return "/tmp/fkst-sync-conflict-restart-" .. tostring(model.codex_calls) .. "\n"
    end
    if name == "FKST_GITHUB_WRITE" then
      return "1"
    end
    if name == "FKST_GITHUB_BOT_LOGIN" then
      return "fkst-test-bot"
    end
    if name == "FKST_CODEX_TIMEOUT_SYNC_CONFLICT" then
      return ""
    end
    error("unexpected env_read name: " .. tostring(name))
  end
  if type(previous_env_read) == "function" then
    env_read = read_test_env
  end
  exec_sync = function(spec)
    local command = type(spec) == "table" and tostring(spec.cmd or "") or tostring(spec or "")
    if type(previous_env_read) ~= "function" then
      local env_name = command:match('^printf %%s "%$([A-Z0-9_]+)"$')
      if env_name ~= nil then
        return success(read_test_env(env_name))
      end
    end
    if command:find("mkdir -p", 1, true) ~= nil then
      return success()
    end
    error("unexpected exec_sync command: " .. command)
  end
  spawn_codex_sync = function()
    model.codex_calls = model.codex_calls + 1
    if model.on_codex ~= nil then
      local callback = model.on_codex
      model.on_codex = nil
      callback()
    end
    return success("completed")
  end
  with_lock = function(_key, locked_fn)
    return locked_fn()
  end

  local ok, err = pcall(fn)
  env_read = previous_env_read
  exec_sync = previous_exec_sync
  spawn_codex_sync = previous_spawn_codex_sync
  with_lock = previous_with_lock
  if not ok then
    error(err, 0)
  end
end

local find_raise = require("testkit_internal.raises").find

return {
  test_attempt_lineage_survives_runtime_restart_and_changing_residuals = function()
    local conflict = conflict_event()
    local model = new_model()
    local upstream_heads = {
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccc",
      "dddddddddddddddddddddddddddddddddddddddd",
    }
    local residuals = {
      "100644 aaa 1\tone.lua\n100644 bbb 2\ttwo.lua\n",
      "100644 ccc 1\ttwo.lua\n",
      "100644 ddd 1\tthree.lua\n",
    }

    with_runtime(model, function()
      local github = github_fake.new(github_fake.model({}))
      for attempt = 1, core.max_sync_conflict_attempts() do
        local outcome = run_unresolved(model, github, conflict, residuals[attempt], upstream_heads[attempt])
        if attempt < core.max_sync_conflict_attempts() then
          t.eq(outcome.exit_code, 1)
          t.eq(#outcome.raises, 0)
        else
          t.eq(outcome.exit_code, 0)
          local escalation = find_raise(outcome.raises, "github-proxy.github_issue_create_request")
          t.is_true(escalation ~= nil)
          t.is_true(escalation.payload.body:find("Attempt: 3", 1, true) ~= nil)
          model.escalation_dedup = escalation.payload.dedup_key
        end
        local ledger = ledger_for(model, conflict)
        if ledger == nil then
          error("attempt ledger was not persisted: " .. tostring(outcome.error))
        end
        t.eq(ledger.attempt, attempt)
        t.eq(ledger.lineage, core.sync_conflict_lineage(conflict))
      end

      local replay = run_unresolved(model, github, conflict, residuals[3], upstream_heads[4])
      local replay_escalation = find_raise(replay.raises, "github-proxy.github_issue_create_request")
      t.is_true(replay_escalation ~= nil)
      t.eq(replay_escalation.payload.dedup_key, model.escalation_dedup)
      t.eq(model.codex_calls, core.max_sync_conflict_attempts())
    end)
  end,

  test_delayed_old_generation_completion_cannot_replace_new_generation_ledger = function()
    local old_conflict = conflict_event()
    local new_conflict = conflict_event({
      integration_sha = "3333333333333333333333333333333333333333",
    })
    local model = new_model()

    with_runtime(model, function()
      local github = github_fake.new(github_fake.model({}))
      local first_old = run_unresolved(model, github, old_conflict, "100644 aaa 1\told.lua\n")
      t.eq(first_old.exit_code, 1)
      t.eq(ledger_for(model, old_conflict).attempt, 1)

      local new_outcome
      model.on_codex = function()
        new_outcome = run_unresolved(model, github, new_conflict, "100644 bbb 1\tnew.lua\n")
      end
      local delayed_old = run_unresolved(model, github, old_conflict, "100644 ccc 1\told-again.lua\n")

      t.eq(new_outcome.exit_code, 1)
      t.eq(delayed_old.exit_code, 1)
      t.is_true(core.sync_conflict_attempt_ref(old_conflict) ~= core.sync_conflict_attempt_ref(new_conflict))
      t.eq(ledger_for(model, new_conflict).attempt, 1)
      t.eq(ledger_for(model, old_conflict).attempt, 2)
    end)
  end,

  test_lost_push_acknowledgement_does_not_count_one_codex_run_twice = function()
    local conflict = conflict_event()
    local model = new_model()
    model.lose_push_ack_once = true

    with_runtime(model, function()
      local github = github_fake.new(github_fake.model({}))
      local outcome = run_unresolved(model, github, conflict, "100644 aaa 1\tone.lua\n")

      t.eq(outcome.exit_code, 1)
      t.eq(ledger_for(model, conflict).attempt, 1)
      t.eq(model.codex_calls, 1)
    end)
  end,
}
