local S = {}

function S.install(M)
local error_facts = require("std.error_facts")

M.error_fingerprint = error_facts.error_fingerprint
M.error_fact_fields = error_facts.error_fact_fields

function M.error_class_from_message(message)
  local text = tostring(message or "")
  local class = text:match("github%-proxy: [^:]+ failed: ([%w%-]+):")
    or text:match("github%-proxy: ([%w%-]+):")
  return class or "caught-failure"
end

function M.log_error_fact(level, dept, tag, error_class, queue, message, context)
  local fields = M.error_fact_fields(error_class, queue, dept, message, context)
  table.insert(fields, "queue=" .. error_facts.one_line(queue))
  table.insert(fields, "error=" .. error_facts.one_line(message))
  M.log_line(level or "warn", dept, tag or "FAILURE", fields)
end

function M.wrap_pipeline_failure(dept, fn)
  return function(event)
    local ok, err = pcall(fn, event)
    if ok then
      return err
    end
    M.log_error_fact("error", dept, "FAILURE", M.error_class_from_message(err), type(event) == "table" and event.queue or nil, err, {
      source_ref = error_facts.event_source_ref(event),
      attempt = type(event) == "table" and event.attempt or nil,
    })
    error(err, 0)
  end
end

end

return S
