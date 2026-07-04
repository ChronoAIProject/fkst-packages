local base_ids = require("devloop.base_ids")
local devloop_entity = require("devloop.entity")
local devloop_logging = require("devloop.logging")
local ledger_codec = require("core.materialize.ledger_codec")
local marker = require("core.marker")
local materialization = require("core.materialization")
local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")

local M = {}

M.DEPT = "workflow_materialize_next"

local function safe_source_ref(repo, issue_number)
  return devloop_entity.issue_source_ref(repo, issue_number)
end

local function attr(text, name)
  return tostring(text or ""):match(name .. '="([^"]*)"')
end

function M.source_ref_digest(source_ref)
  if type(source_ref) ~= "table" then
    return materialization.EMPTY_PREDECESSOR_REF_DIGEST
  end
  return "d-" .. strings.decimal_checksum(tostring(source_ref.kind or "") .. "\n" .. tostring(source_ref.ref or ""))
end

function M.predecessor_ref_digest(predecessor)
  if predecessor == nil then
    return materialization.EMPTY_PREDECESSOR_REF_DIGEST
  end
  -- The predecessor identity is the stable source_ref; result content is rehydrated by source_ref, not hashed into this CAS key component.
  return M.source_ref_digest(predecessor.source_ref)
end

function M.child_ref_for_entry(repo, entry)
  local issue_number = entry and entry.child_issue
  if issue_number == nil then
    return nil
  end
  return {
    kind = "issue",
    repo = repo,
    issue_number = tostring(issue_number),
    proposal_id = base_ids.proposal_id(repo, issue_number),
    source_ref = safe_source_ref(repo, issue_number),
  }
end

function M.ledger_for_frontier(repo, facts)
  local by_slot = marker.latest_materialization_by_slot(facts)
  for _, entry in pairs(by_slot) do
    if type(entry) == "table" and entry.state == "created" and entry.child_issue ~= nil then
      entry.child_ref = M.child_ref_for_entry(repo, entry)
      entry.child_proposal_id = entry.child_ref.proposal_id
      entry.child_source_ref = entry.child_ref.source_ref
    end
  end
  return by_slot
end

function M.find_step(plan, slot_id)
  for _, step in ipairs(plan and plan.steps or {}) do
    if tostring(step.id) == tostring(slot_id) then
      return step
    end
  end
  return nil
end

local function build_comment_request(repo, issue_number, origin, body, dedup_components)
  -- dedup_components is an array of deterministic string parts (slot, digests,
  -- state, ...). Spread them into the key so the dedup_key is deterministic;
  -- tostring()-ing the whole table would collapse it to a Lua address.
  local key_parts = { "workflow", "comment", tostring(origin) }
  for _, part in ipairs(dedup_components) do
    key_parts[#key_parts + 1] = tostring(part)
  end
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = tonumber(issue_number),
    body = body,
    dedup_key = base_ids.dedup_key(key_parts),
    source_ref = safe_source_ref(repo, issue_number),
  }
end

function M.materialization_marker_body(origin, entry, state, child_issue, generated_spec)
  local built, err = marker.build_materialization_marker(
    origin,
    entry.blueprint_digest,
    entry.slot,
    entry.predecessor_ref_digest,
    entry.gen_contract_digest,
    entry.gen_spec_digest,
    entry.child_dedup,
    child_issue,
    state
  )
  if built == nil then
    error("github-devloop-workflow: materialization-marker-build-failed: materialization marker build failed: " .. tostring(err and err.code or "unknown"))
  end
  if generated_spec ~= nil and state == "generated" then
    return built .. "\n" .. ledger_codec.encode_generated_spec(generated_spec)
  end
  return built
end

function M.terminal_request(repo, issue_number, origin, state, reason_code)
  local built, err = marker.build_terminal_marker(origin, state, reason_code)
  if built == nil then
    error("github-devloop-workflow: terminal-marker-build-failed: terminal marker build failed: " .. tostring(err and err.code or "unknown"))
  end
  return build_comment_request(repo, issue_number, origin, built, {
    "terminal",
    tostring(state),
    tostring(reason_code),
  })
end

function M.materialization_comment_request(repo, issue_number, origin, entry, state, child_issue, generated_spec)
  return build_comment_request(
    repo,
    issue_number,
    origin,
    M.materialization_marker_body(origin, entry, state, child_issue, generated_spec),
    {
      "materialization",
      tostring(entry.slot),
      tostring(entry.predecessor_ref_digest),
      tostring(entry.gen_spec_digest),
      tostring(state),
      tostring(child_issue or ""),
    }
  )
end

local function workflow_step_source_ref(repo, origin_issue_number, slot_id)
  return {
    kind = "external",
    ref = tostring(repo) .. "#workflow-step/" .. tostring(origin_issue_number) .. "/" .. tostring(slot_id),
  }
end

function M.issue_create_request(repo, issue_number, origin, blueprint_digest, slot_id, entry, generated_spec)
  local lineage, err = marker.build_lineage_header(origin, blueprint_digest, slot_id)
  if lineage == nil then
    error("github-devloop-workflow: lineage-marker-build-failed: lineage marker build failed: " .. tostring(err and err.code or "unknown"))
  end
  return {
    schema = "github-proxy.issue-create.v1",
    repo = repo,
    title = generated_spec.title,
    body = lineage .. "\n\n" .. generated_spec.body,
    dedup_key = entry.child_dedup,
    source_ref = workflow_step_source_ref(repo, issue_number, slot_id),
    parent = tonumber(issue_number),
    parent_comment_target = {
      repo = repo,
      issue_number = tonumber(issue_number),
    },
  }
