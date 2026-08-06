local base_ids = require("devloop.base_ids")
local context_bundle = require("devloop.context_bundle")
local devloop_base = require("devloop.base")
local devloop_claims = require("devloop.claims")
local dependency_gate = require("devloop.dependency_gate")
local devloop_entity = require("devloop.entity")
local devloop_logging = require("devloop.logging")
local digest = require("core.digest")
local frontier = require("core.frontier")
local generator = require("core.generator")
local materialization = require("core.materialization")
local actions = require("core.materialize.actions")
local child_status = require("core.materialize.child_status")
local discovery = require("core.materialize.discovery")
local lease = require("core.materialize.lease")

local M = {}

M.DEPT = "workflow_materialize_next"
M.TICK_QUEUE = "workflow_materialization_tick"

local function tick_proposal_id()
  return "github-devloop-workflow/materialization"
end

local function event_queue_matches(event, queue)
  local actual = tostring(event and event.queue or "")
  return actual == queue or actual:match("%." .. queue .. "$") ~= nil
end

local function log_decision(proposal_id, from_state, to_state, outcome, reason)
  discovery.log_decision(M.DEPT, proposal_id, from_state, to_state, outcome, reason)
end

local function run_origin_unit_of_work(fn)
  local pending = {}
  local unit = {}

  function unit.raise_request(proposal_id, queue, request)
    pending[#pending + 1] = {
      kind = "raise",
      proposal_id = proposal_id,
      queue = queue,
      request = request,
    }
  end

  function unit.log_decision(proposal_id, from_state, to_state, outcome, reason)
    pending[#pending + 1] = {
      kind = "decision",
      proposal_id = proposal_id,
      from_state = from_state,
      to_state = to_state,
      outcome = outcome,
      reason = reason,
    }
  end

  local ok, outcome = pcall(fn, unit)
  if not ok then
    return false, outcome
  end
  -- Publish all fallible effects before recording decisions as applied. A commit
  -- failure remains tick-fatal and cannot leave a success fact for a rejected raise.
  for _, effect in ipairs(pending) do
    if effect.kind == "raise" then
      actions.raise_request(effect.proposal_id, effect.queue, effect.request)
    end
  end
  for _, effect in ipairs(pending) do
    if effect.kind == "decision" then
      log_decision(effect.proposal_id, effect.from_state, effect.to_state, effect.outcome, effect.reason)
    end
  end
  return true, outcome
end

local function origin_error_class(err)
  local text = tostring(err or "")
  return text:match("github%-devloop%-workflow: ([%w%-]+):")
    or text:match("forge%.github: .- failed: ([%w%-]+):")
    or devloop_logging.error_class_from_message(text)
end

local function log_origin_failure(repo, issue_number, event, err)
  local origin = base_ids.proposal_id(repo, issue_number)
  devloop_logging.log_error_fact(
    "error",
    M.DEPT,
    origin,
    "ORIGIN_FAILURE",
    origin_error_class(err),
    event and event.queue,
    err,
    {
      source_ref = discovery.safe_source_ref(repo, issue_number),
      attempt = event and event.attempt,
      terminal = false,
    }
  )
end

local function terminal(core, deps, repo, issue_number, origin, state, reason_code, unit)
  unit.log_decision(origin, "frontier", "terminal", "applied(" .. tostring(state) .. ")", reason_code)
  unit.raise_request(
    origin,
    "github-proxy.github_issue_comment_request",
    actions.terminal_request(repo, issue_number, origin, state, reason_code)
  )
  if state == "done" then
    -- Cleanup is level-triggered from process_origin only after the terminal marker
    -- and its merged label projection are both visible on a later poll.
  else
    unit.log_decision(origin, "claim", "claim", "hold-terminal-claim", "terminal " .. tostring(state) .. " keeps the lease for follow-up ownership")
  end
  return "terminal"
end

local function raise_label_projection(origin, request, projection_state, unit)
  if request == nil then
    unit.log_decision(origin, "projection", "label-projection", "skip-idempotent(label-current)", projection_state .. " label projection already matches workflow truth")
    return
  end
  unit.log_decision(origin, "projection", "label-projection", "applied(reconcile)", projection_state .. " label projection reconciled under its current generation marker")
  unit.raise_request(origin, "github-proxy.github_issue_label_request", request)
end

