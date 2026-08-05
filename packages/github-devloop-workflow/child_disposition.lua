local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local devloop_claims = require("devloop.claims")
local devloop_entity = require("devloop.entity")
local devloop_entity_view = require("devloop.github_proxy_entity_view")
local devloop_logging = require("devloop.logging")
local devloop_operator_commands = require("devloop.operator_commands")
local devloop_queue = require("devloop.queue")
local request_shared = require("devloop.requests.shared")
local github_factory = require("devloop.github_factory")
local parsers_misc = require("devloop.parsers.misc")
local parsers_pr = require("devloop.parsers.pr")
local strings = require("contract.strings")
local child_completion = require("core.child_completion")
local discovery = require("core.materialize.discovery")
local marker = require("core.marker")

local M = {}

M.REQUEST_QUEUE = "workflow_child_disposition_request"
M.TIMEOUT_SECONDS = 30

local function fail(code, message)
  error(
    "github-devloop-workflow: child-disposition-operation-failed: error_class="
      .. tostring(code) .. " reason=" .. tostring(message),
    0
  )
end

local function same_lineage(left, right)
  return type(left) == "table"
    and type(right) == "table"
    and left.origin == right.origin
    and left.blueprint_digest == right.blueprint_digest
    and left.slot == right.slot
end

local function github()
  if type(exec_argv) ~= "function" then
    fail("github-adapter-missing-exec-argv", "GitHub adapter requires exec_argv")
  end
  return github_factory.production_handle()
end

local function read_issue(deps, source_ref, consumer)
  if type(deps.read_issue) == "function" then
    return deps.read_issue(source_ref, {
      force_fresh = true,
      timeout = M.TIMEOUT_SECONDS,
      consumer = consumer,
    })
  end
  return github().read_issue(source_ref, {
    force_fresh = true,
    timeout = M.TIMEOUT_SECONDS,
    consumer = consumer,
  })
end

local function with_one_lock(deps, key, fn)
  if type(deps.with_lock) == "function" then
    return deps.with_lock(key, fn)
  end
  return with_lock(key, fn)
end

local function with_authority_locks(deps, request, fn)
  local keys = {
    devloop_entity.merge_lane_lock_key(request.repo),
    devloop_entity.observe_lock_key(request.repo, request.origin_issue_number),
    devloop_entity.observe_lock_key(request.repo, request.child_issue_number),
  }
  table.sort(keys)
  local function acquire(index)
    if index > #keys then
      return fn()
    end
    if index > 1 and keys[index] == keys[index - 1] then
      return acquire(index + 1)
    end
    return with_one_lock(deps, keys[index], function()
      return acquire(index + 1)
    end)
  end
  return acquire(1)
end

local function read_pr(deps, repo, pr_number, consumer)
  if type(deps.read_pr) == "function" then
    return deps.read_pr(repo, pr_number, {
      force_fresh = true,
      timeout = M.TIMEOUT_SECONDS,
      consumer = consumer,
    })
  end
  local result = devloop_entity_view.fetch_pr_view(repo, pr_number, nil, {
    force_fresh = true,
    timeout = M.TIMEOUT_SECONDS,
    consumer = consumer,
  })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    fail("child-pr-read-failed", tostring(result and result.stderr or "missing result"))
  end
  return parsers_pr.parse_pr_view_origin(result.stdout)
end

local function trusted_lineage(issue)
  local trusted_bot = devloop_base.trusted_bot_login()
  local author = devloop_base.strip_bot_login_suffix(devloop_claims.issue_author_login(issue or {}))
  if author == trusted_bot then
    local lineage = marker.parse_lineage_header(issue and issue.body or "")
    if lineage ~= nil then
      return lineage
    end
  end
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(issue and issue.comments or {})) do
    local lineage = marker.parse_lineage_header(parsers_misc.comment_body(comment))
    if lineage ~= nil then
      return lineage
    end
  end
  return nil
end

local function trusted_disposition_fact(issue, expected)
  local latest = nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(issue and issue.comments or {})) do
    local fact = marker.parse_child_disposition_marker(
      parsers_misc.comment_body(comment),
      expected.origin,
      expected.blueprint_digest,
      expected.slot,
      expected.child_issue
    )
    if fact ~= nil then
      latest = fact
    end
  end
  return latest
end

function M.current_fact(issue, expected)
  return trusted_disposition_fact(issue, expected)
end

