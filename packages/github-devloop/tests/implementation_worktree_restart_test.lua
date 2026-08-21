local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local harvest = require("departments.implement.harvest")
local result_checkpoint = require("departments.implement.result_checkpoint")
local worktree_lifecycle = require("departments.implement.worktree")
local h = require("tests.devloop_helpers")
local t = h.t

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_command(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok = handle:close()
  if ok == false or ok == nil then
    error("implementation worktree restart fixture command failed: "
      .. tostring(command) .. "\n" .. tostring(output))
  end
  return output
end

local function run_command(command)
  read_command(command)
end

local function assert_error_contains(fn, expected)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(expected, 1, true) ~= nil,
    "expected error containing " .. expected .. ", got: " .. tostring(err))
end

local function remove_fixture(root)
  local tmp_prefix = "/tmp/fkst-implementation-worktree-restart."
  local private_tmp_prefix = "/private/tmp/fkst-implementation-worktree-restart."
  if root:sub(1, #tmp_prefix) ~= tmp_prefix
    and root:sub(1, #private_tmp_prefix) ~= private_tmp_prefix then
    error("refusing to remove unexpected fixture root: " .. tostring(root))
  end
  run_command("rm -rf " .. shell_quote(root))
end

local function implementation_worktree_path(durable_root, event)
  local implementation_root = devloop_base.implementation_worktree_root(durable_root)
  return devloop_base.implement_worktree_path(
    implementation_root,
    "owner/repo",
    42,
    event.dedup_key
  )
end

local function implementation_lock_key(event)
  return devloop_base.implement_lock_key(event.proposal_id)
end

local function worktree_outcome(worktree)
  local event = h.ready()
  local branch = h.deterministic_branch_for(event)
  return harvest.after_codex_success(
    "owner/repo",
    42,
    event,
    "dev",
    branch,
    "abc123",
    worktree,
    1,
    now() - 60,
    "implement/exec/restart-survival",
    "1111111111111111111111111111111111111111"
  )
end

return {
  test_integration_merge_reports_clean_without_probing_unmerged_paths = function()
    t.mock_command("merge --no-edit", {
      stdout = "Already up to date.\n",
      stderr = "",
      exit_code = 0,
    })
    local probes = 0
    local git = {
      unmerged_paths = function()
        probes = probes + 1
        return { stdout = "", stderr = "", exit_code = 0 }
      end,
    }

    local clean = worktree_lifecycle.merge_integration(
      git, "/tmp/fkst-implement-merge-clean", "dev", "abc123")

    t.eq(clean, true)
    t.eq(probes, 0)
  end,

  test_integration_merge_reports_conflict_when_unmerged_paths_exist = function()
    t.mock_command("merge --no-edit", {
      stdout = "",
      stderr = "CONFLICT (content): merge conflict in main.lua\n",
      exit_code = 1,
    })
    local git = {
      unmerged_paths = function(worktree, timeout)
        t.eq(worktree, "/tmp/fkst-implement-merge-conflict")
        t.eq(timeout, 30)
        return { stdout = "main.lua\n", stderr = "", exit_code = 0 }
      end,
    }

    local clean = worktree_lifecycle.merge_integration(
      git, "/tmp/fkst-implement-merge-conflict", "dev", "abc123")

    t.eq(clean, false)
  end,

  test_integration_merge_fails_closed_when_unmerged_paths_cannot_be_read = function()
    t.mock_command("merge --no-edit", {
      stdout = "",
      stderr = "merge failed\n",
      exit_code = 1,
    })
    local git = {
      unmerged_paths = function()
        return { stdout = "", stderr = "index unavailable", exit_code = 2 }
      end,
    }

    assert_error_contains(function()
      worktree_lifecycle.merge_integration(
        git, "/tmp/fkst-implement-merge-probe-failed", "dev", "abc123")
    end, "unmerged-path-check-failed")
  end,

  test_integration_merge_fails_closed_when_failure_has_no_conflicts = function()
    t.mock_command("merge --no-edit", {
      stdout = "",
      stderr = "fatal: refusing to merge unrelated histories\n",
      exit_code = 128,
    })
    local git = {
      unmerged_paths = function()
        return { stdout = "", stderr = "", exit_code = 0 }
      end,
    }

    assert_error_contains(function()
      worktree_lifecycle.merge_integration(
        git, "/tmp/fkst-implement-merge-failed", "dev", "abc123")
    end, "integration-merge-failed")
  end,

  test_durable_root_rejects_leading_and_trailing_newlines_before_trimming = function()
    assert_error_contains(function()
      devloop_base.implementation_worktree_root("\n/tmp/fkst-durable")
    end, "invalid FKST_DURABLE_ROOT")
    assert_error_contains(function()
      devloop_base.implementation_worktree_root("/tmp/fkst-durable\n")
    end, "invalid FKST_DURABLE_ROOT")
  end,

  test_retry_reuses_first_attempt_registered_worktree = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/retry-lineage-durable"
    local event = h.ready()
    local retry = {}
    for key, value in pairs(event) do
      retry[key] = value
    end
    retry.dedup_key = event.dedup_key .. "/reimplement/2"
    retry.impl_retry_attempt = 2
    local branch = h.deterministic_branch_for(event)
    local first_attempt_worktree = implementation_worktree_path(durable_root, event)
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
      stdout = durable_root,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. first_attempt_worktree
        .. "\nHEAD abc123\nbranch refs/heads/" .. branch .. "\n\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("reset --hard", {
      stdout = "HEAD is now at abc123 implementation branch\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("clean -fd", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local worktree = worktree_lifecycle.prepare_worktree(
      "owner/repo", 42, retry, branch, "abc123", nil, implementation_lock_key(retry))

    t.eq(worktree, first_attempt_worktree)
    t.eq(h.count_calls("git worktree remove --force"), 0)
    t.eq(h.count_calls("git worktree add"), 0)
  end,

  test_prepare_fails_closed_when_canonical_path_belongs_to_another_branch = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/path-conflict-durable"
    local event = h.ready()
    local branch = h.deterministic_branch_for(event)
    local worktree = implementation_worktree_path(durable_root, event)
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
      stdout = durable_root,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree
        .. "\nHEAD abc123\nbranch refs/heads/unrelated\n\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree remove --force", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree prune", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree add", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("reset --hard", {
      stdout = "HEAD is now at abc123 implementation branch\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("clean -fd", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    assert_error_contains(function()
      worktree_lifecycle.prepare_worktree(
        "owner/repo", 42, event, branch, "abc123", nil, implementation_lock_key(event))
    end, "worktree-registration-conflict")
    t.eq(h.count_calls("git worktree remove --force"), 0)
  end,

  test_implementation_worktree_survives_runtime_scratch_replacement_and_harvest = function()
    local root = read_command("mktemp -d "
      .. shell_quote("/tmp/fkst-implementation-worktree-restart.XXXXXX")):gsub("%s+$", "")
    root = read_command("cd " .. shell_quote(root) .. " && pwd -P"):gsub("%s+$", "")
    local ok, err = pcall(function()
      local repo = root .. "/repo"
      local runtime_before = root .. "/runtime.1"
      local runtime_after = root .. "/runtime.2"
      local durable_root = root .. "/durable"
      local implementation_root = devloop_base.implementation_worktree_root(durable_root)
      local event = h.ready()
      local branch = h.deterministic_branch_for(event)
      local worktree = devloop_base.implement_worktree_path(
        implementation_root,
        "owner/repo",
        42,
        event.dedup_key
      )

      run_command("git init -b main " .. shell_quote(repo))
      run_command("git -C " .. shell_quote(repo) .. " config user.name " .. shell_quote("FKST Test"))
      run_command("git -C " .. shell_quote(repo) .. " config user.email " .. shell_quote("fkst@example.invalid"))
      file.write(repo .. "/base.txt", "base\n")
      run_command("git -C " .. shell_quote(repo) .. " add base.txt")
      run_command("git -C " .. shell_quote(repo) .. " commit -m " .. shell_quote("base"))
      local base_head = read_command("git -C " .. shell_quote(repo) .. " rev-parse HEAD"):gsub("%s+$", "")
      run_command("mkdir -p " .. shell_quote(runtime_before))
      run_command("mkdir -p " .. shell_quote(implementation_root .. "/worktrees"))
      run_command("git -C " .. shell_quote(repo) .. " worktree add -b "
        .. shell_quote(branch) .. " " .. shell_quote(worktree) .. " HEAD")

      run_command("rmdir " .. shell_quote(runtime_before))
      run_command("git -C " .. shell_quote(repo) .. " worktree prune")
      run_command("mkdir -p " .. shell_quote(runtime_after))
      local porcelain = read_command("git -C " .. shell_quote(repo) .. " worktree list --porcelain")
      t.is_true(porcelain:find("worktree " .. worktree .. "\n", 1, true) ~= nil,
        "stable worktree registration missing after restart simulation: " .. porcelain)

      file.write(worktree .. "/restart-survived.txt", "survived\n")
      run_command("git -C " .. shell_quote(worktree) .. " add restart-survived.txt")
      run_command("git -C " .. shell_quote(worktree) .. " commit -m " .. shell_quote("test: survive restart"))
      local committed_head = read_command("git -C " .. shell_quote(worktree) .. " rev-parse HEAD"):gsub("%s+$", "")
      t.is_true(committed_head ~= base_head,
        "commit through surviving worktree did not advance HEAD")
      porcelain = read_command("git -C " .. shell_quote(repo) .. " worktree list --porcelain")

      t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("git worktree list --porcelain", {
        stdout = porcelain,
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
        stdout = "tests passed\n",
        stderr = "FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE\n",
        exit_code = 0,
      })
      local outcome = harvest.after_codex_success(
        "owner/repo", 42, event, "dev", branch, base_head, worktree,
        1, now() - 60, "implement/exec/restart-survival", committed_head)
      t.eq(outcome.kind, "implementing")
      t.eq(outcome.worktree, worktree)
      t.eq(outcome.head_sha, committed_head)
    end)
    remove_fixture(root)
    if not ok then
      error(err)
    end
  end,

  test_completed_result_reconcile_preserves_work_and_reseals_merged_head = function()
    local root = read_command("mktemp -d "
      .. shell_quote("/tmp/fkst-implementation-worktree-restart.XXXXXX")):gsub("%s+$", "")
    root = read_command("cd " .. shell_quote(root) .. " && pwd -P"):gsub("%s+$", "")
    local ok, err = pcall(function()
      local repo = root .. "/repo"
      local worktree = root .. "/implementation"
      local version = "ready/consensus/github-devloop/issue/owner/repo/42/intake/123"

      run_command("git init -b main " .. shell_quote(repo))
      run_command("git -C " .. shell_quote(repo) .. " config user.name " .. shell_quote("FKST Test"))
      run_command("git -C " .. shell_quote(repo) .. " config user.email " .. shell_quote("fkst@example.invalid"))
      file.write(repo .. "/base.txt", "base B0\n")
      run_command("git -C " .. shell_quote(repo) .. " add base.txt")
      run_command("git -C " .. shell_quote(repo) .. " commit -m " .. shell_quote("base B0"))
      run_command("git -C " .. shell_quote(repo) .. " worktree add -b implementation "
        .. shell_quote(worktree) .. " HEAD")

      file.write(worktree .. "/completed.txt", "completed work\n")
      run_command("git -C " .. shell_quote(worktree) .. " add completed.txt")
      run_command("git -C " .. shell_quote(worktree) .. " commit -m " .. shell_quote("completed work"))
      run_command("git -C " .. shell_quote(worktree) .. " commit --allow-empty -m "
        .. shell_quote(result_checkpoint.subject(version)))
      local original_receipt = read_command("git -C " .. shell_quote(worktree)
        .. " rev-parse HEAD"):gsub("%s+$", "")

      file.write(repo .. "/base-b1.txt", "base B1\n")
      run_command("git -C " .. shell_quote(repo) .. " add base-b1.txt")
      run_command("git -C " .. shell_quote(repo) .. " commit -m " .. shell_quote("base B1"))
      local base_b1 = read_command("git -C " .. shell_quote(repo) .. " rev-parse HEAD"):gsub("%s+$", "")
      run_command("git -C " .. shell_quote(worktree) .. " merge --no-edit " .. shell_quote(base_b1))

      t.eq(read_command("git -C " .. shell_quote(worktree) .. " show HEAD:completed.txt"), "completed work\n")
      t.eq(read_command("git -C " .. shell_quote(worktree) .. " show HEAD:base-b1.txt"), "base B1\n")
      local git = {
        git_head_sha = function(path)
          return {
            stdout = read_command("git -C " .. shell_quote(path) .. " rev-parse HEAD"),
            stderr = "",
            exit_code = 0,
          }
        end,
        git_empty_commit = function(path, message)
          run_command("git -C " .. shell_quote(path) .. " commit --allow-empty -m " .. shell_quote(message))
          return { stdout = "", stderr = "", exit_code = 0 }
        end,
        is_ancestor = function(ancestor, descendant)
          run_command("git -C " .. shell_quote(worktree) .. " merge-base --is-ancestor "
            .. shell_quote(ancestor) .. " " .. shell_quote(descendant))
          return { stdout = "", stderr = "", exit_code = 0 }
        end,
      }
      local resealed = result_checkpoint.reseal(git, worktree, {
        branch = "implementation",
        base_branch = "main",
        head_sha = original_receipt,
      }, version)

      t.is_true(resealed.head_sha ~= original_receipt)
      run_command("git -C " .. shell_quote(worktree) .. " merge-base --is-ancestor "
        .. shell_quote(original_receipt) .. " " .. shell_quote(resealed.head_sha))
      local subject = read_command("git -C " .. shell_quote(worktree)
        .. " show -s --format=%s " .. shell_quote(resealed.head_sha)):gsub("%s+$", "")
      t.eq(subject, result_checkpoint.subject(version))
    end)
    remove_fixture(root)
    if not ok then
      error(err)
    end
  end,

  test_missing_worktree_is_typed_and_nonterminal_before_local_verification = function()
    local missing = "/tmp/fkst-packages-test/github-devloop/missing-worktree"
    t.mock_command("[ -d " .. shell_quote(missing) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })

    local outcome = worktree_outcome(missing)
    t.eq(outcome.kind, "worktree-missing")
    t.eq(outcome.reason, "worktree-missing")
    t.eq(outcome.terminal, false)
    t.eq(outcome.outcome, "retry: worktree-missing")
    t.eq(h.count_calls("scripts/run.sh test-affected"), 0)
  end,

  test_unregistered_worktree_husk_is_typed_and_nonterminal_before_local_verification = function()
    local husk = "/tmp/fkst-packages-test/github-devloop/unregistered-worktree-husk"
    t.mock_command("[ -d " .. shell_quote(husk) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree /tmp/fkst-packages-test/github-devloop/main\nHEAD abc123\nbranch refs/heads/dev\n\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
      stdout = "tests passed\n",
      stderr = "",
      exit_code = 0,
    })

    local outcome = worktree_outcome(husk)
    t.eq(outcome.kind, "worktree-unregistered")
    t.eq(outcome.reason, "worktree-unregistered")
    t.eq(outcome.terminal, false)
    t.eq(outcome.outcome, "retry: worktree-unregistered")
    t.eq(h.count_calls("scripts/run.sh test-affected"), 0)
  end,

  test_worktree_registered_to_wrong_branch_is_typed_and_nonterminal = function()
    local worktree = "/tmp/fkst-packages-test/github-devloop/wrong-branch-worktree"
    t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree
        .. "\nHEAD abc123\nbranch refs/heads/devloop/issue/owner/repo/42/wrong-version\n\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
      stdout = "tests passed\n",
      stderr = "",
      exit_code = 0,
    })

    local outcome = worktree_outcome(worktree)
    t.eq(outcome.kind, "worktree-unregistered")
    t.eq(outcome.reason, "worktree-unregistered")
    t.eq(outcome.terminal, false)
    t.eq(h.count_calls("scripts/run.sh test-affected"), 0)
  end,

  test_worktree_lost_at_cd_boundary_is_typed_and_nonterminal = function()
    local worktree = "/tmp/fkst-packages-test/github-devloop/cd-race-worktree"
    local event = h.ready()
    local branch = h.deterministic_branch_for(event)
    t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree .. "\nHEAD abc123\nbranch refs/heads/" .. branch .. "\n\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
      stdout = "",
      stderr = "FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:MISSING\n",
      exit_code = 1,
    })
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
      stdout = "",
      stderr = "FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:MISSING\n",
      exit_code = 1,
    })

    local outcome = worktree_outcome(worktree)
    t.eq(outcome.kind, "worktree-missing")
    t.eq(outcome.reason, "worktree-missing")
    t.eq(outcome.terminal, false)
    t.eq(outcome.outcome, "retry: worktree-missing")
  end,

  test_candidate_output_cannot_spoof_worktree_missing = function()
    local worktree = "/tmp/fkst-packages-test/github-devloop/spoofed-worktree-marker"
    local event = h.ready()
    local branch = h.deterministic_branch_for(event)
    t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree .. "\nHEAD abc123\nbranch refs/heads/" .. branch .. "\n\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
      stdout = "FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:MISSING\n",
      stderr = "FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED\n"
        .. "FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE\n",
      exit_code = 0,
    })

    local outcome = worktree_outcome(worktree)
    t.eq(outcome.kind, "implementing")
  end,

  test_local_iteration_wrapper_reprobes_absence_before_missing_marker = function()
    local worktree = "/tmp/fkst-packages-test/github-devloop/nonmissing-cd-failure"
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
      stdout = "",
      stderr = "cd failed without directory absence",
      exit_code = 1,
    })

    harvest.local_iteration_check(worktree, "abc123")
    local rendered = nil
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find("scripts/run.sh test-affected", 1, true) ~= nil then
        rendered = tostring(call.rendered)
      end
    end
    t.is_true(rendered ~= nil)
    t.is_true(rendered:find("[ ! -d " .. shell_quote(worktree) .. " ]", 1, true) ~= nil)
    t.is_true(rendered:find("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", 1, true) ~= nil)
  end,

  test_review_worktree_lookup_rejects_unregistered_husk = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/review-husk-durable"
    local event = h.ready()
    local worktree = implementation_worktree_path(durable_root, event)
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
      stdout = durable_root,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree /tmp/fkst-packages-test/github-devloop/main\nHEAD abc123\nbranch refs/heads/dev\n\n",
      stderr = "",
      exit_code = 0,
    })

    t.is_nil(devloop_commands.existing_implementation_worktree(
      "owner/repo",
      42,
      event.dedup_key,
      h.deterministic_branch_for(event)
    ))
  end,

  test_review_worktree_lookup_rejects_wrong_branch_registration = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/review-wrong-branch-durable"
    local event = h.ready()
    local worktree = implementation_worktree_path(durable_root, event)
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
      stdout = durable_root,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree .. "\nHEAD abc123\nbranch refs/heads/unrelated\n\n",
      stderr = "",
      exit_code = 0,
    })

    t.is_nil(devloop_commands.existing_implementation_worktree(
      "owner/repo",
      42,
      event.dedup_key,
      h.deterministic_branch_for(event)
    ))
  end,

  test_review_worktree_lookup_accepts_authoritative_retry_branch = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/review-retry-branch-durable"
    local event = h.ready()
    local impl_version = event.dedup_key .. "/reimplement/2"
    local branch = h.deterministic_branch_for(event)
    local worktree = implementation_worktree_path(durable_root, event)
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
      stdout = durable_root,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree .. "\nHEAD abc123\nbranch refs/heads/" .. branch .. "\n\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    t.eq(devloop_commands.existing_implementation_worktree(
      "owner/repo", 42, impl_version, branch), worktree)
  end,

  test_review_worktree_lookup_surfaces_empty_durable_root = function()
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    assert_error_contains(function()
      local event = h.ready()
      devloop_commands.existing_implementation_worktree(
        "owner/repo", 42, event.dedup_key, h.deterministic_branch_for(event))
    end, "durable-root-invalid")
  end,

  test_review_worktree_lookup_surfaces_registration_probe_failure = function()
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop/review-probe-durable",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "",
      stderr = "git metadata unavailable",
      exit_code = 1,
    })

    assert_error_contains(function()
      local event = h.ready()
      devloop_commands.existing_implementation_worktree(
        "owner/repo", 42, event.dedup_key, h.deterministic_branch_for(event))
    end, "worktree-list-failed")
  end,

  test_review_worktree_lookup_surfaces_directory_probe_failure = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/review-directory-probe-durable"
    local event = h.ready()
    local worktree = implementation_worktree_path(durable_root, event)
    local branch = h.deterministic_branch_for(event)
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
      stdout = durable_root,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree .. "\nHEAD abc123\nbranch refs/heads/" .. branch .. "\n\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
      stdout = "",
      stderr = "filesystem unavailable",
      exit_code = 2,
    })

    assert_error_contains(function()
      devloop_commands.existing_implementation_worktree(
        "owner/repo", 42, event.dedup_key, h.deterministic_branch_for(event))
    end, "worktree-path-check-failed")
  end,
}
