local M = {}

function M.classify(candidate_exit, base_probe)
  local candidate = tonumber(candidate_exit)
  if candidate == 0 then
    return "GREEN"
  end
  if candidate == nil or type(base_probe) ~= "table" then
    return "INDETERMINATE"
  end

  local base_exit = tonumber(base_probe.exit)
  local base_sha = tostring(base_probe.base_sha or "")
  if base_probe.status ~= "completed"
    or base_exit == nil
    or base_sha == ""
    or tostring(base_probe.head_readback or "") ~= base_sha then
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
  if base_exit == 0 then
    return "OWN_LOCAL_RED"
  end
  return "BASE_RED"
end

return M
