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
  if base_exit == 0 then
    return "OWN_LOCAL_RED"
  end
  return "BASE_RED"
end

return M
