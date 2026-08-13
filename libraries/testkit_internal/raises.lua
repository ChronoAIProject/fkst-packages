local M = {}

-- The first raise on `queue` in a flat raises array, as returned by run_department.
-- Deliberately named `find` rather than `find_raise`: testkit.graph.find_raise already
-- exists and walks a multi-step trace (trace.steps -> step.raises), which is a different
-- structure. Eight suites each carried this flat-array version by hand.
function M.find(raises, queue)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      return raised
    end
  end
  return nil
end

return M
