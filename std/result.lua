local S = {}

function S.require_success(result, error_prefix, error_class)
  if result.exit_code ~= 0 then
    error(tostring(error_prefix or "") .. tostring(error_class) .. " failed: " .. tostring(result.stderr))
  end
  return result
end

return S
