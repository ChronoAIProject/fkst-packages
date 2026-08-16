local git_mechanics = require("devloop.git_mechanics")
local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local error_facts = require("contract.error_facts")
local m_claims = require("devloop.claims")
local pr_safety = require("devloop.pr_safety")
local parsers_misc = require("devloop.parsers.misc")
local parsers_pr = require("devloop.parsers.pr")
local parsers_issue = require("devloop.parsers.issue")
local contract_time = require("contract.time")
local entity_highwater = require("devloop.entity_highwater")
local core = require("core")
local git_adapter = require("forge.git")
local config = require("devloop.config")

local saga = require("workflow.saga")
local m_facts = require("devloop.markers.facts")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local devloop_state = require("devloop.state")
local topology = require("topology")

local spec = {
  consumes = { "devloop_branch_tick" },
  produces = { "devloop_sync_conflict" },
  fanout = { "devloop_branch_tick" },
  retry = {},
  stall_window = "10m",
}

local git = git_adapter.production_handle

local blocked_by_skew_label = "fkst-dev:blocked-by-skew"
local checkpoint_consumer = "github-devloop-integration/pr-freshness-scan"

local function require_repo(repo)
  local value = tostring(repo or "")
  if value == "" or base_ids.safe_repo(value) ~= value then
    error("github-devloop: config-missing: FKST_GITHUB_REPO is required for PR freshness")
  end
  return value
end

local function scan_lock_key(repo)
  return "github-devloop/pr-freshness-scan/" .. require_repo(repo)
end

local function trim_stdout(result)
  return tostring(result.stdout or ""):gsub("%s+$", "")
end

local function cleanup_worktree(worktree)
  if worktree == nil then
    return
  end
  local result = core.git.worktree_remove(worktree, 60)
  if result.exit_code ~= 0 then
    devloop_logging.log_line("warn", "pr_freshness_scan", "pr-freshness", "CLEANUP", {
      "worktree=" .. tostring(worktree),
      "reason=" .. error_facts.one_line(result.stderr or ""),
    })
  end
end

local function with_temp_worktree(runtime, repo, branch, integration, branch_sha, fn)
  local worktree = core.branch_sync_worktree_path(runtime, repo, integration, branch, branch_sha)
  local plan = git("github-devloop").git_worktree_add_detached_plan(worktree, branch_sha)
  git_mechanics.run_required(exec_sync({ cmd = devloop_commands.mkdir_p_cmd(plan.parent_dir), timeout = 30 }), "PR freshness worktree parent directory setup")
  git_mechanics.run_required(git("github-devloop").git_worktree_add_detached(plan.worktree, plan.sha, 60), "PR freshness worktree add")

  local ok, result = pcall(fn, worktree)
  cleanup_worktree(worktree)
  if not ok then
    error(result)
  end
  return result
end

local function has_trusted_text(comments, needle)
  if type(comments) ~= "table" then
    return false
  end
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    if parsers_misc._comment_body(comment):find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function has_approval_marker(comments, issue_proposal_id, pr_number, head_sha)
  if type(comments) ~= "table" then
    return false
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:review%-result:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local review_proposal = marker:match('proposal="([^"]+)"')
      local _, reviewed_pr_number, _, reviewed_head_sha = devloop_base.parse_pr_review_proposal_id(review_proposal)
      if marker:match('decision="([^"]+)"') == "approve"
        and marker:match('issue_proposal="([^"]+)"') == tostring(issue_proposal_id)
        and tostring(reviewed_pr_number or "") == tostring(pr_number or "")
        and tostring(reviewed_head_sha or "") == tostring(head_sha or "") then
        return true
      end
    end
  end
  return false
end

local function valid_updated_at(value)
  return type(value) == "string"
    and contract_time.iso_timestamp_epoch_seconds(value) ~= nil
end

local function checkpoint_keys(repo, kind, number)
  local mark_key = entity_highwater.key(checkpoint_consumer, {
    kind = "external",
    ref = tostring(repo) .. "#" .. tostring(kind) .. "/" .. tostring(number),
  })
  if mark_key == nil then
    return nil, nil
  end
  return mark_key, mark_key .. "/view"
end

