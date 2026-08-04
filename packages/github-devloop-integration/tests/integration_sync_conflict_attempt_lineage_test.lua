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

local function conflict_event()
  return {
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
end

local function success(stdout)
  return { stdout = stdout or "", stderr = "", exit_code = 0 }
end

local function record(model, kind, fields)
  local row = fields or {}
  row.kind = kind
  table.insert(model.writes, row)
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
      return success(model.upstream_heads[model.run] .. "\n")
    end
    return success(conflict.integration_sha .. "\n")
  end

  function git.is_ancestor()
    return { stdout = "", stderr = "", exit_code = 1 }
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
    if model.ledger_sha == nil then
      return success()
    end
    return success(model.ledger_sha .. "\t" .. ref .. "\n")
  end

  function git.fetch_ref()
    return success()
  end

  function git.cat_file_pretty(sha)
    t.eq(sha, model.ledger_sha)
    return success("tree " .. TREE_SHA .. "\n\n" .. model.ledger_body .. "\n")
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
    model.pending_ledger = {
      body = file.read(message_file),
      parent_sha = parent_sha,
      sha = sha,
    }
    return success(sha .. "\n")
  end

  function git.push_ref_update(_remote, sha, ref, force_with_lease)
    t.eq(ref, core.sync_conflict_attempt_ref(conflict))
    t.eq(sha, model.pending_ledger.sha)
    t.eq(force_with_lease, model.ledger_sha or "")
    model.ledger_sha = sha
    model.ledger_body = model.pending_ledger.body
    record(model, "push_ref_update", {
      ref = ref,
      sha = sha,
      force_with_lease = force_with_lease,
    })
    return success()
  end

  return git
end

local function find_raise(raises, queue)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      return raised
    end
  end
  return nil
end

return {
  test_attempt_lineage_survives_runtime_restart_and_changing_residuals = function()
    local conflict = conflict_event()
    local model = git_fake.model({})
    model.commit_serial = 100
    model.run = 0
    model.upstream_heads = {
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
    local codex_calls = 0
    local previous_exec_sync = exec_sync
    local previous_spawn_codex_sync = spawn_codex_sync
    local previous_with_lock = with_lock

    exec_sync = function(spec)
      local command = type(spec) == "table" and tostring(spec.cmd or "") or tostring(spec or "")
      if command:find("FKST_RUNTIME_ROOT", 1, true) ~= nil then
        return success("/tmp/fkst-sync-conflict-restart-" .. tostring(model.run) .. "\n")
      end
      if command:find("FKST_GITHUB_WRITE", 1, true) ~= nil then
        return success("1")
      end
      if command:find("FKST_GITHUB_BOT_LOGIN", 1, true) ~= nil then
        return success("fkst-test-bot")
      end
      if command:find("FKST_CODEX_TIMEOUT_SYNC_CONFLICT", 1, true) ~= nil then
        return success("")
      end
      if command:find("mkdir -p", 1, true) ~= nil then
        return success()
      end
      error("unexpected exec_sync command: " .. command)
    end
    spawn_codex_sync = function()
      codex_calls = codex_calls + 1
      return success("completed")
    end
    with_lock = function(_key, fn)
      return fn()
    end

    local ok, err = pcall(function()
      local github = github_fake.new(github_fake.model({}))
      for attempt = 1, core.max_sync_conflict_attempts() do
        model.run = attempt
        local department = sync_conflict.make_department({
          github = github,
          git = make_git(model, conflict, residuals[attempt]),
        })
        local outcome = testing.run_fake_outcome(department, {
          queue = "devloop_sync_conflict",
          payload = conflict,
        })
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
        if model.ledger_body == nil then
          error("attempt ledger was not persisted: " .. tostring(outcome.error))
        end
        local ledger = core.decode_sync_conflict_attempt_ledger(model.ledger_body, conflict)
        t.eq(ledger.attempt, attempt)
        t.eq(ledger.lineage, core.sync_conflict_lineage(conflict))
      end

      model.run = 4
      local replay = testing.run_fake(sync_conflict.make_department({
        github = github,
        git = make_git(model, conflict, residuals[3]),
      }), {
        queue = "devloop_sync_conflict",
        payload = conflict,
      })
      local replay_escalation = find_raise(replay.raises, "github-proxy.github_issue_create_request")
      t.is_true(replay_escalation ~= nil)
      t.eq(replay_escalation.payload.dedup_key, model.escalation_dedup)
      t.eq(codex_calls, core.max_sync_conflict_attempts())
    end)

    exec_sync = previous_exec_sync
    spawn_codex_sync = previous_spawn_codex_sync
    with_lock = previous_with_lock
    if not ok then
      error(err, 0)
    end
  end,
}
