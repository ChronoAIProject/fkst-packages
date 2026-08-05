local M = {}

function M.classify(candidate_result, base_probe)
  local candidate_kind = type(candidate_result) == "table" and candidate_result.kind or nil
  if candidate_kind == "PASS" then
    return "GREEN"
  end
  if candidate_kind ~= "SEMANTIC_FAIL" or type(base_probe) ~= "table" then
    return "INDETERMINATE"
  end

  local base_sha = tostring(base_probe.base_sha or "")
  if base_probe.status ~= "completed"
    or base_sha == ""
    or tostring(base_probe.head_readback or "") ~= base_sha
    or type(base_probe.result) ~= "table" then
    return "INDETERMINATE"
  end
  -- KNOWN v1 LIMITATION (three-point control deferred to a follow-up): OWN_LOCAL_RED
  -- conflates a genuine candidate regression with a "preparation red" -- a preflight
  -- failure introduced by substrate_pin.refresh's harness delta committed into the
  -- candidate worktree before Codex runs (see implement/main.lua). The probe runs the
  -- command on the *raw* base_sha, not the pre-Codex prepared tree, so a red caused
  -- purely by that harness delta is attributed to the candidate. This is a strict
  -- improvement over the prior behavior (which attributed *every* red to the candidate)
  -- and never regresses it; a pre-Codex "prepared" third control point that would split
  -- out PREPARATION_RED is left open for a follow-up change.
  if base_probe.result.kind == "PASS" then
    return "OWN_LOCAL_RED"
  end
  if base_probe.result.kind == "SEMANTIC_FAIL" then
    return "BASE_RED"
  end
  if base_probe.result.kind == "CONFIGURATION_FAIL" then
    return "BASE_CONFIGURATION_FAIL"
  end
  if base_probe.result.kind == "TOOLCHAIN_FAIL" then
    return "BASE_TOOLCHAIN_FAIL"
  end
  if base_probe.result.kind == "INFRASTRUCTURE_FAIL" then
    return "BASE_INFRASTRUCTURE_FAIL"
  end
  return "INDETERMINATE"
end

return M