local function load_checkpointed_entity(repo, kind, number, current_updated_at, parse, fetch, description)
  local mark_key, view_key = checkpoint_keys(repo, kind, number)
  local stored = mark_key ~= nil and cache_get(mark_key) or nil
  if valid_updated_at(current_updated_at)
    and valid_updated_at(stored)
    and current_updated_at == stored then
    local cached = cache_get(view_key)
    local ok, entity = pcall(parse, cached)
    if ok and type(entity) == "table"
      and valid_updated_at(entity.updated_at)
      and entity.updated_at == stored then
      devloop_logging.log_line("info", "pr_freshness_scan", "pr-freshness", "RECONCILE", {
        "outcome=skip-unchanged-freshness",
        "entity=" .. tostring(repo) .. "#" .. tostring(kind) .. "/" .. tostring(number),
        "updated_at=" .. tostring(stored),
      })
      return entity, { dirty = false }
    end
  end

  local viewed = git_mechanics.run_required(fetch(), description)
  local stdout = tostring(viewed.stdout or "")
  local entity = parse(stdout)
  if valid_updated_at(stored)
    and valid_updated_at(entity and entity.updated_at)
    and entity.updated_at == stored then
    devloop_logging.log_line("info", "pr_freshness_scan", "pr-freshness", "RECONCILE", {
      "outcome=verified-unchanged-after-fetch",
      "entity=" .. tostring(repo) .. "#" .. tostring(kind) .. "/" .. tostring(number),
      "updated_at=" .. tostring(stored),
    })
  end
  return entity, {
    dirty = true,
    mark_key = mark_key,
    stdout = stdout,
    view_key = view_key,
  }
end

local function commit_checkpoint(checkpoint, entity)
  if type(checkpoint) ~= "table" or checkpoint.dirty ~= true
    or checkpoint.mark_key == nil or checkpoint.view_key == nil
    or not valid_updated_at(entity and entity.updated_at) then
    return
  end
  cache_set(checkpoint.view_key, checkpoint.stdout)
  cache_set(checkpoint.mark_key, entity.updated_at)
end

local function issue_state(repo, issue_number, current_updated_at)
  if issue_number == nil then
    return { labels = {}, comments = {}, assignees = {} }, nil
  end
  return load_checkpointed_entity(
    repo,
    "issue",
    issue_number,
    current_updated_at,
    function(stdout) return parsers_issue.parse_issue_view_state(stdout) end,
    function() return devloop_commands.gh_issue_view_state(repo, issue_number, 30) end,
    "PR freshness issue view"
  )
end

local function is_blocked_by_skew(pr, issue)
  return devloop_state.has_label(issue.labels, blocked_by_skew_label)
    or devloop_state.has_label(pr.labels, blocked_by_skew_label)
    or has_trusted_text(issue.comments, "blocked-by-skew")
    or has_trusted_text(pr.comments, "blocked-by-skew")
end

local function is_imminently_mergeable(pr)
  local green, _ = core.evaluate_ci_merge_gate(pr, {})
  return green
end

local function is_approved(pr, origin)
  return has_approval_marker(pr.comments, origin.proposal_id, pr.number, pr.head_sha)
end

local function candidate_reason(pr, origin, issue, state)
  if state.state == "fixing" or state.state == "review-meta" or state.state == "merging" then
    return nil, "arbitrating"
  end
  local approved = is_approved(pr, origin)
    or m_facts.merge_ready_fact(pr.comments, origin.proposal_id, state.version, pr.number) ~= nil
  if approved and is_imminently_mergeable(pr) then
    return nil, "imminently-mergeable"
  end
  if approved then
    return "approved"
  end
  if is_blocked_by_skew(pr, issue) and is_imminently_mergeable(pr) then
    return "blocked-by-skew"
  end
  return nil, "not-candidate"
end

local function load_current_pr(repo, listed_pr)
  return load_checkpointed_entity(
    repo,
    "pr",
    listed_pr.number,
    listed_pr.updated_at,
    parsers_pr.parse_pr_view_merge,
    function() return devloop_commands.gh_pr_view_freshness(repo, listed_pr.number, 30) end,
    "PR freshness view"
  )
end

local function list_open_prs(repo)
  local listed = git_mechanics.run_required(devloop_commands.gh_pr_list_freshness(repo, 30), "PR freshness list")
  return parsers_pr.parse_pr_list_freshness(listed.stdout)
end

local function list_issue_versions(repo, issue_numbers)
  if #issue_numbers == 0 then
    return {}
  end
  local listed = git_mechanics.run_required(
    devloop_commands.gh_issue_list_freshness(repo, issue_numbers, 30),
    "PR freshness issue list"
  )
  return parsers_issue.parse_issue_list_freshness(listed.stdout)
end

