local base_ids = require("devloop.base_ids")
local child_disposition_receipt = require("core.child_disposition_receipt")
local child_disposition_request = require("core.child_disposition_request")
local claims = require("devloop.claims")
local devloop_base = require("devloop.base")
local devloop_entity = require("devloop.entity")
local devloop_logging = require("devloop.logging")
local discovery = require("core.materialize.discovery")
local gitref = require("forge.gitref")
local marker = require("core.marker")
local parsers_misc = require("devloop.parsers.misc")

local M = {}

M.DEPT = "workflow_child_disposition"
M.QUEUE = "workflow_child_disposition_request"
M.CLOSE_TIMEOUT_SECONDS = 30

local receipt_fields = {
  "repo",
  "origin",
  "blueprint_digest",
  "slot",
  "child_issue",
  "disposition",
}

local function fail(error_class, reason)
  error(
    "github-devloop-workflow: child-disposition-failed: error_class="
      .. tostring(error_class) .. " reason=" .. tostring(reason),
    0
  )
end

local function queue_matches(event)
  local queue = tostring(event and event.queue or "")
  return queue == M.QUEUE or queue:match("%." .. M.QUEUE .. "$") ~= nil
end

local function log_decision(request, outcome, reason)
  devloop_logging.log_cas_decision(
    M.DEPT,
    request and request.origin or "unknown",
    { state = nil, version = nil },
    "requested",
    "receipt-confirmed|child-closed",
    outcome,
    reason
  )
end

local function trusted_child_lineage(child)
  local trusted_login = devloop_base.trusted_bot_login()
  if devloop_base.strip_bot_login_suffix(child and child.author_login) == trusted_login then
    local lineage = marker.parse_lineage_header(child.body or "")
    if lineage ~= nil then
      return lineage
    end
  end
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(child and child.comments or {})) do
    local lineage = marker.parse_lineage_header(parsers_misc.comment_body(comment))
    if lineage ~= nil then
      return lineage
    end
  end
  return nil
end

local function matching_lineage(lineage, request)
  return type(lineage) == "table"
    and lineage.origin == request.origin
    and lineage.blueprint_digest == request.blueprint_digest
    and lineage.slot == request.slot
end

local function matching_materialization(core, current_origin, request)
  local by_slot = marker.latest_materialization_by_slot(
    discovery.materialization_facts(core, current_origin, request.origin)
  )
  local entry = by_slot[request.slot]
  return type(entry) == "table"
    and entry.state == "created"
    and entry.origin == request.origin
    and entry.blueprint_digest == request.blueprint_digest
    and entry.slot == request.slot
    and tostring(entry.child_issue or "") == request.child_issue
end

local function claim_owner(ports)
  if type(ports.claim_owner) == "function" then
    return ports.claim_owner()
  end
  return claims.claim_owner()
end

local function self_claimed(child, ports)
  return claims.issue_claim_state(
    child and child.assignees,
    claim_owner(ports),
    child and child.labels
  ) == "self"
end

local function read_issue(github, source_ref)
  return github.read_issue(source_ref, {
    force_fresh = true,
    timeout = M.CLOSE_TIMEOUT_SECONDS,
    consumer = M.DEPT,
  })
end

local function authorize(core, ports, request)
  local repo, origin_issue = base_ids.parse_proposal_id(request.origin)
  local current_origin = read_issue(ports.github, base_ids.issue_source_ref(repo, origin_issue))
  local current_child = read_issue(ports.github, request.source_ref)
  if tostring(current_origin.state or ""):upper() ~= "OPEN" then
    fail("origin-not-open", "workflow origin is not open")
  end
  local blueprint = discovery.latest_blueprint(core, current_origin, request.origin)
  if blueprint == nil or blueprint.digest ~= request.blueprint_digest then
    fail("blueprint-authority-mismatch", "current trusted blueprint digest does not match request")
  end
  if not matching_materialization(core, current_origin, request) then
    fail("materialization-authority-mismatch", "current created materialization does not match request")
  end
  if not matching_lineage(trusted_child_lineage(current_child), request) then
    fail("child-lineage-mismatch", "trusted child lineage does not match request")
  end
  if not self_claimed(current_child, ports) then
    fail("child-claim-lost", "child is not held by the current self-only claim")
  end
  return current_child
end

