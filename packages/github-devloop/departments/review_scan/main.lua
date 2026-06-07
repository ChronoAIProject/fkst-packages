local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_branch_tick" },
  produces = {
    "devloop_reviewing",
    "consensus.proposal",
  },
  fanout = { "devloop_branch_tick" },
  retry = core.marker_lag_retry(),
  stall_window = "5m",
}

local PR_LIMIT = 100

local function require_repo(repo)
  local value = tostring(repo or "")
  if value == "" or core.safe_repo(value) ~= value then
    error("github-devloop: FKST_GITHUB_REPO is required for review scan")
  end
  return value
end

local function source_ref(kind, repo, number)
  return {
    kind = "external",
    ref = tostring(repo) .. "#" .. tostring(kind) .. "/" .. tostring(number),
  }
end

local function run_cmd(cmd, timeout, error_class)
  local result = exec_sync({ cmd = cmd, timeout = timeout or 30 })
  if result.exit_code ~= 0 then
    error("github-devloop: " .. error_class .. " failed: " .. tostring(result.stderr))
  end
  return result
end

local function review_loop_unresolved(review_proposal_id, dedup_key, pr_source_ref)
  return {
    schema = "consensus.consensus_unresolved.v1",
    proposal_id = review_proposal_id,
    dedup_key = tostring(dedup_key),
    source_ref = core.normalize_source_ref(pr_source_ref),
  }
end

local function raise_review_loop_proposal(repo, pr, origin, current_issue, diff, review_proposal_id, last_dedup_key, n)
  local pr_source_ref = source_ref("pr", repo, pr.number)
  local unresolved = review_loop_unresolved(review_proposal_id, last_dedup_key, pr_source_ref)
  local proposal = core.build_pr_review_loop_proposal(
    repo,
    origin.issue_number,
    pr.number,
    current_issue.state.version,
    pr.head_sha,
    current_issue.current,
    diff,
    pr_source_ref,
    n
  )
  if not core.validate_proposal(proposal) then
    log.warn("github-devloop dept=review_scan proposal_id=" .. tostring(origin.proposal_id) .. " tag=SKIP reason=cannot-build-valid-review-loop-proposal")
    return
  end
  core.log_apply("review_scan", origin.proposal_id, nil, nil, { add = {}, remove = {} }, {
    "consensus.proposal",
  })
  core.log_raise("review_scan", origin.proposal_id, "consensus.proposal", proposal)
end

local function maybe_raise_initial_review(repo, pr, origin, current_issue, review_proposal_id)
  if core.has_any_review_result_marker(current_issue.current.comments, review_proposal_id, origin.proposal_id) then
    return
  end
  local payload = core.build_devloop_reviewing_payload(origin, pr.number, source_ref("issue", repo, origin.issue_number), current_issue.state.version)
  core.log_apply("review_scan", origin.proposal_id, nil, nil, { add = {}, remove = {} }, {
    "devloop_reviewing",
  })
  core.log_raise("review_scan", origin.proposal_id, "devloop_reviewing", payload)
end

local function fetch_stable_diff(repo, pr, current_pr)
  local diff = run_cmd(core.gh_pr_diff_cmd(repo, pr.number), 30, "gh review scan PR diff")
  local recheck = run_cmd(core.gh_pr_view_origin_cmd(repo, pr.number), 30, "gh review scan PR recheck")
  local rechecked_pr = core.parse_pr_view_origin(recheck.stdout)
  if tostring(rechecked_pr.head_ref_name or "") ~= tostring(current_pr.head_ref_name or "")
    or tostring(rechecked_pr.head_sha or "") ~= tostring(current_pr.head_sha or "")
    or tostring(rechecked_pr.state or ""):lower() ~= "open" then
    error("github-devloop: PR head moved while reading review scan diff; retrying")
  end
  return diff.stdout
end

local function maybe_heal_review(repo, pr, current_pr, origin, current_issue)
  local review_proposal_id = core.pr_review_proposal_id(repo, pr.number, current_issue.state.version, pr.head_sha)
  if core.has_any_review_result_marker(current_issue.current.comments, review_proposal_id, origin.proposal_id) then
    return
  end

  local marker_n, marker_dedup_key = core.review_loop_progress_from_github_markers(current_issue.current.comments, review_proposal_id, origin.proposal_id)
  if marker_n == 0 then
    maybe_raise_initial_review(repo, pr, origin, current_issue, review_proposal_id)
    return
  end

  local budget = core.loop_budget()
  if marker_n >= budget or marker_dedup_key == nil or marker_dedup_key == "" then
    return
  end

  local diff = fetch_stable_diff(repo, pr, current_pr)
  raise_review_loop_proposal(repo, pr, origin, current_issue, diff, review_proposal_id, marker_dedup_key, marker_n)
end

local function scan_pr(repo, pr, branches)
  if tostring(pr.state or ""):lower() ~= "open"
    or tostring(pr.base_ref_name or "") ~= tostring(branches.integration)
    or not core.is_safe_pr_number(pr.number)
    or not core.is_safe_head_sha(pr.head_sha) then
    return
  end

  local pr_view = run_cmd(core.gh_pr_view_origin_cmd(repo, pr.number), 30, "gh review scan PR view")
  local current_pr = core.parse_pr_view_origin(pr_view.stdout)
  local origin = core.pr_origin_fact(current_pr.comments)
  if origin == nil then
    return
  end
  if origin.repo ~= repo
    or tostring(origin.branch or "") ~= tostring(current_pr.head_ref_name or "")
    or tostring(origin.base_branch or "") ~= tostring(branches.integration)
    or tostring(current_pr.head_sha or "") ~= tostring(pr.head_sha)
    or tostring(current_pr.state or ""):lower() ~= "open" then
    return
  end

  local lock_key = core.review_lock_key(origin.proposal_id)
  if lock_key == nil then
    return
  end

  with_lock(lock_key, function()
    local issue_view = run_cmd(core.gh_issue_view_review_cmd(origin.repo, origin.issue_number), 30, "gh review scan issue view")
    local current_issue = core.parse_issue_view_review(issue_view.stdout)
    core.log_forged_markers("review_scan", origin.proposal_id, current_issue.comments)
    local state = core.current_state(current_issue.comments, origin.proposal_id)
    if state.state ~= "reviewing" then
      return
    end

    maybe_heal_review(repo, {
      number = pr.number,
      head_sha = current_pr.head_sha,
    }, current_pr, origin, {
      current = current_issue,
      state = state,
    })
  end)
end

function pipeline(event)
  core.log_entry("review_scan", event, "github-devloop/review-scan", "tick")
  core.assert_trusted_bot_configured()
  local branches = core.branch_config()
  local repo = require_repo(core.devloop_config().repo)
  local listed = run_cmd(core.gh_pr_list_open_cmd(repo, PR_LIMIT), 30, "gh review scan PR list")
  for _, pr in ipairs(core.parse_pr_list_open(listed.stdout)) do
    scan_pr(repo, pr, branches)
  end
end

return M
