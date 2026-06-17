local core = require("core")
local saga = require("std.saga")
local dead_letter = require("std.dead_letter")
local error_facts = require("std.error_facts")

local spec = {
  consumes = { "dead_letter" },
  produces = { "github-proxy.github_issue_create_request" },
  stall_window = "2m",
}

local function recurring_dead_letter(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}

  log.warn(
    "github-devloop dept=dead_letter tag=DEAD_LETTER"
      .. " delivery_id=" .. error_facts.one_line(payload.delivery_id)
      .. " queue=" .. error_facts.one_line(payload.queue)
      .. " dead_dept=" .. error_facts.one_line(payload.dept)
      .. " source_ref=" .. dead_letter.extract_source_ref(payload)
      .. " dedup_key=" .. error_facts.one_line(dead_letter.extract_dedup_key(payload))
      .. " attempt=" .. error_facts.one_line(payload.attempt)
      .. " error=" .. error_facts.one_line(payload.error)
  )

  local decision = core.failure_triage_decision(payload)
  if decision.action == "raise" then
    core.log_raise("failure_triage", decision.fact.fingerprint, "github-proxy.github_issue_create_request", decision.request)
  else
    log.info(
      "github-devloop dept=failure_triage tag=TRIAGE"
        .. " action=" .. tostring(decision.action)
        .. " reason=" .. tostring(decision.reason or "")
        .. " fingerprint=" .. tostring(decision.fact and decision.fact.fingerprint or "")
        .. " count=" .. tostring(decision.count or "")
    )
  end
end

return saga.department{
  consumes = spec.consumes,
  produces = spec.produces,
  fanout = spec.fanout,
  stall_window = spec.stall_window,
  retry = spec.retry,
  ephemeral = spec.ephemeral,
  done = recurring_dead_letter,
  act = act,
  name = "dead_letter",
}
