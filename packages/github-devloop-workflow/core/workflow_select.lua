local core = require("core")
local blueprint = require("core.blueprint")
local catalog = require("core.catalog")
local default_intake = require("devloop.intake.default_intake")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local digest = require("core.digest")
local parsers_misc = require("devloop.parsers.misc")
local select_request = require("core.select_request")
local strings = require("contract.strings")
local workflow_codex = require("workflow.codex")
local workflow_env = require("workflow.env")
local workflow_select_prompt = require("prompts.workflow_select")

local M = {}

M.WORKFLOW_SELECT_LABEL = "⟦FKST:WORKFLOW_SELECT⟧"
M.MAX_WORKFLOW_SELECT_BLUEPRINTS = catalog.MAX_CATALOG_FILES

local function empty_catalog()
  return {
    valid = {},
    errors = {},
    duplicates = {},
  }
end

local function catalog_env_command(name)
  if name ~= "FKST_WORKFLOW_CATALOG_ROOT" and name ~= "HOME" then
    error("github-devloop-workflow: invalid-env-name: env name is not allowed")
  end
  return 'printf %s "$' .. name .. '"'
end

local read_catalog_env = workflow_env.read_env(catalog_env_command)

local function clean_path(value)
  local path = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if path == "" or path:find("[\r\n]") ~= nil then
    return nil
  end
  return path:gsub("/+$", "")
end

function M.resolve_catalog_root(opts)
  opts = opts or {}
  local injected = clean_path(opts.workflow_catalog_root or opts.catalog_root)
  if injected ~= nil then
    return injected
  end

  local run = opts.exec or opts.exec_sync or exec_sync
  local configured = clean_path(read_catalog_env("FKST_WORKFLOW_CATALOG_ROOT", run))
  if configured ~= nil then
    return configured
  end

  local home = clean_path(read_catalog_env("HOME", run))
  if home == nil then
    return nil
  end
  return home .. "/.fkst/workflow"
end

function M.load_catalog_for_ctx(ctx)
  local root = M.resolve_catalog_root(ctx or {})
  if root == nil then
    return empty_catalog(), nil
  end

  local ok, loaded = pcall(function()
    return catalog.load_catalog(root)
  end)
  if not ok or type(loaded) ~= "table" then
    return empty_catalog(), root
  end
  return loaded, root
end

local function has_existing_blueprint(ctx)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(core, ctx.current and ctx.current.comments or {})) do
    if core.marker.parse_blueprint_marker(parsers_misc.comment_body(core, comment), ctx.candidate.proposal_id) ~= nil then
      return true
    end
  end
  return false
end

local function has_existing_blueprint_on_current(current, candidate)
  return has_existing_blueprint({
    current = current,
    candidate = candidate,
  })
end

local function has_workflow_lineage_header(_ctx)
  -- TODO(2b-2b-ii/increment-3): detect the trusted child-of-workflow-step lineage marker once
  -- materialization owns writing it. Descendants remain ordinary default-intake issues here.
  return false
end

local function labels_match(current_labels, selector_labels)
  if type(selector_labels) ~= "table" then
    return false
  end
  local present = {}
  for _, label in ipairs(current_labels or {}) do
    present[tostring(label)] = true
  end
  for _, label in ipairs(selector_labels) do
    if present[tostring(label)] then
      return true
    end
  end
  return false
end

local function title_matches(title, selector_terms)
  if type(selector_terms) ~= "table" then
    return false
  end
  local text = tostring(title or "")
  for _, term in ipairs(selector_terms) do
    if text:find(tostring(term), 1, true) ~= nil then
      return true
    end
  end
  return false
end

function M.selector_matches(current, blueprint)
  local selector = type(blueprint) == "table" and blueprint.selector or nil
  if type(selector) ~= "table" then
    return true
  end

  local has_selector_rule = false
  if type(selector.labels_any) == "table" and #selector.labels_any > 0 then
    has_selector_rule = true
    if labels_match(current and current.labels or {}, selector.labels_any) then
      return true
    end
  end
  if type(selector.title_contains_any) == "table" and #selector.title_contains_any > 0 then
    has_selector_rule = true
    if title_matches(current and current.title or "", selector.title_contains_any) then
      return true
    end
  end

  return not has_selector_rule
