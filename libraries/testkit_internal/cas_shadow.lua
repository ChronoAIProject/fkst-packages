local t = fkst.test

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

-- Returns a capture_raises bound to `devloop_logging`. It records every logged raise, restores
-- the original on every path, and re-raises a failing body unchanged. Four suites carried this.
--
-- Injected rather than required, for the same reason as bind above: this library may depend only
-- on contract, workflow and forge, and devloop_logging lives in devloop.
--
-- Note the name collision: testkit_internal.testing has its own capture_raises which patches the
-- global `raise` and returns (result, raised, err). This one patches devloop_logging.log_raise
-- and returns only the raises. They are different functions.
function M.bind_log_raise_capture(devloop_logging)
  return function(fn)
    local raised = {}
    local original = devloop_logging.log_raise
    devloop_logging.log_raise = function(_, _, queue, payload)
      table.insert(raised, { queue = queue, payload = payload })
    end
    local ok, err = pcall(fn)
    devloop_logging.log_raise = original
    if not ok then
      error(err)
    end
    return raised
  end
end

-- Returns a mock_repo() that stubs the FKST_GITHUB_REPO env read with `repo`. Seven suites
-- carried this. devloop_base is injected for the same reason as the binders above: this
-- library may depend only on contract, workflow and forge, and devloop.base lives in devloop.
function M.bind_mock_repo(devloop_base, repo)
  return function()
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
  end
end

return M
