local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local entity_list_cache = require("devloop.entity_list_cache")
local m_claims = require("devloop.claims")
local strings = require("contract.strings")

local target_queue = "github-devloop-intake.devloop_intake_candidate"
local target_dept = "github-devloop-intake-default.intake_judge"
local index_prefix = "github-devloop-intake/replay-observe-index-v1"

local function source_ref_value(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  return source_ref.ref or source_ref.reference
end

local function source_ref_equal(left, right)
  return type(left) == "table"
    and type(right) == "table"
    and left.kind == right.kind
    and source_ref_value(left) == source_ref_value(right)
end

local function normalized_row_source(row)
  if type(row) ~= "table" or type(row.source) ~= "table" then
    return nil
  end
  return {
    kind = row.source.kind,
    ref = source_ref_value(row.source),
  }
end

local function has_truncated_delivery_facts(snapshot)
  local truncated = snapshot and snapshot.truncated
  if type(truncated) ~= "table" then
    return true
  end
  return truncated.deliveries ~= false or truncated.dead_letters ~= false
end

local function validate_observe_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return nil, "observe-unavailable"
  end
  if type(snapshot.deliveries) ~= "table" or type(snapshot.dead_letters) ~= "table" then
    return nil, "observe-missing-delivery-facts"
  end
  if has_truncated_delivery_facts(snapshot) then
    return nil, "observe-truncated"
  end
  return snapshot, nil
end

local function read_observe_snapshot(observe)
  if type(observe) ~= "function" then
    return nil, "observe-unavailable"
  end
  local ok, snapshot = pcall(function()
    return observe({ limit = 10000 })
  end)
  if not ok then
    return nil, "observe-unavailable:" .. tostring(snapshot)
  end
  return validate_observe_snapshot(snapshot)
end

local function matches_lineage(row, source_ref)
  return type(row) == "table"
    and row.queue == target_queue
    and row.dept == target_dept
    and source_ref_equal(row.source, source_ref)
end

local function matching_live_delivery(snapshot, source_ref)
  for _, row in ipairs(snapshot.deliveries or {}) do
    if matches_lineage(row, source_ref) then
      return row
    end
  end
  return nil
end

local function is_terminal_tombstone(row, source_ref)
  return matches_lineage(row, source_ref)
    and type(row.delivery_id) == "string"
    and row.delivery_id ~= ""
    and tonumber(row.attempts) ~= nil
    and tonumber(row.attempts) >= 1
    and row.permanent == true
    and row.replayable == false
end

local function latest_terminal_tombstone(snapshot, source_ref)
  local selected = nil
  for _, row in ipairs(snapshot.dead_letters or {}) do
    if is_terminal_tombstone(row, source_ref) then
      if selected == nil or tonumber(row.dead_at_ms or 0) >= tonumber(selected.dead_at_ms or 0) then
        selected = row
      end
    end
  end
  return selected
end

local function index_epoch_key(repo)
  return table.concat({ index_prefix, base_ids.safe_repo(repo), "epoch" }, "/")
end

local function index_issue_key(repo, issue_number)
  return table.concat({
    index_prefix,
    base_ids.safe_repo(repo),
    "issue",
    base_ids.safe_issue(issue_number),
  }, "/")
end

local function terminal_json(terminal)
  return '{"delivery_id":' .. strings.json_string(terminal.delivery_id)
    .. ',"attempts":' .. tostring(tonumber(terminal.attempts) or 0)
    .. ',"dead_at_ms":' .. tostring(tonumber(terminal.dead_at_ms) or 0)
    .. "}"
end

local function encode_index_entry(poll_token, live, terminal)
  local fields = {
    '"poll_token":' .. strings.json_string(poll_token),
  }
  if live ~= nil then
    table.insert(fields, '"live_status":' .. strings.json_string(tostring(live.status or "present")))
  end
  if terminal ~= nil then
    table.insert(fields, '"terminal":' .. terminal_json(terminal))
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function encode_epoch_outcome(poll_token, reason)
  local fields = {
    '"poll_token":' .. strings.json_string(poll_token),
  }
  if reason ~= nil then
    table.insert(fields, '"reason":' .. strings.json_string(reason))
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function decode_epoch_outcome(encoded)
  if encoded == nil then
    return nil
  end
  local ok, outcome = pcall(json.decode, encoded)
  if not ok
    or type(outcome) ~= "table"
    or type(outcome.poll_token) ~= "string"
    or outcome.poll_token == ""
    or (outcome.reason ~= nil and type(outcome.reason) ~= "string") then
    return nil
  end
  return outcome
end

local function targeted_snapshot(source_ref, entry)
  local deliveries = {}
  local dead_letters = {}
  if entry ~= nil and type(entry.live_status) == "string" then
    table.insert(deliveries, {
      delivery_id = "indexed-live-delivery",
      queue = target_queue,
      dept = target_dept,
      source = source_ref,
      status = entry.live_status,
    })
  end
  local terminal = entry and entry.terminal or nil
  if type(terminal) == "table" then
    table.insert(dead_letters, {
      delivery_id = terminal.delivery_id,
      queue = target_queue,
      dept = target_dept,
      source = source_ref,
      attempts = terminal.attempts,
      permanent = true,
      replayable = false,
      dead_at_ms = terminal.dead_at_ms,
    })
  end
  return {
    truncated = { deliveries = false, dead_letters = false },
    deliveries = deliveries,
    dead_letters = dead_letters,
  }
end

local function decode_index_entry(encoded, poll_token)
  if encoded == nil then
    return nil, nil
  end
  local ok, entry = pcall(json.decode, encoded)
  if not ok or type(entry) ~= "table" then
    return nil, "observe-index-malformed"
  end
  if tostring(entry.poll_token or "") ~= tostring(poll_token) then
    return nil, nil
  end
  if entry.live_status ~= nil and type(entry.live_status) ~= "string" then
    return nil, "observe-index-malformed"
  end
  if entry.terminal ~= nil then
    local terminal = entry.terminal
    if type(terminal) ~= "table"
      or type(terminal.delivery_id) ~= "string"
      or terminal.delivery_id == ""
      or tonumber(terminal.attempts) == nil
      or tonumber(terminal.dead_at_ms) == nil then
      return nil, "observe-index-malformed"
    end
  end
  return entry, nil
end

local function indexed_issue_number(row, repo)
  local row_source = normalized_row_source(row)
  local row_repo, issue_number = devloop_base.parse_issue_source_ref(row_source)
  if row_repo ~= repo then
    return nil, nil
  end
  return issue_number, row_source
end

local function build_epoch_index(repo, poll_token, snapshot)
  local entries = {}
  for _, row in ipairs(snapshot.deliveries) do
    if row.queue == target_queue and row.dept == target_dept then
      local issue_number = indexed_issue_number(row, repo)
      if issue_number ~= nil then
        local entry = entries[issue_number] or {}
        entry.live = entry.live or row
        entries[issue_number] = entry
      end
    end
  end
  for _, row in ipairs(snapshot.dead_letters) do
    if row.queue == target_queue and row.dept == target_dept then
      local issue_number, row_source = indexed_issue_number(row, repo)
      if issue_number ~= nil and is_terminal_tombstone(row, row_source) then
        local entry = entries[issue_number] or {}
        if entry.terminal == nil
          or tonumber(row.dead_at_ms or 0) >= tonumber(entry.terminal.dead_at_ms or 0) then
          entry.terminal = row
        end
        entries[issue_number] = entry
      end
    end
  end
  for issue_number, entry in pairs(entries) do
    cache_set(
      index_issue_key(repo, issue_number),
      encode_index_entry(poll_token, entry.live, entry.terminal)
    )
  end
end

local function read_targeted_snapshot(observe, source_ref, poll_token)
  local repo, issue_number = devloop_base.parse_issue_source_ref(source_ref)
  if repo == nil or issue_number == nil then
    return nil, "source-ref-unmatchable"
  end
  if poll_token == nil or tostring(poll_token) == "" then
    return nil, "observe-poll-epoch-missing"
  end
  local epoch = tostring(poll_token)
  if not entity_list_cache.poll_epoch_is_current(repo, epoch) then
    return nil, "observe-stale-poll-epoch"
  end

  local epoch_key = index_epoch_key(repo)
  local result_snapshot = nil
  local result_reason = nil
  with_lock(epoch_key, function()
    if not entity_list_cache.poll_epoch_is_current(repo, epoch) then
      result_reason = "observe-stale-poll-epoch"
      return
    end
    local epoch_outcome = decode_epoch_outcome(cache_get(epoch_key))
    if epoch_outcome == nil or epoch_outcome.poll_token ~= epoch then
      local build_reason = nil
      local current = entity_list_cache.with_current_poll_epoch(repo, epoch, function()
        local snapshot, reason = read_observe_snapshot(observe)
        if snapshot == nil then
          build_reason = reason
        else
          build_epoch_index(repo, epoch, snapshot)
        end
        cache_set(epoch_key, encode_epoch_outcome(epoch, build_reason))
      end)
      if not current then
        result_reason = "observe-stale-poll-epoch"
        return
      end
      epoch_outcome = {
        poll_token = epoch,
        reason = build_reason,
      }
    end
    if epoch_outcome.reason ~= nil then
      result_reason = epoch_outcome.reason
      return
    end
    if not entity_list_cache.poll_epoch_is_current(repo, epoch) then
      result_reason = "observe-stale-poll-epoch"
      return
    end
    local entry, decode_reason = decode_index_entry(cache_get(index_issue_key(repo, issue_number)), epoch)
    if decode_reason ~= nil then
      result_reason = decode_reason
      return
    end
    result_snapshot = targeted_snapshot(source_ref, entry)
  end)
  return result_snapshot, result_reason
end

local function make(deps)
  local selected = deps or {}
  local observe = selected.observe or function(opts)
    if type(fkst) ~= "table" or type(fkst.observe) ~= "function" then
      error("github-devloop-intake: observe-unavailable: fkst.observe is unavailable")
    end
    return fkst.observe(opts)
  end
  local S = {}

  function S.terminal_precondition(source_ref, poll_token)
    local normalized = base_ids.normalize_source_ref(source_ref)
    local snapshot, observe_reason = read_targeted_snapshot(observe, normalized, poll_token)
    if snapshot == nil then
      return nil, observe_reason, nil
    end
    if matching_live_delivery(snapshot, normalized) ~= nil then
      return nil, "live-delivery-present", snapshot
    end
    local terminal = latest_terminal_tombstone(snapshot, normalized)
    if terminal == nil then
      return nil, "terminal-dlq-absent", snapshot
    end
    return terminal, nil, snapshot
  end

  function S.successor_key(proposal_id, terminal)
    return base_ids.dedup_key({
      "intake-replay",
      tostring(proposal_id),
      tostring(terminal.delivery_id),
      tostring(terminal.attempts),
    })
  end

  function S.once_key(successor_key)
    return "github-devloop-intake/intake-replay/" .. tostring(successor_key)
  end

  function S.authorize(current, proposal_id, source_ref, opts)
    local options = opts or {}
    if type(current) ~= "table" or current.state ~= "OPEN" then
      return nil, "not-open"
    end
    if options.has_trusted_progress == true then
      return nil, "trusted-progress-visible"
    end
    if m_claims.claim_mode_active() ~= "assignee" then
      return nil, "claim-mode-not-assignee"
    end
    local owner = m_claims.claim_owner()
    if m_claims.issue_claim_state(current.assignees, owner, current.labels) ~= "self" then
      return nil, "not-self-only-assignee"
    end
    local repo, issue_number = devloop_base.parse_issue_source_ref(source_ref)
    if repo == nil or issue_number == nil then
      return nil, "source-ref-unmatchable"
    end

    local normalized = base_ids.normalize_source_ref(source_ref)
    local snapshot, observe_reason
    if options.observe_snapshot ~= nil then
      snapshot, observe_reason = validate_observe_snapshot(options.observe_snapshot)
    else
      snapshot, observe_reason = read_targeted_snapshot(observe, normalized, options.poll_token)
    end
    if snapshot == nil then
      return nil, observe_reason
    end
    if matching_live_delivery(snapshot, normalized) ~= nil then
      return nil, "live-delivery-present"
    end
    local terminal = options.terminal
    if terminal ~= nil and not is_terminal_tombstone(terminal, normalized) then
      return nil, "terminal-dlq-absent"
    end
    terminal = terminal or latest_terminal_tombstone(snapshot, normalized)
    if terminal == nil then
      return nil, "terminal-dlq-absent"
    end

    local successor_key = S.successor_key(proposal_id, terminal)
    return {
      repo = repo,
      issue_number = issue_number,
      terminal = terminal,
      successor_key = successor_key,
      once_key = S.once_key(successor_key),
    }, nil
  end

  return S
end

local S = make()
S.make = make

function S.install(M)
  M.intake_replay_authorize = function(...) return S.authorize(...) end
  M.intake_replay_terminal_precondition = function(...) return S.terminal_precondition(...) end
  M.intake_replay_successor_key = S.successor_key
  M.intake_replay_once_key = S.once_key
end

return S