end

function M.prefilter_eligible_blueprints(current, catalog)
  local eligible = {}
  local valid = type(catalog) == "table" and catalog.valid or {}
  for id, record in pairs(valid or {}) do
    local blueprint = type(record) == "table" and record.blueprint or nil
    if M.selector_matches(current or {}, blueprint) then
      table.insert(eligible, {
        id = tostring(id),
        path = record.path,
        blueprint = blueprint,
      })
    end
  end
  table.sort(eligible, function(left, right)
    return left.id < right.id
  end)
  return eligible
end

local function execution_boundary_clause(source_phrase)
  return table.concat({
    "Execution boundary:",
    "- You are running in an empty runtime scratch directory, not a repository checkout.",
    "- Do not clone, checkout, fetch with git, create branches, or modify any repository.",
    "- " .. tostring(source_phrase or ""),
  }, "\n")
end

local function workflow_digest(eligible)
  if #eligible > M.MAX_WORKFLOW_SELECT_BLUEPRINTS then
    return nil
  end
  local lines = {}
  for _, record in ipairs(eligible) do
    local blueprint = record.blueprint or {}
    table.insert(lines, "- id: " .. devloop_base.neutralize_untrusted_prompt_text(record.id))
    table.insert(lines, "  summary: " .. devloop_base.neutralize_untrusted_prompt_text(blueprint.summary))
    table.insert(lines, "  applies_when: " .. devloop_base.neutralize_untrusted_prompt_text(blueprint.applies_when))
  end
  return devloop_base.quote_untrusted_prompt_text(nil, table.concat(lines, "\n"))
end

function M.build_workflow_select_prompt(ctx, eligible)
  local digest = workflow_digest(eligible or {})
  if digest == nil then
    return nil
  end
  local current = ctx.current or {}
  local comments = table.concat(devloop_state.comment_bodies(current.comments), "\n\n--- comment ---\n\n")
  return devloop_base.render_template(workflow_select_prompt.template, {
    proposal_id = devloop_base.neutralize_untrusted_prompt_text(ctx.candidate and ctx.candidate.proposal_id),
    workflow_digest = digest,
    title = devloop_base.quote_untrusted_prompt_text(nil, current.title),
    body = devloop_base.quote_untrusted_prompt_text(nil, current.body),
    comments = devloop_base.quote_untrusted_prompt_text(nil, comments),
    execution_boundary = execution_boundary_clause("Judge only from the issue data and offered workflow catalog entries provided in this prompt."),
  })
end

function M.parse_workflow_selection(stdout)
  local lines = {}
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    local trimmed = strings.trim(line)
    if trimmed ~= "" then
      table.insert(lines, trimmed)
    end
  end
  if #lines ~= 1 then
    return nil
  end

  local value = lines[1]:match("^" .. M.WORKFLOW_SELECT_LABEL .. "%s+(.+)$") or lines[1]
  value = strings.trim(value)
  if value == "" or value == "none" then
    return nil
  end
  if not strings.is_path_safe_key(value, blueprint.MAX_ID_BYTES) then
    return nil
  end
  return value
end

local function eligible_by_id(eligible)
  local by_id = {}
  for _, record in ipairs(eligible or {}) do
    by_id[record.id] = record
  end
  return by_id
end