local function reconcile_label_projection(repo, issue_number, origin, projection_state, current_labels, current_projection, unit)
  if current_projection == nil or tostring(current_projection.state or "") ~= tostring(projection_state) then
    local generation = (current_projection and current_projection.generation or 0) + 1
    unit.log_decision(origin, "projection", "label-projection", "applied(generation)", projection_state .. " label projection opened generation " .. tostring(generation))
    unit.raise_request(
      origin,
      "github-proxy.github_issue_comment_request",
      actions.label_projection_marker_request(repo, issue_number, origin, projection_state, generation)
    )
    return "marker-requested"
  end
  raise_label_projection(origin, actions.label_projection_request(
    repo,
    issue_number,
    origin,
    current_projection,
    current_labels
  ), projection_state, unit)
  return "projection-current"
end

local function reconcile_terminal_projection(repo, issue_number, origin, terminal_fact, current_labels, current_projection, unit)
  return reconcile_label_projection(
    repo,
    issue_number,
    origin,
    actions.terminal_projection_state(terminal_fact),
    current_labels,
    current_projection,
    unit
  )
end

local function reconcile_done_projection(repo, issue_number, origin, current_labels, unit)
  local request = actions.done_label_request(repo, issue_number, origin, current_labels)
  if request == nil then
    unit.log_decision(origin, "terminal", "terminal-label", "skip-idempotent(label-current)", "merged label projection already matches the trusted workflow terminal marker")
    return true
  end
  unit.log_decision(origin, "terminal", "terminal-label", "applied(reconcile)", "merged label projection derived from the trusted workflow terminal marker")
  unit.raise_request(origin, "github-proxy.github_issue_label_request", request)
  return false
end

local function reconcile_active_projection(repo, issue_number, origin, terminal_fact, current_labels, current_projection, unit)
  if terminal_fact ~= nil and tostring(terminal_fact.state or "") == "blocked" then
    return reconcile_label_projection(
      repo,
      issue_number,
      origin,
      "thinking",
      current_labels,
      current_projection,
      unit
    )
  end
end

local function load_blueprints(deps, ctx)
  if type(deps.load_blueprints) == "function" then
    return deps.load_blueprints(ctx)
  end
  local workflow_select = require("workflow_select")
  return workflow_select.load_catalog_for_ctx(ctx or {})
end

local function verify_claim(core, deps, repo, issue_number, origin)
  if type(deps.verify_issue_claim) == "function" then
    return deps.verify_issue_claim(core, repo, issue_number, origin)
  end
  local owner = devloop_claims.claim_owner()
  return devloop_claims.verify_issue_claim(repo, issue_number, owner)
end

local function content_fetch(core, predecessor_ref, ctx)
  local source_ref = predecessor_ref and predecessor_ref.source_ref or predecessor_ref
  local repo, issue_number = devloop_base.parse_issue_source_ref(source_ref)
  if repo == nil then
    error("github-devloop-workflow: generated-predecessor-source-ref-invalid: generated predecessor source_ref must be an issue ref")
  end
  return context_bundle.context_fetch_from_bundle(core, {
    dept = M.DEPT,
    repo = repo,
    issue_number = issue_number,
    proposal_id = predecessor_ref.proposal_id or base_ids.proposal_id(repo, issue_number),
    version = ctx and ctx.predecessor_ref_digest or "workflow-predecessor",
    tick = ctx and ctx.event_ts,
  })
end

local function generator_deps(core, deps)
  return {
    content_fetch = deps.content_fetch or function(predecessor_ref, ctx)
      return content_fetch(core, predecessor_ref, ctx)
    end,
    spawn_codex = deps.spawn_codex,
    spawn_codex_sync = deps.spawn_codex_sync or spawn_codex_sync,
  }
end

local function make_worktree(identity)
  if type(exec_sync) ~= "function" then
    return nil
  end
  return devloop_base.judgment_worktree_with_exec(exec_sync, "workflow-materialize", identity)
end

local function generator_worktree(deps, slot, identity)
  if type(deps.spawn_codex) == "function" then
    return nil
  end
  return slot.content and slot.content.kind == "generated" and make_worktree(identity) or nil
end

