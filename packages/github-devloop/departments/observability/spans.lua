local common = require("departments.observability.common")
local marker_shared = require("core.markers.shared")
local strings = require("std.strings")

local M = {}

function M.install_spans(core)
local marker_attr = marker_shared.marker_attr
local transition_window_seconds = common.recent_transition_window_seconds
local completed_sample_limit = common.completed_span_sample_limit

local function all_comments(entity)
  local comments = {}
  local function append(source)
    for _, comment in ipairs(source or {}) do
      table.insert(comments, comment)
    end
  end
  append(entity and entity.comments)
  append(entity and entity.parent_issue and entity.parent_issue.comments)
  append(entity and entity.pr and entity.pr.comments)
  return comments
end

local function issue_comments(entity)
  return entity and entity.parent_issue and entity.parent_issue.comments or entity and entity.comments or {}
end

local function pr_comments(entity)
  return entity and entity.pr and entity.pr.comments or {}
end

local function state_records(entity)
  local records = {}
  local seen = {}
  local marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"
  local proposal_id = tostring(entity and entity.proposal_id or "")
  local order = 0
  for _, comment in ipairs(core._trusted_marker_comments(all_comments(entity))) do
    local created_at = core._comment_created_at(comment)
    local created_seconds = core.iso_timestamp_epoch_seconds(created_at)
    if created_seconds ~= nil then
      for marker in core._comment_body(comment):gmatch(marker_pattern) do
        local marker_proposal = marker_attr(marker, "proposal")
        local marker_state = marker_attr(marker, "state")
        local marker_version = marker_attr(marker, "version")
        if marker_proposal == proposal_id and core._label_by_state[marker_state] ~= nil then
          local key = table.concat({ marker_state, marker_version or "", created_at or "" }, "\n")
          if seen[key] ~= true then
            seen[key] = true
            order = order + 1
            table.insert(records, {
              proposal_id = marker_proposal,
              state = marker_state,
              version = marker_version,
              created_at = created_at,
              seconds = created_seconds,
              order = order,
            })
          end
        end
      end
    end
  end
  table.sort(records, function(a, b)
    if a.seconds ~= b.seconds then
      return a.seconds < b.seconds
    end
    return a.order < b.order
  end)
  return records
end

local function transition_row_by_state()
  local rows = {}
  for _, row in ipairs(core.restart_transition_table()) do
    rows[row.from_state] = row
  end
  return rows
end

local function live_defer_row(rows, state)
  local row = rows[state]
  if row == nil or row.watchdog == nil or row.watchdog.mode ~= "live-defer" then
    return nil
  end
  return row
end

local function source_ref_for_signal(entity, row)
  local signal = row and row.liveness_contract and row.liveness_contract.signal
  if signal and signal.surface == "pr-comment-stream" then
    return entity and (entity.pr_source_ref or entity.source_ref)
  end
  return entity and (entity.issue_source_ref or entity.source_ref)
end

local function heartbeat_dwell_seconds(entity, current_state, rows, now_seconds)
  local row = live_defer_row(rows, current_state and current_state.state)
  if row == nil then
    return nil
  end
  local signal_state = {
    proposal_id = entity and entity.proposal_id,
    state = current_state.state,
    version = current_state.version,
    marker_created_at = current_state.marker_created_at,
  }
  local facts = {
    proposal_id = entity and entity.proposal_id,
    source_ref = source_ref_for_signal(entity, row),
    current = {
      comments = issue_comments(entity),
    },
    current_pr = {
      comments = pr_comments(entity),
      number = entity and entity.pr_number,
      head_sha = entity and entity.pr and entity.pr.head_sha,
    },
    head_sha = entity and entity.pr and entity.pr.head_sha,
  }
  local signal = core.restart_row_liveness_signal(row, signal_state, facts, now_seconds)
  if signal ~= nil and signal.age_minutes ~= nil then
    return math.max(0, tonumber(signal.age_minutes) or 0) * 60
  end
  return nil
end

local function state_entry_dwell_seconds(current_state, now_seconds, records)
  local created_at = current_state and current_state.marker_created_at
  local created_seconds = core.iso_timestamp_epoch_seconds(created_at)
  if created_seconds == nil then
    for index = #records, 1, -1 do
      local record = records[index]
      if record.state == current_state.state and record.version == current_state.version then
        created_seconds = record.seconds
        break
      end
    end
  end
  if created_seconds == nil or tonumber(now_seconds) == nil then
    return nil
  end
  return math.max(0, tonumber(now_seconds) - created_seconds)
end

local function ensure_state(metrics, state)
  local by_state = metrics.by_state
  if by_state[state] == nil then
    by_state[state] = {
      state = state,
      open_count = 0,
      open_sample_count = 0,
      open_total_seconds = 0,
      avg_open_dwell_seconds = nil,
      completed_count = 0,
      completed_total_seconds = 0,
      avg_completed_seconds = nil,
      open_anchor = "state-entry",
      completed_samples = {},
    }
  end
  return by_state[state]
