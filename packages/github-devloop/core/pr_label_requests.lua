local S = {}

function S.install(M)
function M.build_pr_state_label_request(repo, issue_number, pr_number, proposal_id, to_state, version, dedup_key_value, source_ref)
  local add_labels, remove_labels = M.state_label_changes(to_state)
  return M.attach_issue_claim({
    schema = "github-proxy.label.v1",
    repo = repo,
    target_kind = "pr",
    target_number = pr_number,
    pr_number = pr_number,
    issue_number = issue_number,
    expected_proposal_id = proposal_id,
    expected_state = to_state,
    expected_version = version,
    add_labels = add_labels,
    remove_labels = remove_labels,
    dedup_key = dedup_key_value,
    source_ref = M.normalize_source_ref(source_ref),
  }, issue_number ~= nil and M.issue_source_ref(repo, issue_number) or nil)
end

function M.build_reconcile_pr_state_label_request(repo, issue_number, pr_number, proposal_id, state, version, source_ref)
  return M.build_pr_state_label_request(
    repo,
    issue_number,
    pr_number,
    proposal_id,
    state,
    version,
    M._dedup_key({
      "reconcile",
      "pr-label",
      tostring(proposal_id),
      tostring(state),
      tostring(version or "unversioned"),
      tostring(pr_number),
    }),
    source_ref
  )
end

function M.build_pr_reviewing_label_request(repo, issue_number, origin, pr_number, source_ref)
  return M.build_pr_state_label_request(
    repo,
    issue_number,
    pr_number,
    origin.proposal_id,
    "reviewing",
    origin.impl_version,
    M._dedup_key({
      "observe-pr",
      "pr-label",
      tostring(origin.proposal_id),
      tostring(origin.impl_version),
      tostring(pr_number),
    }),
    source_ref
  )
end

function M.build_pr_review_result_label_request(repo, issue_number, pr_number, issue_proposal_id, reached, source_ref, state_version)
  local to_state = reached.decision == "approve" and "merge-ready" or "fixing"
  local _, _, review_version = M.parse_pr_review_proposal_id(reached.proposal_id)
  local issue_version = state_version or review_version
  return M.build_pr_state_label_request(
    repo,
    issue_number,
    pr_number,
    issue_proposal_id,
    to_state,
    issue_version,
    M._dedup_key({
      "review-result",
      "pr-label",
      tostring(issue_proposal_id),
      tostring(reached.decision),
      tostring(reached.dedup_key),
      tostring(pr_number),
    }),
    source_ref
  )
end

function M.build_pr_fix_reviewing_label_request(repo, issue_number, pr_number, fix, new_head_sha, new_version)
  return M.build_pr_state_label_request(
    repo,
    issue_number,
    pr_number,
    fix.proposal_id,
    "reviewing",
    new_version,
    M._dedup_key({
      "fix",
      "pr-label",
      tostring(fix.proposal_id),
      tostring(fix.review_dedup_key),
      tostring(new_head_sha),
      tostring(pr_number),
    }),
    fix.source_ref
  )
end

function M.build_pr_merge_head_reviewing_label_request(repo, issue_number, pr_number, merge_ready, new_head_sha, new_version, source_ref)
  return M.build_pr_state_label_request(
    repo,
    issue_number,
    pr_number,
    merge_ready.proposal_id,
    "reviewing",
    new_version,
    M._dedup_key({
      "merge",
      "pr-label",
      "reviewing",
      tostring(merge_ready.proposal_id),
      tostring(new_version),
      tostring(new_head_sha),
      tostring(pr_number),
    }),
    source_ref
  )
end

function M.build_pr_merge_fixing_label_request(repo, issue_number, merge_ready, fix_version, source_ref)
  return M.build_pr_state_label_request(repo, issue_number, merge_ready.pr_number, merge_ready.proposal_id, "fixing", fix_version, merge_ready.dedup_key .. "/pr-label/fixing", source_ref)
end

function M.build_pr_merged_label_request(repo, issue_number, merge_ready, source_ref)
  return M.build_pr_state_label_request(repo, issue_number, merge_ready.pr_number, merge_ready.proposal_id, "merged", merge_ready.version, merge_ready.dedup_key .. "/pr-label/merged", source_ref)
end

function M.build_pr_merging_label_request(repo, issue_number, merge_ready)
  return M.build_pr_state_label_request(repo, issue_number, merge_ready.pr_number, merge_ready.proposal_id, "merging", merge_ready.version, merge_ready.dedup_key .. "/pr-label/merging", M.pr_source_ref(repo, merge_ready.pr_number))
end
end

return S
