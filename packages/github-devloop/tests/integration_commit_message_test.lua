local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local ready = h.ready
local fixing = h.fixing
local default_marker_version = h.default_marker_version
local mock_issue_implement = h.mock_issue_implement
local mock_issue_fix_for_event = h.mock_issue_fix_for_event
local mock_pr_fix = h.mock_pr_fix
local mock_bot_env = h.mock_bot_env
local mock_write_env = h.mock_write_env
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_commit_title = h.mock_commit_title
local mock_commit_title_failure = h.mock_commit_title_failure
local mock_git_push = h.mock_git_push
local deterministic_branch_for = h.deterministic_branch_for

local function commit_command()
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find("commit -m", 1, true) ~= nil then
      return call.rendered
    end
  end
  return nil
end

local function title_fetch_count()
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if call.rendered == "gh api 'repos/owner/repo/issues/42' --jq '.title'" then
      count = count + 1
    end
  end
  return count
end

local function quoted(value)
  return core._shell_single_quote(value)
end

local function bytes(...)
  return string.char(...)
end

local text_fix = bytes(0xe4, 0xbf, 0xae, 0xe6, 0xad, 0xa3)
local text_title = bytes(0xe6, 0xa0, 0x87, 0xe9, 0xa2, 0x98)
local text_feedback = bytes(0xe5, 0x8f, 0x8d, 0xe9, 0xa6, 0x88)

local function assert_valid_utf8(value)
  t.eq(core._utf8_safe_commit_prefix(value, #value), value)
end

local function mock_commit_finish(new_head, branch)
  t.mock_command("git -C", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("commit -m", {
    stdout = "[" .. tostring(branch) .. " 1234567] commit\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("rev-parse --abbrev-ref HEAD", {
    stdout = tostring(branch) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("rev-parse HEAD", {
    stdout = tostring(new_head or "def456") .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function run_implement_commit(title, title_fails)
  local event = ready()
  local branch = deterministic_branch_for(event)
  mock_issue_implement({ "fkst-dev:ready" }, {
    core.state_marker(event.proposal_id, "ready", default_marker_version),
  })
  mock_fresh_implement_worktree()
  mock_implement_codex()
  mock_git_status(" M packages/github-devloop/departments/implement/main.lua\n")
  if title_fails then
    mock_commit_title_failure("forced title fetch failure")
  else
    mock_commit_title(title)
  end
  mock_commit_finish("def456", branch)

  local result = h.run_implement(event, opts("implement-commit-message"))
  t.eq(result.exit_code, 0)
  return commit_command()
end

local function run_fix_commit(title)
  local event = fixing()
  local branch = core.implement_branch("owner/repo", "42", event.version)
  local reject_comment = core.build_review_result_comment_request(
    "owner/repo",
    "42",
    event.proposal_id,
    event.version,
    {
      proposal_id = event.review_proposal_id,
      decision = "reject",
      body = "Reject because parser must fail closed.",
      dedup_key = event.review_dedup_key,
      blocking_gap = "Parser must fail closed.",
      source_ref = { kind = "external", ref = "owner/repo#pr/7" },
    },
    event.source_ref
  ).body
  local origin_marker = core.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev")
  mock_bot_env()
  mock_write_env("1")
  mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, {
    core.state_marker(event.proposal_id, "fixing", event.version),
    reject_comment,
  }, branch, event.version)
  mock_pr_fix({ origin_marker }, branch, "def456")
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git worktree list --porcelain", {
    stdout = "worktree /tmp/fkst-packages-test/github-devloop/runtime/worktrees/fix-worktree\nHEAD def456\nbranch refs/heads/" .. branch .. "\n\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("[ -d '/tmp/fkst-packages-test/github-devloop/runtime/worktrees/fix-worktree' ]", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  mock_implement_codex(0, "fixed review feedback")
  mock_git_status(" M packages/github-devloop/core.lua\n")
  mock_commit_title(title)
  mock_commit_finish("feedface", branch)
  mock_write_env("1")
  mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, {
    core.state_marker(event.proposal_id, "fixing", event.version),
    reject_comment,
  }, branch, event.version)
  mock_pr_fix({ origin_marker }, branch, "def456")
  mock_git_push(branch)
  mock_pr_fix({ origin_marker }, branch, "feedface")

  local result = h.run_fix(event, opts("fix-commit-message", { FKST_GITHUB_WRITE = "1" }))
  t.eq(result.exit_code, 0)
  return commit_command()
end

return {
  test_implement_commit_message_uses_issue_title_and_shell_quoting = function()
    local title = text_fix .. " John's parser"
    local command = run_implement_commit(title)

    t.is_true(command:find("gh issue view", 1, true) == nil)
    t.is_true(command:find("commit -m " .. quoted("auto-implement #42: " .. title), 1, true) ~= nil)
    t.eq(title_fetch_count(), 1)
  end,

  test_implement_commit_message_falls_back_when_title_fetch_fails = function()
    local command = run_implement_commit("ignored", true)

    t.is_true(command:find("commit -m " .. quoted("auto-implement #42"), 1, true) ~= nil)
    t.eq(title_fetch_count(), 1)
  end,

  test_implement_commit_message_truncates_utf8_safely = function()
    local title = text_title:rep(80)
    local message = core._issue_commit_subject("implement", "42", title)

    t.is_true(#message <= 200)
    assert_valid_utf8(message)
    t.is_true(message:find("auto-implement #42: ", 1, true) == 1)
  end,

  test_fix_commit_message_uses_issue_title = function()
    local title = text_fix .. " review " .. text_feedback
    local command = run_fix_commit(title)

    t.is_true(command:find("commit -m " .. quoted("auto-fix #42: " .. title), 1, true) ~= nil)
  end,
}
