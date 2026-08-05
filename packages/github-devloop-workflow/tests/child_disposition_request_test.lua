local core = require("core")
local t = fkst.test

local function request_contract()
  t.is_true(type(core.child_disposition_request) == "table")
  return core.child_disposition_request
end

local function identity()
  return {
    repo = "owner/repo",
    origin = "github-devloop/issue/owner/repo/42",
    blueprint_digest = "d-1234567890",
    slot = "first",
    child_issue = "108",
    disposition = "satisfied",
  }
end

return {
  test_satisfied_request_is_canonical_and_content_free = function()
    local contract = request_contract()
    local first = contract.build(identity())
    local second = contract.build(identity())

    t.eq(first.schema, contract.SCHEMA)
    t.eq(first.source_ref.kind, "external")
    t.eq(first.source_ref.ref, "owner/repo#issue/108")
    t.eq(first.origin, "github-devloop/issue/owner/repo/42")
    t.eq(first.blueprint_digest, "d-1234567890")
    t.eq(first.slot, "first")
    t.eq(first.child_issue, "108")
    t.eq(first.disposition, "satisfied")
    t.eq(first.dedup_key, second.dedup_key)
    t.is_true(first.dedup_key:find("workflow/child-disposition/", 1, true) == 1)
    t.is_nil(first.body)
  end,

  test_request_contract_rejects_non_satisfied_and_extra_content = function()
    local contract = request_contract()
    local request = contract.build(identity())
    request.disposition = "undeliverable"
    request.body = "untrusted content must not enter reliable delivery"

    local ok, err = pcall(contract.normalize, request)

    t.eq(ok, false)
    t.is_true(tostring(err):find("child-disposition-request-invalid", 1, true) ~= nil)
  end,
}
