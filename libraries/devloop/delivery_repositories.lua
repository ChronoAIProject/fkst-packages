local base_ids = require("devloop.base_ids")
local forks = require("devloop.forks")

local R = {}

local function is_canonical_repo(repo)
  return type(repo) == "string"
    and repo ~= ""
    and base_ids.safe_repo(repo) == repo
end

local function resolve_for_repo(proposal_repo, lifecycle_repo, implementation_repo)
  if proposal_repo == nil then
    error("github-devloop: invalid delivery repository proposal")
  end
  if lifecycle_repo == nil and implementation_repo == nil then
    lifecycle_repo = proposal_repo
    implementation_repo = proposal_repo
  elseif lifecycle_repo == nil or implementation_repo == nil then
    error("github-devloop: incomplete delivery repository pair")
  end
  if not is_canonical_repo(lifecycle_repo)
    or not is_canonical_repo(implementation_repo)
    or lifecycle_repo ~= proposal_repo then
    error("github-devloop: invalid delivery repository pair")
  end
  return {
    lifecycle_repo = lifecycle_repo,
    implementation_repo = implementation_repo,
  }
end

function R.resolve(proposal_id, lifecycle_repo, implementation_repo)
  return resolve_for_repo(
    base_ids.parse_proposal_id(proposal_id),
    lifecycle_repo,
    implementation_repo
  )
end

function R.resolve_origin(proposal_id, lifecycle_repo, implementation_repo)
  local proposal_repo = base_ids.parse_proposal_id(proposal_id)
  if proposal_repo == nil then
    proposal_repo = base_ids.parse_pr_proposal_id(proposal_id)
  end
  return resolve_for_repo(proposal_repo, lifecycle_repo, implementation_repo)
end

function R.is_valid(proposal_id, lifecycle_repo, implementation_repo)
  return pcall(R.resolve, proposal_id, lifecycle_repo, implementation_repo)
end

local function parse_pr_source_ref(source_ref)
  if type(source_ref) ~= "table" or source_ref.kind ~= "external" then
    return nil, nil
  end
  local ref = tostring(source_ref.ref or "")
  local pr_number = ref:match("#pr/(%d+)$")
  local repo = pr_number and ref:sub(1, #ref - #("#pr/" .. pr_number)) or nil
  if not is_canonical_repo(repo) or tonumber(pr_number) == nil then
    return nil, nil
  end
  return repo, tonumber(pr_number)
end

function R.from_pr_source_ref(proposal_id, source_ref, lifecycle_repo, implementation_repo)
  local source_repo, pr_number = parse_pr_source_ref(source_ref)
  if source_repo == nil then
    error("github-devloop: invalid delivery PR source ref")
  end
  if lifecycle_repo == nil and implementation_repo == nil then
    local proposal_repo = base_ids.parse_proposal_id(proposal_id)
    if proposal_repo == nil then
      proposal_repo = base_ids.parse_pr_proposal_id(proposal_id)
    end
    lifecycle_repo = proposal_repo
    implementation_repo = source_repo
  end
  local pair = R.resolve_origin(proposal_id, lifecycle_repo, implementation_repo)
  if pair.implementation_repo ~= source_repo then
    error("github-devloop: delivery implementation repository does not match PR source ref")
  end
  return pair, pr_number
end

function R.is_valid_pr_source(proposal_id, source_ref, lifecycle_repo, implementation_repo)
  if lifecycle_repo == nil or implementation_repo == nil then
    return false
  end
  return pcall(R.from_pr_source_ref, proposal_id, source_ref, lifecycle_repo, implementation_repo)
end

function R.from_issue(proposal_id, issue, managed)
  local pair = R.resolve(proposal_id)
  local origin = forks.fork_origin_fact(issue, managed)
  if origin ~= nil then
    pair.implementation_repo = origin.repo
  end
  return R.resolve(proposal_id, pair.lifecycle_repo, pair.implementation_repo)
end

function R.attach(source, pair)
  local copy = {}
  for key, value in pairs(source or {}) do
    copy[key] = value
  end
  copy.lifecycle_repo = pair.lifecycle_repo
  copy.implementation_repo = pair.implementation_repo
  return copy
end

return R
