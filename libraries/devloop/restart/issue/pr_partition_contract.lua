local P = {}
local entity_lib = require("devloop.entity")
local parsers_misc = require("devloop.parsers.misc")
local transition_version = require("contract.transition_version")

local ISSUE_STATES = {
  "thinking",
  "dependency_wait",
  "ready",
  "implementing",
  "awaiting-pr",
  "impl-failed",
  "declined",
  "merged",
  "blocked",
}

local PR_PHASE_STATES = {
  "pr-open",
  "reviewing",
  "fixing",
  "review-meta",
  "merge-ready",
  "merging",
}

local PR_TERMINAL_STATES = {
  "merged",
  "closed-unmerged",
  "blocked",
}

local CHILD_STATE_FACT_SCHEMA = "pr_partition_contract.child-state-fact.v2"
local CHILD_STATE_DISPOSITIONS = {
  ["identity-mismatch"] = true,
  ["in-flight"] = true,
  ["missing"] = true,
  ["missing-version"] = true,
  ["stale"] = true,
  ["terminal"] = true,
  ["unknown"] = true,
}

local AWAITING_PR_CONTRACT = {
  state = "awaiting-pr",
  responsibility = "parent issue polls one delegated PR child terminal state",
  liveness_class = "child_workflow_wait",
  marker_facts = {
    "state:v1 awaiting-pr",
    "pr-delegation:v1",
  },
  child_terminal_states = {
    "merged",
    "closed-unmerged",
    "blocked",
  },
  child_dependency = {
    kind = "delegated-child-pr",
    fact_family = "child-pr-dependency",
    identity = {
      source = "pr-delegation:v1",
      pr_proposal_id = "pr-delegation.pr_proposal_id",
      pr_number = "pr-delegation.pr_number",
      repository = "parent.repo",
    },
    predicate = "pr_partition_contract.child_state_fact",
    unknown_state_outcome = "child-state-unrecognized",
  },
}

local function set_from(list)
  local set = {}
  for _, value in ipairs(list) do
    set[value] = true
  end
  return set
end

local ISSUE_STATE_SET = set_from(ISSUE_STATES)
local PR_PHASE_STATE_SET = set_from(PR_PHASE_STATES)
local PR_TERMINAL_STATE_SET = set_from(PR_TERMINAL_STATES)
local PR_STATE_SET = set_from(PR_PHASE_STATES)
for _, state in ipairs(PR_TERMINAL_STATES) do
  PR_STATE_SET[state] = true
end

for state, _ in pairs(ISSUE_STATE_SET) do
  if PR_PHASE_STATE_SET[state] then
    error("github-devloop: pr-partition-state-overlap: PR partition contract states must be disjoint")
  end
end

local function copy_list(list)
  local copied = {}
  for index, value in ipairs(list) do
    copied[index] = value
  end
  return copied
end

local function copy_table(table_value)
  local copied = {}
  for key, value in pairs(table_value) do
    if type(value) == "table" then
      copied[key] = copy_table(value)
    else
      copied[key] = value
    end
  end
  return copied
end

function P.issue_states()
  return copy_list(ISSUE_STATES)
end

function P.pr_phase_states()
  return copy_list(PR_PHASE_STATES)
end

function P.pr_terminal_states()
  return copy_list(PR_TERMINAL_STATES)
end

function P.awaiting_pr_contract()
  return copy_table(AWAITING_PR_CONTRACT)
end

function P.child_terminal_predicate(state)
  return PR_TERMINAL_STATE_SET[tostring(state or "")] == true
end

function P.child_state_predicate(state)
  return PR_STATE_SET[tostring(state or "")] == true
end

local function child_fact(fields)
  fields.schema = CHILD_STATE_FACT_SCHEMA
  return fields
end

local function classify_child_state(raw_state)
  if PR_PHASE_STATE_SET[tostring(raw_state or "")] then
    return "in-flight"
  end
  if PR_TERMINAL_STATE_SET[tostring(raw_state or "")] then
    return "terminal"
  end
  return "unknown"
end

