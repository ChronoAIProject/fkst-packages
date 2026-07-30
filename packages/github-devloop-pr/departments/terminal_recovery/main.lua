local base_ids = require("devloop.base_ids")
local saga = require("workflow.saga")
local terminal_guard = require("devloop.terminal_guard")
local devloop_logging = require("devloop.logging")

local spec = {
  consumes = {
    "github-proxy.github_comment_refused",
    "github-devloop-decompose.devloop_terminal_refused",
  },
  produces = { "devloop_observe_pr" },
  stall_window = "30s",
  retry = { max_attempts = 6, base = "5s", cap = "30s" },
}

local function accepted(event)
  return terminal_guard.is_supported_refusal(event and event.payload)
end

local function act(event)
  local refusal = event.payload
  local repo = base_ids.parse_proposal_id(refusal.proposal_id)
  local observe = {
    schema = "github-proxy.v1",
    type = "pr",
    repo = repo,
    number = refusal.pr_number,
    state = "OPEN",
    updated_at = "1970-01-01T00:00:00Z",
    dedup_key = base_ids.dedup_key({
      "terminal-refused",
      "observe-pr",
      tostring(refusal.dedup_key),
    }),
    source = "terminal-refused",
    bound_version = refusal.bound_version,
    bound_head_sha = refusal.bound_head_sha,
    refusal_reason = refusal.reason,
    source_ref = refusal.source_ref,
  }
  devloop_logging.log_cas_decision(
    "terminal_recovery",
    refusal.proposal_id,
    {
      state = refusal.current_state,
      version = refusal.current_version,
    },
    "blocked",
    "reviewing",
    "redrive(" .. tostring(refusal.reason) .. ")",
    "terminal refusal requires a fresh PR observation"
  )
  devloop_logging.log_raise("terminal_recovery", refusal.proposal_id, "devloop_observe_pr", observe)
end

return saga.department(spec, {
  accept = accepted,
  done = function() return false end,
  act = act,
  wrap = devloop_logging.wrap_pipeline_failure,
  name = "terminal_recovery",
})
