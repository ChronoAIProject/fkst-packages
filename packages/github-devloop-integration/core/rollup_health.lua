local base_ids = require("devloop.base_ids")
local devloop_entity = require("devloop.entity")
local error_facts = require("contract.error_facts")
local forge_validators = require("devloop.forge_validators")
local parsers_misc = require("devloop.parsers.misc")
local S = {}
local contract_time = require("contract.time")

local observe_sample_marker_name = "fkst:github-devloop-integration:rollup-observe-sample:v1"
local observe_sample_replace_marker = "<!-- " .. observe_sample_marker_name
local observe_sample_marker_pattern = "<!%-%-%s*" .. observe_sample_marker_name:gsub("%-", "%%-") .. ".-%-%->"

local function bool_value(value)
  if value == true then
    return true
  end
  return type(value) == "string" and value:lower() == "true"
end

local function int_value(value)
  local parsed = tonumber(value)
  if parsed == nil then
    return 0
  end
  return math.floor(parsed)
end

local function list_from_any(value)
  if type(value) ~= "table" then
    return {}
  end
  local result = {}
  local max_index = 0
  for key, item in pairs(value) do
    if type(key) == "number" and key > max_index then
      max_index = key
    end
    table.insert(result, item)
  end
  if max_index > 0 then
    result = {}
    for index = 1, max_index do
      if value[index] ~= nil then
        table.insert(result, value[index])
      end
    end
  end
  return result
end

local function first_non_empty_list_from_keys(snapshot, keys)
  if type(snapshot) ~= "table" then
    return {}
  end
  for _, key in ipairs(keys or {}) do
    local values = list_from_any(snapshot[key])
    if #values > 0 then
      return values
    end
  end
  return {}
end

local function first_string(row, keys, default)
  if type(row) ~= "table" then
    return default or "-"
  end
  for _, key in ipairs(keys or {}) do
    local value = row[key]
    if value ~= nil then
      if type(value) == "table" then
        local nested = value.ref or value.id or value.kind
        if nested ~= nil then
          return tostring(nested)
        end
      else
        local text = tostring(value)
        if text ~= "" then
          return text
        end
      end
    end
  end
  return default or "-"
end

local function parse_time_seconds(value)
  if value == nil then
    return nil
  end
  if type(value) == "number" then
    if value > 10000000000 then
      return math.floor(value / 1000)
    end
    return math.floor(value)
  end
  return contract_time.iso_timestamp_epoch_seconds(value)
end

local function event_timestamp_seconds(event)
  if type(event) ~= "table" then
    return nil
  end
  for _, key in ipairs({ "ts", "time", "at", "observed_at", "updated_at", "created_at", "observed_at_ms", "event_ts" }) do
    local parsed = parse_time_seconds(event[key])
    if parsed ~= nil then
      return parsed
    end
  end
  return nil
end

local function event_sort_key(event)
  return event_timestamp_seconds(event) or -1
end

local function latest_entity_events(snapshot, now_seconds)
  local records = {}
  local raw_entities = first_non_empty_list_from_keys(snapshot, {
    "entities",
    "entity_timeline",
    "entity_timelines",
    "timelines",
  })
  for _, raw in ipairs(raw_entities) do
    if type(raw) == "table" then
      local events = list_from_any(raw.events or raw.timeline or raw.event_timeline)
      local latest_event = type(raw.latest_event) == "table" and raw.latest_event or nil
      if latest_event == nil and #events > 0 then
        for _, event in ipairs(events) do
          if type(event) == "table" and (latest_event == nil or event_sort_key(event) > event_sort_key(latest_event)) then
            latest_event = event
          end
        end
      end
      latest_event = latest_event or raw
      local ts = event_timestamp_seconds(latest_event)
      table.insert(records, {
        entity = first_string(raw, { "entity", "entity_id", "id", "source_ref", "ref", "key", "proposal" }),
        event = latest_event,
        dwell_seconds = ts ~= nil and ((tonumber(now_seconds) or now()) - ts) or nil,
        entity_terminal = bool_value(raw.terminal),
      })
    end
  end
  return records
end

