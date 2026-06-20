local core = require("core")

local M = {}

local function open_pr_payload_from_fact(repo, issue_number, ready, fact)
  return core.build_devloop_open_pr_payload(
    repo,
    issue_number,
    {
      proposal_id = ready.proposal_id,
      dedup_key = fact.dedup_key or ready.dedup_key,
      source_ref = ready.source_ref,
    },
    fact.branch,
    fact.head_sha,
    fact.base_branch
  )
end

function M.raise_open_pr_from_fact(repo, issue_number, ready, fact, reason)
  core.log_cas_decision("implement", ready.proposal_id, {
    state = "implementing",
    version = fact.dedup_key or ready.dedup_key,
  }, "implementing", "pr-open", "applied(progress-derived)", reason)
  local payload = open_pr_payload_from_fact(repo, issue_number, ready, fact)
  core.log_apply("implement", ready.proposal_id, "implementing", fact.dedup_key or ready.dedup_key, { add = {}, remove = {} }, {
    "devloop_open_pr",
  })
  core.log_raise("implement", ready.proposal_id, "devloop_open_pr", payload)
end

return M
