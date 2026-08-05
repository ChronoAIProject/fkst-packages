local strings = require("contract.strings")
local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local fail = require("core.errors").fail

local M = {}

M.MAX_ORIGIN_PROPOSAL_ID_BYTES = 200
M.MAX_WORKFLOW_ID_BYTES = 128
M.MAX_PLAN_DIGEST_BYTES = 64
M.MAX_SLOT_ID_BYTES = 128
M.MAX_MATERIALIZATION_DIGEST_BYTES = M.MAX_PLAN_DIGEST_BYTES
M.MAX_CHILD_DEDUP_KEY_BYTES = 512
M.MAX_CHILD_ISSUE_BYTES = 30
M.MAX_TERMINAL_REASON_CODE_BYTES = 128
M.MAX_LABEL_PROJECTION_GENERATION = 2147483647

M.MATERIALIZATION_STATES = {
  pending = true,
  generated = true,
  created = true,
}

M.MATERIALIZATION_STATE_RANK = {
  pending = 1,
  generated = 2,
  created = 3,
}

M.TERMINAL_STATES = {
  done = true,
  blocked = true,
  error = true,
}

M.LABEL_PROJECTION_STATES = {
  thinking = true,
  blocked = true,
}

M.CHILD_DISPOSITIONS = {
  satisfied = true,
  transferred = true,
  undeliverable = true,
}

local BLUEPRINT_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:blueprint:v1.-%-%->"
local MATERIALIZATION_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:materialization:v1.-%-%->"
local TERMINAL_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:terminal:v1.-%-%->"
local LABEL_PROJECTION_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:label%-projection:v1.-%-%->"
local LINEAGE_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:lineage:v1.-%-%->"
local CHILD_DISPOSITION_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:child%-disposition:v1.-%-%->"

local function attr(marker, name)
  return marker:match(name .. '="([^"]*)"')
end

local function validate_attr(value, path, limit)
  if type(value) ~= "string" then
    return false, fail(path, "not_string", "must be a string")
  end
  if value == "" then
    return false, fail(path, "empty", "must not be empty")
  end
  if #value > limit then
    return false, fail(path, "too_large", "exceeds byte limit", {
      max_bytes = limit,
      actual_bytes = #value,
    })
  end
  if value:find("%c") ~= nil or value:find('"', 1, true) ~= nil or value:find("[<>]") ~= nil then
    return false, fail(path, "invalid_marker_attr", "must be safe for a marker attribute")
  end
  if not strings.is_path_safe_key(value, limit) then
    return false, fail(path, "invalid_key", "must be a safe bounded key")
  end
  return true, nil
end

local function validate_origin(value, path)
  return validate_attr(value, path, M.MAX_ORIGIN_PROPOSAL_ID_BYTES)
end

local function validate_workflow(value, path)
  return validate_attr(value, path, M.MAX_WORKFLOW_ID_BYTES)
end

local function validate_digest(value, path)
  return validate_attr(value, path, M.MAX_PLAN_DIGEST_BYTES)
end

local function validate_slot(value, path)
  return validate_attr(value, path, M.MAX_SLOT_ID_BYTES)
end

local function validate_materialization_digest(value, path)
  return validate_attr(value, path, M.MAX_MATERIALIZATION_DIGEST_BYTES)
end

local function validate_child_dedup(value, path)
  return validate_attr(value, path, M.MAX_CHILD_DEDUP_KEY_BYTES)
end

local function validate_child_issue(value, path)
  if value == nil or value == "" then
    return true, nil, ""
  end
  if type(value) ~= "string" then
    return false, fail(path, "not_string", "must be a string")
  end
  if #value > M.MAX_CHILD_ISSUE_BYTES then
    return false, fail(path, "too_large", "exceeds byte limit", {
      max_bytes = M.MAX_CHILD_ISSUE_BYTES,
      actual_bytes = #value,
    })
  end
  if value:find("%c") ~= nil or value:find('"', 1, true) ~= nil or value:find("[<>]") ~= nil then
    return false, fail(path, "invalid_marker_attr", "must be safe for a marker attribute")
  end
  if value:match("^%d+$") == nil then
    return false, fail(path, "invalid_issue_number", "must be a numeric issue string")
  end
  return true, nil, value
