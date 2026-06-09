local S = {}

function S.install(M)
function M.build_devloop_ready_payload(source)
  local payload = {
    schema = "github-devloop.ready.v1",
    proposal_id = source.proposal_id,
    dedup_key = M._dedup_key({
      "ready",
      tostring(source.dedup_key),
    }),
    source_ref = M.normalize_source_ref(source.source_ref),
  }
  if source.framing ~= nil then
    payload.framing = tostring(source.framing)
  end
  return payload
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
  local payload = {
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
  return payload
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

function M.build_issue_fetch_context(repo, issue_number, source_ref)
  local source_repo, source_issue_number = M.parse_issue_source_ref(M.normalize_source_ref(source_ref))
  if source_repo == nil
    or tostring(source_repo) ~= tostring(repo)
    or tostring(source_issue_number) ~= tostring(issue_number) then
    error("github-devloop: issue source_ref does not match fetch context")
  end
  return "Fetch the full current GitHub issue body and all comments before judging.\n"
    .. "Use source_ref external " .. tostring(source_repo) .. "#issue/" .. tostring(source_issue_number) .. " as the issue source of truth.\n"
    .. "Command: gh issue view " .. M._shell_single_quote(issue_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --json title,body,comments,state,labels,updatedAt"
end

function M.build_pr_review_fetch_context(repo, issue_number, pr_number, head_sha, source_ref)
  local source_repo, source_pr_number = M.parse_pr_source_ref(M.normalize_source_ref(source_ref))
  if source_repo == nil
    or tostring(source_repo) ~= tostring(repo)
    or tostring(source_pr_number) ~= tostring(pr_number) then
    error("github-devloop: PR review source_ref does not match fetch context")
  end
  if not M.is_safe_head_sha(head_sha) then
    error("github-devloop: invalid PR review head sha")
  end
  return "Fetch the full current GitHub issue body and all comments before judging.\n"
    .. "Command: gh issue view " .. M._shell_single_quote(issue_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --json title,body,comments,state,labels,updatedAt\n"
    .. "Use source_ref external " .. tostring(source_repo) .. "#pr/" .. tostring(source_pr_number) .. " as the PR source of truth.\n"
    .. "Fetch the complete current PR diff from source_ref before judging.\n"
    .. "Command: gh pr diff " .. M._shell_single_quote(pr_number)
    .. " --repo " .. M._shell_single_quote(repo) .. "\n"
    .. "Do not use proposal payload body, diff, comments, or source_bundle as source material; this proposal intentionally omits them.\n"
    .. "Verify the reviewed PR head is " .. tostring(head_sha) .. ".\n"
    .. "When the diff needs surrounding code context, read relevant files from the checked-out repository or PR worktree at the current working directory."
end

function M.assert_pr_review_fetch_source_available(repo, pr_number, expected_head_sha, source_ref)
  local source_repo, source_pr_number = M.parse_pr_source_ref(M.normalize_source_ref(source_ref))
  if source_repo == nil
    or tostring(source_repo) ~= tostring(repo)
    or tostring(source_pr_number) ~= tostring(pr_number) then
    error("github-devloop: PR review source_ref does not match fetch source")
  end
  if not M.is_safe_head_sha(expected_head_sha) then
    error("github-devloop: invalid expected PR review head sha")
  end

  local result = exec_sync({ cmd = M.gh_pr_diff_cmd(repo, pr_number), timeout = 60 })
  if result.exit_code ~= 0 then
    error("github-devloop: gh pr diff failed for PR review source_ref fetch: " .. tostring(result.stderr))
  end

  local head_view = exec_sync({ cmd = M.gh_pr_view_origin_cmd(repo, pr_number), timeout = 30 })
  if head_view.exit_code ~= 0 then
    error("github-devloop: gh pr head recheck failed after source_ref fetch: " .. tostring(head_view.stderr))
  end
  local current_pr = M.parse_pr_view_origin(head_view.stdout)
  if tostring(current_pr.state or ""):lower() ~= "open"
    or tostring(current_pr.head_sha or "") ~= tostring(expected_head_sha) then
    error("github-devloop: PR head moved after source_ref diff fetch; retrying")
  end
  return true
end

function M.build_proposal(issue)
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
    dedup_key = M.proposal_dedup_key(proposal_id, issue.updated_at),
    source_ref = M.normalize_source_ref(issue.source_ref),
    fetch_context = M.build_issue_fetch_context(issue.repo, issue.number, issue.source_ref),
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
  local proposal = M.build_proposal(issue)
  proposal.dedup_key = proposal.dedup_key .. "/loop/" .. tostring(n)
  return apply_converge_fields(proposal, n, converge)
end

function M.build_pr_review_proposal(repo, issue_number, pr_number, version, head_sha, current_issue, source_ref, codex_cwd)
  local review_id = M.pr_review_proposal_id(repo, pr_number, version, head_sha)
  local title = "Review PR #" .. tostring(pr_number) .. " for issue #" .. tostring(issue_number)
  if type(current_issue) == "table" and tostring(current_issue.title or "") ~= "" then
    title = "Review PR #" .. tostring(pr_number) .. ": " .. tostring(current_issue.title)
  end
  if #title > M._max_title_len then
    title = title:sub(1, M._max_title_len)
  end

  local proposal = {
    schema = "consensus.proposal.v1",
    verdict_mode = "gate",
    proposal_id = review_id,
    title = M.neutralize_untrusted_prompt_text(title),
    dedup_key = M._dedup_key({
      review_id,
      "review",
    }),
    source_ref = M.normalize_source_ref(source_ref),
    fetch_context = M.build_pr_review_fetch_context(repo, issue_number, pr_number, head_sha, source_ref),
  }
  if codex_cwd ~= nil then
    proposal.codex_cwd = codex_cwd
  end
  return proposal
end

function M.build_pr_review_loop_proposal(repo, issue_number, pr_number, version, head_sha, current_issue, source_ref, codex_cwd, n, converge)
  local proposal = M.build_pr_review_proposal(repo, issue_number, pr_number, version, head_sha, current_issue, source_ref, codex_cwd)
  proposal.dedup_key = proposal.dedup_key .. "/loop/" .. tostring(n)
  return apply_converge_fields(proposal, n, converge)
end
end

return S
