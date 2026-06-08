local S = {}

function S.install(M)
function M.build_devloop_ready_payload(source)
  return {
    schema = "github-devloop.ready.v1",
    proposal_id = source.proposal_id,
    dedup_key = M._dedup_key({
      "ready",
      tostring(source.dedup_key),
    }),
    source_ref = M.normalize_source_ref(source.source_ref),
  }
end

function M.build_devloop_reviewing_payload(origin, pr_number, source_ref, version)
  local review_version = version or origin.impl_version
  return {
    schema = "github-devloop.reviewing.v1",
    proposal_id = origin.proposal_id,
    pr_number = pr_number,
    version = review_version,
    dedup_key = M._dedup_key({
      "reviewing",
      tostring(origin.proposal_id),
      tostring(review_version),
      tostring(pr_number),
    }),
    source_ref = M.normalize_source_ref(source_ref),
  }
end

function M.build_devloop_fixing_payload(origin, pr_number, review_fact, source_ref)
  local version = origin.impl_version
  if review_fact.fix_version ~= nil then
    version = review_fact.fix_version
  end
  return {
    schema = "github-devloop.fixing.v1",
    proposal_id = origin.proposal_id,
    pr_number = pr_number,
    version = version,
    review_proposal_id = review_fact.review_proposal_id,
    review_dedup_key = review_fact.review_dedup_key,
    reviewed_head_sha = review_fact.reviewed_head_sha,
    dedup_key = M._dedup_key({
      "fixing",
      tostring(origin.proposal_id),
      tostring(version),
      tostring(pr_number),
      tostring(review_fact.review_dedup_key),
    }),
    source_ref = M.normalize_source_ref(source_ref),
  }
end

function M.build_devloop_review_meta_payload(unresolved, issue_proposal_id, issue_version, pr_number, n, source_ref)
  return {
    schema = "github-devloop.review-meta.v1",
    proposal_id = issue_proposal_id,
    review_proposal_id = unresolved.proposal_id,
    review_dedup_key = unresolved.dedup_key,
    version = issue_version,
    pr_number = pr_number,
    n = n,
    dedup_key = M._dedup_key({
      "review-meta",
      tostring(issue_proposal_id),
      tostring(issue_version),
      tostring(pr_number),
      tostring(n),
      tostring(unresolved.dedup_key),
    }),
    source_ref = M.normalize_source_ref(source_ref or unresolved.source_ref),
  }
end

function M.build_devloop_merge_ready_payload(issue_proposal_id, pr_number, version, review_fact, source_ref)
  return {
    schema = "github-devloop.merge-ready.v1",
    proposal_id = issue_proposal_id,
    pr_number = pr_number,
    version = version,
    review_proposal_id = review_fact and review_fact.review_proposal_id,
    review_dedup_key = review_fact and review_fact.review_dedup_key,
    reviewed_head_sha = review_fact and review_fact.reviewed_head_sha,
    dedup_key = M._dedup_key({
      "merge-ready",
      tostring(issue_proposal_id),
      tostring(version),
      tostring(pr_number),
      tostring(review_fact and review_fact.review_dedup_key or "review"),
    }),
    source_ref = M.normalize_source_ref(source_ref),
  }
end

