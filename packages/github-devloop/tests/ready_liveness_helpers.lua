local M = {}

function M.install(core, repo, proposal_id, timeout_state_comment)
  local function release_comment(state_version, created_at)
    return { body = core.dependency_release_marker(proposal_id, state_version), author_login = "fkst-test-bot", created_at = created_at or "2026-06-03T00:00:00Z" }
  end
  local function timeout_attempt_v2_comment(state_version, round, created_at)
    local row = core.restart_transition_row("ready")
    local comments = { timeout_state_comment("ready", state_version), release_comment(state_version) }
    local now_seconds = core.iso_timestamp_epoch_seconds(created_at or "2026-06-03T02:00:00Z")
    local eval = core.actionable_epoch.resolve(row, { state = "ready", version = state_version, proposal_id = proposal_id, marker_created_at = "2026-06-03T00:00:00Z" }, { proposal_id = proposal_id, current = { comments = comments }, now_seconds = now_seconds }, now_seconds)
    return { body = core.timeout_attempt_v2_marker(proposal_id, state_version, "ready", row.liveness_class_id, eval.generation_key, round, core.issue_source_ref(repo, 42)), author_login = "fkst-test-bot", created_at = created_at or "2026-06-03T00:00:00Z" }
  end
  local function append_release_attempts(comments, state_version)
    table.insert(comments, release_comment(state_version, "2026-06-03T00:00:00Z"))
    table.insert(comments, timeout_attempt_v2_comment(state_version, 1, "2026-06-03T00:01:00Z"))
    table.insert(comments, timeout_attempt_v2_comment(state_version, 2, "2026-06-03T00:02:00Z"))
    return comments
  end
  return { release_comment = release_comment, timeout_attempt_v2_comment = timeout_attempt_v2_comment, append_release_attempts = append_release_attempts }
end

return M