local function expected_transient_event(event)
  if type(event) ~= "table" then
    return false
  end
  return event.disposition == "expected-transient"
    or event.outcome == "retry-pending"
    or event.outcome == "skip-foreign"
    or event.outcome == "deadline-defer"
    or event.error_class == "retry-pending"
    or event.error_class == "marker-lag"
end

local function failure_facts(snapshot)
  for _, key in ipairs({ "failure_facts", "failures", "error_facts" }) do
    local facts = list_from_any(snapshot[key])
    if #facts > 0 then
      return facts
    end
  end
  return {}
end

local function fact_queue(fact)
  return first_string(fact, { "origin_queue", "queue", "event_queue" })
end

local function fact_dept(fact)
  return first_string(fact, { "origin_dept", "dept", "department", "dead_dept" }, fact_queue(fact))
end

local function fact_source_ref_kind(fact)
  local source_ref = type(fact) == "table" and fact.source_ref or nil
  if type(source_ref) == "table" then
    return tostring(source_ref.kind or "")
  end
  return ""
end

local function cron_failure_fact(fact)
  local queue = fact_queue(fact)
  return queue:find("_tick$", 1, false) ~= nil or fact_source_ref_kind(fact) == "cron"
end

local function top_level_dead_letters(snapshot)
  for _, key in ipairs({ "dlq", "dead_letters", "dead_letter" }) do
    local value = snapshot[key]
    if type(value) == "number" and value > 0 then
      return "dead-letter:count=" .. tostring(value)
    end
    if type(value) == "table" and #list_from_any(value) > 0 then
      local first = list_from_any(value)[1]
      return "dead-letter:" .. first_string(first, { "queue", "event_queue", "name" })
    end
  end
  return nil
end

local function queue_dlq(snapshot)
  for _, queue in ipairs(list_from_any(snapshot.queues or snapshot.queue_state or snapshot.queue_states)) do
    if type(queue) == "table" then
      for _, key in ipairs({ "dlq", "dead", "dead_letters", "dead_letter" }) do
        local value = queue[key]
        local count = type(value) == "table" and #list_from_any(value) or int_value(value)
        if count > 0 then
          return "queue-dlq:" .. first_string(queue, { "queue", "name", "id" }) .. ":count=" .. tostring(count)
        end
      end
    end
  end
  return nil
end

local function nonnegative_integer(value)
  if type(value) ~= "number" or value < 0 or value ~= math.floor(value) then
    return nil
  end
  return value
end

local function strict_list(value)
  if type(value) ~= "table" then
    return nil
  end
  local count = 0
  local max_index = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return nil
    end
    count = count + 1
    max_index = math.max(max_index, key)
  end
  if count ~= max_index then
    return nil
  end
  local result = {}
  for index = 1, max_index do
    result[index] = value[index]
  end
  return result
end

local function aggregate_count(value)
  if type(value) == "number" then
    return nonnegative_integer(value)
  end
  local entries = strict_list(value)
  if entries ~= nil then
    return #entries
  end
  return nil
end

local function dead_letter_aggregate_mismatch(snapshot, detail_counts, total)
  for _, key in ipairs({ "dlq", "dead_letter" }) do
    if snapshot[key] ~= nil then
      local count = aggregate_count(snapshot[key])
      if count == nil or count ~= total then
        return "dead-letter-detail-inconsistent:source=" .. key
          .. ":count=" .. tostring(count or "invalid")
          .. ":detail=" .. tostring(total)
      end
    end
  end
  local queues = strict_list(snapshot.queues or snapshot.queue_state or snapshot.queue_states)
  if queues == nil then
    return nil
  end
  for _, queue in ipairs(queues) do
    if type(queue) == "table" then
      local queue_name = first_string(queue, { "queue", "name", "id" })
      for _, key in ipairs({ "dlq", "dead", "dead_letters", "dead_letter" }) do
        if queue[key] ~= nil then
          local count = aggregate_count(queue[key])
          local detail = detail_counts[queue_name] or 0
          if count == nil or count ~= detail then
            return "dead-letter-detail-inconsistent:queue=" .. queue_name
              .. ":count=" .. tostring(count or "invalid")
              .. ":detail=" .. tostring(detail)
          end
        end
      end
    end
  end
  return nil
end

