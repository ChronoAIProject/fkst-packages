local materialization = require("core.materialization")
local discovery = require("core.materialize.discovery")

local M = {}

-- The origin facts a materialization plan is authorized by. Planning reads the
-- origin issue, derives these projections, runs the slot generator, and buffers its
-- effects; the commit re-reads the origin under the transition lock and republishes
-- only when every part below is still identical. A changed part means another actor
-- already advanced this origin, so the buffered plan is superseded and applying it
-- would duplicate work the fresh facts already record.
--
-- Labels and the label-projection generation are deliberately NOT part of currency.
-- Label projections are derived from these same trusted markers and are idempotent:
-- a stale label delta re-asserts marker truth rather than losing an update, so
-- including them would discard a minutes-long generator run for a no-op relabel.
-- An effect that genuinely IS authorized by labels does not rely on this token: it
-- registers its own commit guard and re-validates that authorization against the
-- fresh snapshot (see the irreversible done cleanup in materialize_reconcile).
local PARTS = { "state", "terminal", "blueprint", "materializations" }

local function sorted_join(values)
  table.sort(values)
  return table.concat(values, ",")
end

local function terminal_part(core, current, origin)
  local fact = discovery.latest_terminal(core, current, origin)
  if fact == nil then
    return "none"
  end
  return tostring(fact.state or "") .. "|" .. tostring(fact.reason_code or "")
end

local function blueprint_part(core, current, origin)
  local fact = discovery.latest_blueprint(core, current, origin)
  if fact == nil then
    return "none"
  end
  return tostring(fact.workflow or "") .. "|" .. tostring(fact.digest or "")
end

local function materializations_part(core, current, origin)
  local entries = {}
  for _, fact in ipairs(discovery.materialization_facts(core, current, origin)) do
    entries[#entries + 1] = tostring(materialization.fact_key(fact))
      .. "|" .. tostring(fact.state or "")
      .. "|" .. tostring(fact.child_issue or "")
  end
  return sorted_join(entries)
end

function M.origin_currency(core, current, origin)
  return {
    state = tostring(current and current.state or ""):upper(),
    terminal = terminal_part(core, current, origin),
    blueprint = blueprint_part(core, current, origin),
    materializations = materializations_part(core, current, origin),
  }
end

-- Returns nil when the plan is still current, otherwise the name of the first part
-- that moved, so the skip decision names the fact that superseded the plan.
function M.changed_part(planned, fresh)
  for _, part in ipairs(PARTS) do
    if tostring(planned and planned[part]) ~= tostring(fresh and fresh[part]) then
      return part
    end
  end
  return nil
end

return M
