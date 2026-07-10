local C = {}

function C.find_linked_pr(snapshot, pr_number)
  for _, item in ipairs(snapshot and snapshot.prs or {}) do
    if tostring(item.number or "") == tostring(pr_number or "") then
      return item.current
    end
  end
  return nil
end

function C.snapshot_with_pr_comments(current_pr)
  local snapshot = { comments = {}, prs = {} }
  for _, comment in ipairs(current_pr and current_pr.comments or {}) do
    table.insert(snapshot.comments, comment)
  end
  return snapshot
end

function C.has_reviewing_marker(has_state_marker, comments, proposal_id, version)
  return has_state_marker(comments, proposal_id, "reviewing", version)
end

function C.can_direct_from_observer(dept)
  return dept ~= "observe_pr"
end

function C.fixing_comment_request(build_request, issue, pr_number, fix_payload, feedback, source_ref)
  local reason = fix_payload.gate_failure_excerpt or feedback.review_reason or feedback.reason or "fixing-replay"
  local request = build_request(
    issue.repo,
    issue.number,
    {
      proposal_id = fix_payload.proposal_id,
      pr_number = pr_number,
      version = fix_payload.version,
      review_proposal_id = fix_payload.review_proposal_id,
      review_dedup_key = fix_payload.review_dedup_key,
      reviewed_head_sha = fix_payload.reviewed_head_sha,
    },
    fix_payload.version,
    reason,
    fix_payload.gate_baseline_sha,
    source_ref,
    fix_payload.predecessor_set,
    {
      blocking_gap = fix_payload.blocking_gap,
      gate_failure_excerpt = fix_payload.gate_failure_excerpt,
      ci_failure_key = fix_payload.ci_failure_key,
      preserve_nil_gate_failure_excerpt = fix_payload.gate_failure_excerpt == nil,
    }
  )
  request.handoff.dedup_key = fix_payload.dedup_key
  return request
end

function C.terminal_action(tools, dept, issue, state, proposal_id, link, current_pr, facts)
  if tools == nil or type(tools.terminal_linked_pr_action) ~= "function" then
    return nil
  end
  return tools.terminal_linked_pr_action(dept, issue, state, proposal_id, link, current_pr, facts)
end

return C