local function promotion_dead_letter(snapshot, window_start_ms)
  if snapshot.schema_version ~= 1 then
    return "observe-schema-unsupported"
  end
  local generated_at_ms = nonnegative_integer(snapshot.generated_at_ms)
  local starts_at_ms = nonnegative_integer(window_start_ms)
  if generated_at_ms == nil then
    return "observe-generated-at-invalid"
  end
  if starts_at_ms == nil or starts_at_ms > generated_at_ms then
    return "observe-window-invalid"
  end
  if type(snapshot.truncated) ~= "table" or type(snapshot.truncated.dead_letters) ~= "boolean" then
    return "dead-letter-detail-unavailable"
  end
  if snapshot.truncated.dead_letters then
    return "dead-letter-detail-truncated"
  end
  local entries = strict_list(snapshot.dead_letters)
  if entries == nil then
    return "dead-letter-detail-unavailable"
  end
  local detail_counts = {}
  for _, entry in ipairs(entries) do
    if type(entry) ~= "table" then
      return "dead-letter-entry-invalid"
    end
    local queue = first_string(entry, { "queue", "event_queue", "name" })
    local dead_at_ms = nonnegative_integer(entry.dead_at_ms)
    if queue == "-" or dead_at_ms == nil or dead_at_ms > generated_at_ms then
      return "dead-letter-time-invalid:" .. queue
    end
    detail_counts[queue] = (detail_counts[queue] or 0) + 1
  end
  local mismatch = dead_letter_aggregate_mismatch(snapshot, detail_counts, #entries)
  if mismatch ~= nil then
    return mismatch
  end
  for _, entry in ipairs(entries) do
    if entry.dead_at_ms >= starts_at_ms then
      return "dead-letter:" .. first_string(entry, { "queue", "event_queue", "name" })
    end
  end
  return nil
end

local function terminal_failure_fact(snapshot)
  local cron_counts = {}
  for _, fact in ipairs(failure_facts(snapshot)) do
    if type(fact) == "table" and cron_failure_fact(fact) then
      local key = fact_dept(fact)
      cron_counts[key] = (cron_counts[key] or 0) + 1
    end
  end
  for key, count in pairs(cron_counts) do
    if count > 1 then
      return "infra-stall:" .. tostring(key) .. ":observed_count=" .. tostring(count)
    end
  end
  for _, fact in ipairs(failure_facts(snapshot)) do
    if type(fact) == "table"
      and (bool_value(fact.terminal) or fact.disposition == "terminal")
      and not cron_failure_fact(fact) then
      return "terminal-failure:" .. fact_queue(fact)
    end
  end
  return nil
end

local function entity_anomaly(snapshot, now_seconds, stall_seconds)
  for _, row in ipairs(latest_entity_events(snapshot, now_seconds)) do
    local event = row.event
    if type(event) == "table" then
      if bool_value(event.safety_violation) or event.disposition == "safety-violation" then
        return "safety-violation:" .. row.entity
      end
      if bool_value(event.terminal) or event.disposition == "terminal" or event.tag == "DEAD_LETTER" then
        return "terminal-failure:" .. row.entity
      end
      if expected_transient_event(event) then
        goto continue
      end
      if row.entity_terminal ~= true
        and row.dwell_seconds ~= nil
        and row.dwell_seconds > (tonumber(stall_seconds) or 1800) then
        return "stalled-entity:" .. row.entity
      end
    end
    ::continue::
  end
  return nil
end

local function observed_at_ms(value)
  local number = tonumber(value)
  if number == nil then
    return nil
  end
  return math.floor(number)
end

-- Keep this cumulative operator-health contract in sync with scripts/board.py.
-- Candidate promotion uses the head-window verdict below.
function S.verdict(snapshot, opts)
  if type(snapshot) ~= "table" then
    return { clean = false, reason = "observe-malformed" }
  end
  local options = opts or {}
  local reason = top_level_dead_letters(snapshot)
    or queue_dlq(snapshot)
    or terminal_failure_fact(snapshot)
    or entity_anomaly(snapshot, options.now_seconds, options.stall_seconds)
  if reason ~= nil then
    return { clean = false, reason = reason }
  end
  return { clean = true, reason = "clean" }
end

function S.promotion_verdict(snapshot, window_start_ms, opts)
  if type(snapshot) ~= "table" then
    return { clean = false, reason = "observe-malformed" }
  end
  local options = opts or {}
  local reason = promotion_dead_letter(snapshot, window_start_ms)
    or terminal_failure_fact(snapshot)
    or entity_anomaly(
      snapshot,
      math.floor((nonnegative_integer(snapshot.generated_at_ms) or 0) / 1000),
      options.stall_seconds
    )
  if reason ~= nil then
    return { clean = false, reason = reason }
  end
  return { clean = true, reason = "clean" }
end

local function observe_runtime_snapshot()
  if type(fkst) ~= "table" or type(fkst.observe) ~= "function" then
    return nil
  end
  local ok, snapshot = pcall(function()
    return fkst.observe({ include = { "queues", "errors", "events", "entities" } })
  end)
  if not ok then
    return nil
  end
  return snapshot
end

function S.observe_runtime_health()
  local snapshot = observe_runtime_snapshot()
  if snapshot == nil then
    return { clean = false, reason = "observe-unavailable" }
  end
  local verdict = S.verdict(snapshot)
  if verdict.clean ~= true and verdict.reason == "observe-malformed" then
    verdict.reason = "observe-unavailable"
  end
  return verdict
end

function S.observe_promotion_health(window_start_ms, opts)
  local snapshot = observe_runtime_snapshot()
  if snapshot == nil then
    return { clean = false, reason = "observe-unavailable" }
  end
  local starts_at_ms = window_start_ms
  if starts_at_ms == nil then
    starts_at_ms = snapshot.generated_at_ms
  end
  local verdict = S.promotion_verdict(snapshot, starts_at_ms, opts)
  if verdict.clean ~= true and verdict.reason == "observe-malformed" then
    verdict.reason = "observe-unavailable"
  end
  return verdict, nonnegative_integer(snapshot.generated_at_ms)
end

function S.runtime_observe_gate(verdict)
  if type(verdict) ~= "table" or verdict.clean ~= true then
    local reason = type(verdict) == "table" and verdict.reason or "observe-unavailable"
    if reason == "observe-unavailable" or reason == "observe-malformed" then
      return false, "observe-unavailable", reason
    end
    return false, "runtime-unstable", reason or "observe-dirty"
  end
  return true, "runtime-clean"
end

function S.observe_sample_marker(head_sha, status, first_clean_observed_at_ms_value, sampled_at_ms_value)
  if not forge_validators.is_git_sha(head_sha) then
    error("github-devloop-integration: rollup-observe-sample-head-invalid: invalid rollup observe sample head sha")
  end
  if status ~= "clean" and status ~= "dirty" then
    error("github-devloop-integration: rollup-observe-sample-status-invalid: invalid rollup observe sample status")
  end
  local first_clean = observed_at_ms(first_clean_observed_at_ms_value)
  local sampled = observed_at_ms(sampled_at_ms_value)
  if first_clean == nil or first_clean < 0 or sampled == nil or sampled < 0 then
    error("github-devloop-integration: rollup-observe-sample-timestamp-invalid: invalid rollup observe sample timestamps")
  end
  return "<!-- " .. observe_sample_marker_name
    .. ' head_sha="' .. tostring(head_sha)
    .. '" status="' .. tostring(status)
    .. '" first_clean_observed_at_ms="' .. tostring(first_clean)
    .. '" sampled_at_ms="' .. tostring(sampled)
    .. '" -->'
end

local function parse_observe_sample_marker(marker)
  local head_sha = tostring(marker or ""):match('head_sha="([^"]+)"')
  local status = tostring(marker or ""):match('status="([^"]+)"')
  local first_clean = observed_at_ms(tostring(marker or ""):match('first_clean_observed_at_ms="([^"]+)"'))
  local sampled = observed_at_ms(tostring(marker or ""):match('sampled_at_ms="([^"]+)"'))
  if not forge_validators.is_git_sha(head_sha) then
    return nil
  end
  if status ~= "clean" and status ~= "dirty" then
    return nil
  end
  if first_clean == nil or first_clean < 0 or sampled == nil or sampled < 0 then
    return nil
  end
  return {
    head_sha = head_sha,
    status = status,
    first_clean_observed_at_ms = first_clean,
    sampled_at_ms = sampled,
    observed_at_ms = sampled,
  }
end

function S.observe_samples(comments)
  local result = {}
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments or {})) do
    for marker in parsers_misc._comment_body(comment):gmatch(observe_sample_marker_pattern) do
      local sample = parse_observe_sample_marker(marker)
      if sample ~= nil then
        table.insert(result, sample)
      end
    end
  end
  table.sort(result, function(a, b)
    if a.sampled_at_ms == b.sampled_at_ms then
      return tostring(a.status) < tostring(b.status)
    end
    return a.sampled_at_ms < b.sampled_at_ms
  end)
  return result
