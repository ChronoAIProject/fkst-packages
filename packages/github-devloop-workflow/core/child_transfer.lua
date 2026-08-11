local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local devloop_entity = require("devloop.entity")
local parsers_misc = require("devloop.parsers.misc")
local devloop_logging = require("devloop.logging")
local discovery = require("core.materialize.discovery")
local marker = require("core.marker")
local receipt = require("core.child_disposition_receipt")
local transfer_chain = require("core.child_transfer_chain")
local sha256 = require("contract.sha256")
local source_refs = require("contract.source_ref")

local M = {}

M.REQUEST_SCHEMA = "github-devloop-workflow.child-transfer.v1"
M.QUEUE = "workflow_child_transfer_request"
M.DEPT = "workflow_transfer_child"
M.IO_TIMEOUT_SECONDS = 30

local function fail(error_class, reason)
  error(
    "github-devloop-workflow: child-transfer-failed: error_class="
      .. tostring(error_class) .. " reason=" .. tostring(reason),
    0
  )
end

local function canonical_issue_source_ref(value, expected_repo, field)
  local repo, issue_number = devloop_base.parse_issue_source_ref(value)
  if repo == nil or repo ~= expected_repo then
    fail("transfer-identity-invalid", field .. " must be a canonical issue source_ref in the origin repo")
  end
  return base_ids.issue_source_ref(repo, issue_number), tostring(issue_number)
end

local function canonical_request(value)
  if type(value) ~= "table" or value.schema ~= M.REQUEST_SCHEMA then
    fail("transfer-request-invalid", "request schema is invalid")
  end
  local repo, origin_issue = base_ids.parse_proposal_id(value.origin)
  if repo == nil or not base_ids.issue_ref_round_trips(repo, origin_issue) then
    fail("transfer-identity-invalid", "origin must be a canonical issue proposal identity")
  end
  local predecessor_source_ref, predecessor_issue = canonical_issue_source_ref(
    value.predecessor_source_ref,
    repo,
    "predecessor_source_ref"
  )
  local successor_source_ref, successor_issue = canonical_issue_source_ref(
    value.successor_source_ref,
    repo,
    "successor_source_ref"
  )
  if source_refs.same(predecessor_source_ref, successor_source_ref) then
    fail("transfer-identity-invalid", "predecessor and successor must be distinct")
  end
  local identity = {
    origin = value.origin,
    blueprint_digest = value.blueprint_digest,
    slot = value.slot,
    predecessor_source_ref = predecessor_source_ref,
    successor_source_ref = successor_source_ref,
  }
  local built, marker_error = marker.build_transfer_accept_marker(identity)
  if built == nil then
    fail("transfer-identity-invalid", tostring(marker_error and marker_error.code or "invalid marker identity"))
  end
  local origin_source_ref = base_ids.issue_source_ref(repo, origin_issue)
  if not source_refs.same(value.source_ref, origin_source_ref) then
    fail("transfer-request-invalid", "source_ref must identify the origin issue")
  end
  local dedup_key = base_ids.dedup_key({
    "github-devloop-workflow",
    "child-transfer",
    value.origin,
    value.blueprint_digest,
    value.slot,
    predecessor_source_ref.ref,
    successor_source_ref.ref,
  })
  if value.dedup_key ~= dedup_key then
    fail("transfer-request-invalid", "dedup_key does not match the transfer identity")
  end
  identity.repo = repo
  identity.origin_issue = tostring(origin_issue)
  identity.predecessor_issue = predecessor_issue
  identity.successor_issue = successor_issue
  identity.source_ref = origin_source_ref
  identity.dedup_key = dedup_key
  identity.acceptance_marker = built
  return identity
end

function M.build_request(value)
  if type(value) ~= "table" then
    fail("transfer-request-invalid", "request identity must be a table")
  end
  local repo, origin_issue = base_ids.parse_proposal_id(value.origin)
  if repo == nil or not base_ids.issue_ref_round_trips(repo, origin_issue) then
    fail("transfer-identity-invalid", "origin must be a canonical issue proposal identity")
  end
  local predecessor_source_ref = select(1, canonical_issue_source_ref(
    value.predecessor_source_ref,
    repo,
    "predecessor_source_ref"
  ))
  local successor_source_ref = select(1, canonical_issue_source_ref(
    value.successor_source_ref,
    repo,
    "successor_source_ref"
  ))
  if source_refs.same(predecessor_source_ref, successor_source_ref) then
    fail("transfer-identity-invalid", "predecessor and successor must be distinct")
  end
  local request = {
    schema = M.REQUEST_SCHEMA,
    origin = value.origin,
    blueprint_digest = value.blueprint_digest,
    slot = value.slot,
    predecessor_source_ref = predecessor_source_ref,
    successor_source_ref = successor_source_ref,
    source_ref = base_ids.issue_source_ref(repo, origin_issue),
  }
  request.dedup_key = base_ids.dedup_key({
    "github-devloop-workflow",
    "child-transfer",
    request.origin,
    request.blueprint_digest,
    request.slot,
    request.predecessor_source_ref.ref,
    request.successor_source_ref.ref,
  })
  canonical_request(request)
  return request
