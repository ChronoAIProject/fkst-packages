-- contract.github_devloop_pr_origin: policy-free PR-origin marker decoding.
local C = {}

local marker_pattern = "<!%-%- fkst:github%-devloop:pr%-origin:v1.-%-%->"

local function marker_attr(marker, name, allow_empty)
  local value_pattern = allow_empty and '="([^"]*)"' or '="([^"]+)"'
  return tostring(marker or ""):match(tostring(name) .. value_pattern)
end

function C.fact(text, authorities)
  local parse_issue_proposal_id = authorities.parse_issue_proposal_id
  local parse_pr_proposal_id = authorities.parse_pr_proposal_id
  local is_git_ref_safe = authorities.is_git_ref_safe
  local is_implementation_version = authorities.is_implementation_version

  for marker in tostring(text or ""):gmatch(marker_pattern) do
    local marker_proposal = marker_attr(marker, "proposal")
    local marker_issue = marker_attr(marker, "issue")
    local marker_branch = marker_attr(marker, "branch")
    local marker_impl_version = marker_attr(marker, "impl_version", true)
    local marker_base_branch = marker_attr(marker, "base_branch")
    local repo, issue_number = parse_issue_proposal_id(marker_proposal)
    if repo ~= nil
      and marker_issue == issue_number
      and is_git_ref_safe(marker_branch)
      and is_implementation_version(marker_impl_version)
      and is_git_ref_safe(marker_base_branch) then
      return {
        proposal_id = marker_proposal,
        repo = repo,
        issue_number = issue_number,
        branch = marker_branch,
        impl_version = marker_impl_version,
        base_branch = marker_base_branch,
      }
    end
    local pr_repo, pr_number = parse_pr_proposal_id(marker_proposal)
    if pr_repo ~= nil
      and marker_issue == tostring(pr_number)
      and is_git_ref_safe(marker_branch)
      and is_implementation_version(marker_impl_version)
      and is_git_ref_safe(marker_base_branch) then
      return {
        proposal_id = marker_proposal,
        repo = pr_repo,
        issue_number = nil,
        pr_number = pr_number,
        branch = marker_branch,
        impl_version = marker_impl_version,
        base_branch = marker_base_branch,
        pr_native = true,
      }
    end
  end
  return nil
end

return C