function M.build_devloop_intake_candidate_payload(repo, issue_number, updated_at)
  local proposal_id = M.proposal_id(repo, issue_number)
  local source_ref = {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
  return {
    schema = "github-devloop.intake-candidate.v1",
    repo = repo,
    issue_number = issue_number,
    proposal_id = proposal_id,
    dedup_key = M.intake_dedup_key(proposal_id, updated_at),
    source_ref = source_ref,
  }
end

function M.build_proposal(issue, body)
  local proposal_id = M.proposal_id(issue.repo, issue.number)
  local title = tostring(issue.title or "")
  if #title > M._max_title_len then
    title = title:sub(1, M._max_title_len)
  end

  return {
    schema = "consensus.proposal.v1",
    verdict_mode = "converge",
    proposal_id = proposal_id,
    title = title,
    body = M.bounded_body(body),
    dedup_key = M.proposal_dedup_key(proposal_id, issue.updated_at),
    source_ref = M.normalize_source_ref(issue.source_ref),
  }
end

-- Thread the meta-judge's narrowing onto a re-raised next-round proposal so the next
-- angles converge instead of blindly re-judging the same question. The next round sees
-- ONLY the bounded convergence_question + prior-round digests (verdict + short reply),
-- never prior peer full text, preserving angle peer-invisibility. The `/loop/N` dedup
-- shape stays unchanged so the existing round parsing + budget endpoint still work.
local function apply_converge_fields(proposal, n, converge)
  proposal.round = n
  if type(converge) ~= "table" then
    return proposal
  end
  if converge.narrowed_question ~= nil and converge.narrowed_question ~= "" then
    proposal.convergence_question = converge.narrowed_question
  end
  if type(converge.angle_digests) == "table" then
    proposal.prior_round_digests = converge.angle_digests
  end
  return proposal
end

function M.build_loop_proposal(repo, issue_number, current, source_ref, n, converge)
  local issue = {
    repo = repo,
    number = issue_number,
    title = current.title,
    updated_at = current.updated_at,
    source_ref = source_ref,
  }
  local proposal = M.build_proposal(issue, current.body)
  proposal.dedup_key = proposal.dedup_key .. "/loop/" .. tostring(n)
  return apply_converge_fields(proposal, n, converge)
end

local function build_pr_review_context(repo, pr_number, head_sha)
  local diff_cmd = M.gh_pr_diff_cmd(repo, pr_number)
  local checkout_cmd = "gh pr checkout " .. M._shell_single_quote(pr_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --detach"
  local head_check_cmd = M.gh_pr_view_origin_cmd(repo, pr_number)
  local context = "PR review source access:\n"
    .. "The full PR diff is intentionally not embedded in this reliable event payload.\n"
    .. "Before deciding, read the complete current diff from GitHub and inspect files as needed.\n"
    .. "Use this read-only command for the complete diff:\n"
    .. diff_cmd .. "\n"
    .. "Pin your review to head SHA: " .. tostring(head_sha) .. "\n"
    .. "Re-check the head with:\n"
    .. head_check_cmd .. "\n"
    .. "If headRefOid differs from the pinned SHA, reject or abstain as stale instead of reviewing mixed state.\n"
    .. "To inspect surrounding code locally when needed, use:\n"
    .. checkout_cmd .. "\n"
  if #context > M._max_pr_review_context_len then
    error("github-devloop: PR review source access context exceeds bounded context")
  end
  return context
end

function M.build_pr_review_proposal(repo, issue_number, pr_number, version, head_sha, current_issue, source_ref)
  local review_id = M.pr_review_proposal_id(repo, pr_number, version, head_sha)
  local title = "Review PR #" .. tostring(pr_number) .. " for issue #" .. tostring(issue_number)
  if type(current_issue) == "table" and tostring(current_issue.title or "") ~= "" then
    title = "Review PR #" .. tostring(pr_number) .. ": " .. tostring(current_issue.title)
  end
  if #title > M._max_title_len then
    title = title:sub(1, M._max_title_len)
  end

  local issue_title = type(current_issue) == "table" and tostring(current_issue.title or "") or ""
  if #issue_title > M._max_title_len then
    issue_title = issue_title:sub(1, M._max_title_len)
  end
  local issue_body = type(current_issue) == "table" and tostring(current_issue.body or "") or "(issue context unavailable)"
  if issue_body == "" then
    issue_body = "(empty issue body)"
  end
  issue_title = M.neutralize_untrusted_prompt_text(M._neutralize_fkst_markers(issue_title))
  issue_body = M.neutralize_untrusted_prompt_text(M._neutralize_fkst_markers(issue_body))
  if #issue_body > M._max_pr_issue_context_len then
    issue_body = issue_body:sub(1, M._max_pr_issue_context_len)
  end
  local context = build_pr_review_context(repo, pr_number, head_sha)
  local body = "Review the complete PR diff and decide whether it should advance to merge-ready."
    .. "\n\n" .. M._untrusted_issue_data_begin
    .. "\nIssue proposal: " .. tostring(M.proposal_id(repo, issue_number))
    .. "\nReviewed PR head: " .. tostring(head_sha)
    .. "\nIssue title:\n" .. issue_title
    .. "\n\nIssue body:\n" .. issue_body
    .. "\n" .. M._untrusted_issue_data_end
  if #body > M._max_body_len then
    error("github-devloop: PR review proposal exceeds bounded body")
  end
  return {
    schema = "consensus.proposal.v1",
    verdict_mode = "gate",
    proposal_id = review_id,
    title = M.neutralize_untrusted_prompt_text(title),
    body = body,
    context = context,
    dedup_key = M._dedup_key({
      review_id,
      "review",
    }),
    source_ref = M.normalize_source_ref(source_ref),
  }
end

function M.build_pr_review_loop_proposal(repo, issue_number, pr_number, version, head_sha, current_issue, source_ref, n, converge)
  local proposal = M.build_pr_review_proposal(repo, issue_number, pr_number, version, head_sha, current_issue, source_ref)
  proposal.dedup_key = proposal.dedup_key .. "/loop/" .. tostring(n)
  return apply_converge_fields(proposal, n, converge)
end
end

return S
