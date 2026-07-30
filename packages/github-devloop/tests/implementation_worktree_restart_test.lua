local devloop_base = require("devloop.base")
local harvest = require("departments.implement.harvest")
local h = require("tests.devloop_helpers")
local t = h.t

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function make_dir(path)
  local ok = os.execute("mkdir -p " .. shell_quote(path))
  if ok ~= true and ok ~= 0 then
    error("github-devloop test mkdir failed: " .. tostring(path))
  end
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
    local root = "/tmp/fkst-packages-test/github-devloop/restart-survival"
    local runtime_before = root .. "/runtime.1"
    local runtime_after = root .. "/runtime.2"
    local durable_root = root .. "/durable"
    local implementation_root = devloop_base.implementation_worktree_root(durable_root)
    local event = h.ready()
    local worktree = devloop_base.implement_worktree_path(
      implementation_root,
      "owner/repo",
      42,
      event.dedup_key
    )

    make_dir(runtime_before)
    make_dir(worktree)
    local removed, remove_error = os.remove(runtime_before)
    t.is_true(removed, remove_error)
    make_dir(runtime_after)
    local present = os.rename(worktree, worktree)
    t.is_true(present)

    t.mock_command("[ -d " .. shell_quote(worktree) .. " ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("scripts/run.sh test-affected", {
      stdout = "tests passed\n",
      stderr = "",
      exit_code = 0,
    })
    local outcome = worktree_outcome(worktree)
    t.eq(outcome.kind, "implementing")
    t.eq(outcome.worktree, worktree)

    os.remove(runtime_after)
    os.remove(worktree)
    os.remove(implementation_root .. "/worktrees")
    os.remove(implementation_root)
    os.remove(root)
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
}