local function raise_conflict(repo, branch, integration, branch_sha, integration_sha, pr_number)
  local payload = {
    schema = "github-devloop.v1",
    repo = repo,
    upstream_branch = integration,
    integration_branch = branch,
    upstream_sha = integration_sha,
    integration_sha = branch_sha,
    dedup_key = core.pr_freshness_dedup_key(repo, branch, integration_sha),
    source_ref = core.pr_freshness_source_ref(repo, pr_number),
  }
  devloop_logging.log_raise("pr_freshness_scan", "pr-freshness", "devloop_sync_conflict", payload)
end

local function write_refresh_commit(worktree, runtime, repo, branch, integration, branch_sha, integration_sha)
  local message_file = core.pr_freshness_message_file(runtime, repo, branch, integration, branch_sha, integration_sha)
  file.write(message_file, core.pr_freshness_commit_message(repo, branch, integration, branch_sha, integration_sha))
  git_mechanics.run_required(core.git.commit_message_file(worktree, message_file, 60), "PR freshness commit")
end

local function push_if_real(repo, branch, branch_sha, worktree)
  if config.write_mode() ~= "real" then
    devloop_logging.log_line("info", "pr_freshness_scan", "pr-freshness", "OUTBOUND", {
      "mode=dry-run",
      "repo=" .. tostring(repo),
      "branch=" .. tostring(branch),
      "branch_sha=" .. tostring(branch_sha),
      "reason=PR freshness push requires FKST_GITHUB_WRITE=1",
    })
    return
  end

  parsers_misc.assert_trusted_bot_configured()
  git_mechanics.fetch_branches(core.git, repo, { branch }, "PR freshness fetch")
  local rechecked_branch_sha = git_mechanics.remote_head(core.git, branch, "PR freshness remote head", "unsafe PR freshness branch head")
  if rechecked_branch_sha ~= branch_sha then
    devloop_logging.log_cas_decision("pr_freshness_scan", "pr-freshness", {
      state = "branch",
      version = rechecked_branch_sha,
    }, "freshness", "push", "skip-foreign(head)", "PR branch head changed before push")
    return
  end
  local merge_head = trim_stdout(git_mechanics.run_required(git("github-devloop").git_head_sha(worktree, 30), "PR freshness head"))
  if not require("devloop.pr_safety").is_safe_head_sha(merge_head) then
    error("github-devloop: unsafe-head-sha: unsafe PR freshness merge head")
  end
  git_mechanics.run_required(git("github-devloop").git_push_worktree_branch_update_with_lease(worktree, branch, branch_sha, 120), "PR freshness push")
  git_mechanics.fetch_branches(core.git, repo, { branch }, "PR freshness fetch")
  local pushed_head = git_mechanics.remote_head(core.git, branch, "PR freshness remote head", "unsafe PR freshness branch head")
  if pushed_head ~= merge_head then
    error("github-devloop: push-verification-mismatch: PR freshness push verification failed")
  end
  devloop_logging.log_apply("pr_freshness_scan", "pr-freshness", "refreshed", merge_head, {}, {})
end

local function in_managed_scope(repo, branches, pr, origin)
  return tostring(pr.state or ""):upper() == "OPEN"
    and not pr.is_draft
    and origin ~= nil
    and origin.repo == repo
    and origin.branch == pr.head_ref_name
    and origin.base_branch == branches.integration
    and pr.base_ref_name == branches.integration
    and require("devloop.pr_safety").is_devloop_issue_branch(pr.head_ref_name)
    and require("forge.merge.shared").is_same_repo_pr_head(pr, repo)
end

