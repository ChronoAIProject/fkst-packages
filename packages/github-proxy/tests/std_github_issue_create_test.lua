-- Contract library behavior tests are hosted in github-proxy (a flat package,
-- the strictest single-root conformance gate) because the engine test runner
-- only scans package tests and department tests.
local core = require("core")
local t = fkst.test

local function issue_create_contract()
  local ok, contract = pcall(require, "contract.github_issue_create")
  t.eq(ok, true)
  return contract
end

local function bounded_payload(limits)
  return {
    schema = "github-proxy.issue-create.v1",
    repo = string.rep("r", limits.repo),
    title = string.rep("t", limits.title),
    body = string.rep("b", limits.body),
    dedup_key = string.rep("d", limits.dedup_key),
    source_ref = {
      kind = string.rep("k", limits.source_ref_kind),
      ref = string.rep("s", limits.source_ref_ref),
    },
  }
end

return {
  test_issue_create_contract_exports_fresh_field_limits = function()
    local contract = issue_create_contract()
    local first = contract.limits()
    local second = contract.limits()

    t.eq(first.repo, 200)
    t.eq(first.title, 240)
    t.eq(first.body, 12000)
    t.eq(first.dedup_key, 512)
    t.eq(first.source_ref_kind, 80)
    t.eq(first.source_ref_ref, 200)
    first.repo = 1
    t.eq(second.repo, 200)
  end,

  test_issue_create_validator_accepts_contract_field_boundaries = function()
    local limits = issue_create_contract().limits()

    t.eq(core.validate_issue_create_payload(bounded_payload(limits)), true)
  end,

  test_issue_create_validator_rejects_values_beyond_contract_field_boundaries = function()
    local limits = issue_create_contract().limits()
    local mutations = {
      function(payload) payload.repo = string.rep("r", limits.repo + 1) end,
      function(payload) payload.title = string.rep("t", limits.title + 1) end,
      function(payload) payload.body = string.rep("b", limits.body + 1) end,
      function(payload) payload.dedup_key = string.rep("d", limits.dedup_key + 1) end,
      function(payload) payload.source_ref.kind = string.rep("k", limits.source_ref_kind + 1) end,
      function(payload) payload.source_ref.ref = string.rep("s", limits.source_ref_ref + 1) end,
    }

    for _, mutate in ipairs(mutations) do
      local payload = bounded_payload(limits)
      mutate(payload)
      t.eq(core.validate_issue_create_payload(payload), false)
    end
  end,

  test_issue_create_parent_comment_target_uses_contract_repo_boundary = function()
    local limits = issue_create_contract().limits()
    local payload = bounded_payload(limits)
    payload.parent_comment_target = {
      repo = string.rep("r", limits.repo),
      issue_number = 1,
    }
    t.eq(core.validate_issue_create_payload(payload), true)

    payload.parent_comment_target.repo = string.rep("r", limits.repo + 1)
    t.eq(core.validate_issue_create_payload(payload), false)
  end,
}
