local M = {}

local gh_argv = require("testkit_internal.gh_argv_mock")
local testing = require("testkit_internal.testing")

local default_durable_root = "/tmp/fkst-packages-test/github-devloop/durable"
local default_repo = "owner/repo"
local default_issue_number = 42
local default_ready_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

function M.new(deps)
  deps = deps or {}
  local devloop_base = deps.devloop_base or error("testkit_internal.devloop_worktree_fixtures: fixture-dependency-missing: deps.devloop_base is required")
  local base_ids = deps.base_ids or error("testkit_internal.devloop_worktree_fixtures: fixture-dependency-missing: deps.base_ids is required")
  local base = deps.base or error("testkit_internal.devloop_worktree_fixtures: fixture-dependency-missing: deps.base is required")
  local t = base.t
  local enable_substrate_pin_refresh = deps.enable_substrate_pin_refresh == true
  local include_head_ref_push = deps.include_head_ref_push == true
  local include_branch_diff_paths = deps.include_branch_diff_paths == true
  local implementation_lineage = deps.implementation_lineage

  gh_argv.install(t, base.core)

  local function worktree_options(path)
    if type(path) == "table" then
      local opts = path
      local durable = opts.durable_root or opts.path or default_durable_root
      return durable, opts
    end
    return path or default_durable_root, {}
  end

  local function implement_worktree_for(durable, opts)
    local stable_root = devloop_base.implementation_worktree_root(durable)
    local worktree_version = opts.impl_version or default_ready_version
    if implementation_lineage ~= nil then
      worktree_version = implementation_lineage.implementation_branch_version(
        worktree_version,
        opts.impl_retry_attempt
      )
    end
    local prefix = devloop_base.implement_worktree_path(
      stable_root,
      opts.repo or default_repo,
      opts.issue_number or opts.issue or default_issue_number,
      worktree_version
    )
    local attempt = opts.attempt or opts.impl_retry_attempt or 1
    return prefix .. "-attempt-" .. tostring(attempt) .. "-AAAAAA"
  end

  local function implement_branch_for(opts)
    if opts.branch ~= nil then
      return opts.branch
    end
    local branch_version = opts.impl_version or default_ready_version
    if implementation_lineage ~= nil then
      branch_version = implementation_lineage.implementation_branch_version(
        branch_version,
        opts.impl_retry_attempt
      )
    end
    return devloop_base.implement_branch(
      opts.repo or default_repo,
      opts.issue_number or opts.issue or default_issue_number,
      branch_version
    )
  end

  local function command_result(exit_code, stderr, stdout)
    return {
      stdout = stdout or "",
      stderr = stderr or "",
      exit_code = exit_code,
    }
  end

  local function mock_durable_root(root)
    t.mock_command('printf %s "$FKST_DURABLE_ROOT"', command_result(0, "", root))
  end

  local function mock_dev_base_head(head_sha)
    t.mock_command("git fetch 'origin' 'dev'", command_result(0))
    t.mock_command("refs/remotes/'origin'/'dev'^{commit}",
      command_result(0, "", tostring(head_sha or "abc123") .. "\n"))
  end

  local function worktree_registration(path, branch)
    local ownership = branch ~= nil
      and ("branch refs/heads/" .. tostring(branch))
      or "detached"
    return "worktree " .. tostring(path) .. "\nHEAD abc123\n" .. ownership .. "\n\n"
  end

  local function mock_harvest_worktree(worktree, branch, additional_registrations, checks)
    local registrations = ""
    for _, registered in ipairs(additional_registrations or {}) do
      registrations = registrations .. worktree_registration(registered.path, registered.branch)
    end
    for _ = 1, checks or 2 do
      t.mock_command("[ -d '" .. tostring(worktree) .. "' ]", command_result(0))
      t.mock_command("git worktree list --porcelain",
        command_result(0, "", registrations .. worktree_registration(worktree, nil)))
    end
  end

  local function mock_setup_worktree(path)
    t.mock_command("git -C", command_result(0, "", "dev\n"))
    t.mock_command("git -C", command_result(0))
    t.mock_command("rev-parse --abbrev-ref HEAD",
      command_result(0, "", "devloop-owner-repo-42-01HY\n"))
    return path
  end

  local function deterministic_branch_for(event)
    local repo, issue_number = base_ids.parse_proposal_id(event.proposal_id)
    return devloop_base.implement_branch(repo, issue_number, event.dedup_key)
  end

  local function mock_worktree_parent_mkdir()
    t.mock_command("mkdir -p", command_result(0))
  end

  local function mock_attempt_worktree_allocation(durable, worktree)
    mock_durable_root(durable)
    mock_worktree_parent_mkdir()
    t.mock_command("mktemp -d", command_result(0, "", worktree .. "\n"))
    t.mock_command("git worktree add --detach", command_result(0))
  end

  local function mock_force_clean(worktree, options)
    local opts = options or {}
    local remove_result = opts.remove_result or command_result(0)
    local directory_result = opts.directory_result or command_result(0)
    local prune_result = opts.prune_result or command_result(0)
    local path_result = opts.path_result or command_result(1)
    local list_result = opts.list_result or command_result(0)

    t.mock_command("git worktree remove --force", remove_result)
    t.mock_command("rm -rf --", directory_result)
    t.mock_command("git worktree prune", prune_result)
    if directory_result.exit_code ~= 0 then
      return
    end
    if prune_result.exit_code ~= 0 then
      return
    end
    t.mock_command("[ -e ", path_result)
    if path_result.exit_code ~= 1 then
      return
    end
    t.mock_command("git worktree list --porcelain", list_result)
  end

  local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
  end

  local function ensure_dir(path)
    local ok = os.execute("mkdir -p " .. shell_quote(path))
    if ok ~= true and ok ~= 0 then
      error("github-devloop-test: directory-setup-failed: mkdir failed for " .. tostring(path))
    end
  end

  local function git_show_pin_result(value, fallback)
    if type(value) == "table" then
      return value
    end
    return command_result(0, "", tostring(value or fallback) .. "\n")
  end

  local function mock_substrate_pin_refresh(worktree, base_pin, branch_pin, base_head)
    if not enable_substrate_pin_refresh then
      return
    end
    local pin = base_pin or "2222222222222222222222222222222222222222"
    local stale = branch_pin or "1111111111111111111111111111111111111111"
    t.mock_command("git show " .. tostring(base_head or "abc123") .. ":.fkst/substrate-ref",
      git_show_pin_result(pin))
    t.mock_command("rev-parse HEAD", command_result(0, "", "def456\n"))
    t.mock_command("git show", git_show_pin_result(stale))
    if worktree ~= nil then
      ensure_dir(tostring(worktree):gsub("/+$", "") .. "/.fkst")
    end
    t.mock_command("add -A", command_result(0))
    t.mock_command("commit -m 'chore: refresh fkst-substrate pin'",
      command_result(0, "", "[devloop-owner-repo-42-01HY 9999999] chore: refresh fkst-substrate pin\n"))
    t.mock_command("diff --name-only", command_result(
      0, "", ".fkst/substrate-ref\n"))
  end

  local function mock_attempt_worktree_head(head_sha)
    t.mock_command("rev-parse HEAD", command_result(0, "", tostring(head_sha) .. "\n"))
  end

  local function mock_fresh_implement_worktree(path, base_pin, branch_pin)
    local durable, opts = worktree_options(path)
    local worktree = implement_worktree_for(durable, opts)
    base_pin = opts.base_pin or base_pin
    branch_pin = opts.branch_pin or branch_pin
    mock_dev_base_head()
    t.mock_command("show-ref --verify --quiet", command_result(1))
    mock_attempt_worktree_allocation(durable, worktree)
    t.mock_command("merge --no-edit 'abc123'", command_result(0, "", "Already up to date.\n"))
    mock_substrate_pin_refresh(worktree, base_pin, branch_pin)
    mock_attempt_worktree_head(enable_substrate_pin_refresh and "def456" or "abc123")
    if opts.harvest ~= false then
      mock_harvest_worktree(
        worktree,
        implement_branch_for(opts),
        opts.additional_registrations,
        opts.harvest_checks
      )
    end
    return worktree
  end

  local function mock_fresh_external_pr_implement_worktree(path, provision)
    local durable, opts = worktree_options(path)
    local worktree = implement_worktree_for(durable, opts)
    local external = provision or {}
    local pr_number = external.pr_number or 7
    local head_sha = external.head_sha or "1234567890abcdef1234567890abcdef12345678"
    mock_dev_base_head()
    mock_attempt_worktree_allocation(durable, worktree)
    t.mock_command("merge --no-edit 'abc123'", command_result(0, "", "Already up to date.\n"))
    t.mock_command("git fetch 'origin' 'refs/pull/" .. tostring(pr_number) .. "/head'",
      command_result(external.fetch_exit_code or 0))
    if external.fetch_exit_code == nil or external.fetch_exit_code == 0 then
      t.mock_command("git rev-parse --verify FETCH_HEAD^{commit}",
        command_result(0, "", head_sha .. "\n"))
      t.mock_command("merge --no-edit '" .. head_sha .. "'", command_result(
        external.merge_exit_code or 0,
        external.merge_stderr,
        external.merge_stdout or "Merge made by the 'ort' strategy.\n"
      ))
      if external.merge_exit_code ~= nil and external.merge_exit_code ~= 0 then
        t.mock_command("ls-files -u", command_result(
          0, "", external.unmerged_stdout or "100644 abc123 1\tpackages/github-devloop/core.lua\n"
        ))
      end
    end
    mock_substrate_pin_refresh(worktree, opts.base_pin, opts.branch_pin)
    if opts.harvest ~= false then
      mock_harvest_worktree(
        worktree,
        implement_branch_for(opts),
        opts.additional_registrations,
        opts.harvest_checks
      )
    end
    return worktree
  end

  local function mock_existing_empty_implement_worktree(path, base_pin, branch_pin)
    local durable, opts = worktree_options(path)
    local worktree = implement_worktree_for(durable, opts)
    base_pin = opts.base_pin or base_pin
    branch_pin = opts.branch_pin or branch_pin
    mock_dev_base_head()
    t.mock_command("show-ref --verify --quiet", command_result(0))
    t.mock_command("rev-parse --verify refs/heads/", command_result(0, "", "abc123\n"))
    mock_attempt_worktree_allocation(durable, worktree)
    t.mock_command("merge --no-edit 'abc123'", command_result(0, "", "Already up to date.\n"))
    mock_substrate_pin_refresh(worktree, base_pin, branch_pin)
    mock_attempt_worktree_head(enable_substrate_pin_refresh and "def456" or "abc123")
    if opts.harvest ~= false then
      mock_harvest_worktree(
        worktree,
        implement_branch_for(opts),
        opts.additional_registrations,
        opts.harvest_checks
      )
    end
  end

  local function mock_existing_empty_implement_worktree_reuse(path, branch, ahead_count)
    local durable, opts = worktree_options(path)
    local base_head = opts.base_head or "abc123"
    branch = opts.branch or branch
    ahead_count = opts.ahead_count or ahead_count
    local stable_root = devloop_base.implementation_worktree_root(durable)
    local worktree = enable_substrate_pin_refresh and implement_worktree_for(durable, opts)
      or (stable_root .. "/worktrees/devloop-owner-repo-42-01HY-attempt-"
        .. tostring(opts.attempt or opts.impl_retry_attempt or 1) .. "-AAAAAA")
    local branch_head = tonumber(ahead_count or "0") > 0 and "def456" or base_head
    mock_dev_base_head(base_head)
    t.mock_command("show-ref --verify --quiet", command_result(0))
    t.mock_command("rev-list --count",
      command_result(0, "", tostring(ahead_count or "0") .. "\n"))
    t.mock_command("rev-parse --verify refs/heads/", command_result(0, "", branch_head .. "\n"))
    t.mock_command("show-ref --verify --quiet", command_result(0))
    t.mock_command("rev-parse --verify refs/heads/", command_result(0, "", branch_head .. "\n"))
    mock_attempt_worktree_allocation(durable, worktree)
    local merge = opts.merge or {}
    t.mock_command("merge --no-edit '" .. tostring(base_head) .. "'",
      command_result(merge.exit_code or 0, merge.stderr, merge.stdout or "Already up to date.\n"))
    if merge.exit_code ~= nil and merge.exit_code ~= 0 then
      t.mock_command("ls-files -u", command_result(
        merge.unmerged_exit_code or 0,
        merge.unmerged_stderr,
        merge.unmerged_stdout or "100644 abc123 1\tpackages/github-devloop/core.lua\n"
      ))
    end
    mock_substrate_pin_refresh(worktree, opts.base_pin, opts.branch_pin, base_head)
    mock_attempt_worktree_head(enable_substrate_pin_refresh and "def456" or branch_head)
    mock_harvest_worktree(worktree, branch)
    return worktree
  end

  local function mock_existing_dirty_implement_worktree_reuse(path, branch, ahead_count)
    return mock_existing_empty_implement_worktree_reuse(path, branch, ahead_count)
  end

  local function mock_noncanonical_implement_worktree_conflict(durable_root, branch)
    local durable = durable_root or default_durable_root
    local stale = "/tmp/fkst-packages-test/github-devloop/noncanonical/worktrees/devloop-owner-repo-42-01HY"
    mock_dev_base_head()
    t.mock_command("show-ref --verify --quiet", command_result(0))
    t.mock_command("rev-list --count", command_result(0, "", "1\n"))
    mock_durable_root(durable)
    t.mock_command("git worktree list --porcelain", command_result(
      0, "", "worktree " .. stale .. "\nHEAD abc123\nbranch refs/heads/" .. tostring(branch) .. "\n\n"
    ))
    return stale
  end

  local function mock_existing_implement_branch(head)
    mock_dev_base_head()
    t.mock_command("show-ref --verify --quiet", command_result(0))
    t.mock_command("rev-parse --verify refs/heads/",
      command_result(0, "", tostring(head or "def456") .. "\n"))
  end

  local function mock_cached_diff_check(result)
    t.mock_command("diff --cached --check", command_result(
      result and result.exit_code or 0,
      result and result.stderr,
      result and result.stdout
    ))
  end

  local function mock_result_checkpoint(head_sha, branch)
    t.mock_command("commit --allow-empty -m", command_result(
      0,
      "",
      "[" .. tostring(branch or "devloop-owner-repo-42-01HY")
        .. " 7654321] implementation result receipt\n"
    ))
    t.mock_command("rev-parse HEAD", command_result(0, "", (head_sha or "def456") .. "\n"))
  end

  local function mock_git_commit(new_head, branch, cached_diff_result, receipt_head)
    t.mock_command("git -C", command_result(0))
    mock_cached_diff_check(cached_diff_result)
    t.mock_command("commit -m", command_result(
      0, "", "[" .. tostring(branch or "devloop-owner-repo-42-01HY")
        .. " 1234567] Implement github-devloop ready state\n"
    ))
    if branch ~= nil then
      t.mock_command("rev-parse --abbrev-ref HEAD", command_result(0, "", tostring(branch) .. "\n"))
    end
    t.mock_command("rev-parse HEAD", command_result(0, "", (new_head or "def456") .. "\n"))
    mock_result_checkpoint(receipt_head or new_head, branch)
  end

  local function mock_git_push(branch)
    t.mock_command("git push origin",
      command_result(0, "", "pushed " .. tostring(branch or "branch") .. "\n"))
    if include_head_ref_push then
      t.mock_command("push origin HEAD:refs/heads/" .. tostring(branch or "branch"),
        command_result(0, "", "pushed " .. tostring(branch or "branch") .. "\n"))
    end
  end

  local function mock_existing_devloop_worktree(issue_slug)
    local slug = tostring(issue_slug or "owner-repo-42")
    t.mock_command("git worktree list", command_result(
      0,
      "",
      "/tmp/devloop-" .. slug .. "-01HY" .. " abcdef1 [devloop-" .. slug .. "-01HY]\n"
    ))
  end

  local function mock_implement_codex(exit_code, stdout, stderr)
    local resolved_exit_code = exit_code or 0
    t.mock_command("codex exec", command_result(
      resolved_exit_code,
      stderr,
      testing.codex_agent_message_jsonl(stdout or "implemented")
    ))
    if resolved_exit_code == 0 then
      t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED",
        command_result(0, "FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE\n"))
    end
  end

  local function mock_git_status(stdout, exit_code, stderr)
    t.mock_command("status --porcelain", command_result(exit_code or 0, stderr, stdout))
  end

  local function mock_branch_diff_paths(stdout, receipt_subject)
    t.mock_command("diff --name-only", command_result(0, "", stdout))
    t.mock_command("cat-file -p", command_result(
      0,
      "",
      "tree aaaaaaa\nparent bbbbbbb\n\n"
        .. tostring(receipt_subject or "ordinary implementation progress") .. "\n"
    ))
  end

  local function mock_no_unmerged_paths()
    t.mock_command("ls-files -u", command_result(0))
  end

  local function mock_candidate_diff_check(merge)
    t.mock_command("diff --check", command_result(
      merge and merge.candidate_diff_exit_code or 0,
      merge and merge.candidate_diff_stderr,
      merge and merge.candidate_diff_stdout
    ))
  end

  local function mock_fix_worktree_precondition(branch, reviewed_head_sha, local_contains_reviewed)
    t.mock_command("merge-base --is-ancestor",
      command_result(local_contains_reviewed == false and 1 or 0))
    local reset_target = "refs/heads/" .. tostring(branch)
    if local_contains_reviewed == false then
      reset_target = tostring(reviewed_head_sha)
    end
    t.mock_command("reset --hard " .. reset_target,
      command_result(0, "", "HEAD is now at " .. tostring(reviewed_head_sha) .. " reviewed head\n"))
    t.mock_command("clean -fd", command_result(0))
  end

  local function mock_existing_fix_worktree(branch, head, path, merge)
    local reviewed_head_sha = merge and merge.reviewed_head_sha or head or "def456"
    local stable_root = devloop_base.implementation_worktree_root(default_durable_root)
    local worktree = path or devloop_base.implement_worktree_path(
      stable_root,
      default_repo,
      default_issue_number,
      default_ready_version
    )
    mock_durable_root(default_durable_root)
    t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", command_result(0))
    t.mock_command("refs/remotes/'origin'/'" .. tostring(branch) .. "'^{commit}",
      command_result(0, "", tostring(reviewed_head_sha) .. "\n"))
    t.mock_command("git worktree list --porcelain", command_result(
      0,
      "",
      "worktree " .. worktree .. "\nHEAD " .. tostring(head or "def456")
        .. "\nbranch refs/heads/" .. tostring(branch) .. "\n\n"
    ))
    t.mock_command("[ -d '" .. worktree .. "' ]", command_result(0))
    mock_fix_worktree_precondition(
      branch, reviewed_head_sha, merge and merge.local_contains_reviewed)
    t.mock_command("git fetch 'origin' 'dev'", command_result(0))
    t.mock_command("refs/remotes/'origin'/'dev'^{commit}",
      command_result(0, "", tostring(merge and merge.sha or "abc123") .. "\n"))
    t.mock_command("merge --no-edit '" .. tostring(merge and merge.sha or "abc123") .. "'", command_result(
      merge and merge.exit_code or 0,
      merge and merge.stderr,
      merge and merge.stdout or "Already up to date.\n"
    ))
    if merge ~= nil and merge.exit_code ~= nil and merge.exit_code ~= 0 then
      t.mock_command("ls-files -u", command_result(
        merge.unmerged_exit_code or 0,
        merge.unmerged_stderr,
        merge.unmerged_stdout or "100644 abc123 1\tpackages/github-devloop/core.lua\n"
      ))
    end
    if merge ~= nil and merge.post_codex_unmerged_stdout ~= nil then
      t.mock_command("ls-files -u", command_result(
        merge.post_codex_unmerged_exit_code or 0,
        merge.post_codex_unmerged_stderr,
        merge.post_codex_unmerged_stdout
      ))
    else
      mock_no_unmerged_paths()
    end
    mock_candidate_diff_check(merge)
    return worktree
  end

  local function mock_missing_fix_worktree(branch, head, path)
    local reviewed_head_sha = head or "def456"
    local worktree = path or "/tmp/fkst-packages-test/github-devloop/missing/worktrees/fix-worktree"
    mock_durable_root(default_durable_root)
    t.mock_command("git worktree list --porcelain", command_result(
      0,
      "",
      "worktree " .. worktree .. "\nHEAD " .. tostring(head or "def456")
        .. "\nbranch refs/heads/" .. tostring(branch) .. "\n\n"
    ))
    t.mock_command("[ -d '" .. worktree .. "' ]", command_result(1))
    t.mock_command("git worktree prune", command_result(0))
    t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", command_result(0))
    t.mock_command("refs/remotes/'origin'/'" .. tostring(branch) .. "'^{commit}",
      command_result(0, "", tostring(reviewed_head_sha) .. "\n"))
    mock_worktree_parent_mkdir()
    t.mock_command("git worktree add --force -B", command_result(0))
    mock_fix_worktree_precondition(branch, reviewed_head_sha)
    mock_dev_base_head()
    t.mock_command("merge --no-edit 'abc123'", command_result(0, "", "Already up to date.\n"))
    mock_no_unmerged_paths()
    mock_candidate_diff_check()
    return worktree
  end

  local function mock_outside_stable_root_fix_worktree(branch, head, path)
    local reviewed_head_sha = head or "def456"
    local worktree = path or "/tmp/fkst-packages-test/github-devloop/noncanonical/worktrees/fix-worktree"
    mock_durable_root(default_durable_root)
    t.mock_command("git worktree list --porcelain", command_result(
      0,
      "",
      "worktree " .. worktree .. "\nHEAD " .. tostring(head or "def456")
        .. "\nbranch refs/heads/" .. tostring(branch) .. "\n\n"
    ))
    t.mock_command("[ -d '" .. worktree .. "' ]", command_result(0))
    t.mock_command("git worktree remove --force", command_result(0))
    t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", command_result(0))
    t.mock_command("refs/remotes/'origin'/'" .. tostring(branch) .. "'^{commit}",
      command_result(0, "", tostring(reviewed_head_sha) .. "\n"))
    mock_worktree_parent_mkdir()
    t.mock_command("git worktree add --force -B", command_result(0))
    mock_fix_worktree_precondition(branch, reviewed_head_sha)
    mock_dev_base_head()
    t.mock_command("merge --no-edit 'abc123'", command_result(0, "", "Already up to date.\n"))
    mock_no_unmerged_paths()
    mock_candidate_diff_check()
    return worktree
  end

  local function mock_write_env(value)
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', command_result(0, "", value))
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', command_result(0, "", value))
  end

  local function mock_bot_env(value)
    for _ = 1, 8 do
      t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"',
        command_result(0, "", value or "fkst-test-bot"))
    end
    t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', command_result(0, "", "dev"))
    t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', command_result(0))
    t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', command_result(0))
  end

  local function mock_issue_view_failure(json_selector, stderr)
    t.mock_command(json_selector, command_result(1, stderr or "forced issue view failure"))
  end

  local function count_calls(needle)
    local count = gh_argv.count_calls(t, needle)
    local alternate = nil
    if needle == "--json headRefName,headRefOid,baseRefName,state,comments" then
      alternate = "--json title,body,headRefName,headRefOid,baseRefName,state,updatedAt,mergedAt,comments,labels,author,mergeable,mergeStateStatus"
    end
    if alternate ~= nil then
      for _, call in ipairs(t.command_calls()) do
        if tostring(call.rendered or ""):find(alternate, 1, true) ~= nil then
          count = count + 1
        end
      end
    end
    return count
  end

  local function find_raise(raises, queue, predicate)
    for _, raised in ipairs(raises or {}) do
      if raised.queue == queue
        and (predicate == nil or predicate(raised.payload, raised)) then
        return raised
      end
    end
    if queue == "github-proxy.github_issue_comment_request" then
      for _, raised in ipairs(raises or {}) do
        if raised.queue == "github-proxy.github_pr_comment_request"
          and (predicate == nil or predicate(raised.payload, raised)) then
          return raised
        end
      end
    end
    return nil
  end

  local fixtures = {
    mock_setup_worktree = mock_setup_worktree,
    mock_force_clean = mock_force_clean,
    deterministic_branch_for = deterministic_branch_for,
    mock_fresh_implement_worktree = mock_fresh_implement_worktree,
    mock_fresh_external_pr_implement_worktree = mock_fresh_external_pr_implement_worktree,
    mock_existing_empty_implement_worktree = mock_existing_empty_implement_worktree,
    mock_existing_empty_implement_worktree_reuse = mock_existing_empty_implement_worktree_reuse,
    mock_existing_dirty_implement_worktree_reuse = mock_existing_dirty_implement_worktree_reuse,
    mock_noncanonical_implement_worktree_conflict = mock_noncanonical_implement_worktree_conflict,
    mock_existing_implement_branch = mock_existing_implement_branch,
    mock_git_commit = mock_git_commit,
    mock_result_checkpoint = mock_result_checkpoint,
    mock_git_push = mock_git_push,
    mock_existing_devloop_worktree = mock_existing_devloop_worktree,
    mock_implement_codex = mock_implement_codex,
    mock_git_status = mock_git_status,
    mock_existing_fix_worktree = mock_existing_fix_worktree,
    mock_missing_fix_worktree = mock_missing_fix_worktree,
    mock_outside_stable_root_fix_worktree = mock_outside_stable_root_fix_worktree,
    mock_write_env = mock_write_env,
    mock_bot_env = mock_bot_env,
    mock_issue_view_failure = mock_issue_view_failure,
    count_calls = count_calls,
    find_raise = find_raise,
  }

  if include_branch_diff_paths then
    fixtures.mock_branch_diff_paths = mock_branch_diff_paths
  end

  return fixtures
end

return M