end

local function read_fresh(github, source_ref, consumer)
  local current = github.read_issue(source_ref, {
    force_fresh = true,
    consumer = consumer,
    timeout = M.IO_TIMEOUT_SECONDS,
  })
  if type(current) ~= "table" or not source_refs.same(current.source_ref, source_ref) then
    fail("transfer-source-read-invalid", consumer .. " read did not return the exact source identity")
  end
  return current
end

local function origin_ledger_child(origin_current, identity)
  local by_slot = marker.latest_materialization_by_slot(
    discovery.materialization_facts(nil, origin_current, identity.origin)
  )
  local entry = by_slot[identity.slot]
  if type(entry) ~= "table"
    or entry.state ~= "created"
    or entry.blueprint_digest ~= identity.blueprint_digest
    or not base_ids.issue_ref_round_trips(identity.repo, entry.child_issue) then
    fail("transfer-origin-ledger-mismatch", "origin ledger does not own a child for the exact slot")
  end
  return base_ids.issue_source_ref(identity.repo, entry.child_issue)
end

local function receipt_identity(identity)
  return {
    repo = identity.repo,
    origin = identity.origin,
    blueprint_digest = identity.blueprint_digest,
    slot = identity.slot,
    child_issue = identity.predecessor_issue,
  }
end

local function matching_transfer_receipt(value, identity)
  return type(value) == "table"
    and value.disposition == "transferred"
    and source_refs.same(value.successor_source_ref, identity.successor_source_ref)
end

local function chain_lock_key(identity)
  return base_ids.dedup_key({
    "github-devloop-workflow",
    "child-transfer-chain",
    identity.origin,
    identity.blueprint_digest,
    identity.slot,
  })
end

local function with_transfer_locks(identity, fn)
  return with_lock(devloop_entity.observe_lock_key(identity.repo, identity.origin_issue), function()
    return with_lock(chain_lock_key(identity), fn)
  end)
end

local function verified_satisfaction_for_tip(origin_current, identity, chain)
  local _, tip_issue = devloop_base.parse_issue_source_ref(chain.tip_source_ref)
  for _, fact in ipairs(discovery.verified_satisfaction_facts(nil, origin_current, identity.origin)) do
    if fact.blueprint_digest == identity.blueprint_digest
      and fact.slot == identity.slot
      and fact.child_issue == tostring(tip_issue) then
      return fact
    end
  end
  return nil
end

local function acceptance_body_file(identity)
  return "/tmp/fkst-github-devloop-workflow-transfer-accept-"
    .. sha256.hex(identity.acceptance_marker) .. ".md"
end

local function write_acceptance(github, file_port, identity)
  local path = acceptance_body_file(identity)
  file_port.write(path, identity.acceptance_marker .. "\n")
  github.issue_comment_create(
    identity.repo,
    identity.successor_issue,
    path,
    M.IO_TIMEOUT_SECONDS
  )
  devloop_logging.log_line("info", M.DEPT, identity.origin, "TRANSFER", {
    "action=acceptance-issued",
    "slot=" .. identity.slot,
    "successor=" .. identity.successor_source_ref.ref,
  })
end

local function close_predecessor(github, identity)
  github.issue_close(
    identity.repo,
    identity.predecessor_issue,
    { kind = "duplicate", duplicate_of = tonumber(identity.successor_issue) },
    M.IO_TIMEOUT_SECONDS
  )
  local closed = read_fresh(github, identity.predecessor_source_ref, M.DEPT .. ":close-readback")
  if tostring(closed.state or ""):upper() ~= "CLOSED" then
    fail("transfer-close-readback-missing", "predecessor close is not source-visible")
  end
  devloop_logging.log_line("info", M.DEPT, identity.origin, "TRANSFER", {
    "action=predecessor-closed",
    "slot=" .. identity.slot,
    "predecessor=" .. identity.predecessor_source_ref.ref,
  })
end

