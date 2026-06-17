return function(M, h)
  local fact = h.fact
  local obligation = h.obligation
  local effect = h.effect
  local budget = h.budget
  local timeout = h.timeout
  local liveness = h.liveness
  local watchdog = h.watchdog
  local actionable_epoch = h.actionable_epoch
  return {
    from_state = "thinking",
    terminal = false,
    to_states = { "ready", "blocked" },
    driving_queue = "consensus.proposal",
    observe_surfaces = { issue = true, liveness_scan = true },
    timeout_surfaces = { issue = true, issue_liveness_scan = true, liveness_scan = true },
    output_obligation = obligation({ "consensus.consensus_reached", "consensus.consensus_converge" }, { "ready", "blocked", "thinking" }),
    budget = budget(150, "The long consensus receiver is supervised by converge-round heartbeats; this budget only bounds stale heartbeat redrive."),
    watchdog = watchdog({
      mode = "live-defer",
      budget_ms = 9000000,
    }),
    liveness_class_id = "thinking.consensus-heartbeat",
    actionable_epoch = actionable_epoch({
      source = "state_entry:v1",
      generation_source = "same_as_actionable_epoch",
    }),
    defer = {
      live_marker = "converge-round",
      freshness_ms = 7200000,
      clear_fact = "consensus.consensus_reached or state:v1 blocked",
      observed_fact = "converge-round:v1",
      clear_opens_generation = true,
    },
    liveness_contract = liveness({
      mode = "live-defer",
      signal = {
        family = "converge-round",
        producer = "converge-round",
        surface = "issue-comment-stream",
        version_form = "raw",
        max_age_minutes = 120,
      },
    }),
    on_timeout = timeout("consensus.proposal"),
    payload_builder = M.build_proposal,
    dedup_shape = "proposal:<proposal_id>/<updated_at> or consensus:<base_version>/loop/<n>",
    required_facts = { fact("state", "marker-read") },
    payload_fields = {
      proposal_id = "marker:state.proposal",
      dedup_key = "marker:state.version",
      source_ref = "source_ref:issue",
    },
    version_identity = "strip_transition_version_suffixes(state.version)",
    effects = effect({ "consensus.proposal" }, "consensus proposal dedup is derived from state.version or next complete converge-round"),
    marker_facts = "state:v1 thinking plus optional converge-round:v1",
    kickoff = "consensus.proposal",
    replay = "Initial thinking reuses the state version as proposal dedup; convergence replays the next /loop/N from the latest complete converge-round marker.",
  }
end
