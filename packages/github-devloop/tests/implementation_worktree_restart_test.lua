local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local harvest = require("departments.implement.harvest")
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

local function remove_fixture(root)
  local tmp_prefix = "/tmp/fkst-implementation-worktree-restart."
  local private_tmp_prefix = "/private/tmp/fkst-implementation-worktree-restart."
  if root:sub(1, #tmp_prefix) ~= tmp_prefix
    and root:sub(1, #private_tmp_prefix) ~= private_tmp_prefix then
    error("refusing to remove unexpected fixture root: " .. tostring(root))
  end
  run_command("rm -rf " .. shell_quote(root))
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
      t.mock_command("scripts/run.sh test-affected", {
        stdout = "tests passed\n",
        stderr = "",
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
    t.mock_command("scripts/run.sh test-affected", {
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

  test_review_worktree_lookup_rejects_unregistered_husk = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/review-husk-durable"
    local event = h.ready()
    local implementation_root = devloop_base.implementation_worktree_root(durable_root)
    local worktree = devloop_base.implement_worktree_path(
      implementation_root,
      "owner/repo",
      42,
      event.dedup_key
    )
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
      event.dedup_key
    ))
  end,
}
