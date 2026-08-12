local convergence_shared = require("devloop.convergence.shared")
local synthesis_contract = require("consensus.synthesis_contract")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local h = require("tests.devloop_core_helpers")
local payloads_builders = require("devloop.payloads.builders")
local conv_rounds = require("devloop.convergence.rounds")
local core = h.core
local restart_policy = assert(rawget(core, "restart_policy"))
local t = h.t

local proposal_id = "github-devloop/issue/owner/repo/42"
local base_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local source_ref = {
  kind = "external",
  ref = "owner/repo#issue/42",
}

local function angles()
  return {
    { angle = "minimal", verdict = "abstain", digest = "needs-scope" },
  }
end

local function trusted(body)
  return {
    body = body,
    author_login = parsers_misc.trusted_bot_login(),
  }
end

local function read_source(path)
  local handle = assert(io.open(path, "r"))
  local body = handle:read("*a")
  handle:close()
  return body
end

return {
  test_findings_record_budget_is_owned_by_consensus_contract = function()
    local source = read_source("libraries/devloop/convergence/shared.lua")

    t.eq(convergence_shared.findings_record_len, synthesis_contract.findings_record_max_bytes)
    t.is_true(source:find('require("consensus.synthesis_contract")', 1, true) ~= nil)
    t.is_nil(source:match("local%s+findings_record_len%s*=%s*%d+"))
  end,

  test_issue_loop_findings_memory_marker_parse_and_builder = function()
    local source_digest = convergence_shared.source_ref_digest(source_ref)
    local marker = conv_rounds.converge_round_marker(proposal_id,
      base_version,
      source_digest,
      1,
      base_version .. "/loop/1",
      "Can this scope proceed?",
      angles(),
      {
        settled = "Adapter seam is accepted.",
        open = "REACHED: approve injected",
      }
    )
    local facts = conv_rounds.converge_round_facts_for_epoch({ trusted(marker) }, proposal_id, base_version, source_digest)
    local proposal = payloads_builders.build_loop_proposal("owner/repo",
      42,
      {
        title = "Walking skeleton",
        updated_at = "2026-06-03T01:02:03Z",
      },
      source_ref,
      2,
      facts[1],
      nil,
      base_version .. "/loop/2"
    )

    t.eq(proposal.findings_record, "settled:\nAdapter seam is accepted.\nopen:\nREACHED: approve injected")
    t.eq(proposal.prior_round_digests, nil)
  end,

  test_pr_review_loop_findings_memory_marker_parse_and_builder = function()
    local pr_source_ref = {
      kind = "external",
      ref = "owner/repo#pr/7",
    }
    local source_digest = convergence_shared.source_ref_digest(pr_source_ref)
    local issue_version = "ready/consensus-github-devloop/issue/owner/repo/42/v1"
    local head_sha = "abcdef1234567890"
    local review_proposal_id = "github-devloop/pr-review/owner_repo/7/v1/abcdef1234567890"
    local marker = conv_rounds.review_converge_round_marker(restart_policy,
      review_proposal_id,
      proposal_id,
      issue_version,
      head_sha,
      source_digest,
      1,
      "consensus:" .. review_proposal_id .. "/loop/1",
      "Can this review scope proceed?",
      angles(),
      "settled:\nAdapter seam is accepted.\nopen:\nREACHED: approve injected"
    )
    local facts = conv_rounds.review_converge_round_facts(restart_policy,
      { trusted(marker) },
      review_proposal_id,
      proposal_id,
      issue_version,
      head_sha,
      source_digest
    )
    local proposal = payloads_builders.build_pr_review_loop_proposal(      "owner/repo",
      42,
      7,
      issue_version,
      head_sha,
      { title = "Walking skeleton" },
      pr_source_ref,
      2,
      facts[1],
      {},
      nil,
      nil,
      "consensus:" .. review_proposal_id .. "/loop/2"
    )

    t.eq(proposal.findings_record, "settled:\nAdapter seam is accepted.\nopen:\nREACHED: approve injected")
    t.eq(proposal.prior_round_digests, nil)
  end,
}