end

function M.raise_request(proposal_id, queue, request)
  devloop_logging.log_raise(M.DEPT, proposal_id, queue, request)
end

function M.trusted_issue_created_number(core, current, child_dedup_key, trusted_comments)
  local pattern = "<!%-%- fkst:github%-proxy:issue%-created:v1.-%-%->"
  for _, comment in ipairs(trusted_comments(core, current and current.comments)) do
    for found in parsers_misc.comment_body(core, comment):gmatch(pattern) do
      if attr(found, "dedup") == tostring(child_dedup_key) then
        local issue = attr(found, "issue")
        if issue ~= nil and tostring(issue):match("^%d+$") and tonumber(issue) > 0 then
          return tostring(math.floor(tonumber(issue)))
        end
      end
    end
  end
  return nil
end

function M.generated_spec_for_fact(core, current, fact, trusted_comments)
  if fact == nil then
    return nil
  end
  for _, comment in ipairs(trusted_comments(core, current and current.comments)) do
    local body = parsers_misc.comment_body(core, comment)
    local parsed = marker.parse_materialization_marker(body, fact.origin, fact.slot)
    if parsed ~= nil
      and parsed.state == "generated"
      and parsed.blueprint_digest == fact.blueprint_digest
      and parsed.predecessor_ref_digest == fact.predecessor_ref_digest
      and parsed.gen_spec_digest == fact.gen_spec_digest
      and parsed.child_dedup == fact.child_dedup then
      local generated_spec = ledger_codec.decode_generated_spec_block(body)
      if generated_spec == nil then
        return nil
      end
      if materialization.generated_spec_digest(generated_spec) ~= fact.gen_spec_digest then
        return nil
      end
      return generated_spec
    end
  end
  return nil
end

function M.maybe_write_created_from_parent_ledger(core, repo, issue_number, origin, facts, current, trusted_comments, log_decision)
  -- A slot whose "created" ledger fact already exists must NOT be re-derived from
  -- its "generated" fact on every tick: the generated marker stays visible next to
  -- the created marker, so re-writing "created" and returning true here forever
  -- starves frontier advancement (compute_frontier is never reached, the next slot
  -- never materializes). Skip a generated fact once its slot already has a created
  -- fact. Found by real supervise dogfood 2026-07-03: a merged scaffold child never
  -- advanced to the implement slot because this returned true every 5m tick.
  local already_created = {}
  for _, fact in ipairs(facts or {}) do
    if fact.state == "created" and fact.child_dedup ~= nil then
      already_created[fact.child_dedup] = true
    end
  end
  for _, fact in ipairs(facts or {}) do
    if fact.state == "generated" and not already_created[fact.child_dedup] then
      local child_issue = M.trusted_issue_created_number(core, current, fact.child_dedup, trusted_comments)
      if child_issue ~= nil then
        local created_entry = {
          origin = fact.origin,
          blueprint_digest = fact.blueprint_digest,
          slot = fact.slot,
          predecessor_ref_digest = fact.predecessor_ref_digest,
          gen_contract_digest = fact.gen_contract_digest,
          gen_spec_digest = fact.gen_spec_digest,
          child_dedup = fact.child_dedup,
        }
        log_decision(origin, "materialization", "created", "applied(parent-ledger-created)", "trusted github-proxy issue-created marker is visible")
        M.raise_request(
          origin,
          "github-proxy.github_issue_comment_request",
          M.materialization_comment_request(repo, issue_number, origin, created_entry, "created", child_issue, nil)
        )
        return true
      end
    end
  end
  return false
end

function M.create_from_generated(core, repo, issue_number, origin, blueprint_digest, slot_id, fact, current, trusted_comments, log_decision)
  local child_issue = M.trusted_issue_created_number(core, current, fact.child_dedup, trusted_comments)
  if child_issue ~= nil then
    return M.maybe_write_created_from_parent_ledger(core, repo, issue_number, origin, { fact }, current, trusted_comments, log_decision)
  end
  local generated_spec = M.generated_spec_for_fact(core, current, fact, trusted_comments)
  if generated_spec == nil then
    return nil, "generated-spec-missing"
  end
  local entry = {
    origin = fact.origin,
    blueprint_digest = fact.blueprint_digest,
    slot = fact.slot,
    predecessor_ref_digest = fact.predecessor_ref_digest,
    gen_contract_digest = fact.gen_contract_digest,
    gen_spec_digest = fact.gen_spec_digest,
    child_dedup = fact.child_dedup,
  }
  log_decision(origin, "materialization", "create", "applied(proceed-create)", "generated spec is latched and no child ledger is visible")
  M.raise_request(
    origin,
    "github-proxy.github_issue_create_request",
    M.issue_create_request(repo, issue_number, origin, blueprint_digest, slot_id, entry, generated_spec)
  )
  return true, nil
end

function M.facts_for_key(facts, key)
  local matched = {}
  for _, fact in ipairs(facts or {}) do
    if materialization.fact_key(fact) == key then
      matched[#matched + 1] = fact
    end
  end
  return matched
end

function M.best_fact_for_key(facts, key)
  local best = nil
  local best_rank = -1
  for _, fact in ipairs(M.facts_for_key(facts, key)) do
    local rank = marker.MATERIALIZATION_STATE_RANK[fact.state] or 0
    if best == nil or rank >= best_rank then
      best = fact
      best_rank = rank
    end
  end
  return best
end

return M