local function perform_materialize(core, deps, repo, issue_number, origin, blueprint_fact, record, blueprint_digest, facts, current, decision, event, unit)
  local slot = actions.find_step(record.blueprint, decision.slot)
  if slot == nil then
    return terminal(core, deps, repo, issue_number, origin, "error", "frontier-slot-missing", unit)
  end

  -- The first slot has no prior child; its "predecessor result" is the ORIGIN
  -- idea itself, so a GENERATED slot 1 reads the origin issue via source_ref
  -- (SPEC §6). A static slot 1 ignores this. The CAS key/digest stay derived
  -- from decision.predecessor (empty for slot 1), so static-slot behavior and
  -- the ledger key are unchanged; only the generator's content source is filled.
  local predecessor = decision.predecessor
  if predecessor == nil then
    predecessor = {
      proposal_id = origin,
      source_ref = { kind = "external", ref = tostring(repo) .. "#issue/" .. tostring(issue_number) },
    }
  end

  local predecessor_ref_digest = actions.predecessor_ref_digest(decision.predecessor)
  local key = materialization.materialization_key(origin, blueprint_digest, slot.id, predecessor_ref_digest)
  local existing = actions.best_fact_for_key(facts, key)
  if existing ~= nil and existing.state == "created" then
    unit.log_decision(origin, "materialization", "materialization", "skip-idempotent(already-created)", "created materialization fact is already visible")
    return "noop"
  end
  if existing ~= nil and existing.state == "generated" then
    devloop_logging.log_line("info", M.DEPT, origin, "LATCH", {
      "action=generated_marker_without_body",
      "slot=" .. tostring(slot.id),
      "reason=generated materialization fact no longer stores a replayable body",
    })
  end

  local planned_child_dedup = materialization.child_dedup_key(origin, slot.id, predecessor_ref_digest)
  local wrote_existing, existing_reason = actions.record_existing_child_or_created_marker(
    core,
    deps,
    repo,
    issue_number,
    origin,
    blueprint_digest,
    slot,
    predecessor_ref_digest,
    planned_child_dedup,
    facts,
    current,
    discovery.trusted_comments,
    unit.log_decision,
    unit.raise_request
  )
  if wrote_existing == nil then
    return terminal(core, deps, repo, issue_number, origin, "error", existing_reason or "existing-child-malformed", unit)
  end
  if wrote_existing == "wait" then
    return "wait"
  end
  if wrote_existing then
    return true
  end

  local generator_result = generator.run_slot_generator(generator_deps(core, deps), {
    origin_proposal_id = origin,
    workflow_id = record.blueprint.id,
    predecessor_ref_digest = predecessor_ref_digest,
    event_ts = event and event.ts,
    worktree = generator_worktree(deps, slot, planned_child_dedup),
  }, slot, predecessor)
  if type(generator_result) ~= "table" then
    error("github-devloop-workflow: generator-result-invalid: slot generator returned a non-table result")
  end
  if generator_result.disposition == "retry" then
    local reason_code = generator_result.reason_code or "generator-codex-failed"
    devloop_logging.log_error_fact(
      "warn",
      M.DEPT,
      origin,
      "GENERATOR_ATTEMPT_RETRY",
      reason_code,
      event and event.queue,
      "workflow generator attempt did not produce a usable child spec",
      {
        source_ref = discovery.safe_source_ref(repo, issue_number),
        attempt = event and event.attempt,
        terminal = false,
      }
    )
    unit.log_decision(origin, "materialization", "generator", "retry(generator-attempt)", reason_code)
    return "wait"
  end
  if generator_result.disposition == "cannot_proceed" then
    return terminal(core, deps, repo, issue_number, origin, "error", generator_result.reason_code, unit)
  end
  if generator_result.disposition ~= "ready" or type(generator_result.spec) ~= "table" then
    error("github-devloop-workflow: generator-result-invalid: slot generator returned an invalid disposition")
  end
  local generated_spec = generator_result.spec

  local latch = materialization.latch_generated(facts, key, generated_spec)
  devloop_logging.log_line("info", M.DEPT, origin, "LATCH", {
    "action=" .. tostring(latch.action),
    "slot=" .. tostring(slot.id),
    "reason=" .. tostring(latch.reason_code or ""),
  })
  if latch.action == "error" then
    return terminal(core, deps, repo, issue_number, origin, "error", latch.reason_code or "materialization-latch-error", unit)
  end
  if latch.action == "noop" then
    unit.log_decision(origin, "materialization", "materialization", "skip-idempotent(already-created)", "created materialization fact is already visible")
    return "noop"
  end
  local ok, reason = actions.record_created_or_raise_create(
    core,
    deps,
    repo,
    issue_number,
    origin,
    blueprint_fact,
    current,
    discovery.trusted_comments,
    facts,
    blueprint_digest,
    slot,
    predecessor_ref_digest,
    generated_spec,
    unit.log_decision,
    unit.raise_request
  )
  if not ok then
    return terminal(core, deps, repo, issue_number, origin, "error", reason or "invalid-materialization-entry", unit)
  end
  if ok == "wait" then
    return "wait"
  end
  return ok
