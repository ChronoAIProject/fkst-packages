local saga = require("workflow.saga")

local spec = {
  consumes = { "browser_qa_result" },
  produces = {},
  stall_window = "30s",
  retry = false,
}

local function is_result(event)
  local queue = tostring(event and event.queue or "")
  return queue == "browser_qa_result" or queue == "browser-qa.browser_qa_result"
end

local function done(event)
  if not is_result(event) then
    error("browser-qa: unknown-queue: " .. tostring(event and event.queue), 0)
  end
  return false
end

local function act(event)
  local payload = event.payload or {}
  if payload.schema ~= "browser-qa.result.v1"
    or payload.status ~= "failed"
    or payload.reason ~= "blank-render" then
    error("browser-qa: invalid-result-fact: unsupported result", 0)
  end
  log.info(
    "browser-qa dept=result_log tag=RESULT status=failed reason=blank-render"
      .. " repo=" .. tostring(payload.repo)
      .. " pr=" .. tostring(payload.pr_number)
      .. " dedup_key=" .. tostring(payload.dedup_key)
  )
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "result_log",
})
