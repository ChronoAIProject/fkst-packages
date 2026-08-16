local M = {}

local function url_encode(value)
  return (tostring(value or ""):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function repo_owner(repo)
  return tostring(repo or ""):match("^([^/]+)/")
end

local function bounded_page_number(page)
  if page == nil then
    return nil
  end
  local n = tonumber(page)
  if n == nil or n ~= math.floor(n) or n < 1 then
    error("github-devloop: list-page-number-invalid: invalid list page number")
  end
  return n
end

local function parent_dir(worktree)
  return tostring(worktree):gsub("/+$", ""):match("^(.*)/[^/]+$") or "."
end

function M.new(rendering)
  local shell_single_quote = assert(rendering.shell_single_quote, "shell_single_quote is required")
  local render_argv = assert(rendering.render_argv, "render_argv is required")

  local function gh_issue_list_intake_command(repo, limit)
    return "gh issue list --repo " .. shell_single_quote(repo)
      .. " --state open --limit " .. tostring(math.floor(tonumber(limit or 100)))
      .. " --json number,title,body,updatedAt,labels,assignees,author"
  end

  local function gh_issue_list_decompose_children_command(repo, proposal_id)
    return "gh issue list --repo " .. shell_single_quote(repo)
      .. " --state all --limit 100 --search "
      .. shell_single_quote("fkst:github-devloop:decompose-child:v1 " .. tostring(proposal_id))
      .. " --json number,title,state,author,body,url"
  end

  local function gh_issue_list_recent_closed_command(repo, limit)
    return "gh issue list --repo " .. shell_single_quote(repo)
      .. " --state closed --limit " .. tostring(math.floor(tonumber(limit or 30)))
      .. " --json number,title,closedAt,labels,author"
  end

  local function gh_issue_list_board_digest_command(repo)
    return "gh issue list --repo " .. shell_single_quote(repo)
      .. " --state open --limit 100 --json number,title,labels,author"
  end

  local function gh_pr_list_board_digest_command(repo)
    return "gh pr list --repo " .. shell_single_quote(repo)
      .. " --state open --limit 100 --json number,title,labels,author"
  end

  local function gh_issue_list_observe_command(repo, label, page, include_headers)
    local selected_page = bounded_page_number(page)
    local include = include_headers and "--include " or ""
    local paginate = "--paginate --slurp "
    local page_query = selected_page ~= nil and ("&page=" .. tostring(selected_page)) or ""
    if selected_page ~= nil then
      paginate = ""
    end
    local query = "repos/" .. tostring(repo) .. "/issues?state=open&per_page=100" .. page_query
    if label ~= nil and tostring(label) ~= "" then
      query = "repos/" .. tostring(repo) .. "/issues?state=open&labels="
        .. tostring(label):gsub(":", "%%3A") .. "&per_page=100" .. page_query
    end
    return "gh api " .. include .. paginate .. shell_single_quote(query)
  end

  local function gh_pr_list_observe_command(repo, page, include_headers)
    local selected_page = bounded_page_number(page)
    local include = include_headers and "--include " or ""
    local paginate = selected_page == nil and "--paginate --slurp " or ""
    local page_query = selected_page ~= nil and ("&page=" .. tostring(page)) or ""
    return "gh api " .. include .. paginate
      .. shell_single_quote("repos/" .. tostring(repo) .. "/pulls?state=open&per_page=100" .. page_query)
  end

  local function gh_issue_view_command(repo, issue_number, fields)
    return "gh issue view " .. shell_single_quote(issue_number)
      .. " --repo " .. shell_single_quote(repo)
      .. " --json " .. tostring(fields)
  end

  local function gh_pr_view_command(repo, pr_number, fields)
    return "gh pr view " .. shell_single_quote(pr_number)
      .. " --repo " .. shell_single_quote(repo)
      .. " --json " .. tostring(fields)
  end

  local function gh_pr_list_head_command(repo, head, base)
    local owner = repo_owner(repo)
    local head_filter = owner ~= nil and (owner .. ":" .. tostring(head)) or tostring(head)
    local query = "repos/" .. tostring(repo)
      .. "/pulls?state=open&head=" .. url_encode(head_filter)
      .. "&per_page=100"
    if base ~= nil then
      query = query .. "&base=" .. url_encode(base)
    end
    return "gh api --paginate --slurp " .. shell_single_quote(query)
  end

  local function gh_api_paginate(path)
    return "gh api --paginate --slurp " .. shell_single_quote(path)
  end

  local function gh_api_method_command(method, path, fields, input_file, include_headers)
    local parts = { "gh", "api", "--method", tostring(method) }
    if include_headers then
      table.insert(parts, "--include")
    end
    table.insert(parts, tostring(path))
    for _, field in ipairs(fields or {}) do
      table.insert(parts, "-f")
      table.insert(parts, tostring(field))
    end
    if input_file ~= nil then
      table.insert(parts, "--input")
      table.insert(parts, tostring(input_file))
    end
    return render_argv(parts)
  end

  local function gh_blocked_by_command(core, repo, issue_number)
    local owner, name = tostring(repo or ""):match("^([^/]+)/([^/]+)$")
    if owner == nil then
      owner = ""
      name = ""
    end
    local query = core.render_github_graphql_query("dependency_blocked_by", {
      owner = owner,
      name = name,
      issue_number = tostring(math.floor(tonumber(issue_number) or 0)),
    })
    return render_argv({ "gh", "api", "graphql", "-f", "query=" .. query })
  end

  local function install_legacy_command_renderers(core)
    core.gh_issue_list_intake_cmd = core.gh_issue_list_intake_cmd or gh_issue_list_intake_command
    core.gh_issue_list_decompose_children_cmd = core.gh_issue_list_decompose_children_cmd or gh_issue_list_decompose_children_command
    core.gh_issue_list_recent_closed_cmd = core.gh_issue_list_recent_closed_cmd or gh_issue_list_recent_closed_command
    core.gh_issue_list_board_digest_cmd = core.gh_issue_list_board_digest_cmd or gh_issue_list_board_digest_command
    core.gh_pr_list_board_digest_cmd = core.gh_pr_list_board_digest_cmd or gh_pr_list_board_digest_command
    core.gh_issue_list_observe_cmd = core.gh_issue_list_observe_cmd or gh_issue_list_observe_command
    core.gh_pr_list_observe_cmd = core.gh_pr_list_observe_cmd or gh_pr_list_observe_command
    core.gh_issue_list_observe_opts = function(repo, label, page, include_headers)
      local timeout = 10
      return {
        cmd = core.gh_issue_list_observe_cmd(repo, label, page, include_headers),
        run = function(selected_timeout)
          return core.gh_issue_list_observe(repo, label, page, include_headers, selected_timeout or timeout)
        end,
        timeout = timeout,
        read_coalesce = core.gh_issue_list_observe_read_coalesce(repo, label, page),
      }
    end
    core.gh_pr_list_observe_opts = function(repo, page, include_headers)
      local timeout = 10
      return {
        cmd = core.gh_pr_list_observe_cmd(repo, page, include_headers),
        run = function(selected_timeout)
          return core.gh_pr_list_observe(repo, page, include_headers, selected_timeout or timeout)
        end,
        timeout = timeout,
        read_coalesce = core.gh_pr_list_observe_read_coalesce(repo, page),
      }
    end
    core.gh_issue_list_wip_cmd = core.gh_issue_list_wip_cmd or function(repo)
      return "gh issue list --repo " .. shell_single_quote(repo)
        .. " --state open --limit 100 --json number"
    end
    core.gh_dashboard_issue_list_cmd = core.gh_dashboard_issue_list_cmd or function(repo, label)
      return gh_api_paginate("repos/" .. tostring(repo) .. "/issues?state=open&labels=" .. tostring(label):gsub(":", "%%3A") .. "&per_page=100")
    end
    core.gh_dashboard_issue_all_open_cmd = core.gh_dashboard_issue_all_open_cmd or function(repo)
      return gh_api_paginate("repos/" .. tostring(repo) .. "/issues?state=open&per_page=100")
    end
    core.gh_dashboard_label_get_cmd = core.gh_dashboard_label_get_cmd or function(repo, label)
      return "gh api --method GET " .. shell_single_quote("repos/" .. tostring(repo) .. "/labels/" .. tostring(label):gsub(":", "%%3A"))
    end
    core.gh_dashboard_issue_get_cmd = core.gh_dashboard_issue_get_cmd or function(repo, issue_number)
      return "gh api --method GET --include " .. shell_single_quote("repos/" .. tostring(repo) .. "/issues/" .. tostring(issue_number))
    end
    core.gh_dashboard_issue_create_cmd = core.gh_dashboard_issue_create_cmd or function(repo, input_file)
      return gh_api_method_command("POST", "repos/" .. tostring(repo) .. "/issues", nil, input_file)
    end
    core.gh_dashboard_issue_update_cmd = core.gh_dashboard_issue_update_cmd or function(repo, issue_number, input_file)
      return gh_api_method_command("PATCH", "repos/" .. tostring(repo) .. "/issues/" .. tostring(issue_number), nil, input_file)
    end
    core.gh_repo_labels_list_cmd = core.gh_repo_labels_list_cmd or function(repo)
      return gh_api_paginate("repos/" .. tostring(repo) .. "/labels?per_page=100")
    end
    core.gh_repo_label_create_cmd = core.gh_repo_label_create_cmd or function(repo, name, color, description)
      return "gh api --method POST " .. shell_single_quote("repos/" .. tostring(repo) .. "/labels")
        .. " -f " .. shell_single_quote("name=" .. tostring(name))
        .. " -f " .. shell_single_quote("color=" .. tostring(color))
        .. " -f " .. shell_single_quote("description=" .. tostring(description or ""))
    end
    core.gh_repo_label_update_cmd = core.gh_repo_label_update_cmd or function(repo, name, color, description)
      return "gh api --method PATCH " .. shell_single_quote("repos/" .. tostring(repo) .. "/labels/" .. tostring(name):gsub(":", "%%3A"))
        .. " -f " .. shell_single_quote("color=" .. tostring(color))
        .. " -f " .. shell_single_quote("description=" .. tostring(description or ""))
    end

    core.gh_issue_view_intake_judge_cmd = core.gh_issue_view_intake_judge_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone")
    end
    core.gh_issue_view_state_cmd = core.gh_issue_view_state_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,createdAt,updatedAt,labels,state,comments,assignees,author")
    end
    core.gh_issue_view_claim_cmd = core.gh_issue_view_claim_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "assignees,author,labels")
    end
    core.gh_issue_view_result_cmd = core.gh_issue_view_result_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "labels,comments")
    end
    core.gh_issue_view_loop_cmd = core.gh_issue_view_loop_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,updatedAt,labels,comments,state,author")
    end
    core.gh_issue_view_meta_cmd = core.gh_issue_view_meta_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,labels,comments,author")
    end
    core.gh_issue_view_implement_cmd = core.gh_issue_view_implement_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,body,labels,comments,state,author")
    end
    core.gh_issue_view_open_pr_cmd = core.gh_issue_view_open_pr_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,labels,comments,assignees,author")
    end
    core.gh_issue_view_reviewing_cmd = core.gh_issue_view_reviewing_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "labels,comments")
    end
    core.gh_issue_view_review_cmd = core.gh_issue_view_review_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,labels,comments,assignees,author")
    end
    core.gh_issue_view_decompose_cmd = core.gh_issue_view_decompose_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,body,labels,comments,author")
    end
    core.gh_issue_view_fix_cmd = core.gh_issue_view_fix_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,labels,comments,author")
    end
    core.gh_issue_view_commit_subject_cmd = core.gh_issue_view_commit_subject_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "number,title,author")
    end
    core.gh_issue_view_review_loop_cmd = core.gh_issue_view_review_loop_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,labels,comments,assignees,author")
    end
    core.gh_issue_view_merge_cmd = core.gh_issue_view_merge_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,labels,comments,state,assignees,author")
    end
    core.gh_issue_view_observe_cmd = core.gh_issue_view_observe_cmd or function(repo, number)
      return gh_issue_view_command(repo, number, "title,body,comments,labels,state,stateReason,assignees,author")
    end

    core.gh_pr_view_origin_cmd = core.gh_pr_view_origin_cmd or function(repo, number)
      return gh_pr_view_command(repo, number, "title,body,headRefName,headRefOid,baseRefName,state,updatedAt,mergedAt,comments,labels,author,mergeable,mergeStateStatus")
    end
    core.gh_pr_view_observe_cmd = core.gh_pr_view_observe_cmd or core.gh_pr_view_origin_cmd
    core.gh_pr_view_merge_cmd = core.gh_pr_view_merge_cmd or function(repo, number)
      return gh_pr_view_command(repo, number, "headRefName,headRefOid,baseRefName,baseRefOid,state,updatedAt,isDraft,mergedAt,comments,headRepository,headRepositoryOwner,isCrossRepository,mergeable,mergeStateStatus,statusCheckRollup")
    end
    core.gh_pr_view_fix_cmd = core.gh_pr_view_fix_cmd or function(repo, number)
      return gh_pr_view_command(repo, number, "headRefName,headRefOid,baseRefName,state,comments,headRepository,headRepositoryOwner,isCrossRepository")
    end
    core.gh_pr_view_fix_precheck_cmd = core.gh_pr_view_fix_precheck_cmd or function(repo, number)
      return gh_pr_view_command(repo, number, "headRefName,headRefOid,baseRefName,state,updatedAt,comments,headRepository,headRepositoryOwner,isCrossRepository")
    end
    core.gh_pr_view_freshness_cmd = core.gh_pr_view_freshness_cmd or function(repo, number)
      return gh_pr_view_command(repo, number, "headRefName,headRefOid,baseRefName,state,updatedAt,isDraft,comments,labels,headRepository,headRepositoryOwner,isCrossRepository,mergeable,mergeStateStatus,statusCheckRollup")
    end
    core.gh_pr_view_head_cmd = core.gh_pr_view_head_cmd or function(repo, number)
      return gh_pr_view_command(repo, number, "headRefName,baseRefName,state")
    end
    core.gh_pr_view_context_cmd = core.gh_pr_view_context_cmd or function(repo, number)
      return gh_pr_view_command(repo, number, "title,body,headRefName,headRefOid,baseRefName,state,updatedAt,comments,labels,author")
    end
    core.gh_pr_list_freshness_cmd = core.gh_pr_list_freshness_cmd or function(repo)
      return gh_api_paginate("repos/" .. tostring(repo) .. "/pulls?state=open&per_page=100")
    end
    core.gh_pr_list_recent_merged_cmd = core.gh_pr_list_recent_merged_cmd or function(repo, limit)
      return "gh pr list --repo " .. shell_single_quote(repo)
        .. " --state merged --limit " .. tostring(math.floor(tonumber(limit or 30)))
        .. " --json number,title,mergedAt,headRefOid"
    end
    core.gh_pr_list_merge_queue_cmd = core.gh_pr_list_merge_queue_cmd or function(repo, base)
      return gh_api_paginate("repos/" .. tostring(repo) .. "/pulls?state=open&base=" .. url_encode(base) .. "&per_page=100")
    end
    core.gh_pr_list_head_base_cmd = core.gh_pr_list_head_base_cmd or function(repo, head, base)
      return gh_pr_list_head_command(repo, head, base)
    end
    core.gh_pr_list_head_cmd = core.gh_pr_list_head_cmd or function(repo, head)
      return gh_pr_list_head_command(repo, head, nil)
    end
    core.gh_pr_merge_cmd = core.gh_pr_merge_cmd or function(repo, number, head_sha)
      return "gh pr merge " .. shell_single_quote(number)
        .. " --repo " .. shell_single_quote(repo)
        .. " --merge --match-head-commit " .. shell_single_quote(head_sha)
    end
    core.gh_check_run_rerequest_cmd = core.gh_check_run_rerequest_cmd or function(repo, id)
      return "gh api --method POST " .. shell_single_quote("repos/" .. tostring(repo) .. "/check-runs/" .. tostring(id) .. "/rerequest")
    end
    core.gh_commit_check_runs_cmd = core.gh_commit_check_runs_cmd or function(repo, head_sha)
      return "gh api " .. shell_single_quote("repos/" .. tostring(repo) .. "/commits/" .. tostring(head_sha) .. "/check-runs")
    end
    core.gh_issue_comment_get_cmd = core.gh_issue_comment_get_cmd or function(repo, comment_id)
      return "gh api " .. shell_single_quote("repos/" .. tostring(repo) .. "/issues/comments/" .. tostring(comment_id))
    end
    core.gh_pr_ready_cmd = core.gh_pr_ready_cmd or function(repo, number)
      return "gh pr ready " .. shell_single_quote(number) .. " --repo " .. shell_single_quote(repo)
    end
    core.gh_pr_comment_cmd = core.gh_pr_comment_cmd or function(repo, number, body_file)
      return "gh pr comment " .. shell_single_quote(number)
        .. " --repo " .. shell_single_quote(repo)
        .. " --body-file " .. shell_single_quote(body_file)
    end
    core.gh_issue_comment_cmd = core.gh_issue_comment_cmd or function(repo, number, body_file)
      return "gh issue comment " .. shell_single_quote(number)
        .. " --repo " .. shell_single_quote(repo)
        .. " --body-file " .. shell_single_quote(body_file)
    end
    core.gh_pr_close_cmd = core.gh_pr_close_cmd or function(repo, number)
      return "gh pr close " .. shell_single_quote(number) .. " --repo " .. shell_single_quote(repo)
    end
    core.gh_issue_close_cmd = core.gh_issue_close_cmd or function(repo, number, disposition)
      local command = "gh issue close " .. shell_single_quote(number) .. " --repo " .. shell_single_quote(repo)
      if disposition.kind == "completed" then
        return command .. " --reason completed"
      end
      if disposition.kind == "not_planned" then
        return command .. " --reason " .. shell_single_quote("not planned")
      end
      return command .. " --duplicate-of " .. shell_single_quote(disposition.duplicate_of)
    end
    core.gh_pr_diff_cmd = core.gh_pr_diff_cmd or function(repo, number)
      return "gh pr diff " .. shell_single_quote(number) .. " --repo " .. shell_single_quote(repo)
    end
    core.gh_pr_diff_name_only_cmd = core.gh_pr_diff_name_only_cmd or function(repo, number)
      return "gh pr diff " .. shell_single_quote(number) .. " --repo " .. shell_single_quote(repo) .. " --name-only"
    end
    core.gh_blocked_by_cmd = core.gh_blocked_by_cmd or function(repo, issue_number)
      return gh_blocked_by_command(core, repo, issue_number)
    end

    core.git_status_cmd = core.git_status_cmd or function(worktree)
      return "git -C " .. shell_single_quote(worktree) .. " status --porcelain"
    end
    core.git_add_all_cmd = core.git_add_all_cmd or function(worktree)
      return "git -C " .. shell_single_quote(worktree) .. " add -A"
    end
    core.git_commit_cmd = core.git_commit_cmd or function(worktree, message)
      return "git -C " .. shell_single_quote(worktree) .. " commit -m " .. shell_single_quote(message)
    end
    core.git_empty_commit_cmd = core.git_empty_commit_cmd or function(worktree, message)
      return "git -C " .. shell_single_quote(worktree) .. " commit --allow-empty -m " .. shell_single_quote(message)
    end
    core.git_current_branch_cmd = core.git_current_branch_cmd or function(worktree)
      if worktree == nil then
        return "git rev-parse --abbrev-ref HEAD"
      end
      return "git -C " .. shell_single_quote(worktree) .. " rev-parse --abbrev-ref HEAD"
    end
    core.git_head_sha_cmd = core.git_head_sha_cmd or function(worktree)
      return "git -C " .. shell_single_quote(worktree) .. " rev-parse HEAD"
    end
    core.git_base_head_cmd = core.git_base_head_cmd or function(branch)
      return "git rev-parse --verify refs/remotes/origin/" .. shell_single_quote(branch) .. "^{commit}"
    end
    core.git_fetch_branch_cmd = core.git_fetch_branch_cmd or function(remote, branch)
      return "git fetch " .. shell_single_quote(remote) .. " " .. shell_single_quote(branch)
    end
    core.git_fetch_pr_merge_ref_cmd = core.git_fetch_pr_merge_ref_cmd or function(remote, number)
      return "git fetch " .. shell_single_quote(remote) .. " " .. shell_single_quote("refs/pull/" .. tostring(number) .. "/merge")
    end
    core.git_fetch_pr_head_ref_cmd = core.git_fetch_pr_head_ref_cmd or function(remote, number)
      return "git fetch " .. shell_single_quote(remote) .. " " .. shell_single_quote("refs/pull/" .. tostring(number) .. "/head")
    end
    core.git_fetch_head_commit_cmd = core.git_fetch_head_commit_cmd or function()
      return "git rev-parse --verify FETCH_HEAD^{commit}"
    end
    core.git_remote_branch_head_cmd = core.git_remote_branch_head_cmd or function(remote, branch)
      return "git rev-parse --verify refs/remotes/" .. shell_single_quote(remote) .. "/" .. shell_single_quote(branch) .. "^{commit}"
    end
    core.git_ls_remote_branch_cmd = core.git_ls_remote_branch_cmd or function(remote, branch)
      return "git ls-remote " .. shell_single_quote(remote) .. " refs/heads/" .. shell_single_quote(branch)
    end
    core.git_fetch_remote_branch_to_tracking_ref_cmd = core.git_fetch_remote_branch_to_tracking_ref_cmd or function(remote, branch, tracking_ref)
      return "git fetch " .. shell_single_quote(remote) .. " " .. shell_single_quote("refs/heads/" .. tostring(branch) .. ":" .. tostring(tracking_ref))
    end
    core.git_rev_parse_ref_commit_cmd = core.git_rev_parse_ref_commit_cmd or function(ref)
      return "git rev-parse --verify " .. shell_single_quote(tostring(ref) .. "^{commit}")
    end
    core.git_worktree_merge_no_edit_cmd = core.git_worktree_merge_no_edit_cmd or function(worktree, sha)
      return "git -C " .. shell_single_quote(worktree) .. " merge --no-edit " .. shell_single_quote(sha)
    end
    core.git_worktree_add_new_branch_cmd = core.git_worktree_add_new_branch_cmd or function(worktree, branch, base)
      return "mkdir -p " .. shell_single_quote(parent_dir(worktree))
        .. " && git worktree add -b " .. shell_single_quote(branch)
        .. " " .. shell_single_quote(worktree)
        .. " " .. shell_single_quote(base)
    end
    core.git_worktree_add_reset_branch_cmd = core.git_worktree_add_reset_branch_cmd or function(worktree, branch, base)
      return "mkdir -p " .. shell_single_quote(parent_dir(worktree))
        .. " && git worktree add -B " .. shell_single_quote(branch)
        .. " " .. shell_single_quote(worktree)
        .. " " .. shell_single_quote(base)
    end
    core.git_worktree_add_existing_branch_cmd = core.git_worktree_add_existing_branch_cmd or function(worktree, branch)
      return "mkdir -p " .. shell_single_quote(parent_dir(worktree))
        .. " && git worktree add " .. shell_single_quote(worktree)
        .. " " .. shell_single_quote(branch)
    end
    core.git_worktree_add_remote_branch_cmd = core.git_worktree_add_remote_branch_cmd or function(worktree, remote, branch, force)
      return "mkdir -p " .. shell_single_quote(parent_dir(worktree))
        .. " && git worktree add" .. (force and " --force" or "")
        .. " -B " .. shell_single_quote(branch)
        .. " " .. shell_single_quote(worktree)
        .. " refs/remotes/" .. shell_single_quote(remote) .. "/" .. shell_single_quote(branch)
    end
    core.git_worktree_reset_hard_cmd = core.git_worktree_reset_hard_cmd or function(worktree, branch)
      return "git -C " .. shell_single_quote(worktree) .. " reset --hard refs/heads/" .. shell_single_quote(branch)
    end
    core.git_worktree_clean_cmd = core.git_worktree_clean_cmd or function(worktree)
      return "git -C " .. shell_single_quote(worktree) .. " clean -fd"
    end
    core.git_ahead_count_cmd = core.git_ahead_count_cmd or function(upstream, integration)
      return "git rev-list --count refs/remotes/origin/" .. shell_single_quote(upstream) .. "..refs/remotes/origin/" .. shell_single_quote(integration)
    end
    core.git_show_ref_branch_cmd = core.git_show_ref_branch_cmd or function(branch)
      return "git show-ref --verify --quiet refs/heads/" .. shell_single_quote(branch)
    end
    core.git_show_ref_cmd = core.git_show_ref_cmd or function(worktree, branch)
      return "git -C " .. shell_single_quote(worktree) .. " show-ref --verify --quiet refs/heads/" .. shell_single_quote(branch)
    end
    core.git_branch_ahead_count_cmd = core.git_branch_ahead_count_cmd or function(base, branch)
      return "git rev-list --count " .. shell_single_quote(tostring(base) .. "..refs/heads/" .. tostring(branch))
    end
    core.git_branch_head_cmd = core.git_branch_head_cmd or function(branch)
      return "git rev-parse --verify refs/heads/" .. shell_single_quote(branch)
    end
    core.git_push_branch_cmd = core.git_push_branch_cmd or function(branch)
      return "git push origin " .. shell_single_quote(branch)
    end
    core.git_switch_branch_cmd = core.git_switch_branch_cmd or function(worktree, branch)
      return "git -C " .. shell_single_quote(worktree) .. " switch " .. shell_single_quote(branch)
    end
    core.git_rev_parse_branch_cmd = core.git_rev_parse_branch_cmd or function(worktree, branch)
      return "git -C " .. shell_single_quote(worktree) .. " rev-parse --verify refs/heads/" .. shell_single_quote(branch)
    end
    core.git_worktree_list_cmd = core.git_worktree_list_cmd or function()
      return "git worktree list --porcelain"
    end
  end

  local function gh_issue_view_entity_command(repo, issue_number)
    return "gh issue view " .. tostring(issue_number)
      .. " --repo " .. tostring(repo)
      .. " --json"
  end

  local function gh_pr_view_entity_command(repo, pr_number)
    return "gh pr view " .. tostring(pr_number)
      .. " --repo " .. tostring(repo)
      .. " --json"
  end

  local function gh_entity_updated_at_command(repo, kind, number)
    local path_kind = kind == "pr" and "pulls" or "issues"
    return "gh api " .. "repos/" .. tostring(repo) .. "/" .. path_kind .. "/" .. tostring(number)
      .. " --jq .updated_at // .updatedAt // \"\""
  end

  local function install(core)
    install_legacy_command_renderers(core)
    core.gh_issue_view_entity_cmd = core.gh_issue_view_entity_cmd or gh_issue_view_entity_command
    core.gh_pr_view_entity_cmd = core.gh_pr_view_entity_cmd or gh_pr_view_entity_command
    core.gh_entity_updated_at_cmd = core.gh_entity_updated_at_cmd or gh_entity_updated_at_command
  end

  return { install = install }
end

return M
