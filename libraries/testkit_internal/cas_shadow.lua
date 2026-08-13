local M = {}

-- Returns an observe_shadow bound to `catalog`. It swaps in a recording `resolve`, runs the
-- body, and restores the original on every path, so a failing body cannot leak a patched
-- catalog into later tests. Eleven CAS-parity suites each carried this by hand.
--
-- The catalog is injected rather than required: this library may depend only on contract,
-- workflow and forge, and the catalog lives in devloop.
function M.bind(catalog)
  return function(run)
    local captured = nil
    local original_resolve = catalog.resolve
    catalog.resolve = function(policy_id, evidence, candidate_projection)
      captured = evidence
      return original_resolve(policy_id, evidence, candidate_projection)
    end
    local ok, result = pcall(run)
    catalog.resolve = original_resolve
    if not ok then
      error(result, 0)
    end
    return result, captured
  end
end

return M