end

local function process_origin(core, deps, repo, issue_number, event, catalog, unit)
  local origin = base_ids.proposal_id(repo, issue_number)
  return with_lock(devloop_entity.observe_lock_key(repo, issue_number), function()
    local current = discovery.read_issue(core, deps, repo, issue_number)
    if tostring(current.state or ""):upper() ~= "OPEN" then
      unit.log_decision(origin, "tick", "discover", "skip-closed", "issue is not open")
      return "skip"
    end
    -- Successful and configuration-error terminals are monotonic. A blocked terminal
    -- is a derived child verdict, so each poll must recompute it from current child
    -- facts: a child can recover and merge after the workflow recorded child-fatal.
    local terminal_fact = discovery.latest_terminal(core, current, origin)
    local label_projection = discovery.latest_label_projection(core, current, origin)
    if terminal_fact ~= nil and tostring(terminal_fact.state or "") ~= "blocked" then
      if tostring(terminal_fact.state or "") == "done" then
        if reconcile_done_projection(repo, issue_number, origin, current.labels, unit) then
          lease.release_done_claim(core, deps, repo, issue_number, origin)
          lease.close_done_origin(core, deps, repo, issue_number, origin)
        end
      else
        reconcile_terminal_projection(repo, issue_number, origin, terminal_fact, current.labels, label_projection, unit)
      end
      unit.log_decision(origin, "discover", "terminal", "skip-terminal", "trusted workflow terminal marker already exists")
      return "skip"
    end
    if not verify_claim(core, deps, repo, issue_number, origin) then
      unit.log_decision(origin, "claim", "materialize", "skip-claim-lost", "origin materialization lease is not self-held")
      return "skip"
    end

    local blueprint_fact = discovery.latest_blueprint(core, current, origin)
    if blueprint_fact == nil then
      unit.log_decision(origin, "discover", "blueprint", "skip-no-blueprint", "no trusted workflow blueprint marker")
      return "skip"
    end

    local record = catalog and catalog.valid and catalog.valid[blueprint_fact.workflow] or nil
    if record == nil or type(record.blueprint) ~= "table" then
      return terminal(core, deps, repo, issue_number, origin, "error", "workflow-not-in-catalog", unit)
    end
    local current_digest = digest.blueprint_digest(record.blueprint)
    if current_digest ~= blueprint_fact.digest then
      return terminal(core, deps, repo, issue_number, origin, "error", "blueprint-digest-mismatch", unit)
    end

    local facts = discovery.materialization_facts(core, current, origin)
    local created_marker = actions.maybe_write_created_from_existing_child(core, deps, repo, issue_number, origin, blueprint_fact, record, facts, current, discovery.trusted_comments, unit.log_decision, unit.raise_request)
    if created_marker == "wait" then
      reconcile_active_projection(repo, issue_number, origin, terminal_fact, current.labels, label_projection, unit)
      return "wait"
    end
    if created_marker then
      reconcile_active_projection(repo, issue_number, origin, terminal_fact, current.labels, label_projection, unit)
      return "created-marker"
    end

    local decision = frontier.compute_frontier(
      record.blueprint,
      actions.ledger_for_frontier(repo, facts),
      child_status.reader(core, deps, repo)
    )
    devloop_logging.log_line("info", M.DEPT, origin, "FRONTIER", {
      "action=" .. tostring(decision.action),
      "slot=" .. tostring(decision.slot or ""),
      "reason=" .. tostring(decision.reason_code or decision.why or ""),
    })
    if decision.action == "wait" then
      reconcile_active_projection(repo, issue_number, origin, terminal_fact, current.labels, label_projection, unit)
      unit.log_decision(origin, "frontier", "wait", "skip-wait", decision.why or "frontier-waits")
      return "wait"
    end
    if decision.action == "terminal" then
      if terminal_fact ~= nil
        and tostring(terminal_fact.state or "") == "blocked"
        and tostring(decision.state or "error") == "blocked" then
        reconcile_terminal_projection(repo, issue_number, origin, terminal_fact, current.labels, label_projection, unit)
        if tostring(terminal_fact.reason_code or "") == tostring(decision.reason_code or "frontier-terminal") then
          return "terminal"
        end
      end
      return terminal(core, deps, repo, issue_number, origin, decision.state or "error", decision.reason_code or "frontier-terminal", unit)
    end
    if decision.action == "materialize" then
      local resolve_dependencies = deps.dependency_gate or core.dependency_gate
      if type(resolve_dependencies) ~= "function" then
        error("github-devloop-workflow: dependency-gate-unavailable: workflow materialization requires the shared dependency gate")
      end
      local dependency_is_satisfied = deps.dependency_gate_is_satisfied or dependency_gate.dependency_gate_is_satisfied
      if type(dependency_is_satisfied) ~= "function" then
        error("github-devloop-workflow: dependency-gate-predicate-unavailable: workflow materialization requires the shared dependency predicate")
      end
      local dependency = resolve_dependencies(repo, issue_number)
      if type(dependency) ~= "table" then
        error("github-devloop-workflow: dependency-gate-invalid-result: shared dependency gate returned an invalid result")
      end
      if not dependency_is_satisfied(dependency) then
        reconcile_active_projection(repo, issue_number, origin, terminal_fact, current.labels, label_projection, unit)
        unit.log_decision(
          origin,
          "frontier",
          "dependency-gate",
          "skip-wait(" .. tostring(dependency.kind or "unavailable") .. ")",
          dependency.reason or "dependency-unresolved"
        )
        return "wait"
      end
      local outcome = perform_materialize(core, deps, repo, issue_number, origin, blueprint_fact, record, current_digest, facts, current, decision, event, unit)
      if outcome ~= "terminal" then
        reconcile_active_projection(repo, issue_number, origin, terminal_fact, current.labels, label_projection, unit)
      end
      return outcome
    end
    return terminal(core, deps, repo, issue_number, origin, "error", "unknown-frontier-action", unit)
  end)
