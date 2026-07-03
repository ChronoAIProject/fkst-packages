local actions = require("core.materialize.actions")
local base_ids = require("devloop.base_ids")
local t = fkst.test

local repo = "owner/repo"
local origin = base_ids.proposal_id(repo, 42)

-- A valid materialization ledger entry (bounded digest strings + slot).
local function entry()
  return {
    blueprint_digest = "d-3588118930",
    slot = "implement",
    predecessor_ref_digest = "d-0000000000",
    gen_contract_digest = "d-2364386957",
    gen_spec_digest = "d-0975672535",
    child_dedup = "workflow/materialize/owner/repo/implement/d-0000000000",
  }
end

local function has(s, sub)
  return tostring(s):find(sub, 1, true) ~= nil
end

return {
  -- Regression: the materialization marker comment dedup_key must be
  -- DETERMINISTIC and derived from the slot/digests/state — not a Lua table
  -- address (tostring of the components table collapsed to "table: 0x...",
  -- which made replayed marker writes non-idempotent). Found by real dogfood.
  test_materialization_comment_dedup_deterministic_no_table_address = function()
    local e = entry()
    local spec = { title = "Implement the website feature", body = "Implement the requested page." }
    local r1 = actions.materialization_comment_request(repo, 1, origin, e, "generated", "", spec)
    local r2 = actions.materialization_comment_request(repo, 1, origin, e, "generated", "", spec)
    t.eq(r1.dedup_key, r2.dedup_key)
    t.is_true(not has(r1.dedup_key, "table"))
    t.is_true(not has(r1.dedup_key, "0x"))
  end,

  test_materialization_comment_dedup_varies_by_state = function()
    local e = entry()
    local spec = { title = "Implement the website feature", body = "Implement the requested page." }
    local generated = actions.materialization_comment_request(repo, 1, origin, e, "generated", "", spec)
    local created = actions.materialization_comment_request(repo, 1, origin, e, "created", "7", nil)
    t.is_true(generated.dedup_key ~= created.dedup_key)
    t.is_true(not has(created.dedup_key, "table"))
  end,

  test_terminal_comment_dedup_deterministic_no_table_address = function()
    local r1 = actions.terminal_request(repo, 1, origin, "done", "all-slots-merged")
    local r2 = actions.terminal_request(repo, 1, origin, "done", "all-slots-merged")
    t.eq(r1.dedup_key, r2.dedup_key)
    t.is_true(not has(r1.dedup_key, "table"))
    t.is_true(r1.dedup_key ~= actions.terminal_request(repo, 1, origin, "blocked", "child-fatal").dedup_key)
  end,
}
