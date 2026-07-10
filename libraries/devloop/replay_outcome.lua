local captures = setmetatable({}, { __mode = "k" })

local C = {}

function C.record(owner_token, disposition, fields)
  local capture = captures[owner_token]
  if capture == nil then
    return
  end
  capture.disposition = disposition
  for key, value in pairs(fields or {}) do
    capture[key] = value
  end
end

function C.classify(owner_token, replay)
  local capture = {}
  local previous = captures[owner_token]
  captures[owner_token] = capture
  local ok, issued = pcall(replay)
  captures[owner_token] = previous
  if not ok then error(issued) end
  if issued then
    return { kind = "issued", issued = true }
  end
  return {
    kind = capture.disposition == "deferred" and "deferred" or "stuck",
    issued = false,
    outcome = capture.outcome,
    reason = capture.reason,
  }
end

return C
