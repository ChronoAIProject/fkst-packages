local S = {}

function S.install(M)
local function safe_cwd(value)
  return type(value) == "string"
    and value ~= ""
    and #value <= 1000
    and value:sub(1, 1) == "/"
    and value:find("[%c]") == nil
end

local function same_source_ref(a, b)
  return type(a) == "table"
    and type(b) == "table"
    and tostring(a.kind or "") == tostring(b.kind or "")
    and tostring(a.ref or "") == tostring(b.ref or "")
end

local function command_matches(command, tool, args)
  if type(command) ~= "table" or tostring(command.tool or "") ~= tostring(tool) then
    return false
  end
  if type(command.args) ~= "table" or #command.args ~= #args then
    return false
  end
  for index, expected in ipairs(args) do
    if tostring(command.args[index] or "") ~= tostring(expected) then
      return false
    end
  end
  return true
end

local function valid_issue_fetch_source(source, repo, issue_number)
  local expected_ref = {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
  return type(source) == "table"
    and source.kind == "github_issue"
    and same_source_ref(source.source_ref, expected_ref)
    and command_matches(source.command, "gh", {
      "issue",
      "view",
      tostring(issue_number),
      "--repo",
      tostring(repo),
      "--json",
      "title,body,comments,state,labels,updatedAt",
    })
end

local function valid_pr_diff_fetch_source(source, repo, pr_number, head_sha)
  local expected_ref = {
    kind = "external",
    ref = tostring(repo) .. "#pr/" .. tostring(pr_number),
  }
  return type(source) == "table"
    and source.kind == "github_pr_diff"
    and same_source_ref(source.source_ref, expected_ref)
    and command_matches(source.command, "gh", {
      "pr",
      "diff",
      tostring(pr_number),
      "--repo",
      tostring(repo),
    })
    and tostring(source.expected_head_sha or "") == tostring(head_sha)
    and source.cwd_required == true
    and source.read_files_from_cwd == true
end

local function valid_issue_fetch_sources(fetch_sources, repo, issue_number)
  return type(fetch_sources) == "table"
    and #fetch_sources == 1
    and valid_issue_fetch_source(fetch_sources[1], repo, issue_number)
end

local function valid_pr_review_fetch_sources(fetch_sources, repo, issue_number, pr_number, head_sha)
  return type(fetch_sources) == "table"
    and #fetch_sources == 2
    and valid_issue_fetch_source(fetch_sources[1], repo, issue_number)
    and valid_pr_diff_fetch_source(fetch_sources[2], repo, pr_number, head_sha)
end

function M.validate_proposal(proposal)
  if type(proposal) ~= "table" then
    return false
  end
  if proposal.schema ~= "consensus.proposal.v1" then
    return false
  end
  local repo, issue_number = M.parse_proposal_id(proposal.proposal_id)
  if repo == nil or issue_number == nil then
    local review_repo, pr_number, _, head_sha = M.parse_pr_review_proposal_id(proposal.proposal_id)
    if review_repo == nil or pr_number == nil then
      return false
    end
    if not M._is_path_safe_key(proposal.proposal_id, M._max_key_len) or not M._is_path_safe_key(proposal.dedup_key, M._max_dedup_len) then
      return false
    end
    local source_repo, source_pr_number = M.parse_pr_source_ref(proposal.source_ref)
    if source_repo == nil
      or tostring(source_pr_number) ~= tostring(pr_number) then
      return false
    end
    local issue_repo, fetched_issue_number = nil, nil
    if type(proposal.fetch_sources) == "table"
      and type(proposal.fetch_sources[1]) == "table"
      and type(proposal.fetch_sources[1].source_ref) == "table" then
      issue_repo, fetched_issue_number = M.parse_issue_source_ref(proposal.fetch_sources[1].source_ref)
    end
    if issue_repo == nil
      or tostring(issue_repo) ~= tostring(source_repo)
      or not valid_pr_review_fetch_sources(proposal.fetch_sources, source_repo, fetched_issue_number, source_pr_number, head_sha) then
      return false
    end
    if not safe_cwd(proposal.codex_cwd) then
      return false
    end
  else
    if not M.is_safe_proposal_ref(proposal.proposal_id, proposal.dedup_key) then
      return false
    end
    local source_repo, source_issue_number = M.parse_issue_source_ref(proposal.source_ref)
    if source_repo == nil
      or tostring(source_repo) ~= tostring(repo)
      or tostring(source_issue_number) ~= tostring(issue_number) then
      return false
    end
    if not valid_issue_fetch_sources(proposal.fetch_sources, repo, issue_number) then
      return false
    end
  end
  if not M._is_bounded_string(proposal.title, M._max_title_len) then
    return false
  end
  if proposal.body ~= nil or proposal.diff ~= nil or proposal.comments ~= nil or proposal.source_bundle ~= nil then
    return false
  end
  if proposal.fetch_context ~= nil then
    return false
  end
  if proposal.codex_cwd ~= nil and not safe_cwd(proposal.codex_cwd) then
    return false
  end
  return M._has_bounded_source_ref(proposal.source_ref)
end
function M.is_supported_issue(payload)
  return type(payload) == "table"
    and payload.schema == "github-proxy.v1"
    and payload.type == "issue"
    and payload.repo ~= nil
    and payload.number ~= nil
    and payload.title ~= nil
    and payload.updated_at ~= nil
    and M.issue_ref_round_trips(payload.repo, payload.number)
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_pr(payload)
  return type(payload) == "table"
    and payload.schema == "github-proxy.v1"
    and payload.type == "pr"
    and payload.repo ~= nil
    and M.is_safe_pr_number(payload.number)
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_result(payload)
  return type(payload) == "table"
    and payload.schema == "consensus.consensus_reached.v1"
    and payload.decision == "approve"
    and M.is_safe_consensus_result_ref(payload.proposal_id, payload.dedup_key)
    and M._is_bounded_string(payload.body, M._max_body_len)
    and (payload.framing == nil or M._is_bounded_string(payload.framing, M._max_framing_len))
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_review_result(payload)
  return type(payload) == "table"
    and payload.schema == "consensus.consensus_reached.v1"
    and (payload.decision == "approve" or payload.decision == "reject")
    and M.is_safe_pr_review_result_ref(payload.proposal_id, payload.dedup_key)
    and M._is_bounded_string(payload.body, M._max_body_len)
    and (payload.framing == nil or M._is_bounded_string(payload.framing, M._max_framing_len))
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_unresolved(payload)
  return type(payload) == "table"
    and payload.schema == "consensus.consensus_converge.v1"
    and M.is_safe_consensus_result_ref(payload.proposal_id, payload.dedup_key)
    and payload.body == nil
    and payload.angle_results == nil
    and payload.decision == nil
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_pr_review_unresolved(payload)
  return type(payload) == "table"
    and payload.schema == "consensus.consensus_converge.v1"
    and M.is_safe_pr_review_result_ref(payload.proposal_id, payload.dedup_key)
    and payload.body == nil
    and payload.angle_results == nil
    and payload.decision == nil
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_ready(payload)
  return type(payload) == "table"
    and payload.schema == "github-devloop.ready.v1"
    and M.is_safe_proposal_ref(payload.proposal_id, payload.dedup_key)
    and (payload.framing == nil or M._is_bounded_string(payload.framing, M._max_framing_len))
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_reviewing(payload)
  return type(payload) == "table"
    and payload.schema == "github-devloop.reviewing.v1"
    and M.is_safe_proposal_ref(payload.proposal_id, payload.dedup_key)
    and M.is_safe_pr_number(payload.pr_number)
    and M._is_bounded_string(payload.version, M._max_dedup_len)
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_fixing(payload)
  return type(payload) == "table"
    and payload.schema == "github-devloop.fixing.v1"
    and M.is_safe_proposal_ref(payload.proposal_id, payload.dedup_key)
    and M.is_safe_pr_number(payload.pr_number)
    and M._is_bounded_string(payload.version, M._max_dedup_len)
    and M.is_safe_pr_review_result_ref(payload.review_proposal_id, payload.review_dedup_key)
    and M._is_git_sha(payload.reviewed_head_sha)
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_review_meta(payload)
  return type(payload) == "table"
    and payload.schema == "github-devloop.review-meta.v1"
    and M.is_safe_proposal_ref(payload.proposal_id, payload.dedup_key)
    and M.is_safe_pr_review_result_ref(payload.review_proposal_id, payload.review_dedup_key)
    and M._is_bounded_string(payload.version, M._max_dedup_len)
    and M.is_safe_pr_number(payload.pr_number)
    and tonumber(payload.n) ~= nil
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_merge_ready(payload)
  return type(payload) == "table"
    and payload.schema == "github-devloop.merge-ready.v1"
    and M.is_safe_proposal_ref(payload.proposal_id, payload.dedup_key)
    and M.is_safe_pr_number(payload.pr_number)
    and M._is_bounded_string(payload.version, M._max_dedup_len)
    and M.is_safe_pr_review_result_ref(payload.review_proposal_id, payload.review_dedup_key)
    and M._is_git_sha(payload.reviewed_head_sha)
    and M._has_bounded_source_ref(payload.source_ref)
end

function M.is_supported_intake_candidate(payload)
  if type(payload) ~= "table"
    or payload.schema ~= "github-devloop.intake-candidate.v1"
    or not M.is_safe_proposal_ref(payload.proposal_id, payload.dedup_key)
    or not M._has_bounded_source_ref(payload.source_ref) then
    return false
  end
  local repo, issue_number = M.parse_issue_source_ref(payload.source_ref)
  return repo ~= nil
    and issue_number ~= nil
    and tostring(repo) == tostring(payload.repo)
    and tostring(issue_number) == tostring(payload.issue_number)
    and tostring(payload.proposal_id) == M.proposal_id(repo, issue_number)
end
end

return S