end

local function validate_member(value, path, allowed, code)
  if type(value) ~= "string" then
    return false, fail(path, "not_string", "must be a string")
  end
  if allowed[value] ~= true then
    return false, fail(path, code, "is not an allowed value")
  end
  return true, nil
end

local function validate_materialization_state(value, path)
  return validate_member(value, path, M.MATERIALIZATION_STATES, "invalid_materialization_state")
end

local function validate_terminal_state(value, path)
  return validate_member(value, path, M.TERMINAL_STATES, "invalid_terminal_state")
end

local function validate_projection_state(value, path)
  return validate_member(value, path, M.LABEL_PROJECTION_STATES, "invalid_projection_state")
end

local function validate_projection_generation(value, path)
  local generation = tonumber(value)
  if generation == nil
    or generation < 1
    or generation ~= math.floor(generation)
    or generation > M.MAX_LABEL_PROJECTION_GENERATION
    or (type(value) == "string" and tostring(generation) ~= value) then
    return false, fail(path, "invalid_generation", "must be a canonical positive integer")
  end
  return true, nil, generation
end

local function validate_reason_code(value, path)
  return validate_attr(value, path, M.MAX_TERMINAL_REASON_CODE_BYTES)
end

local function validate_issue_source_ref(value, path)
  if type(value) ~= "table" then
    return false, fail(path, "not_source_ref", "must be an issue source_ref")
  end
  local repo, issue_number = devloop_base.parse_issue_source_ref(value)
  if repo == nil or issue_number == nil then
    return false, fail(path, "invalid_issue_source_ref", "must round-trip as an external issue source_ref")
  end
  return true, nil, {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
end

local function validate_child_disposition_fields(fields)
  if type(fields) ~= "table" then
    return nil, fail("fields", "not_table", "must be a table")
  end
  local ok, err = validate_origin(fields.origin, "origin")
  if not ok then return nil, err end
  ok, err = validate_digest(fields.blueprint_digest, "blueprint_digest")
  if not ok then return nil, err end
  ok, err = validate_slot(fields.slot, "slot")
  if not ok then return nil, err end
  local child_issue
  ok, err, child_issue = validate_child_issue(fields.child_issue, "child_issue")
  if not ok then return nil, err end
  if child_issue == "" then
    return nil, fail("child_issue", "empty", "must not be empty")
  end
  ok, err = validate_member(
    fields.disposition,
    "disposition",
    M.CHILD_DISPOSITIONS,
    "invalid_child_disposition"
  )
  if not ok then return nil, err end

  local successor_source_ref = fields.successor_source_ref
  if fields.disposition == "transferred" then
    if successor_source_ref == nil then
      return nil, fail("successor_source_ref", "required_for_transfer", "is required for transferred")
    end
    ok, err, successor_source_ref = validate_issue_source_ref(successor_source_ref, "successor_source_ref")
    if not ok then return nil, err end
  elseif successor_source_ref ~= nil then
    return nil, fail("successor_source_ref", "forbidden_for_disposition", "is only allowed for transferred")
  end

  local reason_code = fields.reason_code
  if fields.disposition == "undeliverable" then
    if reason_code == nil or reason_code == "" then
      return nil, fail("reason_code", "required_for_undeliverable", "is required for undeliverable")
    end
    ok, err = validate_reason_code(reason_code, "reason_code")
    if not ok then return nil, err end
  elseif reason_code ~= nil then
    return nil, fail("reason_code", "forbidden_for_disposition", "is only allowed for undeliverable")
  end

  local dedup_key = base_ids.dedup_key({
    "workflow",
    "child-disposition",
    fields.origin,
    fields.blueprint_digest,
    fields.slot,
    child_issue,
  })
  if fields.dedup_key ~= nil and fields.dedup_key ~= dedup_key then
    return nil, fail("dedup_key", "disposition_identity_mismatch", "must match the workflow slot receipt identity")
  end

  return {
    origin = fields.origin,
    blueprint_digest = fields.blueprint_digest,
    slot = fields.slot,
    child_issue = child_issue,
    disposition = fields.disposition,
    successor_source_ref = successor_source_ref,
    reason_code = reason_code,
    dedup_key = dedup_key,
  }, nil
end

function M.build_blueprint_marker(origin_proposal_id, workflow_id, plan_digest)
  local ok, err = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then return nil, err end
  ok, err = validate_workflow(workflow_id, "workflow_id")
  if not ok then return nil, err end
  ok, err = validate_digest(plan_digest, "plan_digest")
  if not ok then return nil, err end

  return '<!-- fkst:github-devloop-workflow:blueprint:v1 origin="' .. origin_proposal_id
    .. '" workflow="' .. workflow_id
    .. '" digest="' .. plan_digest
    .. '" -->',
    nil
end

local function fact_from_marker(marker, origin_proposal_id)
  local origin = attr(marker, "origin")
  local workflow = attr(marker, "workflow")
  local digest = attr(marker, "digest")
  local ok = validate_origin(origin, "origin")
  if not ok then return nil end
  ok = validate_workflow(workflow, "workflow")
  if not ok then return nil end
  ok = validate_digest(digest, "digest")
  if not ok then return nil end
  if origin ~= tostring(origin_proposal_id) then
    return nil
  end
  return {
    origin = origin,
    workflow = workflow,
    digest = digest,
  }
end

function M.parse_blueprint_marker(comment_body, origin_proposal_id)
  if type(comment_body) ~= "string" then
    return nil
  end
  local ok = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then
    return nil
  end

  -- Caller owns bot-author trust filtering; this parser only inspects one body string.
  local latest_marker = nil
  for marker in comment_body:gmatch(BLUEPRINT_MARKER_PATTERN) do
    if attr(marker, "origin") == tostring(origin_proposal_id) then
      latest_marker = marker
    end
  end
  if latest_marker == nil then
    return nil
  end
  return fact_from_marker(latest_marker, origin_proposal_id)
end

function M.build_materialization_marker(
  origin_proposal_id,
  blueprint_digest,
  slot_id,
  predecessor_ref_digest,
  generator_contract_digest,
  generated_spec_digest,
  child_dedup_key,
  child_issue,
  state
)
  local ok, err = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then return nil, err end
  ok, err = validate_materialization_digest(blueprint_digest, "blueprint_digest")
  if not ok then return nil, err end
  ok, err = validate_slot(slot_id, "slot_id")
  if not ok then return nil, err end
  ok, err = validate_materialization_digest(predecessor_ref_digest, "predecessor_ref_digest")
  if not ok then return nil, err end
  ok, err = validate_materialization_digest(generator_contract_digest, "generator_contract_digest")
  if not ok then return nil, err end
  ok, err = validate_materialization_digest(generated_spec_digest, "generated_spec_digest")
  if not ok then return nil, err end
  ok, err = validate_child_dedup(child_dedup_key, "child_dedup_key")
  if not ok then return nil, err end
  local child_issue_attr
  ok, err, child_issue_attr = validate_child_issue(child_issue, "child_issue")
  if not ok then return nil, err end
  ok, err = validate_materialization_state(state, "state")
  if not ok then return nil, err end

  return '<!-- fkst:github-devloop-workflow:materialization:v1 origin="' .. origin_proposal_id
    .. '" blueprint_digest="' .. blueprint_digest
    .. '" slot="' .. slot_id
    .. '" predecessor_ref_digest="' .. predecessor_ref_digest
    .. '" gen_contract_digest="' .. generator_contract_digest
    .. '" gen_spec_digest="' .. generated_spec_digest
    .. '" child_dedup="' .. child_dedup_key
    .. '" child_issue="' .. child_issue_attr
    .. '" state="' .. state
    .. '" -->',
    nil
end

local function materialization_fact_from_marker(marker, origin_proposal_id, slot_id)
  local origin = attr(marker, "origin")
  local blueprint_digest = attr(marker, "blueprint_digest")
  local slot = attr(marker, "slot")
  local predecessor_ref_digest = attr(marker, "predecessor_ref_digest")
  local gen_contract_digest = attr(marker, "gen_contract_digest")
  local gen_spec_digest = attr(marker, "gen_spec_digest")
  local child_dedup = attr(marker, "child_dedup")
  local child_issue = attr(marker, "child_issue")
  local state = attr(marker, "state")

  local ok = validate_origin(origin, "origin")
  if not ok then return nil end
  ok = validate_materialization_digest(blueprint_digest, "blueprint_digest")
  if not ok then return nil end
  ok = validate_slot(slot, "slot")
  if not ok then return nil end
  ok = validate_materialization_digest(predecessor_ref_digest, "predecessor_ref_digest")
  if not ok then return nil end
  ok = validate_materialization_digest(gen_contract_digest, "gen_contract_digest")
  if not ok then return nil end
  ok = validate_materialization_digest(gen_spec_digest, "gen_spec_digest")
  if not ok then return nil end
  ok = validate_child_dedup(child_dedup, "child_dedup")
  if not ok then return nil end
  ok = validate_child_issue(child_issue, "child_issue")
  if not ok then return nil end
  ok = validate_materialization_state(state, "state")
  if not ok then return nil end
  if origin ~= tostring(origin_proposal_id) then
    return nil
  end
  if slot_id ~= nil and slot ~= tostring(slot_id) then
    return nil
  end

  return {
    origin = origin,
    blueprint_digest = blueprint_digest,
    slot = slot,
    predecessor_ref_digest = predecessor_ref_digest,
    gen_contract_digest = gen_contract_digest,
    gen_spec_digest = gen_spec_digest,
    child_dedup = child_dedup,
    child_issue = child_issue ~= "" and child_issue or nil,
    state = state,
  }
end

function M.parse_materialization_marker(comment_body, origin_proposal_id, slot_id)
  if type(comment_body) ~= "string" then
    return nil
  end
  local ok = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then
    return nil
  end
  ok = validate_slot(slot_id, "slot_id")
  if not ok then
    return nil
  end

  -- Caller owns bot-author trust filtering; this parser only inspects one body string.
  local latest_marker = nil
  for marker in comment_body:gmatch(MATERIALIZATION_MARKER_PATTERN) do
    if attr(marker, "origin") == tostring(origin_proposal_id) and attr(marker, "slot") == tostring(slot_id) then
      latest_marker = marker
    end
  end
  if latest_marker == nil then
    return nil
  end
  return materialization_fact_from_marker(latest_marker, origin_proposal_id, slot_id)
end

function M.parse_materialization_markers(comment_body, origin_proposal_id)
  local facts = {}
  if type(comment_body) ~= "string" then
    return facts
  end
  local ok = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then
    return facts
  end
  for marker in comment_body:gmatch(MATERIALIZATION_MARKER_PATTERN) do
    local fact = materialization_fact_from_marker(marker, origin_proposal_id, nil)
    if fact ~= nil then
      table.insert(facts, fact)
    end
  end
  return facts
end

function M.latest_materialization_by_slot(facts)
  local by_slot = {}
  for _, fact in ipairs(facts or {}) do
    if type(fact) == "table" and type(fact.slot) == "string" and type(fact.state) == "string" then
      local rank = M.MATERIALIZATION_STATE_RANK[fact.state]
      if rank ~= nil then
        local current = by_slot[fact.slot]
        local current_rank = current ~= nil and M.MATERIALIZATION_STATE_RANK[current.state] or nil
        -- State is monotonic pending -> generated -> created; highest rank wins, and
        -- repeated same-state records use latest stream order for replay freshness.
        if current == nil or current_rank == nil or rank >= current_rank then
          by_slot[fact.slot] = fact
        end
      end
    end
  end
  return by_slot
end

function M.build_terminal_marker(origin_proposal_id, terminal_state, reason_code)
  local ok, err = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then return nil, err end
  ok, err = validate_terminal_state(terminal_state, "terminal_state")
  if not ok then return nil, err end
  ok, err = validate_reason_code(reason_code, "reason_code")
  if not ok then return nil, err end

  local monotonic = terminal_state == "blocked" and "false" or "true"
  return '<!-- fkst:github-devloop-workflow:terminal:v1 origin="' .. origin_proposal_id
    .. '" state="' .. terminal_state
    .. '" reason_code="' .. reason_code
    .. '" monotonic="' .. monotonic
    .. '" -->',
    nil
end

local function terminal_fact_from_marker(marker, origin_proposal_id)
  local origin = attr(marker, "origin")
  local state = attr(marker, "state")
  local reason_code = attr(marker, "reason_code")
  local ok = validate_origin(origin, "origin")
  if not ok then return nil end
  ok = validate_terminal_state(state, "state")
  if not ok then return nil end
  ok = validate_reason_code(reason_code, "reason_code")
  if not ok then return nil end
  if origin ~= tostring(origin_proposal_id) then
    return nil
  end
  return {
    origin = origin,
    state = state,
    reason_code = reason_code,
  }
end

function M.parse_terminal_marker(comment_body, origin_proposal_id)
  if type(comment_body) ~= "string" then
    return nil
  end
  local ok = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then
    return nil
  end

  -- Caller owns bot-author trust filtering; this parser only inspects one body string.
  local latest_marker = nil
  for marker in comment_body:gmatch(TERMINAL_MARKER_PATTERN) do
    if attr(marker, "origin") == tostring(origin_proposal_id) then
      latest_marker = marker
    end
  end
  if latest_marker == nil then
    return nil
  end
  return terminal_fact_from_marker(latest_marker, origin_proposal_id)
end

function M.build_label_projection_marker(origin_proposal_id, projection_state, generation)
  local ok, err = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then return nil, err end
  ok, err = validate_projection_state(projection_state, "projection_state")
  if not ok then return nil, err end
  local parsed_generation
  ok, err, parsed_generation = validate_projection_generation(generation, "generation")
  if not ok then return nil, err end

  return '<!-- fkst:github-devloop-workflow:label-projection:v1 origin="' .. origin_proposal_id
    .. '" state="' .. projection_state
    .. '" generation="' .. tostring(parsed_generation)
    .. '" -->',
    nil
end

local function label_projection_fact_from_marker(projection_marker, origin_proposal_id)
  local origin = attr(projection_marker, "origin")
  local state = attr(projection_marker, "state")
  local generation = attr(projection_marker, "generation")
  local ok = validate_origin(origin, "origin")
  if not ok then return nil end
  ok = validate_projection_state(state, "state")
  if not ok then return nil end
  local parsed_generation
  ok, _, parsed_generation = validate_projection_generation(generation, "generation")
  if not ok or origin ~= tostring(origin_proposal_id) then
    return nil
  end
  return {
    origin = origin,
    state = state,
    generation = parsed_generation,
  }
end

function M.parse_label_projection_marker(comment_body, origin_proposal_id)
  if type(comment_body) ~= "string" then
    return nil
  end
  local ok = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then
    return nil
  end

  local latest_marker = nil
  for projection_marker in comment_body:gmatch(LABEL_PROJECTION_MARKER_PATTERN) do
    if attr(projection_marker, "origin") == tostring(origin_proposal_id) then
      latest_marker = projection_marker
    end
  end
  if latest_marker == nil then
    return nil
  end
  return label_projection_fact_from_marker(latest_marker, origin_proposal_id)
end

function M.build_lineage_header(origin_proposal_id, blueprint_digest, slot_id)
  local ok, err = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then return nil, err end
  ok, err = validate_digest(blueprint_digest, "blueprint_digest")
  if not ok then return nil, err end
  ok, err = validate_slot(slot_id, "slot_id")
  if not ok then return nil, err end

  return '<!-- fkst:github-devloop-workflow:lineage:v1 origin="' .. origin_proposal_id
    .. '" blueprint_digest="' .. blueprint_digest
    .. '" slot="' .. slot_id
    .. '" -->',
    nil
end

local function lineage_fact_from_marker(marker)
  local origin = attr(marker, "origin")
  local blueprint_digest = attr(marker, "blueprint_digest")
  local slot = attr(marker, "slot")
  local ok = validate_origin(origin, "origin")
  if not ok then return nil end
  ok = validate_digest(blueprint_digest, "blueprint_digest")
  if not ok then return nil end
  ok = validate_slot(slot, "slot")
  if not ok then return nil end
  return {
    origin = origin,
    blueprint_digest = blueprint_digest,
    slot = slot,
  }
end

function M.parse_lineage_header(text)
  if type(text) ~= "string" then
    return nil
  end
  for marker in text:gmatch(LINEAGE_MARKER_PATTERN) do
    return lineage_fact_from_marker(marker)
  end
  return nil
end

function M.build_child_disposition_marker(fields)
  local fact, err = validate_child_disposition_fields(fields)
  if fact == nil then return nil, err end
  local successor = fact.successor_source_ref or {}
  return '<!-- fkst:github-devloop-workflow:child-disposition:v1 origin="' .. fact.origin
    .. '" blueprint_digest="' .. fact.blueprint_digest
    .. '" slot="' .. fact.slot
    .. '" child_issue="' .. fact.child_issue
    .. '" dedup="' .. fact.dedup_key
    .. '" disposition="' .. fact.disposition
    .. '" successor_kind="' .. tostring(successor.kind or "")
    .. '" successor_ref="' .. tostring(successor.ref or "")
    .. '" reason_code="' .. tostring(fact.reason_code or "")
    .. '" -->',
    nil
end

local function child_disposition_fact_from_marker(disposition_marker)
  local dedup_key = attr(disposition_marker, "dedup")
  if dedup_key == nil or dedup_key == "" then
    return nil
  end
  local successor_kind = attr(disposition_marker, "successor_kind")
  local successor_ref = attr(disposition_marker, "successor_ref")
  local reason_code = attr(disposition_marker, "reason_code")
  local fields = {
    origin = attr(disposition_marker, "origin"),
    blueprint_digest = attr(disposition_marker, "blueprint_digest"),
    slot = attr(disposition_marker, "slot"),
    child_issue = attr(disposition_marker, "child_issue"),
    dedup_key = dedup_key,
    disposition = attr(disposition_marker, "disposition"),
    successor_source_ref = (successor_kind ~= "" or successor_ref ~= "") and {
      kind = successor_kind,
      ref = successor_ref,
    } or nil,
    reason_code = reason_code ~= "" and reason_code or nil,
  }
  return validate_child_disposition_fields(fields)
end

function M.parse_child_disposition_marker(text, origin, blueprint_digest, slot, child_issue)
  if type(text) ~= "string" then
    return nil
  end
  for disposition_marker in text:gmatch(CHILD_DISPOSITION_MARKER_PATTERN) do
    local fact = child_disposition_fact_from_marker(disposition_marker)
    if fact ~= nil
      and fact.origin == tostring(origin)
      and fact.blueprint_digest == tostring(blueprint_digest)
      and fact.slot == tostring(slot)
      and fact.child_issue == tostring(child_issue) then
      return fact
    end
  end
  return nil
end

function M.install(target)
  target.marker = M
end

return M
