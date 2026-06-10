local core = require("core")

local M = {}

M.spec = {
  consumes = { "consensus.consensus_reached" },
  produces = {},
  fanout = { "consensus.consensus_reached" },
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

local function temp_notes_file(repo, tag, head_sha)
  return "/tmp/fkst-github-devloop-release-"
    .. core._decimal_checksum(tostring(repo) .. "#" .. tostring(tag) .. "#" .. tostring(head_sha))
    .. ".md"
end

local function existing_ok(cmd)
  local result = exec_sync({ cmd = cmd, timeout = 30 })
  return result.exit_code == 0
end

local function draft_notes(repo, tag, base_ref, head_sha)
  core.log_codex_start("release_publish", core.release_proposal_id(repo, tag, head_sha), "release-notes")
  local result = spawn_codex_sync({
    prompt = core.release_notes_prompt(repo, tag, base_ref, head_sha),
    timeout = 600,
  })
  if result.exit_code ~= 0 then
    core.log_codex_result("release_publish", core.release_proposal_id(repo, tag, head_sha), "release-notes", result, nil, tostring(result.stderr or ""))
    error("github-devloop: release notes codex failed: " .. tostring(result.stderr or ""))
  end
  core.log_codex_result("release_publish", core.release_proposal_id(repo, tag, head_sha), "release-notes", result, "result=completed", nil)
  return core.normalize_release_notes(result.stdout, tag)
end

function pipeline(event)
  local reached = event.payload or {}
  if not core.is_supported_release_result(reached) then
    core.log_entry("release_publish", event, "unknown", reached.dedup_key)
    core.log_cas_decision("release_publish", "unknown", { state = nil, version = nil }, "approve", "published", "skip-foreign(proposal_id)", "unsupported release consensus")
    return
  end

  local _, base_ref, tag, proposed_head = core.parse_release_proposal_id(reached.proposal_id)
  local repo = tostring(reached.source_ref.ref):match("^(.-)#repo$")
  if repo == nil or core.safe_repo(repo) ~= repo then
    core.log_cas_decision("release_publish", reached.proposal_id, { state = nil, version = nil }, "approve", "published", "skip-foreign(source_ref)", "release source_ref repo is invalid")
    return
  end
  core.log_entry("release_publish", event, reached.proposal_id, reached.dedup_key)
  with_lock(core.release_lock_key(repo), function()
    run_cmd(core.git_fetch_branch_cmd("origin", "dev"), 60, "git release publish fetch")
    local current_head = trim_stdout(run_cmd(core.git_remote_branch_head_cmd("origin", "dev"), 30, "git release publish head"))
    if tostring(current_head) ~= tostring(proposed_head) then
      core.log_cas_decision("release_publish", reached.proposal_id, { state = "head-moved", version = current_head }, "approve", "published", "skip-stale(head-cas)", "dev moved after release proposal")
      return
    end

    if core.write_mode() ~= "real" then
      core.log_line("info", "release_publish", reached.proposal_id, "OUTBOUND", {
        "mode=dry-run",
        "repo=" .. tostring(repo),
        "tag=" .. tostring(tag),
        "head_sha=" .. tostring(proposed_head),
        "reason=release publish requires FKST_GITHUB_WRITE=1",
      })
      return
    end

    local notes = draft_notes(repo, tag, base_ref, proposed_head)
    local notes_file = temp_notes_file(repo, tag, proposed_head)
    file.write(notes_file, notes)

    if not existing_ok(core.git_tag_exists_cmd(tag)) then
      run_cmd(core.git_annotated_tag_cmd(tag, proposed_head, notes_file), 60, "git release tag")
      run_cmd(core.git_push_tag_cmd(tag), 60, "git release tag push")
    end
    if not existing_ok(core.gh_release_view_cmd(repo, tag)) then
      run_cmd(core.gh_release_create_cmd(repo, tag, notes_file), 60, "gh release create")
    end
    core.log_cas_decision("release_publish", reached.proposal_id, { state = "approved", version = reached.dedup_key }, "approve", "published", "applied", "release published or already existed")
  end)
end

return M
