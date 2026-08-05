local base_ids = require("devloop.base_ids")
local receipt = require("core.child_disposition_receipt")
local marker = require("core.marker")

local M = {}

M.SCHEMA = "github-devloop-workflow.child-disposition-request.v1"

local request_fields = {
  schema = true,
  source_ref = true,
  origin = true,
  blueprint_digest = true,
  slot = true,
  child_issue = true,
  disposition = true,
  dedup_key = true,
}

local function fail(reason)
  error(
    "github-devloop-workflow: child-disposition-request-invalid: reason=" .. tostring(reason),
    0
  )
end

local function canonical_issue_number(value, field)
  if type(value) ~= "string" and type(value) ~= "number" then
    fail(field .. " must be a canonical positive issue number")
  end
  local text = tostring(value)
  local number = tonumber(text)
  if text:find("^[1-9]%d*$") == nil
    or number == nil
    or number ~= math.floor(number)
    or number > 2147483647 then
    fail(field .. " must be a canonical positive issue number")
  end
  return text
end

local function normalize_identity(value)
  if type(value) ~= "table" then
    fail("identity must be a table")
  end
  if type(value.repo) ~= "string" or value.repo == "" or base_ids.safe_repo(value.repo) ~= value.repo then
    fail("repo must be a canonical repository identity")
  end
  local origin_repo, origin_issue = base_ids.parse_proposal_id(value.origin)
  if origin_repo ~= value.repo then
    fail("origin must belong to repo")
  end
  canonical_issue_number(origin_issue, "origin issue")
  local child_issue = canonical_issue_number(value.child_issue, "child_issue")
  if not base_ids.issue_ref_round_trips(value.repo, child_issue) then
    fail("child issue identity must round-trip")
  end
  if type(value.blueprint_digest) ~= "string" or type(value.slot) ~= "string" then
    fail("blueprint_digest and slot must be strings")
  end
  if marker.build_lineage_header(value.origin, value.blueprint_digest, value.slot) == nil then
    fail("workflow lineage is invalid")
  end
  if value.disposition ~= "satisfied" then
    fail("only disposition=satisfied is supported")
  end
  local identity = {
    repo = value.repo,
    origin = value.origin,
    blueprint_digest = value.blueprint_digest,
    slot = value.slot,
    child_issue = child_issue,
    disposition = "satisfied",
  }
  local ok = pcall(receipt.canonical_identity, identity)
  if not ok then
    fail("receipt identity is invalid")
  end
  return identity
end

function M.dedup_key(value)
  local identity = normalize_identity(value)
  return base_ids.dedup_key({
    "workflow",
    "child-disposition",
    identity.origin,
    identity.blueprint_digest,
    identity.slot,
    identity.child_issue,
    identity.disposition,
  })
end

function M.build(value)
  local identity = normalize_identity(value)
  return {
    schema = M.SCHEMA,
    source_ref = base_ids.issue_source_ref(identity.repo, identity.child_issue),
    origin = identity.origin,
    blueprint_digest = identity.blueprint_digest,
    slot = identity.slot,
    child_issue = identity.child_issue,
    disposition = identity.disposition,
    dedup_key = M.dedup_key(identity),
  }
end

function M.normalize(value)
  if type(value) ~= "table" then
    fail("request must be a table")
  end
  for field in pairs(value) do
    if request_fields[field] ~= true then
      fail("unsupported field " .. tostring(field))
    end
  end
  if value.schema ~= M.SCHEMA then
    fail("schema is invalid")
  end
  local source_ref_ok, source_ref = pcall(base_ids.normalize_source_ref, value.source_ref)
  if not source_ref_ok then
    fail("source_ref is invalid")
  end
  local source_repo, source_issue = tostring(source_ref.ref or ""):match("^([^#]+)#issue/(%d+)$")
  local origin_repo = base_ids.parse_proposal_id(value.origin)
  local identity = normalize_identity({
    repo = origin_repo,
    origin = value.origin,
    blueprint_digest = value.blueprint_digest,
    slot = value.slot,
    child_issue = value.child_issue,
    disposition = value.disposition,
  })
  if source_ref.kind ~= "external"
    or source_repo ~= identity.repo
    or source_issue ~= identity.child_issue then
    fail("source_ref must identify the child issue")
  end
  if value.dedup_key ~= M.dedup_key(identity) then
    fail("dedup_key is not canonical")
  end
  identity.schema = M.SCHEMA
  identity.source_ref = source_ref
  identity.dedup_key = value.dedup_key
  return identity
end

function M.install(target)
  target.child_disposition_request = M
end

return M