end

local function add_open_span(metrics, state, dwell_seconds, anchor)
  local row = ensure_state(metrics, state)
  row.open_count = row.open_count + 1
  if dwell_seconds ~= nil then
    row.open_sample_count = row.open_sample_count + 1
    row.open_total_seconds = row.open_total_seconds + dwell_seconds
  end
  if anchor == "heartbeat" then
    row.open_anchor = "heartbeat"
  end
end

local function trim_completed_samples(row)
  table.sort(row.completed_samples, function(a, b)
    if a.completed_at ~= b.completed_at then
      return (a.completed_at or 0) < (b.completed_at or 0)
    end
    return (a.duration_seconds or 0) < (b.duration_seconds or 0)
  end)
  while #row.completed_samples > completed_sample_limit do
    table.remove(row.completed_samples, 1)
  end
end

local function add_completed_span(metrics, from_state, to_state, duration_seconds, completed_at, now_seconds)
  if duration_seconds == nil or duration_seconds < 0 then
    return
  end
  local row = ensure_state(metrics, from_state)
  table.insert(row.completed_samples, {
    duration_seconds = duration_seconds,
    completed_at = completed_at,
  })
  trim_completed_samples(row)

  if tonumber(now_seconds) ~= nil and completed_at ~= nil
    and completed_at <= now_seconds
    and now_seconds - completed_at <= transition_window_seconds then
    local key = tostring(from_state) .. "->" .. tostring(to_state)
    metrics.transition_counts[key] = (metrics.transition_counts[key] or 0) + 1
  end
end

local function finalize_state_rows(metrics)
  for _, row in pairs(metrics.by_state) do
    if row.open_sample_count > 0 then
      row.avg_open_dwell_seconds = math.floor((row.open_total_seconds / row.open_sample_count) + 0.5)
    end
    trim_completed_samples(row)
    local completed_total = 0
    for _, sample in ipairs(row.completed_samples) do
      completed_total = completed_total + sample.duration_seconds
    end
    row.completed_count = #row.completed_samples
    row.completed_total_seconds = completed_total
    if row.completed_count > 0 then
      row.avg_completed_seconds = math.floor((completed_total / row.completed_count) + 0.5)
    end
  end
end

local function sorted_transitions(transition_counts)
  local rows = {}
  for transition, count in pairs(transition_counts or {}) do
    table.insert(rows, {
      transition = transition,
      count = count,
    })
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.transition < b.transition
  end)
  return rows
end

local function stable_summary(metrics)
  local lines = {
    "recent_window_seconds=" .. tostring(metrics.recent_window_seconds),
  }
  for _, state in ipairs(core._state_order) do
    local row = metrics.by_state[state]
    if row ~= nil then
      table.insert(lines, table.concat({
        state,
        tostring(row.open_count),
        tostring(row.avg_open_dwell_seconds or ""),
        tostring(row.completed_count),
        tostring(row.avg_completed_seconds or ""),
        tostring(row.open_anchor or ""),
      }, "|"))
    end
  end
  for _, transition in ipairs(metrics.transitions) do
    table.insert(lines, tostring(transition.transition) .. "=" .. tostring(transition.count))
  end
  return table.concat(lines, "\n")
end

function core.observability_span_metrics(entities, now_seconds)
  local metrics = {
    by_state = {},
    transition_counts = {},
    transitions = {},
    recent_window_seconds = transition_window_seconds,
  }
  local rows = transition_row_by_state()
  local current_seconds = tonumber(now_seconds) or now()
  for _, entity in ipairs(entities or {}) do
    local records = state_records(entity)
    for index = 1, #records - 1 do
      local current = records[index]
      local successor = records[index + 1]
      if current.state ~= successor.state then
        add_completed_span(metrics, current.state, successor.state, successor.seconds - current.seconds, successor.seconds, current_seconds)
      end
    end

    local current_state = entity.state
    if type(current_state) == "table" and core._label_by_state[current_state.state] ~= nil then
      local heartbeat_dwell = heartbeat_dwell_seconds(entity, current_state, rows, current_seconds)
      if heartbeat_dwell ~= nil then
        add_open_span(metrics, current_state.state, heartbeat_dwell, "heartbeat")
      else
        add_open_span(metrics, current_state.state, state_entry_dwell_seconds(current_state, current_seconds, records), "state-entry")
      end
    end
  end
  finalize_state_rows(metrics)
  metrics.transitions = sorted_transitions(metrics.transition_counts)
  metrics.summary_hash = strings.decimal_checksum(stable_summary(metrics))
  return metrics
end
end

return M
