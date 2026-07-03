local base_ids = require("devloop.base_ids")
local context_bundle = require("devloop.context_bundle")
local devloop_base = require("devloop.base")
local devloop_claims = require("devloop.claims")
local devloop_entity = require("devloop.entity")
local devloop_logging = require("devloop.logging")
local digest = require("core.digest")
local frontier = require("core.frontier")
local generator = require("core.generator")
local materialization = require("core.materialization")
local actions = require("core.materialize.actions")
local child_status = require("core.materialize.child_status")
local discovery = require("core.materialize.discovery")
local ledger_codec = require("core.materialize.ledger_codec")
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

local function terminal(core, deps, repo, issue_number, origin, state, reason_code)
  log_decision(origin, "frontier", "terminal", "applied(" .. tostring(state) .. ")", reason_code)
  actions.raise_request(
    origin,
    "github-proxy.github_issue_comment_request",
    actions.terminal_request(repo, issue_number, origin, state, reason_code)
  )
  if state == "done" then
    lease.release_done_claim(core, deps, repo, issue_number, origin)
  else
    log_decision(origin, "claim", "claim", "hold-terminal-claim", "terminal " .. tostring(state) .. " keeps the lease for follow-up ownership")
  end
  return "terminal"
end

local function load_blueprint(deps, ctx, workflow_id)
  if type(deps.load_blueprint) == "function" then
    return deps.load_blueprint(ctx, workflow_id)
  end
  local workflow_select = require("core.workflow_select")
  local catalog = workflow_select.load_catalog_for_ctx(ctx or {})
  local record = catalog and catalog.valid and catalog.valid[workflow_id] or nil
  return record
end

local function verify_claim(core, deps, repo, issue_number, origin)
  if type(deps.verify_issue_claim) == "function" then
    return deps.verify_issue_claim(core, repo, issue_number, origin)
  end
  local owner = devloop_claims.claim_owner()
  return devloop_claims.verify_issue_claim(core, repo, issue_number, owner)
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

local function run_generator(core, deps, ctx, slot, predecessor_ref)
  local generated, reason = generator.run_slot_generator(generator_deps(core, deps), ctx, slot, predecessor_ref)
  if generated == nil then
    return nil, reason or "generator-failed"
  end
  return generated, nil
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

local function replay_latched_generated(core, deps, repo, issue_number, origin, blueprint_digest, slot_id, fact, current)
  local ok, reason = actions.create_from_generated(
    core,
    repo,
    issue_number,
    origin,
    blueprint_digest,
    slot_id,
    fact,
    current,
    discovery.trusted_comments,
    log_decision
  )
  if not ok then
    return terminal(core, deps, repo, issue_number, origin, "error", reason or "generated-spec-missing")
  end
  return ok
end

local function write_generated(repo, issue_number, origin, blueprint_digest, slot, predecessor_ref_digest, generated_spec, planned_child_dedup)
  local entry = materialization.write_generated_entry(origin, blueprint_digest, slot, predecessor_ref_digest, generated_spec)
  if entry == nil then
    return nil
  end
  entry.child_dedup = planned_child_dedup
  log_decision(origin, "materialization", "generated", "applied(write-generated)", "generated spec latched before child create")
  actions.raise_request(
    origin,
    "github-proxy.github_issue_comment_request",
    actions.materialization_comment_request(repo, issue_number, origin, entry, "generated", nil, generated_spec)
  )
  return true
end

