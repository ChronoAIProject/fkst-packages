local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local marker = require("core.marker")
local parsers_misc = require("devloop.parsers.misc")
local source_refs = require("contract.source_ref")

local M = {}

local function fail(error_class, reason)
  error(
    "github-devloop-workflow: child-transfer-chain-failed: error_class="
      .. tostring(error_class) .. " reason=" .. tostring(reason),
    0
  )
end

local function canonical_issue_source_ref(value, expected_repo, field)
  local repo, issue_number = devloop_base.parse_issue_source_ref(value)
  if repo == nil then
    fail("transfer-chain-identity-invalid", field .. " must be a canonical issue source_ref")
  end
  if repo ~= expected_repo then
    fail("transfer-chain-cross-repository", field .. " must remain in the origin repository")
  end
  local canonical = base_ids.issue_source_ref(repo, issue_number)
  if not source_refs.same(value, canonical) then
    fail("transfer-chain-identity-invalid", field .. " must be canonical")
  end
  return canonical, tostring(issue_number)
end

local function canonical_identity(value)
  if type(value) ~= "table"
    or type(value.repo) ~= "string"
    or base_ids.safe_repo(value.repo) ~= value.repo then
    fail("transfer-chain-identity-invalid", "repo must be canonical")
  end
  local origin_repo, origin_issue = base_ids.parse_proposal_id(value.origin)
  if origin_repo ~= value.repo or not base_ids.issue_ref_round_trips(origin_repo, origin_issue) then
    fail("transfer-chain-identity-invalid", "origin must identify an issue in repo")
  end
  if marker.build_lineage_header(value.origin, value.blueprint_digest, value.slot) == nil then
    fail("transfer-chain-identity-invalid", "workflow lineage is invalid")
  end
  local initial_source_ref = canonical_issue_source_ref(
    value.initial_source_ref,
    value.repo,
    "initial_source_ref"
  )
  return {
    repo = value.repo,
    origin = value.origin,
    blueprint_digest = value.blueprint_digest,
    slot = value.slot,
    initial_source_ref = initial_source_ref,
  }
end

function M.has_matching_acceptance(current, identity)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(current and current.comments or {})) do
    if marker.parse_transfer_accept_marker(parsers_misc.comment_body(comment), identity) ~= nil then
      return true
    end
  end
  return false
end

function M.contains(chain, source_ref)
  return type(chain) == "table"
    and type(source_ref) == "table"
    and chain.visited[source_ref.ref] == true
end

function M.edge_matches(chain, predecessor_source_ref, successor_source_ref)
  if type(chain) ~= "table" or type(predecessor_source_ref) ~= "table" then
    return false
  end
  return source_refs.same(
    chain.successors[predecessor_source_ref.ref],
    successor_source_ref
  )
end

function M.new(deps)
  local selected = deps or {}
  local receipt_store = selected.receipt_store
  local read_issue = selected.read_issue
  if type(receipt_store) ~= "table" or type(receipt_store.read) ~= "function" then
    fail("transfer-chain-ports-invalid", "receipt_store.read is required")
  end
  if type(read_issue) ~= "function" then
    fail("transfer-chain-ports-invalid", "read_issue is required")
  end

  local function resolve(value)
    local identity = canonical_identity(value)
    local current_source_ref = identity.initial_source_ref
    local current_issue = select(2, canonical_issue_source_ref(
      current_source_ref,
      identity.repo,
      "initial_source_ref"
    ))
    local chain = {
      visited = {},
      successors = {},
    }

    while true do
      if chain.visited[current_source_ref.ref] then
        fail("transfer-chain-cycle", "committed transfer receipts contain a cycle")
      end
      chain.visited[current_source_ref.ref] = true

      local receipt_value = receipt_store.read({
        repo = identity.repo,
        origin = identity.origin,
        blueprint_digest = identity.blueprint_digest,
        slot = identity.slot,
        child_issue = current_issue,
      })
      if receipt_value == nil or receipt_value.disposition ~= "transferred" then
        if receipt_value ~= nil
          and receipt_value.disposition ~= "satisfied"
          and receipt_value.disposition ~= "undeliverable" then
          fail("transfer-chain-receipt-invalid", "receipt has an unsupported disposition")
        end
        chain.tip_source_ref = current_source_ref
        chain.tip_issue = current_issue
        return chain
      end

      local successor_source_ref, successor_issue = canonical_issue_source_ref(
        receipt_value.successor_source_ref,
        identity.repo,
        "successor_source_ref"
      )
      if chain.visited[successor_source_ref.ref] then
        fail("transfer-chain-cycle", "committed transfer receipts contain a cycle")
      end
      local acceptance_identity = {
        origin = identity.origin,
        blueprint_digest = identity.blueprint_digest,
        slot = identity.slot,
        predecessor_source_ref = current_source_ref,
        successor_source_ref = successor_source_ref,
      }
      local successor = read_issue(successor_source_ref)
      if type(successor) ~= "table"
        or not source_refs.same(successor.source_ref, successor_source_ref) then
        fail("transfer-chain-source-read-invalid", "successor read did not return the exact source identity")
      end
      if not M.has_matching_acceptance(successor, acceptance_identity) then
        fail(
          "transfer-chain-acceptance-invalid",
          "committed transfer has no exact trusted successor acceptance"
        )
      end

      chain.successors[current_source_ref.ref] = successor_source_ref
      current_source_ref = successor_source_ref
      current_issue = successor_issue
    end
  end

  return {
    resolve = resolve,
  }
end

return M
