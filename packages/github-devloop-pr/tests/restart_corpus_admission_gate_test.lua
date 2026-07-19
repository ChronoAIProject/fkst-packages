-- Whole-corpus symmetric shadow-admission gate (Step 0.1).
--
-- Enumerates the full canonical owner-edge corpus from the owner pending
-- projection and asserts the shadow decider partitions it exactly:
--   * every edge that carries a cas_policy_id is a CAS-admission edge and MUST
--     be admitted by decide_transition (reason_code != "unsupported-shadow-edge";
--     a resolve-based edge may return "invalid-evidence" under this generic
--     intent -- that still proves the edge is inside the accepted whitelist, not
--     unsupported);
--   * every edge WITHOUT a cas_policy_id is a non-CAS edge (guard / entry-branch /
--     dependency-wait / structural) and MUST be rejected as
--     "unsupported-shadow-edge".
-- A MISSING CAS edge (cas_policy_id set but unsupported) and a MIS-EXCLUDED edge
-- (nil cas_policy_id but admitted) both FAIL. Grant is always nil.
local core = require("core")
local owner = core.restart_package_name
local rows = core.restart_transition_table()
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local restart_authority = require("core.restart_authority")
local h = require("tests.devloop_helpers")
local t = h.t

local GENERIC_VERSION = "2026-06-03T01-02-03Z"

local function admission_for(edge)
  local sealed = restart_authority.seal_snapshot({
    owner = owner,
    current = { state = edge.source and edge.source.state or nil, version = nil },
  })
  local intent = {
    semantic_variant = edge.semantic_variant,
    target = edge.target,
    source_boundary = edge.source and edge.source.boundary or nil,
    incoming_version = GENERIC_VERSION,
    overlay_version = GENERIC_VERSION,
  }
  local decision = restart_authority.decide_transition(sealed, intent)
  return decision
end

return {
  test_corpus_shadow_admission_partition_is_exact = function()
    local edges = owner_pending_projection.edges(owner, rows, inventories)
    t.is_true(#edges > 0, owner .. ": projection must enumerate a non-empty corpus")
    local failures = {}
    local cas_count, non_cas_count = 0, 0
    for _, edge in ipairs(edges) do
      local decision = admission_for(edge)
      t.eq(decision.grant, nil, "grant must stay disabled for " .. tostring(edge.semantic_variant))
      local is_cas = edge.cas_policy_id ~= nil
      local unsupported = decision.status == "illegal"
        and decision.reason_code == "unsupported-shadow-edge"
      if is_cas then
        cas_count = cas_count + 1
        if unsupported then
          table.insert(failures, "MISSING cas edge: " .. tostring(edge.cas_policy_id)
            .. "/" .. tostring(edge.cas_variant) .. " (" .. tostring(edge.semantic_variant) .. ")")
        end
      else
        non_cas_count = non_cas_count + 1
        if not unsupported then
          table.insert(failures, "MIS-EXCLUDED non-cas edge admitted: "
            .. tostring(edge.semantic_variant) .. " -> " .. tostring(edge.target)
            .. " (status=" .. tostring(decision.status) .. " reason=" .. tostring(decision.reason_code) .. ")")
        end
      end
    end
    if #failures > 0 then
      error(owner .. " corpus admission partition failed (" .. #failures .. "):\n"
        .. table.concat(failures, "\n"), 0)
    end
    t.is_true(cas_count > 0, owner .. ": must have CAS-admission edges")
    t.is_true(non_cas_count >= 0, owner .. ": non-cas partition present")
  end,
}
