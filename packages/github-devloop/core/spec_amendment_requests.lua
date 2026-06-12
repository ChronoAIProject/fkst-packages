local S = {}

function S.install(M)
function M.build_spec_amendment_issue_create_request(repo, issue_number, review_meta, title_brief, reason, comments)
  local title = "Spec amendment needed: " .. tostring(title_brief or ("Issue #" .. tostring(issue_number or "unknown")))
  if #title > M._max_title_len then
    title = M.truncate_utf8(title, M._max_title_len)
  end
  local evidence = M.build_comment_evidence_digest(comments)
  local body = "Spec flaw statement:\n" .. M.neutralize_untrusted_comment_text(reason or "")
    .. "\n\nEvidence digest:\n" .. M.neutralize_untrusted_comment_text(evidence)
    .. "\n\nParent issue: #" .. tostring(issue_number or "unknown")
    .. "\nParent PR: #" .. tostring(review_meta.pr_number)
    .. "\nReview proposal: " .. tostring(review_meta.review_proposal_id)
    .. "\nReview dedup: " .. tostring(review_meta.dedup_key)
    .. "\n\nThis issue requests a spec revision only. Do not edit the human-authored parent issue text."
  if #body > M._max_body_len then
    body = M.truncate_utf8(body, M._max_body_len)
  end
  return {
    schema = "github-proxy.issue-create.v1",
    repo = repo,
    title = title,
    body = body,
    labels = json.decode("[]"),
    dedup_key = M._dedup_key({
      "spec-amendment",
      tostring(review_meta.proposal_id),
      tostring(review_meta.dedup_key),
    }),
    parent_comment_target = {
      repo = repo,
      pr_number = review_meta.pr_number,
    },
    source_ref = M.normalize_source_ref(review_meta.source_ref),
  }
end
end

return S
