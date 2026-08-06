local implementation_escalation = require("devloop.implementation_escalation")
local devloop_state = require("devloop.state")

local function effect_entitlements(semantic_variant)
  local id = "github-devloop/implementation-escalating/autonomous/" .. semantic_variant
  return {
    apply = {
      id = id .. "/apply",
      effect_ids = {
        "github-proxy.github_issue_comment_request",
        "github-proxy.github_issue_label_request",
      },
    },
    idempotent = { id = id .. "/idempotent", effect_ids = {} },
  }
end

return function(_, h)
  local fact = h.fact
  local obligation = h.obligation
  local effect = h.effect
  local budget = h.budget
  local timeout = h.timeout
  local liveness = h.liveness
  local advancing_fact = h.advancing_fact
  local responsibility_signature = h.responsibility_signature
  local span_contract = h.span_contract
  return {
    from_state = "implementation-escalating",
    receiver_dispatch_effect_entitlement = {
      id = "github-devloop/implementation-escalating/receiver_dispatch",
      effect_ids = { "codex.dispatch:decompose" },
    },
    liveness_class_id = "implementation-escalating.active",
    watchdog = {
      mode = "live-defer",
      budget_ms = 60 * 60 * 1000,
      on_stale = { op = "redrive_receiver" },
    },
    actionable_epoch = {
      source = "codex_run:v1",
      generation_source = "same_as_actionable_epoch",
    },
    defer = {
      kind = "codex_run",
      redrive_opens_generation = true,
    },
    terminal = false,
    to_states = { "dependency_wait", "ready" },
    driving_queue = "github-devloop-decompose.devloop_implementation_decompose",
    observe_surfaces = { issue = true, liveness_scan = true },
    output_obligation = obligation(
      { "implementation-decomposition:v1", "state:v1 dependency_wait|ready" },
      { "dependency_wait", "ready" }),
    temporal_obligations = {
      {
        obligation_id = "github-devloop/issue/implementation-escalating/response-with-deadline",
        kind = "response-with-deadline",
        body = {
          actionable_epoch_source = "codex_run:v1",
          resolver = "fkst.codex_runs",
          budget_minutes = 60,
        },
      },
    },
    budget = budget(60,
      "A live decomposition supervisor defers while fkst.codex_runs() reports its decompose run; an absent run is redriven without terminalizing the issue."),
    liveness_contract = liveness({
      mode = "live-defer",
      real_execution = {
        primitive = "fkst.codex_runs",
        match = {
          role = "decompose",
          proposal_id = "state.proposal_id",
          dedup_key = "state.version",
        },
        status = "running",
        on_error = "defer",
        indeterminate_timeout = "row-budget",
      },
    }),
    on_timeout = timeout("github-devloop-decompose.devloop_implementation_decompose"),
    responsibility_signature = responsibility_signature({
      receiver_kind = "decomposition-supervisor",
      driving_queue = "github-devloop-decompose.devloop_implementation_decompose",
      state_kind = "worker",
      liveness_class = "implementation-escalating.active",
      input_fact_family = "implementation-escalation",
      output_postcondition_family = "implementation_supervision_result",
      phase_rank = devloop_state.stage_rank("implementation-escalating"),
      lineage_keys = { "state.version", "implementation-escalation.attempt", "implementation-escalation.head_sha" },
      successors = {
        {
          state = "dependency_wait",
          output_variant = "child_dependencies_pending",
          kind = "autonomous",
          transition_effect_entitlements = effect_entitlements("child_dependencies_pending"),
          pending_order = { participates = true, predecessor_state = "implementation-escalating" },
          postcondition_family = "implementation_supervision_result",
          bump = true,
        },
        {
          state = "ready",
          output_variant = "child_dependencies_satisfied",
          kind = "autonomous",
          transition_effect_entitlements = effect_entitlements("child_dependencies_satisfied"),
          pending_order = { participates = true, predecessor_state = "implementation-escalating" },
          postcondition_family = "implementation_supervision_result",
          bump = true,
        },
      },
    }),
    payload_builder = function(_, fields)
      return implementation_escalation.build_payload({
        proposal_id = fields.proposal_id,
        version = fields.version,
        branch = fields.branch,
        source_ref = fields.source_ref,
      }, {
        policy_id = fields.evidence_policy,
        previous_attempt = fields.previous_attempt,
        attempt = fields.attempt,
        head_sha = fields.head_sha,
      })
    end,
    dedup_shape = "implementation-escalation/<proposal>/<version>/<attempt>/<head>",
    required_facts = {
      fact("state", "marker-read"),
      fact("implement-checkpoint", "marker-read"),
      fact("implementation-escalation", "marker-read"),
      fact("implementation-decomposition", "marker-read"),
      fact("implementation-child-linkage", "marker-read"),
      fact("implementation-supervision-result", "marker-read"),
    },
    advancing_facts = {
      advancing_fact("implementation-supervision-result", "dependency_wait",
        { issue = true, liveness_scan = true }, "source_ref:issue"),
      advancing_fact("implementation-supervision-result", "ready",
        { issue = true, liveness_scan = true }, "source_ref:issue"),
    },
    payload_fields = {
      proposal_id = "marker:state.proposal",
      version = "marker:state.version",
      branch = "marker:implement-checkpoint.branch",
      head_sha = "marker:implementation-escalation.head_sha",
      previous_attempt = "marker:implementation-escalation.previous_attempt",
      attempt = "marker:implementation-escalation.attempt",
      evidence_policy = "marker:implementation-escalation.evidence_policy",
      source_ref = "source_ref:issue",
    },
    version_identity = "implementation escalation preserves the implementing version until dependencies are established",
    effects = effect({ "github-devloop-decompose.devloop_implementation_decompose" },
      "Escalation replay reissues only the dedicated pre-PR supervisor intent; timeout count never selects a terminal state."),
    marker_facts = "state:v1 implementation-escalating plus implementation-escalation:v1 and implement-checkpoint:v1",
    kickoff = "github-devloop-decompose.devloop_implementation_decompose",
    replay = "Observe replays the dedicated supervisor until its decomposition marker and every child created/blockedBy fact are visible, then projects dependency_wait or ready from the dependency gate.",
    span_contract = span_contract({
      department = "implementation_decompose",
      durable_start_marker = "implementation-escalation:v1",
      spawn_predecessor = "implementation_escalation_handoff",
      spawn_function = "run_supervisor",
    }),
  }
end
