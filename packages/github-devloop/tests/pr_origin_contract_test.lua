local base_ids = require("devloop.base_ids")
local contract_pr_origin = require("devloop.markers.pr_origin")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local forge_validators = require("devloop.forge_validators")
local strings = require("contract.strings")
local t = fkst.test

local issue_proposal_id = "github-devloop/issue/owner/repo/42"
local pr_proposal_id = "github-devloop/pr/owner/repo/7"
local implementation_version = "ready/github-devloop/issue/owner/repo/42/intake/0000000001"

local function marker(proposal_id, issue_number, branch, impl_version, base_branch)
  return '<!-- fkst:github-devloop:pr-origin:v1 proposal="' .. proposal_id
    .. '" issue="' .. issue_number
    .. '" branch="' .. branch
    .. '" impl_version="' .. impl_version
    .. '" base_branch="' .. base_branch .. '" -->'
end

local authorities = {
  parse_issue_proposal_id = base_ids.parse_proposal_id,
  parse_pr_proposal_id = entity_lib.parse_pr_proposal_id,
  is_git_ref_safe = forge_validators.is_git_ref_safe,
  is_implementation_version = function(value)
    return strings.is_bounded_string(value, devloop_base._max_dedup_len)
  end,
}

return {
  test_issue_backed_origin_uses_injected_validation_authorities = function()
    local calls = {
      issue_parser = 0,
      git_ref = 0,
      implementation_version = 0,
    }
    local delegated = {
      parse_issue_proposal_id = function(value)
        calls.issue_parser = calls.issue_parser + 1
        return authorities.parse_issue_proposal_id(value)
      end,
      parse_pr_proposal_id = authorities.parse_pr_proposal_id,
      is_git_ref_safe = function(value)
        calls.git_ref = calls.git_ref + 1
        return authorities.is_git_ref_safe(value)
      end,
      is_implementation_version = function(value)
        calls.implementation_version = calls.implementation_version + 1
        return authorities.is_implementation_version(value)
      end,
    }

    local fact = contract_pr_origin.fact(
      marker(issue_proposal_id, "42", "feature/stale", implementation_version, "main"),
      delegated)

    t.eq(fact.proposal_id, issue_proposal_id)
    t.eq(fact.repo, "owner/repo")
    t.eq(fact.issue_number, "42")
    t.is_nil(fact.pr_number)
    t.eq(fact.branch, "feature/stale")
    t.eq(fact.impl_version, implementation_version)
    t.eq(fact.base_branch, "main")
    t.is_nil(fact.pr_native)
    t.eq(calls.issue_parser, 1)
    t.eq(calls.git_ref, 2)
    t.eq(calls.implementation_version, 1)
  end,

  test_pr_native_origin_preserves_pr_shape = function()
    local fact = contract_pr_origin.fact(
      marker(pr_proposal_id, "7", "contributor/topic", "external-pr-intake-v1", "dev"),
      authorities)

    t.eq(fact.proposal_id, pr_proposal_id)
    t.eq(fact.repo, "owner/repo")
    t.is_nil(fact.issue_number)
    t.eq(fact.pr_number, 7)
    t.eq(fact.branch, "contributor/topic")
    t.eq(fact.impl_version, "external-pr-intake-v1")
    t.eq(fact.base_branch, "dev")
    t.eq(fact.pr_native, true)
  end,

  test_invalid_origin_fields_are_rejected_by_existing_authorities = function()
    t.is_nil(contract_pr_origin.fact(
      marker(issue_proposal_id, "41", "feature/topic", implementation_version, "main"),
      authorities))
    t.is_nil(contract_pr_origin.fact(
      marker(issue_proposal_id, "42", "feature topic", implementation_version, "main"),
      authorities))
    t.is_nil(contract_pr_origin.fact(
      marker(issue_proposal_id, "42", "feature/topic", string.rep("v", devloop_base._max_dedup_len + 1), "main"),
      authorities))
  end,
}
