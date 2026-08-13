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

-- How many raises in a flat array target `queue`. Sibling of find, same argument shape.
-- Four suites carried this under two names, differing only in the loop variable.
-- Two other definitions take a result object rather than the array and are left alone.
function M.count(raises, queue)
  local count = 0
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      count = count + 1
    end
  end
  return count
end

return M