end

local function act(core, event, opts)
  if not event_queue_matches(event, M.TICK_QUEUE) then
    error("github-devloop-workflow: unsupported-consumed-queue: unsupported consumed queue: " .. tostring(event and event.queue or ""))
  end
  local deps = opts and opts.deps or {}
  devloop_logging.log_entry(M.DEPT, event, tick_proposal_id(), "tick")
  devloop_base.assert_trusted_bot_configured()
  local repo = discovery.read_repo(deps)
  if repo == nil then
    log_decision(tick_proposal_id(), "tick", "discover", "skip-invalid-repo", "FKST_GITHUB_REPO is missing or invalid")
    return
  end

  local listed = discovery.list_open_issues(core, deps, repo)
  local issues, deferred = discovery.bounded_slice(core, M.DEPT, repo, listed)
  devloop_logging.log_line("info", M.DEPT, tick_proposal_id(), "DISCOVERY", {
    "repo=" .. tostring(repo),
    "listed=" .. tostring(#listed),
    "selected=" .. tostring(#issues),
    "deferred=" .. tostring(deferred),
    "bound=" .. tostring(discovery.MAX_ORIGINS_PER_TICK),
  })
  local catalog = load_blueprints(deps, {
    event_ts = event and event.ts,
  })
  for _, issue in ipairs(issues) do
    if issue.number ~= nil then
      local ok, err = run_origin_unit_of_work(function(unit)
        return process_origin(core, deps, repo, issue.number, event, catalog, unit)
      end)
      if not ok then
        log_origin_failure(repo, issue.number, event, err)
      end
    end
  end
end

function M.handlers(package_core, opts)
  local resolved_core = package_core or require("core")
  return {
    accept = function(event)
      return event_queue_matches(event, M.TICK_QUEUE)
    end,
    done = function(_event)
      return false
    end,
    act = function(event)
      return act(resolved_core, event, opts or {})
    end,
    wrap = resolved_core.wrap_pipeline_failure,
    name = M.DEPT,
  }
end

M._private = {
  trusted_issue_created_number = function(core, current, child_dedup_key)
    return actions.trusted_issue_created_number(core, current, child_dedup_key, discovery.trusted_comments)
  end,
  predecessor_ref_digest = actions.predecessor_ref_digest,
}

return M
