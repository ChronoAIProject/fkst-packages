local devloop_state = require("devloop.state")
local h = require("tests.devloop_helpers")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local result_facts = require("devloop.markers.result_facts")

local M = {}
local t = h.t
local core = h.core
local canonical_json = observation_support.canonical_json

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[copy(key)] = copy(item)
  end
  return out
end

local function sorted_unique(values)
  local seen = {}
  local out = {}
  for _, value in ipairs(values or {}) do
    local key = tostring(value)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = key
    end
  end
  table.sort(out)
  return out
end

local function semantic_identity(raised, index)
  local payload = raised.payload or {}
  local dedup_key = payload.dedup_key
  if dedup_key ~= nil and tostring(dedup_key) ~= "" then
    return tostring(raised.queue) .. "\0" .. tostring(dedup_key)
  end
  return tostring(raised.queue) .. "\0index=" .. tostring(index)
end

local function deduplicate(raises)
  local seen = {}
  local payload_by_identity = {}
  local out = {}
  for index, raised in ipairs(raises or {}) do
    local identity = semantic_identity(raised, index)
    local canonical_payload = canonical_json(raised.payload or {})
    if seen[identity] and payload_by_identity[identity] ~= canonical_payload then
      error("projection outcome conflicting duplicate identity: " .. identity)
    end
    if not seen[identity] then
      seen[identity] = true
      payload_by_identity[identity] = canonical_payload
      out[#out + 1] = raised
    end
  end
  return out
end

local function trusted_comment(id, body)
  return {
    id = id,
    body = body,
    author_login = core._test_bot_login,
    created_at = "2026-06-03T01:00:00Z",
  }
end

local function comment_written_payload(request, comment_id)
  return {
    schema = "github-proxy.comment-written.v1",
    repo = request.repo,
    target = "issue",
    issue_number = request.issue_number,
    comment_id = comment_id,
    request_dedup_key = request.dedup_key,
    dedup_key = tostring(request.dedup_key) .. "/written/" .. tostring(comment_id),
    source_ref = request.source_ref,
    handoff = request.handoff,
  }
end

function M.acknowledge(request, comment_id, name)
  return t.run_department("departments/comment_handoff/main.lua", {
    queue = "github-proxy.github_comment_written",
    payload = comment_written_payload(request, comment_id),
  }, h.opts(name))
end

local function collect_comments(raises, options, acked_ids)
  local comments = {}
  local request_comment_ids = {}
  local next_comment_id = 0
  for _, comment in ipairs(options.visible_comments or {}) do
    comments[#comments + 1] = copy(comment)
  end
  for _, raised in ipairs(deduplicate(raises)) do
    local payload = raised.payload or {}
    if raised.queue == "github-proxy.github_issue_comment_request" and type(payload.body) == "string" then
      local request_identity = tostring(payload.dedup_key or "")
      local comment_id = request_comment_ids[request_identity]
      if comment_id == nil then
        next_comment_id = next_comment_id + 1
        comment_id = tostring(options.comment_id_prefix or "IC_projection") .. "_" .. tostring(next_comment_id)
        request_comment_ids[request_identity] = comment_id
      end
      comments[#comments + 1] = trusted_comment(comment_id, payload.body)
      if type(payload.handoff) == "table" then
        acked_ids[comment_id] = true
      end
    end
  end
  return comments, request_comment_ids
end

local function run_handoffs(raises, options, request_comment_ids)
  local handoff_raises = {}
  local run_index = 0
  for _, raised in ipairs(raises or {}) do
    local payload = raised.payload or {}
    if raised.queue == "github-proxy.github_issue_comment_request" and type(payload.handoff) == "table" then
      run_index = run_index + 1
      local comment_id = request_comment_ids[tostring(payload.dedup_key or "")]
      local result = M.acknowledge(
        payload,
        comment_id,
        tostring(options.name or "projection-outcome-handoff") .. "-" .. tostring(run_index)
      )
      if result.exit_code ~= 0 then
        error("projection outcome handoff failed: " .. tostring(result.error or result.stderr))
      end
      for _, item in ipairs(result.raises or {}) do
        handoff_raises[#handoff_raises + 1] = item
      end
    end
  end
  return handoff_raises
end

local function collect_state_and_result_facts(comments, options)
  local state_seen = {}
  local result_seen = {}
  local states = {}
  local results = {}
  for _, comment in ipairs(comments) do
    local current = devloop_state.current_state({ comment }, options.proposal_id)
    if current.state ~= nil then
      local identity = table.concat({ tostring(current.state), tostring(current.version) }, "\0")
      if not state_seen[identity] then
        state_seen[identity] = true
        states[#states + 1] = {
          state = current.state,
          version = current.version,
          effects = current.effects,
          comment_id = comment.id,
        }
      end
    end
    if options.result_identity ~= nil then
      local fact = result_facts.first_result_fact(
        { comment },
        options.proposal_id,
        options.result_identity
      )
      if fact ~= nil then
        local identity = table.concat({ tostring(fact.decision), tostring(fact.logical_identity) }, "\0")
        if not result_seen[identity] then
          result_seen[identity] = true
          results[#results + 1] = fact
        end
      end
    end
  end
  return states, results
end

local function collect_labels(raises)
  local out = {}
  for _, raised in ipairs(raises) do
    local payload = raised.payload or {}
    if raised.queue == "github-proxy.github_issue_label_request" then
      out[#out + 1] = {
        dedup_key = payload.dedup_key,
        guarded = payload.require_marker_guard == true,
        proposal_id = payload.expected_proposal_id,
        state = payload.expected_state,
        version = payload.expected_version,
        target_kind = payload.target_kind,
        target_number = payload.target_number,
        add_labels = sorted_unique(payload.add_labels),
        remove_labels = sorted_unique(payload.remove_labels),
      }
    end
  end
  return out
end

local function collect_activations(raises)
  local out = {}
  for _, raised in ipairs(raises) do
    local payload = raised.payload or {}
    if raised.queue == "devloop_ready" then
      out[#out + 1] = {
        dedup_key = payload.dedup_key,
        proposal_id = payload.proposal_id,
        comment_id = payload.ready_hand_off and payload.ready_hand_off.comment_id or nil,
        marker_version = payload.ready_hand_off and payload.ready_hand_off.marker_version or nil,
      }
    end
  end
  return out
end

function M.collect(raises, options)
  local opts = options or {}
  local acked_comment_ids = {}
  local comments, request_comment_ids = collect_comments(raises, opts, acked_comment_ids)
  local handoff_raises = run_handoffs(raises, opts, request_comment_ids)
  local combined = {}
  for _, raised in ipairs(raises or {}) do combined[#combined + 1] = raised end
  for _, raised in ipairs(handoff_raises) do combined[#combined + 1] = raised end
  local normalized = deduplicate(combined)
  local visible_comment_ids = {}
  for _, comment in ipairs(opts.visible_comments or {}) do
    if comment.id ~= nil then visible_comment_ids[tostring(comment.id)] = true end
  end
  local state_facts, parsed_result_facts = collect_state_and_result_facts(comments, opts)
  return {
    state_facts = state_facts,
    result_facts = parsed_result_facts,
    label_projections = collect_labels(normalized),
    lifecycle_activations = collect_activations(normalized),
    normalized_raises = normalized,
    acked_comment_ids = acked_comment_ids,
    visible_comment_ids = visible_comment_ids,
  }
end

function M.activation_has_marker_evidence(outcome, activation)
  local comment_id = tostring(activation and activation.comment_id or "")
  return outcome.acked_comment_ids[comment_id] == true
    or outcome.visible_comment_ids[comment_id] == true
end

function M.copy(value)
  return copy(value)
end

function M.has_value(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then return true end
  end
  return false
end

function M.set_key(values)
  return table.concat(sorted_unique(values), "\0")
end

function M.semantic_json(outcome)
  return canonical_json({
    state_facts = outcome.state_facts,
    result_facts = outcome.result_facts,
    label_projections = outcome.label_projections,
    lifecycle_activations = outcome.lifecycle_activations,
  })
end

return M