function M.new(deps)
  local selected = deps or {}
  local github = selected.github
  local git = selected.git
  local file_port = selected.file or file
  if type(github) ~= "table" or type(git) ~= "table" then
    fail("transfer-ports-invalid", "github and git ports are required")
  end
  local store = receipt.new({ git = git, file = file_port })
  local resolver = transfer_chain.new({
    receipt_store = store,
    read_issue = function(source_ref)
      return read_fresh(github, source_ref, M.DEPT .. ":chain")
    end,
  })

  local function transfer(request)
    local identity = canonical_request(request)
    if devloop_base.read_env("FKST_GITHUB_WRITE") ~= "1" then
      devloop_logging.log_line("info", M.DEPT, identity.origin, "TRANSFER", {
        "action=dry-run",
        "slot=" .. identity.slot,
      })
      return "dry-run"
    end
    parsers_misc.assert_trusted_bot_configured()

    return with_transfer_locks(identity, function()
      local origin_current = read_fresh(github, identity.source_ref, M.DEPT .. ":origin")
      local initial_source_ref = origin_ledger_child(origin_current, identity)
      local chain = resolver.resolve({
        repo = identity.repo,
        origin = identity.origin,
        blueprint_digest = identity.blueprint_digest,
        slot = identity.slot,
        initial_source_ref = initial_source_ref,
      })
      local replay = transfer_chain.edge_matches(
        chain,
        identity.predecessor_source_ref,
        identity.successor_source_ref
      )
      if not replay
        and source_refs.same(chain.tip_source_ref, identity.predecessor_source_ref)
        and verified_satisfaction_for_tip(origin_current, identity, chain) ~= nil then
        fail(
          "transfer-tip-satisfaction-verified",
          "the current transfer tip already has a trusted verified-satisfaction fact"
        )
      end
      if not source_refs.same(chain.tip_source_ref, identity.predecessor_source_ref)
        and not replay then
        if transfer_chain.contains(chain, identity.predecessor_source_ref) then
          fail("transfer-chain-predecessor-stale", "predecessor is no longer the accepted chain tip")
        end
        fail("transfer-origin-ledger-mismatch", "origin transfer chain does not contain the predecessor")
      end
      if transfer_chain.contains(chain, identity.successor_source_ref) and not replay then
        fail("transfer-chain-cycle", "successor is already present in the accepted transfer chain")
      end

      local predecessor_current = read_fresh(github, identity.predecessor_source_ref, M.DEPT .. ":predecessor")
      local successor_current = read_fresh(github, identity.successor_source_ref, M.DEPT .. ":successor")

      local receipt_value = store.read(receipt_identity(identity))
      if receipt_value ~= nil then
        if not matching_transfer_receipt(receipt_value, identity) then
          fail("transfer-receipt-conflict", "child disposition was already committed differently")
        end
        if not transfer_chain.has_matching_acceptance(successor_current, identity) then
          fail("transfer-acceptance-missing", "committed transfer has no exact source-visible acceptance")
        end
      else
        if tostring(predecessor_current.state or ""):upper() ~= "OPEN" then
          fail("transfer-predecessor-not-open", "an uncommitted transfer requires an open predecessor")
        end
        if tostring(successor_current.state or ""):upper() ~= "OPEN" then
          fail("transfer-successor-not-open", "an uncommitted transfer requires an open successor")
        end
        if not transfer_chain.has_matching_acceptance(successor_current, identity) then
          write_acceptance(github, file_port, identity)
        end
        successor_current = read_fresh(github, identity.successor_source_ref, M.DEPT .. ":acceptance-readback")
        if tostring(successor_current.state or ""):upper() ~= "OPEN" then
          fail("transfer-successor-not-open", "successor closed before transfer receipt commit")
        end
        if not transfer_chain.has_matching_acceptance(successor_current, identity) then
          fail("transfer-acceptance-readback-missing", "exact successor acceptance is not source-visible")
        end
        devloop_logging.log_line("info", M.DEPT, identity.origin, "TRANSFER", {
          "action=acceptance-visible",
          "slot=" .. identity.slot,
          "successor=" .. identity.successor_source_ref.ref,
        })
        local requested_receipt = receipt_identity(identity)
        requested_receipt.disposition = "transferred"
        requested_receipt.successor_source_ref = identity.successor_source_ref
        receipt_value = store.put_once(requested_receipt)
        if not matching_transfer_receipt(receipt_value, identity) then
          fail("transfer-receipt-conflict", "first-writer disposition does not match the accepted successor")
        end
        devloop_logging.log_line("info", M.DEPT, identity.origin, "TRANSFER", {
          "action=receipt-visible",
          "slot=" .. identity.slot,
          "successor=" .. identity.successor_source_ref.ref,
        })
      end

      predecessor_current = read_fresh(github, identity.predecessor_source_ref, M.DEPT .. ":pre-close-predecessor")
      local predecessor_state = tostring(predecessor_current.state or ""):upper()
      if predecessor_state == "OPEN" then
        successor_current = read_fresh(github, identity.successor_source_ref, M.DEPT .. ":pre-close-successor")
        if not transfer_chain.has_matching_acceptance(successor_current, identity) then
          fail("transfer-acceptance-missing", "exact acceptance disappeared before predecessor close")
        end
        close_predecessor(github, identity)
      elseif predecessor_state ~= "CLOSED" then
        fail("transfer-predecessor-state-invalid", "predecessor state is neither open nor closed")
      end
      return "transferred"
    end)
  end

  return {
    transfer = transfer,
  }
end

function M.install(target)
  target.child_transfer = M
end

return M
