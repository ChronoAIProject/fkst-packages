local t = fkst.test
local core = require("core")
local gh_argv = require("testkit_internal.gh_argv_mock")
gh_argv.install(t, core)

local current_pin = "cccccccccccccccccccccccccccccccccccccccc"
local target_sha = "1234567890abcdef1234567890abcdef12345678"
local older_valid_pin = "2125600000000000000000000000000000000000"
local base_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local old_branch_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local pr_head_sha = "dddddddddddddddddddddddddddddddddddddddd"
local pr_number = 27
local substrate_repo = "ChronoAIProject/fkst-substrate"

local function opts(name, extra)
  local env = {
    FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop/" .. tostring(now()) .. "/" .. tostring(name),
    FKST_GITHUB_REPO = "owner/repo",
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_GITHUB_WRITE = "",
    FKST_DEVLOOP_UPSTREAM_BRANCH = "dev",
    FKST_DEVLOOP_INTEGRATION_BRANCH = "integration/dev",
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return { env = env }
end

local function run_scan(run_opts)
  return t.run_department("departments/substrate_ref_scan/main.lua", {
    queue = "devloop_substrate_ref_tick",
    payload = { schema = "github-devloop.substrate-ref-tick.v1" },
  }, run_opts or opts("substrate-ref"))
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function ensure_dir(path)
  local ok = os.execute("mkdir -p " .. shell_quote(path))
  if ok ~= true and ok ~= 0 then
    error("github-devloop: test directory setup failed")
  end
end

local function mock_env(write_mode)
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = "dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = "integration/dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 3 do
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = write_mode or "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 3 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_substrate_head(sha)
  t.mock_command("git ls-remote https://github.com/ChronoAIProject/fkst-substrate.git refs/heads/dev", {
    stdout = tostring(sha) .. "\trefs/heads/dev\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git ls-remote 'https://github.com/ChronoAIProject/fkst-substrate.git' 'refs/heads/dev'", {
    stdout = tostring(sha) .. "\trefs/heads/dev\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_substrate_check_runs(sha, status, conclusion)
  local conclusion_json = conclusion == nil and "null" or ('"' .. tostring(conclusion) .. '"')
  t.mock_command(core.gh_commit_check_runs_cmd(substrate_repo, sha), {
    stdout = '{"total_count":4,"check_runs":[{"name":"verify","status":"'
      .. tostring(status)
      .. '","conclusion":'
      .. conclusion_json
      .. '},{"name":"coverage","status":"completed","conclusion":"success"}'
      .. ',{"name":"Analyze (actions)","status":"completed","conclusion":"success"}'
      .. ',{"name":"Analyze (rust)","status":"completed","conclusion":"success"}]}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_substrate_check_runs_green(sha, times)
  for _ = 1, times or 1 do
    mock_substrate_check_runs(sha, "completed", "success")
  end
end

local function mock_current_pin(sha)
  t.mock_command("git show HEAD:.fkst/substrate-ref", {
    stdout = tostring(sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_missing_pin()
  t.mock_command("git show HEAD:.fkst/substrate-ref", {
    stdout = "",
    stderr = "fatal: path '.fkst/substrate-ref' does not exist in 'HEAD'\n",
    exit_code = 128,
  })
end

local function mock_pin_read_failure()
  t.mock_command("git show HEAD:.fkst/substrate-ref", {
    stdout = "",
    stderr = "fatal: bad object HEAD\n",
    exit_code = 128,
  })
end

local function mock_no_existing_pr()
  t.mock_command(core.gh_pr_list_head_cmd("owner/repo", "chore/substrate-ref-bump"), {
    stdout = "[[]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_existing_pr()
  t.mock_command(core.gh_pr_list_head_cmd("owner/repo", "chore/substrate-ref-bump"), {
    stdout = '[[{"number":27,"head":{"ref":"chore/substrate-ref-bump"},"base":{"ref":"dev"}}]]\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_base_head()
  t.mock_command("git fetch origin dev", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify 'refs/remotes/origin/dev^{commit}'", {
    stdout = base_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_bump_branch_base_ancestry(exit_code)
  t.mock_command("git merge-base --is-ancestor " .. base_sha .. " " .. old_branch_sha, {
    stdout = "",
    stderr = "",
    exit_code = exit_code or 0,
  })
end

local function mock_runtime_root(name)
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/" .. tostring(name),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_branch_missing()
  t.mock_command("git fetch origin chore/substrate-ref-bump", {
    stdout = "",
    stderr = "fatal: couldn't find remote ref chore/substrate-ref-bump\n",
    exit_code = 128,
  })
end

local function mock_branch_present()
  t.mock_command("git fetch origin chore/substrate-ref-bump", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify refs/remotes/origin/chore/substrate-ref-bump^{commit}", {
    stdout = old_branch_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify 'refs/remotes/origin/chore/substrate-ref-bump^{commit}'", {
    stdout = old_branch_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git fetch 'origin' 'chore/substrate-ref-bump'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify refs/remotes/'origin'/'chore/substrate-ref-bump'^{commit}", {
    stdout = old_branch_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_branch_present_at(sha)
  t.mock_command("git fetch origin chore/substrate-ref-bump", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify refs/remotes/origin/chore/substrate-ref-bump^{commit}", {
    stdout = tostring(sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify 'refs/remotes/origin/chore/substrate-ref-bump^{commit}'", {
    stdout = tostring(sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git fetch 'origin' 'chore/substrate-ref-bump'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify refs/remotes/'origin'/'chore/substrate-ref-bump'^{commit}", {
    stdout = tostring(sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_branch_pin(sha)
  t.mock_command("git show " .. old_branch_sha .. ":.fkst/substrate-ref", {
    stdout = tostring(sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show '" .. old_branch_sha .. ":.fkst/substrate-ref'", {
    stdout = tostring(sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_branch_pin_for_head(head_sha, pin)
  t.mock_command("git show " .. tostring(head_sha) .. ":.fkst/substrate-ref", {
    stdout = tostring(pin) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show '" .. tostring(head_sha) .. ":.fkst/substrate-ref'", {
    stdout = tostring(pin) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_branch_pin_missing()
  t.mock_command("git show " .. old_branch_sha .. ":.fkst/substrate-ref", {
    stdout = "",
    stderr = "fatal: path '.fkst/substrate-ref' exists on disk, but not in '" .. old_branch_sha .. "'\n",
    exit_code = 128,
  })
  t.mock_command("git show '" .. old_branch_sha .. ":.fkst/substrate-ref'", {
    stdout = "",
    stderr = "fatal: path '.fkst/substrate-ref' exists on disk, but not in '" .. old_branch_sha .. "'\n",
    exit_code = 128,
  })
end

local function mock_no_checked_out_bump_branch()
  t.mock_command("git worktree list --porcelain", {
    stdout = "worktree /repo\nHEAD " .. base_sha .. "\nbranch refs/heads/dev\n\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_checked_out_bump_branch()
  t.mock_command("git worktree list --porcelain", {
    stdout = table.concat({
      "worktree /repo",
      "HEAD " .. base_sha,
      "branch refs/heads/dev",
      "",
      "worktree /tmp/fkst-packages-test/github-devloop/stale-substrate",
      "HEAD " .. old_branch_sha,
      "branch refs/heads/chore/substrate-ref-bump",
      "",
    }, "\n"),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git worktree remove --force /tmp/fkst-packages-test/github-devloop/stale-substrate", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_worktree_commands(runtime_name, push_with_lease, expected_old_sha)
  local worktree = "/tmp/fkst-packages-test/github-devloop/"
    .. tostring(runtime_name)
    .. "/worktrees/substrate-ref-owner-repo-"
    .. target_sha:sub(1, 12)
  ensure_dir(worktree .. "/.fkst")
  t.mock_command("test -d /tmp/fkst-packages-test/github-devloop/", {
    stdout = "",
    stderr = "",
    exit_code = 1,
  })
  t.mock_command("mkdir -p /tmp/fkst-packages-test/github-devloop/", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git worktree add -B chore/substrate-ref-bump", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p /tmp/fkst-packages-test/github-devloop/", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git -C /tmp/fkst-packages-test/github-devloop/", {
    stdout = ".fkst/substrate-ref\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git -C /tmp/fkst-packages-test/github-devloop/", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git -C /tmp/fkst-packages-test/github-devloop/", {
    stdout = "[chore/substrate-ref-bump 5555555] chore: bump fkst-substrate pin\n",
    stderr = "",
    exit_code = 0,
  })
  if push_with_lease then
    t.mock_command("--force-with-lease=refs/heads/chore/substrate-ref-bump:" .. tostring(expected_old_sha or old_branch_sha), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  else
    t.mock_command("git -C ", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(" push origin HEAD:refs/heads/chore/substrate-ref-bump", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command("git worktree remove --force", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_create()
  t.mock_command("gh pr create --repo owner/repo --head chore/substrate-ref-bump --base dev --title 'chore: bump fkst-substrate pin'", {
    stdout = "https://github.com/owner/repo/pull/27\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr create --repo owner/repo --head chore/substrate-ref-bump --base dev --title chore: bump fkst-substrate pin", {
    stdout = "https://github.com/owner/repo/pull/27\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr create --repo 'owner/repo' --head 'chore/substrate-ref-bump' --base 'dev' --title 'chore: bump fkst-substrate pin'", {
    stdout = "https://github.com/owner/repo/pull/27\n",
    stderr = "",
    exit_code = 0,
  })
end

local function json_string(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function render_comment(body)
  return string.format(
    '{"body":"%s","author":{"login":"fkst-test-bot"},"createdAt":"2026-06-16T22:10:00Z"}',
    json_string(body)
  )
end

local function mock_bump_pr_view(comments, extra)
  extra = extra or {}
  local state = extra.state or "OPEN"
  local merged_at = extra.merged_at or ""
  local head_sha = extra.head_sha or pr_head_sha
  local is_draft = extra.is_draft == true and "true" or "false"
  local mergeable = extra.mergeable or "MERGEABLE"
  local merge_state = extra.merge_state or "CLEAN"
  local rollup = extra.rollup or string.format(
    '[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"verification-subject:%s:%s","status":"COMPLETED","conclusion":"SUCCESS"}]',
    base_sha,
    head_sha
  )
  t.mock_command("gh pr view '27' --repo 'owner/repo' --json headRefName,headRefOid,baseRefName,baseRefOid,state,updatedAt,isDraft,mergedAt,comments,headRepository,headRepositoryOwner,isCrossRepository,mergeable,mergeStateStatus,statusCheckRollup", {
    stdout = string.format(
      '{"headRefName":"chore/substrate-ref-bump","headRefOid":"%s","baseRefName":"dev","baseRefOid":"%s","state":"%s","updatedAt":"2026-06-16T22:10:00Z","isDraft":%s,"mergedAt":"%s","comments":[%s],"headRepository":{"nameWithOwner":"owner/repo"},"headRepositoryOwner":{"login":"owner"},"isCrossRepository":false,"mergeable":"%s","mergeStateStatus":"%s","statusCheckRollup":%s}\n',
      head_sha,
      base_sha,
      state,
      is_draft,
      merged_at,
      comments and render_comment(comments) or "",
      mergeable,
      merge_state,
      rollup
    ),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr view 27 --repo owner/repo --json 'headRefName,headRefOid,baseRefName,baseRefOid,state,updatedAt,isDraft,mergedAt,comments,headRepository,headRepositoryOwner,isCrossRepository,mergeable,mergeStateStatus,statusCheckRollup'", {
    stdout = string.format(
      '{"headRefName":"chore/substrate-ref-bump","headRefOid":"%s","baseRefName":"dev","baseRefOid":"%s","state":"%s","updatedAt":"2026-06-16T22:10:00Z","isDraft":%s,"mergedAt":"%s","comments":[%s],"headRepository":{"nameWithOwner":"owner/repo"},"headRepositoryOwner":{"login":"owner"},"isCrossRepository":false,"mergeable":"%s","mergeStateStatus":"%s","statusCheckRollup":%s}\n',
      head_sha,
      base_sha,
      state,
      is_draft,
      merged_at,
      comments and render_comment(comments) or "",
      mergeable,
      merge_state,
      rollup
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_bump_diff(path)
  t.mock_command("gh pr diff '27' --repo 'owner/repo' --name-only", {
    stdout = (path or ".fkst/substrate-ref") .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr diff 27 --repo owner/repo --name-only", {
    stdout = (path or ".fkst/substrate-ref") .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_branch_head_for_merge(sha, pin)
  t.mock_command("git fetch origin chore/substrate-ref-bump", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git fetch 'origin' 'chore/substrate-ref-bump'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify 'refs/remotes/origin/chore/substrate-ref-bump^{commit}'", {
    stdout = tostring(sha or pr_head_sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify refs/remotes/'origin'/'chore/substrate-ref-bump'^{commit}", {
    stdout = tostring(sha or pr_head_sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show " .. tostring(sha or pr_head_sha) .. ":.fkst/substrate-ref", {
    stdout = tostring(pin or target_sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show '" .. tostring(sha or pr_head_sha) .. ":.fkst/substrate-ref'", {
    stdout = tostring(pin or target_sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_substrate_pin_ancestor(pin, exit_code)
  t.mock_command("git fetch https://github.com/ChronoAIProject/fkst-substrate.git refs/heads/dev:refs/remotes/fkst-substrate/dev", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git fetch 'https://github.com/ChronoAIProject/fkst-substrate.git' 'refs/heads/dev:refs/remotes/fkst-substrate/dev'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify 'refs/remotes/fkst-substrate/dev^{commit}'", {
    stdout = target_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git merge-base --is-ancestor " .. tostring(pin or target_sha) .. " " .. target_sha, {
    stdout = "",
    stderr = "",
    exit_code = exit_code or 0,
  })
end

local function mock_merge_success()
  t.mock_command("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  mock_bump_pr_view(nil, {
    state = "MERGED",
    merged_at = "2026-06-16T22:30:00Z",
  })
end

local function count_calls(needle)
  return gh_argv.count_calls(t, needle)
end

local function count_git_write_calls()
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    local rendered = gh_argv.call_rendered(call)
    if rendered:find("git worktree add", 1, true) ~= nil
      or rendered:find(" git add ", 1, true) ~= nil
      or rendered:find(" commit ", 1, true) ~= nil
      or rendered:find("git push", 1, true) ~= nil
      or rendered:find(" push origin ", 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function count_raises(result, queue)
  local count = 0
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue then
      count = count + 1
    end
  end
  return count
end

local function eq_zero(value, label)
  if value ~= 0 then
    error(tostring(label) .. ": expected 0, got " .. tostring(value))
  end
end

return {
  t = t,
  core = core,
  gh_argv = gh_argv,
  current_pin = current_pin,
  target_sha = target_sha,
  older_valid_pin = older_valid_pin,
  base_sha = base_sha,
  old_branch_sha = old_branch_sha,
  pr_head_sha = pr_head_sha,
  pr_number = pr_number,
  substrate_repo = substrate_repo,
  opts = opts,
  run_scan = run_scan,
  shell_quote = shell_quote,
  ensure_dir = ensure_dir,
  mock_env = mock_env,
  mock_substrate_head = mock_substrate_head,
  mock_substrate_check_runs = mock_substrate_check_runs,
  mock_substrate_check_runs_green = mock_substrate_check_runs_green,
  mock_current_pin = mock_current_pin,
  mock_missing_pin = mock_missing_pin,
  mock_pin_read_failure = mock_pin_read_failure,
  mock_no_existing_pr = mock_no_existing_pr,
  mock_existing_pr = mock_existing_pr,
  mock_base_head = mock_base_head,
  mock_bump_branch_base_ancestry = mock_bump_branch_base_ancestry,
  mock_runtime_root = mock_runtime_root,
  mock_branch_missing = mock_branch_missing,
  mock_branch_present = mock_branch_present,
  mock_branch_present_at = mock_branch_present_at,
  mock_branch_pin = mock_branch_pin,
  mock_branch_pin_for_head = mock_branch_pin_for_head,
  mock_branch_pin_missing = mock_branch_pin_missing,
  mock_no_checked_out_bump_branch = mock_no_checked_out_bump_branch,
  mock_checked_out_bump_branch = mock_checked_out_bump_branch,
  mock_worktree_commands = mock_worktree_commands,
  mock_pr_create = mock_pr_create,
  json_string = json_string,
  render_comment = render_comment,
  mock_bump_pr_view = mock_bump_pr_view,
  mock_bump_diff = mock_bump_diff,
  mock_branch_head_for_merge = mock_branch_head_for_merge,
  mock_substrate_pin_ancestor = mock_substrate_pin_ancestor,
  mock_merge_success = mock_merge_success,
  count_calls = count_calls,
  count_git_write_calls = count_git_write_calls,
  count_raises = count_raises,
  eq_zero = eq_zero,
}