local function git_commands(git)
  return {
    git_ls_remote_ref = function(...) return git.ls_remote_ref(...) end,
    git_fetch_ref = function(...) return git.fetch_ref(...) end,
    git_cat_file_pretty = function(...) return git.cat_file_pretty(...) end,
    git_rev_parse_ref_commit = function(...) return git.rev_parse_ref_commit(...) end,
    git_rev_parse_ref_tree = function(...) return git.rev_parse_ref_tree(...) end,
    git_commit_tree = function(...) return git.commit_tree(...) end,
    git_push_ref_update = function(...) return git.push_ref_update(...) end,
  }
end

local function receipt_store(ports)
  if type(ports.receipt_store) == "table" then
    return ports.receipt_store
  end
  if type(ports.git) ~= "table" then
    fail("receipt-git-port-missing", "receipt persistence requires the Git port")
  end
  return child_disposition_receipt.new({ commands = git_commands(ports.git) })
end

local function matching_receipt(receipt, request)
  if type(receipt) ~= "table"
    or receipt.schema ~= child_disposition_receipt.RECEIPT_SCHEMA
    or not gitref.is_git_sha(receipt.commit_sha) then
    return false
  end
  for _, field in ipairs(receipt_fields) do
    if tostring(receipt[field] or "") ~= tostring(request[field] or "") then
      return false
    end
  end
  return true
end

local function receipt_value(request)
  local value = {}
  for _, field in ipairs(receipt_fields) do
    value[field] = request[field]
  end
  return value
end

local function write_enabled(ports)
  if type(ports.write_enabled) == "function" then
    return ports.write_enabled()
  end
  return devloop_base.read_env("FKST_GITHUB_WRITE") == "1"
end

local function reconcile(core, ports, request)
  local repo = base_ids.parse_proposal_id(request.origin)
  return with_lock(devloop_entity.merge_lane_lock_key(repo), function()
    local child = authorize(core, ports, request)
    if tostring(child.state or ""):upper() ~= "OPEN" then
      log_decision(request, "skip-idempotent(child-closed)", "child is already closed")
      return "child-closed"
    end
    if not write_enabled(ports) then
      log_decision(request, "dry-run", "confirmed disposition would persist and close child but FKST_GITHUB_WRITE!=1")
      return "dry-run"
    end

    local store = receipt_store(ports)
    local proposed = receipt_value(request)
    store.put_once(proposed)
    local confirmed = store.read(proposed)
    if not matching_receipt(confirmed, proposed) then
      fail("receipt-readback-unconfirmed", "authoritative receipt readback does not match request")
    end
    log_decision(request, "applied(receipt-confirmed)", "source-visible satisfied receipt authorizes close")

    local current_child = read_issue(ports.github, request.source_ref)
    if not matching_lineage(trusted_child_lineage(current_child), request) then
      fail("child-lineage-mismatch", "trusted child lineage changed before close")
    end
    if not self_claimed(current_child, ports) then
      fail("child-claim-lost", "child claim changed before close")
    end
    if tostring(current_child.state or ""):upper() ~= "OPEN" then
      log_decision(request, "skip-idempotent(child-closed)", "receipt is confirmed and child is already closed")
      return "child-closed"
    end

    local result = ports.github.issue_close(
      repo,
      request.child_issue,
      { kind = "completed" },
      M.CLOSE_TIMEOUT_SECONDS
    )
    if type(result) == "table" and result.exit_code ~= nil and tonumber(result.exit_code) ~= 0 then
      fail("child-close-failed", tostring(result.stderr or "GitHub issue close failed"))
    end
    log_decision(request, "applied(child-closed)", "confirmed satisfied receipt closed child as completed")
    return "child-closed"
  end)
end

function M.handlers(package_core, opts)
  local resolved_core = package_core or require("core")
  local ports = opts and opts.ports or opts or {}
  return {
    done = function(event)
      if not queue_matches(event) then
        fail("unsupported-consumed-queue", tostring(event and event.queue or ""))
      end
      return false
    end,
    act = function(event)
      if not queue_matches(event) then
        fail("unsupported-consumed-queue", tostring(event and event.queue or ""))
      end
      local request = child_disposition_request.normalize(event and event.payload)
      return reconcile(resolved_core, ports, request)
    end,
    wrap = resolved_core.wrap_pipeline_failure,
    name = M.DEPT,
  }
end

return M