local function run_workflow_select_codex(ctx, eligible)
  local prompt = M.build_workflow_select_prompt(ctx, eligible)
  if prompt == nil then
    return nil
  end

  local proposal_id = ctx.candidate and ctx.candidate.proposal_id or "unknown"
  devloop_logging.log_codex_start("workflow_select", proposal_id, "workflow-select")
  local ok, result = pcall(function()
    return spawn_codex_sync(workflow_codex.judgment_codex_opts(
      prompt,
      devloop_base.judgment_worktree_with_exec(exec_sync, "workflow-select", ctx.candidate and ctx.candidate.dedup_key)
    ))
  end)
  if not ok then
    devloop_logging.log_codex_result("workflow_select", proposal_id, "workflow-select", nil, nil, result, {
      queue = "github-devloop-intake.devloop_intake_candidate",
      source_ref = ctx.candidate and ctx.candidate.source_ref,
      terminal = false,
    })
    return nil
  end
  if type(result) ~= "table" or result.exit_code ~= 0 or result.stdout == nil then
    local stderr = type(result) == "table" and result.stderr or "nil result"
    devloop_logging.log_codex_result("workflow_select", proposal_id, "workflow-select", result, nil, stderr, {
      queue = "github-devloop-intake.devloop_intake_candidate",
      source_ref = ctx.candidate and ctx.candidate.source_ref,
      terminal = false,
    })
    return nil
  end

  local parsed = M.parse_workflow_selection(result.stdout)
  devloop_logging.log_codex_result(
    "workflow_select",
    proposal_id,
    "workflow-select",
    result,
    parsed ~= nil and ("workflow=" .. parsed) or "workflow=none-or-unparseable",
    nil
  )
  return parsed
end

local function build_blueprint_request(ctx, record)
  local plan_digest = digest.blueprint_digest(record.blueprint)
  if plan_digest == nil then
    return nil
  end
  return select_request.build_blueprint_decision_comment_request(
    core,
    ctx.repo,
    ctx.issue_number,
    ctx.candidate,
    record.id,
    plan_digest,
    "Selected workflow " .. record.id .. " from the user-authored workflow catalog."
  )
end

local function raise_blueprint_decision(ctx, record)
  local handled = false
  with_lock(ctx.lock_key, function()
    local ok, fresh = pcall(default_intake.read_current_for_candidate, core, "workflow_select", ctx.repo, ctx.issue_number, ctx.candidate, ctx.event_ts, ctx.decision_dedup_key)
    handled = true
    if not ok then
      devloop_logging.log_cas_decision(
        "workflow_select",
        ctx.candidate and ctx.candidate.proposal_id or "unknown",
        { state = nil, version = nil },
        "candidate",
        "blueprint-decision",
        "fail-closed(apply-gate-read-failed)",
        fresh
      )
      return
    end
    if fresh == nil then
      return
    end
    if has_existing_blueprint_on_current(fresh.current, ctx.candidate) then
      devloop_logging.log_cas_decision(
        "workflow_select",
        ctx.candidate and ctx.candidate.proposal_id or "unknown",
        { state = nil, version = nil },
        "candidate",
        "blueprint-decision",
        "skip-idempotent(blueprint marker already visible)",
        "trusted workflow blueprint marker exists"
      )
      return
    end
    local request = build_blueprint_request(ctx, record)
    if request == nil then
      devloop_logging.log_cas_decision(
        "workflow_select",
        ctx.candidate and ctx.candidate.proposal_id or "unknown",
        { state = nil, version = nil },
        "candidate",
        "blueprint-decision",
        "fail-closed(invalid-blueprint-request)",
        "selected workflow blueprint request could not be built"
      )
      return
    end
    devloop_logging.log_raise(
      "workflow_select",
      ctx.candidate and ctx.candidate.proposal_id or "unknown",
      "github-proxy.github_issue_comment_request",
      request
    )
  end)
  return handled
end

local function workflow_prefilter(ctx)
  if has_existing_blueprint(ctx) then
    return true
  end
  if has_workflow_lineage_header(ctx) then
    return false
  end
  local catalog = M.load_catalog_for_ctx(ctx)
  local eligible = M.prefilter_eligible_blueprints(ctx.current or {}, catalog)
  if #eligible == 0 then
    return false
  end

  local selected = run_workflow_select_codex(ctx, eligible)
  local record = eligible_by_id(eligible)[selected]
  if record == nil then
    return false
  end
  return raise_blueprint_decision(ctx, record)
end

M.workflow_prefilter = workflow_prefilter

function M.handlers()
  return {
    done = function(_event) return false end,
    act = function(event)
      return default_intake.act(core, event, {
        dept = "workflow_select",
        before_codex = workflow_prefilter,
      })
    end,
    wrap = core.wrap_pipeline_failure,
    name = "workflow_select",
  }
end

return M