end

local function latest_observe_sample(comments)
  local samples = S.observe_samples(comments)
  return samples[#samples]
end

function S.promotion_window_start_ms(comments, head_sha)
  local sample = latest_observe_sample(comments)
  if sample == nil or tostring(sample.head_sha) ~= tostring(head_sha) then
    return nil
  end
  return sample.first_clean_observed_at_ms
end

function S.observe_sample_comment_request(repo, pr_number, head_sha, verdict, observed_seconds, comments, source_ref)
  local status = type(verdict) == "table" and verdict.clean == true and "clean" or "dirty"
  local sampled_ms = math.floor((tonumber(observed_seconds) or now()) * 1000)
  local previous = latest_observe_sample(comments)
  local first_clean_ms = sampled_ms
  if status == "clean"
    and previous ~= nil
    and previous.status == "clean"
    and tostring(previous.head_sha) == tostring(head_sha)
    and tonumber(previous.first_clean_observed_at_ms) ~= nil
    and previous.first_clean_observed_at_ms <= sampled_ms then
    first_clean_ms = previous.first_clean_observed_at_ms
  end
  local marker = S.observe_sample_marker(head_sha, status, first_clean_ms, sampled_ms)
  local reason = type(verdict) == "table" and tostring(verdict.reason or status) or status
  local body = "github-devloop-integration rollup observe sample"
    .. "\n\n"
    .. "status=" .. status
    .. "\n"
    .. "reason=" .. error_facts.one_line(reason)
    .. "\n"
    .. "head_sha=" .. tostring(head_sha)
    .. "\n"
    .. "first_clean_observed_at_ms=" .. tostring(first_clean_ms)
    .. "\n"
    .. "sampled_at_ms=" .. tostring(sampled_ms)
    .. "\n\n"
    .. marker
  return devloop_entity.build_entity_comment_request({
    kind = "pr",
    repo = repo,
    number = pr_number,
  }, body, base_ids.dedup_key({
    "rollup-observe-sample",
    tostring(repo or ""),
    tostring(pr_number or ""),
  }), source_ref or devloop_entity.pr_source_ref(repo, pr_number), {
    replace_marker = observe_sample_replace_marker,
  })
end

function S.observe_soak_verdict(comments, head_sha, required_seconds, now_seconds)
  if not forge_validators.is_git_sha(head_sha) then
    return false, "runtime-soak-head-missing"
  end
  local now_ms = math.floor((tonumber(now_seconds) or now()) * 1000)
  local required_ms = math.floor((tonumber(required_seconds) or 0) * 1000)
  local sample = latest_observe_sample(comments)
  if sample == nil then
    return false, "runtime-soak-no-clean-sample"
  end
  if tostring(sample.head_sha) ~= tostring(head_sha) then
    return false, "runtime-soak-head-changed:marker_head=" .. tostring(sample.head_sha)
  end
  if sample.status ~= "clean" then
    return false, "runtime-soak-reset:dirty_sampled_at_ms=" .. tostring(sample.sampled_at_ms)
  end
  local age_ms = now_ms - sample.first_clean_observed_at_ms
  if age_ms < required_ms then
    return false,
      "runtime-soak-pending:age_seconds=" .. tostring(math.floor(age_ms / 1000))
        .. ":required_seconds=" .. tostring(math.floor(required_ms / 1000))
  end
  return true, "runtime-soak-ok", sample.first_clean_observed_at_ms
end

function S.observe_sample_marker_name()
  return observe_sample_marker_name
end

function S.observe_sample_replace_marker()
  return observe_sample_replace_marker
end

return S