function P.require_child_state_fact(fact)
  if fact == nil then
    return nil
  end
  if type(fact) ~= "table" or fact.schema ~= CHILD_STATE_FACT_SCHEMA then
    error("github-devloop: child-state-fact-tag-invalid: expected " .. CHILD_STATE_FACT_SCHEMA)
  end
  if CHILD_STATE_DISPOSITIONS[fact.disposition] ~= true then
    error("github-devloop: child-state-fact-disposition-invalid: unrecognized child disposition")
  end
  return fact
end

local function marker_attr(marker, key)
  return marker:match('%s' .. key .. '="([^"]*)"')
end

function P.child_state_fact(observed_pr, delegation, parent_repo)
  if type(delegation) ~= "table" then
    return child_fact({ disposition = "missing", identity_valid = false })
  end
  local pr_repo, parsed_number = entity_lib.parse_pr_proposal_id(delegation.pr_proposal_id or delegation.pr_proposal)
  local observed_repo = type(observed_pr) == "table" and observed_pr.repo or nil
  local observed_pr_number = type(observed_pr) == "table" and observed_pr.number or nil
  local identity_valid = pr_repo == tostring(parent_repo or "")
    and tostring(parsed_number or "") == tostring(delegation.pr_number or "")
    and tostring(observed_repo or "") == tostring(pr_repo or "")
    and tostring(observed_pr_number or "") == tostring(delegation.pr_number or "")
  if not identity_valid then
    return child_fact({
      disposition = "identity-mismatch",
      identity_valid = false,
      observed_repo = observed_repo,
      observed_pr_number = observed_pr_number,
      pr_proposal_id = delegation.pr_proposal_id or delegation.pr_proposal,
      pr_number = delegation.pr_number,
    })
  end
  local latest = nil
  local latest_stale = nil
  local delegation_version = tostring(delegation.version or "")
  if delegation_version == "" then
    return child_fact({
      disposition = "missing-version",
      identity_valid = true,
      observed_repo = observed_repo,
      observed_pr_number = observed_pr_number,
      pr_proposal_id = delegation.pr_proposal_id or delegation.pr_proposal,
      pr_number = delegation.pr_number,
    })
  end
  local lineage_base = transition_version.strip_suffixes(delegation.version)
  local marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(observed_pr.comments or {})) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local proposal_id = marker_attr(marker, "proposal")
      local version = marker_attr(marker, "version")
      if proposal_id == tostring(delegation.proposal_id or "") and version ~= nil then
        local candidate = {
          raw_state = marker_attr(marker, "state"),
          version = version,
          proposal_id = proposal_id,
          pr_proposal_id = delegation.pr_proposal_id or delegation.pr_proposal,
          pr_number = tonumber(delegation.pr_number),
          identity_valid = true,
          observed_repo = observed_repo,
          observed_pr_number = observed_pr_number,
          comment_created_at = parsers_misc._comment_created_at(comment),
        }
        if transition_version.strip_suffixes(version) == lineage_base then
          if latest == nil or transition_version.compare(version, latest.version) >= 0 then
            latest = candidate
          end
        elseif latest_stale == nil or transition_version.compare(version, latest_stale.version) >= 0 then
          latest_stale = candidate
        end
      end
    end
  end
  if latest == nil then
    if latest_stale ~= nil then
      latest_stale.disposition = "stale"
      return child_fact(latest_stale)
    end
    return child_fact({
      disposition = "missing",
      identity_valid = true,
      observed_repo = observed_repo,
      observed_pr_number = observed_pr_number,
      pr_proposal_id = delegation.pr_proposal_id or delegation.pr_proposal,
      pr_number = tonumber(delegation.pr_number),
    })
  end
  latest.disposition = classify_child_state(latest.raw_state)
  if latest.disposition ~= "unknown" then
    latest.state = latest.raw_state
  end
  return child_fact(latest)
end

function P.state_allowed_for_saga(saga_kind, state)
  if saga_kind == "issue" then
    return ISSUE_STATE_SET[state] == true
  end
  if saga_kind == "pr" then
    return PR_PHASE_STATE_SET[state] == true or PR_TERMINAL_STATE_SET[state] == true
  end
  return false
end

function P.install(M)
  M.pr_partition_contract = P
end

return P
