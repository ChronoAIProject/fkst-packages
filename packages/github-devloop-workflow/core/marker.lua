local strings = require("contract.strings")
local source_refs = require("contract.source_ref")
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
M.MAX_SOURCE_REF_BYTES = 240

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

local BLUEPRINT_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:blueprint:v1.-%-%->"
local MATERIALIZATION_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:materialization:v1.-%-%->"
local TERMINAL_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:terminal:v1.-%-%->"
local HOLD_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:hold:v1.-%-%->"
local LABEL_PROJECTION_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:label%-projection:v1.-%-%->"
local LINEAGE_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:lineage:v1.-%-%->"
local TRANSFER_ACCEPT_MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:transfer%-accept:v1.-%-%->"

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
  local repo, issue_number = devloop_base.parse_issue_source_ref(value)
  if repo == nil or issue_number == nil then
    return false, fail(path, "invalid_issue_source_ref", "must be a canonical external issue source_ref")
  end
  local canonical_ref = tostring(repo) .. "#issue/" .. tostring(issue_number)
  local ok, err = validate_attr(value.kind, path .. ".kind", M.MAX_SOURCE_REF_BYTES)
  if not ok then return false, err end
  ok, err = validate_attr(canonical_ref, path .. ".ref", M.MAX_SOURCE_REF_BYTES)
  if not ok then return false, err end
  return true, nil, {
    kind = "external",
    ref = canonical_ref,
  }
end

local function validate_transfer_accept_identity(value)
  if type(value) ~= "table" then
    return false, fail("identity", "not_table", "must be a table")
  end
  local ok, err = validate_origin(value.origin, "origin")
  if not ok then return false, err end
  ok, err = validate_digest(value.blueprint_digest, "blueprint_digest")
  if not ok then return false, err end
  ok, err = validate_slot(value.slot, "slot")
  if not ok then return false, err end
  local predecessor
  ok, err, predecessor = validate_issue_source_ref(value.predecessor_source_ref, "predecessor_source_ref")
  if not ok then return false, err end
  local successor
  ok, err, successor = validate_issue_source_ref(value.successor_source_ref, "successor_source_ref")
  if not ok then return false, err end
  if source_refs.same(predecessor, successor) then
    return false, fail(
      "successor_source_ref",
      "same_as_predecessor",
      "must be distinct from predecessor_source_ref"
    )
  end
  return true, nil, {
    origin = value.origin,
    blueprint_digest = value.blueprint_digest,
    slot = value.slot,
    predecessor_source_ref = predecessor,
    successor_source_ref = successor,
  }
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

function M.build_hold_marker(origin_proposal_id, reason_code)
  local ok, err = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then return nil, err end
  ok, err = validate_reason_code(reason_code, "reason_code")
  if not ok then return nil, err end

  return '<!-- fkst:github-devloop-workflow:hold:v1 origin="' .. origin_proposal_id
    .. '" reason_code="' .. reason_code
    .. '" -->',
    nil
end

local function hold_fact_from_marker(found, origin_proposal_id)
  local origin = attr(found, "origin")
  local reason_code = attr(found, "reason_code")
  local ok = validate_origin(origin, "origin")
  if not ok then return nil end
  ok = validate_reason_code(reason_code, "reason_code")
  if not ok or origin ~= tostring(origin_proposal_id) then return nil end
  if M.build_hold_marker(origin, reason_code) ~= found then return nil end
  return {
    origin = origin,
    reason_code = reason_code,
  }
end

function M.parse_hold_marker(comment_body, origin_proposal_id)
  if type(comment_body) ~= "string" then
    return nil
  end
  local ok = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then
    return nil
  end

  local latest = nil
  for found in comment_body:gmatch(HOLD_MARKER_PATTERN) do
    if attr(found, "origin") == tostring(origin_proposal_id) then
      latest = found
    end
  end
  if latest == nil then
    return nil
  end
  return hold_fact_from_marker(latest, origin_proposal_id)
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

function M.build_transfer_accept_marker(value)
  local ok, err, identity = validate_transfer_accept_identity(value)
  if not ok then return nil, err end
  return '<!-- fkst:github-devloop-workflow:transfer-accept:v1 origin="' .. identity.origin
    .. '" blueprint_digest="' .. identity.blueprint_digest
    .. '" slot="' .. identity.slot
    .. '" predecessor_kind="' .. identity.predecessor_source_ref.kind
    .. '" predecessor_ref="' .. identity.predecessor_source_ref.ref
    .. '" successor_kind="' .. identity.successor_source_ref.kind
    .. '" successor_ref="' .. identity.successor_source_ref.ref
    .. '" -->',
    nil
end

local function transfer_accept_fact_from_marker(transfer_marker)
  local candidate = {
    origin = attr(transfer_marker, "origin"),
    blueprint_digest = attr(transfer_marker, "blueprint_digest"),
    slot = attr(transfer_marker, "slot"),
    predecessor_source_ref = {
      kind = attr(transfer_marker, "predecessor_kind"),
      ref = attr(transfer_marker, "predecessor_ref"),
    },
    successor_source_ref = {
      kind = attr(transfer_marker, "successor_kind"),
      ref = attr(transfer_marker, "successor_ref"),
    },
  }
  local ok, _, identity = validate_transfer_accept_identity(candidate)
  if not ok then
    return nil
  end
  return identity
end

function M.parse_transfer_accept_marker(text, expected)
  if type(text) ~= "string" then
    return nil
  end
  local ok, _, identity = validate_transfer_accept_identity(expected)
  if not ok then
    return nil
  end
  local matched = nil
  for transfer_marker in text:gmatch(TRANSFER_ACCEPT_MARKER_PATTERN) do
    local fact = transfer_accept_fact_from_marker(transfer_marker)
    if fact ~= nil
      and fact.origin == identity.origin
      and fact.blueprint_digest == identity.blueprint_digest
      and fact.slot == identity.slot
      and source_refs.same(fact.predecessor_source_ref, identity.predecessor_source_ref)
      and source_refs.same(fact.successor_source_ref, identity.successor_source_ref) then
      matched = fact
    end
  end
  return matched
end

function M.install(target)
  target.marker = M
end

return M
