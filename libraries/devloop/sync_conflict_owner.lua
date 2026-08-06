local base_ids = require("devloop.base_ids")
local forge_validators = require("devloop.forge_validators")

local owner = {}

local marker_prefix = "fkst:github-devloop-integration:sync-conflict-owner:v1"
local marker_comment_pattern = "<!%-%-%s*" .. marker_prefix:gsub("%-", "%%-") .. ".-%-%->"

local function positive_issue_number(value, context)
  local number = tonumber(value)
  if number == nil or number < 1 or number % 1 ~= 0 then
    error("devloop.sync_conflict_owner: invalid-issue-number: " .. tostring(context))
  end
  return math.floor(number)
end

local function marker_attr(marker, name)
  return tostring(marker or ""):match(tostring(name) .. '="([^"]*)"')
end

local function require_repo(repo)
  local value = tostring(repo or "")
  if value == "" or base_ids.safe_repo(value) ~= value then
    error("devloop.sync_conflict_owner: invalid-repo: exact owner repo is invalid")
  end
  return value
end

function owner.owner_issue_number(repo, branch)
  local safe_repo = require_repo(repo)
  local value = tostring(branch or "")
  if not forge_validators.is_git_ref_safe(value) then
    error("devloop.sync_conflict_owner: invalid-branch: exact owner branch is unsafe")
  end
  local prefix = "devloop/issue/" .. safe_repo .. "/"
  if value:sub(1, #prefix) ~= prefix then
    return nil
  end
  local issue, suffix = value:sub(#prefix + 1):match("^(%d+)/(.+)$")
  if issue == nil or suffix == nil or suffix == "" then
    error("devloop.sync_conflict_owner: invalid-owner-branch: exact owner branch is malformed")
  end
  local issue_number = positive_issue_number(issue, "branch owner")
  if tostring(issue_number) ~= issue
    or not base_ids.issue_ref_round_trips(safe_repo, issue_number) then
    error("devloop.sync_conflict_owner: invalid-owner-branch: exact owner issue identity is not canonical")
  end
  return issue_number
end

function owner.marker(repo, branch, head_sha)
  local safe_repo = require_repo(repo)
  local issue_number = owner.owner_issue_number(safe_repo, branch)
  if issue_number == nil then
    error("devloop.sync_conflict_owner: owner-branch-required: exact owner branch must use the deterministic issue namespace")
  end
  if not forge_validators.is_git_sha(head_sha) then
    error("devloop.sync_conflict_owner: invalid-head-sha: exact owner head is unsafe")
  end
  local proposal_id = base_ids.proposal_id(safe_repo, issue_number)
  return '<!-- ' .. marker_prefix
    .. ' repo="' .. safe_repo .. '"'
    .. ' issue="' .. tostring(issue_number) .. '"'
    .. ' proposal="' .. proposal_id .. '"'
    .. ' branch="' .. tostring(branch) .. '"'
    .. ' head_sha="' .. tostring(head_sha) .. '" -->'
end

function owner.find_marker_comment(body)
  return tostring(body or ""):match(marker_comment_pattern)
end

function owner.has_marker(body)
  return owner.find_marker_comment(body) ~= nil
end

function owner.parse_marker_text(marker)
  if tostring(marker or ""):find(marker_prefix, 1, true) == nil then
    return nil
  end
  local repo = marker_attr(marker, "repo")
  local issue = marker_attr(marker, "issue")
  local proposal_id = marker_attr(marker, "proposal")
  local branch = marker_attr(marker, "branch")
  local head_sha = marker_attr(marker, "head_sha")
  if repo == nil or issue == nil or proposal_id == nil or branch == nil or head_sha == nil then
    error("devloop.sync_conflict_owner: invalid-marker: exact owner marker is incomplete")
  end
  local safe_repo = require_repo(repo)
  local issue_number = positive_issue_number(issue, "marker owner")
  local branch_issue_number = owner.owner_issue_number(safe_repo, branch)
  if tostring(issue_number) ~= issue
    or branch_issue_number ~= issue_number
    or proposal_id ~= base_ids.proposal_id(safe_repo, issue_number) then
    error("devloop.sync_conflict_owner: owner-mismatch: exact owner identities disagree")
  end
  if not forge_validators.is_git_sha(head_sha) then
    error("devloop.sync_conflict_owner: invalid-head-sha: exact owner head is unsafe")
  end
  return {
    repo = safe_repo,
    issue_number = issue_number,
    proposal_id = proposal_id,
    branch = branch,
    head_sha = head_sha,
    marker = marker,
  }
end

function owner.find_marker(body)
  local marker = owner.find_marker_comment(body)
  if marker == nil then
    return nil
  end
  return owner.parse_marker_text(marker)
end

return owner
