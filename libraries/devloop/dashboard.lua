local M = {}

M.title = "fkst-dev board"
M.label = "fkst-dashboard"
M.marker_prefix = "<!-- fkst:dashboard:v1"

function M.marker(hash, generated_at)
  return M.marker_prefix
    .. ' version="' .. tostring(generated_at or "")
    .. '" hash="' .. tostring(hash or "")
    .. '" generated_at="' .. tostring(generated_at or "")
    .. '" -->'
end

function M.is_anchor_body(body)
  return tostring(body or ""):find(M.marker_prefix, 1, true) ~= nil
end

return M