local function perform_materialize(core, deps, repo, issue_number, origin, record, blueprint_digest, facts, current, decision, event)
  local slot = actions.find_step(record.blueprint, decision.slot)
  if slot == nil then
    return terminal(core, deps, repo, issue_number, origin, "error", "frontier-slot-missing")
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
    log_decision(origin, "materialization", "materialization", "skip-idempotent(already-created)", "created materialization fact is already visible")
    return "noop"
  end
  if existing ~= nil and existing.state == "generated" then
    devloop_logging.log_line("info", M.DEPT, origin, "LATCH", {
      "action=replay_generated",
      "slot=" .. tostring(slot.id),
      "reason=generated materialization fact is already visible",
    })
    return replay_latched_generated(core, deps, repo, issue_number, origin, blueprint_digest, slot.id, existing, current)
  end

  local planned_child_dedup = materialization.child_dedup_key(origin, slot.id, predecessor_ref_digest)
  local generated_spec, gen_reason = run_generator(core, deps, {
    origin_proposal_id = origin,
    workflow_id = record.blueprint.id,
    predecessor_ref_digest = predecessor_ref_digest,
    event_ts = event and event.ts,
    worktree = generator_worktree(deps, slot, planned_child_dedup),
  }, slot, predecessor)
  if generated_spec == nil then
    return terminal(core, deps, repo, issue_number, origin, "error", gen_reason)
  end

  local latch = materialization.latch_generated(facts, key, generated_spec)
  devloop_logging.log_line("info", M.DEPT, origin, "LATCH", {
    "action=" .. tostring(latch.action),
    "slot=" .. tostring(slot.id),
    "reason=" .. tostring(latch.reason_code or ""),
  })
  if latch.action == "error" then
    return terminal(core, deps, repo, issue_number, origin, "error", latch.reason_code or "materialization-latch-error")
  end
  if latch.action == "noop" then
    log_decision(origin, "materialization", "materialization", "skip-idempotent(already-created)", "created materialization fact is already visible")
    return "noop"
  end
  if latch.action == "proceed_create" then
    return replay_latched_generated(core, deps, repo, issue_number, origin, blueprint_digest, slot.id, latch.fact, current)
  end

  local wrote = write_generated(repo, issue_number, origin, blueprint_digest, slot, predecessor_ref_digest, generated_spec, planned_child_dedup)
  if not wrote then
    return terminal(core, deps, repo, issue_number, origin, "error", "invalid-materialization-entry")
  end
  return true
end

local function process_origin(core, deps, repo, issue_number, event)
  local origin = base_ids.proposal_id(repo, issue_number)
  return with_lock(devloop_entity.observe_lock_key(repo, issue_number), function()
    local current = discovery.read_issue(core, deps, repo, issue_number)
    if tostring(current.state or ""):upper() ~= "OPEN" then
      log_decision(origin, "tick", "discover", "skip-closed", "issue is not open")
      return "skip"
    end
    if not verify_claim(core, deps, repo, issue_number, origin) then
      log_decision(origin, "claim", "materialize", "skip-claim-lost", "origin materialization lease is not self-held")
      return "skip"
    end

    local blueprint_fact = discovery.latest_blueprint(core, current, origin)
    if blueprint_fact == nil then
      log_decision(origin, "discover", "blueprint", "skip-no-blueprint", "no trusted workflow blueprint marker")
      return "skip"
    end
    if discovery.latest_terminal(core, current, origin) ~= nil then
      log_decision(origin, "discover", "terminal", "skip-terminal", "trusted workflow terminal marker already exists")
      return "skip"
    end

    local record = load_blueprint(deps, {
      origin_proposal_id = origin,
      event_ts = event and event.ts,
    }, blueprint_fact.workflow)
    if record == nil or type(record.blueprint) ~= "table" then
      return terminal(core, deps, repo, issue_number, origin, "error", "workflow-not-in-catalog")
    end
    local current_digest = digest.blueprint_digest(record.blueprint)
    if current_digest ~= blueprint_fact.digest then
      return terminal(core, deps, repo, issue_number, origin, "error", "blueprint-digest-mismatch")
    end

    local facts = discovery.materialization_facts(core, current, origin)
    if actions.maybe_write_created_from_parent_ledger(core, repo, issue_number, origin, facts, current, discovery.trusted_comments, log_decision) then
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
      log_decision(origin, "frontier", "wait", "skip-wait", decision.why or "frontier-waits")
      return "wait"
    end
    if decision.action == "terminal" then
      return terminal(core, deps, repo, issue_number, origin, decision.state or "error", decision.reason_code or "frontier-terminal")
    end
    if decision.action == "materialize" then
      return perform_materialize(core, deps, repo, issue_number, origin, record, current_digest, facts, current, decision, event)
    end
    return terminal(core, deps, repo, issue_number, origin, "error", "unknown-frontier-action")
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
  for _, issue in ipairs(issues) do
    if issue.number ~= nil then
      process_origin(core, deps, repo, issue.number, event)
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
  generated_spec_block = ledger_codec.encode_generated_spec,
  parse_generated_spec_block = ledger_codec.decode_generated_spec_block,
  trusted_issue_created_number = function(core, current, child_dedup_key)
    return actions.trusted_issue_created_number(core, current, child_dedup_key, discovery.trusted_comments)
  end,
  predecessor_ref_digest = actions.predecessor_ref_digest,
}

return M