local function normalized_request(payload)
  if type(payload) ~= "table" or payload.schema ~= "github-devloop-workflow.child-disposition.v1" then
    fail("invalid-disposition-request", "request schema is unsupported")
  end
  local repo = tostring(payload.repo or "")
  local origin_issue_number = tostring(payload.origin_issue_number or "")
  local child_issue_number = tostring(payload.child_issue_number or "")
  if not base_ids.issue_ref_round_trips(repo, origin_issue_number) then
    fail("invalid-origin-ref", "origin issue identity does not round-trip")
  end
  if not base_ids.issue_ref_round_trips(repo, child_issue_number) then
    fail("invalid-child-ref", "child issue identity does not round-trip")
  end
  if not strings.is_path_safe_key(payload.dedup_key, base_ids.max_dedup_len) then
    fail("invalid-request-dedup", "request dedup_key is not a safe bounded key")
  end
  local child_source_ref = base_ids.issue_source_ref(repo, child_issue_number)
  if not devloop_operator_commands.source_refs_match(payload.source_ref, child_source_ref) then
    fail("invalid-request-source-ref", "request source_ref must identify the child issue")
  end
  local origin = base_ids.proposal_id(repo, origin_issue_number)
  local marker_fields = {
    origin = origin,
    blueprint_digest = payload.blueprint_digest,
    slot = payload.slot,
    child_issue = child_issue_number,
    disposition = payload.disposition,
    successor_source_ref = payload.successor_source_ref,
    reason_code = payload.reason_code,
  }
  local disposition_marker, marker_err = marker.build_child_disposition_marker(marker_fields)
  if disposition_marker == nil then
    fail(
      "invalid-disposition-fields",
      tostring(marker_err and marker_err.path or "fields") .. ":" .. tostring(marker_err and marker_err.code or "invalid")
    )
  end

  local successor_issue_number = nil
  if payload.successor_source_ref ~= nil then
    local successor_repo
    successor_repo, successor_issue_number = devloop_base.parse_issue_source_ref(payload.successor_source_ref)
    if successor_repo ~= repo then
      fail("successor-repo-mismatch", "transferred successor must be in the workflow repository")
    end
    if tostring(successor_issue_number) == child_issue_number then
      fail("successor-self-cycle", "transferred successor must differ from the closed child")
    end
  end

  return {
    schema = payload.schema,
    repo = repo,
    origin = origin,
    origin_issue_number = tonumber(origin_issue_number),
    child_issue_number = tonumber(child_issue_number),
    child_source_ref = child_source_ref,
    blueprint_digest = payload.blueprint_digest,
    slot = payload.slot,
    disposition = payload.disposition,
    successor_source_ref = payload.successor_source_ref,
    successor_issue_number = successor_issue_number and tonumber(successor_issue_number) or nil,
    reason_code = payload.reason_code,
    dedup_key = payload.dedup_key,
    marker = disposition_marker,
  }
end

