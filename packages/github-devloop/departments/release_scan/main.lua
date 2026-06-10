local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_release_tick" },
  produces = {
    "consensus.proposal",
    "github-proxy.github_issue_create_request",
  },
  fanout = { "devloop_release_tick" },
  stall_window = "5m",
}

local function run_cmd(cmd, timeout, error_class)
  local result = exec_sync({ cmd = cmd, timeout = timeout or 30 })
  if result.exit_code ~= 0 then
    error("github-devloop: " .. error_class .. " failed: " .. tostring(result.stderr))
  end
  return result
end

local function trim_stdout(result)
  local stdout = tostring(result.stdout or ""):gsub("%s+$", "")
  return stdout
end

local function latest_tag()
  local result = exec_sync({ cmd = core.git_latest_release_tag_cmd("dev"), timeout = 30 })
  if result.exit_code ~= 0 then
    return "v0.0.0"
  end
  local tag = trim_stdout(result)
  if tag == "" then
    return "v0.0.0"
  end
  return tag
end

local function delta_count(base_ref, head_sha)
  local result = run_cmd(core.git_release_delta_count_cmd(base_ref, head_sha), 30, "git release delta count")
  local count = tonumber(trim_stdout(result))
  if count == nil or count < 0 then
    error("github-devloop: invalid release delta count")
  end
  return count
end

local function marker_issue_create_request(repo, proposal)
  return {
    schema = "github-proxy.issue-create.v1",
    repo = repo,
    title = "Release proposal " .. tostring(proposal.tag),
    body = "github-devloop release proposal pending\n\n"
      .. core.release_marker(repo, proposal.tag, proposal.head_sha, "pending", proposal.dedup_key),
    dedup_key = core._dedup_key({ "release", "pending-marker", repo, proposal.tag, proposal.head_sha }),
    source_ref = core.release_source_ref(repo),
  }
end

function pipeline(event)
  core.log_entry("release_scan", event, "release", event and event.queue or "")
  local cfg = core.devloop_config()
  local repo = tostring(cfg.repo or "")
  if repo == "" or core.safe_repo(repo) ~= repo then
    error("github-devloop: FKST_GITHUB_REPO is required for release scan")
  end

  with_lock(core.release_lock_key(repo), function()
    run_cmd(core.git_fetch_branch_cmd("origin", "dev"), 60, "git release fetch")
    local head_sha = trim_stdout(run_cmd(core.git_remote_branch_head_cmd("origin", "dev"), 30, "git release remote head"))
    if not core._is_git_sha(head_sha) then
      error("github-devloop: unsafe release dev head")
    end

    local base_ref = latest_tag()
    local count = delta_count(base_ref, head_sha)
    if count == 0 then
      core.log_cas_decision("release_scan", "release", { state = "empty", version = base_ref }, "tick", "proposal", "skip-idempotent(empty-delta)", "dev has no release delta")
      return
    end

    local tag = core.next_release_tag(base_ref)
    local proposal = core.build_release_proposal(repo, tag, head_sha, base_ref)
    local marker_view = run_cmd(core.gh_issue_list_release_markers_cmd(repo), 30, "gh release marker list")
    local comments = core.parse_release_marker_issue_list(marker_view.stdout)
    core.log_forged_markers("release_scan", proposal.proposal_id, comments)
    local fact = core.release_fact(comments, repo, tag, head_sha)
    if fact ~= nil then
      core.log_cas_decision("release_scan", proposal.proposal_id, { state = fact.status, version = fact.dedup_key }, "tick", "proposal", "skip-idempotent(release-marker)", "release marker already covers this head")
      return
    end

    core.log_raise("release_scan", proposal.proposal_id, "github-proxy.github_issue_create_request", marker_issue_create_request(repo, {
      tag = tag,
      head_sha = head_sha,
      dedup_key = proposal.dedup_key,
    }))
    core.log_raise("release_scan", proposal.proposal_id, "consensus.proposal", proposal)
  end)
end

return M
