local h = require("tests.devloop_helpers")
local t = h.t
local replayer = require("core.awaiting_pr_replayer")

-- `fetch_then_scan_rollup_receipts` is the batch: it walks every candidate and asks the callback for
-- that candidate's receipt head. A per-candidate external failure must stay inside its own
-- iteration. Raising out of the callback escapes the scan and fails the whole `observe_issue` pass,
-- which is how one row's momentary git failure froze every other row for eleven hours.
return {
  test_one_candidate_failing_does_not_stop_the_scan = function()
    local visited = {}
    local landed = replayer.fetch_then_scan_rollup_receipts(
      { { number = 1 }, { number = 2 }, { number = 3 } },
      function(candidate)
        table.insert(visited, candidate.number)
        if candidate.number == 1 then
          return nil -- unverifiable this pass, exactly as an unfetchable head now resolves
        end
        return "head" .. tostring(candidate.number)
      end,
      function(receipt_head) return receipt_head == "head3" end)
    t.is_true(landed)
    t.eq(#visited, 3)
    t.eq(visited[1], 1)
    t.eq(visited[3], 3)
  end,

  -- The isolated outcome must remain non-terminal: no receipt found means "not landed", which the
  -- caller renders as `skip-pending(rollup-receipt-missing)` and re-derives next tick.
  test_all_candidates_unverifiable_is_not_landed_and_not_an_error = function()
    local ok, landed = pcall(replayer.fetch_then_scan_rollup_receipts,
      { { number = 1 }, { number = 2 } },
      function() return nil end,
      function() return true end)
    t.is_true(ok)
    t.is_true(not landed)
  end,

  -- The other half, so this cannot degrade into "nothing ever fails": a candidate that DOES yield a
  -- head still gets its ancestry checked, and a genuine mismatch still returns not-landed.
  test_a_fetched_head_is_still_checked_for_ancestry = function()
    local checked = {}
    local landed = replayer.fetch_then_scan_rollup_receipts(
      { { number = 7 } },
      function(candidate) return "head" .. tostring(candidate.number) end,
      function(receipt_head) table.insert(checked, receipt_head); return false end)
    t.is_true(not landed)
    t.eq(#checked, 1)
    t.eq(checked[1], "head7")
  end,

  test_a_matching_head_still_lands = function()
    t.is_true(replayer.fetch_then_scan_rollup_receipts(
      { { number = 9 } },
      function() return "head9" end,
      function(receipt_head) return receipt_head == "head9" end))
  end,
}