local function same_disposition(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then
    return false
  end
  return left.origin == right.origin
    and left.blueprint_digest == right.blueprint_digest
    and left.slot == right.slot
    and tostring(left.child_issue) == tostring(right.child_issue_number)
    and left.disposition == right.disposition
    and tostring(left.reason_code or "") == tostring(right.reason_code or "")
    and (
      (left.successor_source_ref == nil and right.successor_source_ref == nil)
      or devloop_operator_commands.source_refs_match(left.successor_source_ref, right.successor_source_ref)
    )
end

local function expected_lineage(request)
  return {
    origin = request.origin,
    blueprint_digest = request.blueprint_digest,
    slot = request.slot,
  }
end

local function assert_self_claim(child)
  local claim_state = devloop_claims.issue_claim_state(
    child.assignees,
    devloop_claims.claim_owner(),
    child.labels
  )
  if claim_state ~= "self" then
    fail("child-claim-not-self", "workflow child must retain the configured actor's claim")
  end
end

local function assert_authority(deps, request)
  local origin_issue = read_issue(
    deps,
    base_ids.issue_source_ref(request.repo, request.origin_issue_number),
    "github-devloop-workflow.child-disposition-origin"
  )
  local origin_is_open = tostring(origin_issue and origin_issue.state or ""):upper() == "OPEN"
  local blueprint_fact = discovery.latest_blueprint(nil, origin_issue, request.origin)
  if blueprint_fact == nil or blueprint_fact.digest ~= request.blueprint_digest then
    fail("blueprint-lineage-mismatch", "request does not match the current trusted workflow blueprint")
  end
  local ledger = marker.latest_materialization_by_slot(
    discovery.materialization_facts(nil, origin_issue, request.origin)
  )
  local slot_fact = ledger[tostring(request.slot)]
  if type(slot_fact) ~= "table"
    or slot_fact.state ~= "created"
    or slot_fact.blueprint_digest ~= request.blueprint_digest
    or tostring(slot_fact.child_issue) ~= tostring(request.child_issue_number) then
    fail("created-slot-lineage-mismatch", "request child is not the created child for this workflow slot")
  end

  local child = read_issue(
    deps,
    request.child_source_ref,
    "github-devloop-workflow.child-disposition-child"
  )
  local child_ref = {
    proposal_id = base_ids.proposal_id(request.repo, request.child_issue_number),
    source_ref = request.child_source_ref,
  }
  if not same_lineage(trusted_lineage(child), expected_lineage(request)) then
    fail("child-lineage-mismatch", "child does not carry trusted lineage for the created slot")
  end
  local current_fact = trusted_disposition_fact(child, {
    origin = request.origin,
    blueprint_digest = request.blueprint_digest,
    slot = request.slot,
    child_issue = tostring(request.child_issue_number),
  })
  if current_fact ~= nil and not same_disposition(current_fact, request) then
    fail("conflicting-child-disposition", "child already has a different trusted disposition")
  end
  local child_is_closed = tostring(child.state or ""):upper() == "CLOSED"
  if current_fact ~= nil then
    if not child_is_closed then
      assert_self_claim(child)
    end
    return child, current_fact
  end
  if child_is_closed then
    fail("raw-closed-child", "a raw closed child cannot be retrofitted without a prior workflow disposition")
  end
  if not origin_is_open then
    fail("origin-not-open", "workflow origin must remain open while a child is disposed")
  end

  local link = child_completion.linked_pr(child, child_ref)
  if request.disposition ~= "satisfied" then
    local completion = child_completion.evidence(child, nil, child_ref)
    if not completion.marker and link ~= nil then
      completion = child_completion.evidence(child, read_pr(
        deps,
        request.repo,
        link.pr_number,
        "github-devloop-workflow.child-disposition-pr"
      ), child_ref)
    end
    if completion.merged then
      fail("child-already-merged", "a merged workflow child cannot be transferred or marked undeliverable")
    end
  end
  assert_self_claim(child)

  if request.successor_source_ref ~= nil then
    local successor = read_issue(
      deps,
      request.successor_source_ref,
      "github-devloop-workflow.child-disposition-successor"
    )
    if not same_lineage(trusted_lineage(successor), expected_lineage(request)) then
      fail("successor-lineage-mismatch", "transferred successor does not carry the same workflow slot lineage")
    end
  end
  return child, current_fact
end

local function visible_disposition_line(request)
  if request.disposition == "transferred" then
    return "Workflow child disposition: transferred to #" .. tostring(request.successor_issue_number) .. "."
  end
  if request.disposition == "undeliverable" then
    return "Workflow child disposition: undeliverable (" .. tostring(request.reason_code) .. ")."
  end
  return "Workflow child disposition: satisfied."
end

local function receipt_body(request)
  return visible_disposition_line(request)
    .. "\n\n" .. request.marker
    .. "\n" .. request_shared.ai_sentinel
end

local function write_enabled(deps)
  if type(deps.write_enabled) == "function" then
    return deps.write_enabled()
  end
  return devloop_base.read_env("FKST_GITHUB_WRITE") == "1"
end

local function issue_close(deps, request, disposition)
  if type(deps.issue_close) == "function" then
    return deps.issue_close(
      request.repo,
      request.child_issue_number,
      disposition,
      M.TIMEOUT_SECONDS
    )
  end
  return github().issue_close(
    request.repo,
    request.child_issue_number,
    disposition,
    M.TIMEOUT_SECONDS
  )
end

local function write_receipt(deps, request, body)
  if type(deps.write_receipt) == "function" then
    return deps.write_receipt(request, body, M.TIMEOUT_SECONDS)
  end
  local repo_key = request.repo:gsub("[^%w_.-]", "-")
  local path = "/tmp/fkst-github-devloop-workflow-child-disposition-"
    .. repo_key .. "-" .. tostring(request.child_issue_number) .. ".md"
  file.write(path, body)
  return github().issue_comment_create(
    request.repo,
    request.child_issue_number,
    path,
    M.TIMEOUT_SECONDS
  )
end

local function invalidate(deps, request)
  if type(deps.invalidate_entity_after_write) == "function" then
    deps.invalidate_entity_after_write(request.repo, "issue", request.child_issue_number)
    return
  end
  devloop_entity_view.invalidate_entity_after_write(request.repo, "issue", request.child_issue_number)
end

local function close_disposition(request)
  if request.disposition == "satisfied" then
    return { kind = "completed" }
  end
  if request.disposition == "transferred" then
    return {
      kind = "duplicate",
      duplicate_of = request.successor_issue_number,
    }
  end
  return { kind = "not_planned" }
end

function M.request_handlers(opts)
  local deps = opts and opts.deps or {}
  return {
    accept = function(event)
      return devloop_queue.event_queue_matches(event, M.REQUEST_QUEUE, "github-devloop-workflow")
    end,
    done = function() return false end,
    act = function(event)
      if not devloop_queue.event_queue_matches(event, M.REQUEST_QUEUE, "github-devloop-workflow") then
        fail("unsupported-consumed-queue", "unsupported consumed queue")
      end
      local request = normalized_request(event and event.payload)
      with_authority_locks(deps, request, function()
        local child, current_fact = assert_authority(deps, request)
        if tostring(child.state or ""):upper() == "CLOSED" and current_fact ~= nil then
          return
        end
        if not write_enabled(deps) then
          return
        end
        if current_fact == nil then
          local receipt = write_receipt(deps, request, receipt_body(request))
          if type(receipt) ~= "table" or receipt.exit_code ~= 0 then
            fail("child-disposition-receipt-failed", tostring(receipt and receipt.stderr or "missing result"))
          end
          invalidate(deps, request)
        end
        local result = issue_close(deps, request, close_disposition(request))
        if type(result) ~= "table" or result.exit_code ~= 0 then
          fail("child-disposition-close-failed", tostring(result and result.stderr or "missing result"))
        end
        invalidate(deps, request)
      end)
    end,
    wrap = devloop_logging.wrap_pipeline_failure,
    name = "workflow_child_disposition",
  }
end

return M