local function process_pr(repo, branches, listed_pr, pr, origin, issue)
  if not m_claims.verify_pr_review_issue_claim("pr_freshness_scan", origin.repo, origin.issue_number, issue, origin.proposal_id) then
    return
  end
  local state = require("devloop.entity").current_entity_state(pr.comments, origin.proposal_id)
  local reason, skip_reason = candidate_reason(pr, origin, issue, state)
  if reason == nil then
    devloop_logging.log_cas_decision("pr_freshness_scan", origin.proposal_id, state, "tick", "freshness", "skip-idempotent(" .. skip_reason .. ")", "PR is not a freshness candidate")
    return
  end

  with_lock(core.pr_freshness_lock_key(repo, pr.head_ref_name), function()
    if not topology.integration_topology_available({
      git = core.git,
      repo = repo,
      branches = branches,
      department = "pr_freshness_scan",
      domain = "pr-freshness",
      error_class = "PR freshness fetch",
    }) then
      return
    end
    git_mechanics.fetch_branches(core.git, repo, { pr.head_ref_name }, "PR freshness fetch")
    local integration_sha = git_mechanics.remote_head(core.git, branches.integration, "PR freshness remote head", "unsafe PR freshness branch head")
    local branch_sha = git_mechanics.remote_head(core.git, pr.head_ref_name, "PR freshness remote head", "unsafe PR freshness branch head")
    if branch_sha ~= pr.head_sha then
      devloop_logging.log_cas_decision("pr_freshness_scan", origin.proposal_id, state, "tick", "freshness", "skip-stale(head)", "PR head changed after GitHub read")
      return
    end
    if git_mechanics.is_ancestor(core.git, integration_sha, branch_sha, "PR freshness ancestor check") then
      devloop_logging.log_cas_decision("pr_freshness_scan", origin.proposal_id, state, "tick", "freshness", "skip-idempotent(integration-ancestor)", "PR branch already contains integration")
      return
    end

    local runtime = git_mechanics.runtime_root()
    with_temp_worktree(runtime, repo, pr.head_ref_name, branches.integration, branch_sha, function(worktree)
      local merge_result = git_mechanics.git_merge_no_ff(core.git, worktree, integration_sha, 120)
      if merge_result.exit_code == 0 then
        write_refresh_commit(worktree, runtime, repo, pr.head_ref_name, branches.integration, branch_sha, integration_sha)
        push_if_real(repo, pr.head_ref_name, branch_sha, worktree)
        return
      end
      local unmerged = core.git.unmerged_paths(worktree, 30)
      if unmerged.exit_code ~= 0 then
        error("github-devloop: unmerged-path-check-failed: PR freshness unmerged path check failed: " .. tostring(unmerged.stderr))
      end
      if tostring(unmerged.stdout or "") ~= "" then
        raise_conflict(repo, pr.head_ref_name, branches.integration, branch_sha, integration_sha, listed_pr.number)
        return
      end
      error("github-devloop: merge-conflict-state-missing: PR freshness merge failed without conflicts: " .. tostring(merge_result.stderr))
    end)
  end)
end

local function prepare_listed_pr(repo, branches, listed_pr)
  local pr, pr_checkpoint = load_current_pr(repo, listed_pr)
  pr.number = listed_pr.number
  local origin = m_facts.pr_origin_fact(pr.comments)
  if not in_managed_scope(repo, branches, pr, origin) then
    devloop_logging.log_cas_decision("pr_freshness_scan", "pr-freshness", { state = nil, version = nil }, "tick", "freshness", "skip-foreign(pr-shape)", "PR is outside managed freshness scope")
    commit_checkpoint(pr_checkpoint, pr)
    return nil
  end

  return {
    listed_pr = listed_pr,
    origin = origin,
    pr = pr,
    pr_checkpoint = pr_checkpoint,
  }
end

local function backing_issue_numbers(prepared_prs)
  local numbers = {}
  local seen = {}
  for _, prepared in ipairs(prepared_prs) do
    local number = tonumber(prepared.origin.issue_number)
    if number ~= nil and not seen[number] then
      seen[number] = true
      table.insert(numbers, number)
    end
  end
  return numbers
end

local function process_prepared_pr(repo, branches, prepared, issue_versions)
  local issue_number = prepared.origin.issue_number
  local issue_updated_at = issue_versions[tonumber(issue_number)]
  local issue, issue_checkpoint = issue_state(repo, issue_number, issue_updated_at)
  process_pr(repo, branches, prepared.listed_pr, prepared.pr, prepared.origin, issue)
  commit_checkpoint(issue_checkpoint, issue)
  commit_checkpoint(prepared.pr_checkpoint, prepared.pr)
end

return saga.department(spec, { done = function() return false end, act = function(event)
  devloop_logging.log_entry("pr_freshness_scan", event, "pr-freshness", event and event.queue or "")
  local branches = config.branch_config()
  local cfg = config.devloop_config()
  local repo = require_repo(cfg.repo)
  if branches.integration == branches.upstream then
    devloop_logging.log_cas_decision("pr_freshness_scan", "pr-freshness", { state = "same-branch", version = branches.integration }, "tick", "freshness", "skip-idempotent(same-branch)", "integration branch equals upstream branch")
    return
  end
  with_lock(scan_lock_key(repo), function()
    local prs = list_open_prs(repo)
    local prepared_prs = {}
    for _, listed_pr in ipairs(prs) do
      local prepared = prepare_listed_pr(repo, branches, listed_pr)
      if prepared ~= nil then
        table.insert(prepared_prs, prepared)
      end
    end
    local issue_versions = list_issue_versions(repo, backing_issue_numbers(prepared_prs))
    for _, prepared in ipairs(prepared_prs) do
      process_prepared_pr(repo, branches, prepared, issue_versions)
    end
  end)
end, name = "pr_freshness_scan" })
