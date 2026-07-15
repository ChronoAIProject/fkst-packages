-- workflow-writer: the single binding table.
--
-- This composes the four kernel seams (executor / completion / catalog / platform) and
-- the adapter's OWN intake, then hands them to engine.make_departments. It is the only
-- place that touches the GitHub port + ambient runners; the department main.lua files
-- are ~3-line wrappers that each invoke exactly ONE of the returned lazy closures (so
-- saga.department's _G.pipeline mutation never clobbers a sibling).
--
-- It requires the shared kernel by a LOCAL name (engine) and the adapter modules by
-- their bare package-root names -- never require("core"), never _G reads for policy.
local engine = require("workflow.engine")
local codex = require("workflow.codex")
local env = require("workflow.env")
local strings = require("contract.strings")
local github_factory = require("devloop.github_factory")

local authoring = require("authoring")
local records = require("records")
local discovery_mod = require("discovery")
local executor_mod = require("executor")
local completion_mod = require("completion")
local catalog_mod = require("catalog")
local intake_mod = require("intake")

local function env_read_command(name)
  return 'printf %s "$' .. tostring(name) .. '"'
end

local function env_value(name)
  local ok, value = pcall(env.read_env, name, exec_sync, env_read_command)
  if not ok or type(value) ~= "string" then
    return nil
  end
  return strings.trim(value)
end

local function production_github()
  local ok, handle = pcall(github_factory.production_handle)
  if ok then
    return handle
  end
  return nil
end

-- The injected authoring runner. Authoring needs a real wired codex (it drafts a
-- template AND opens a PR), so the generated step works; the unrestricted opts let the
-- agent edit files + run gh/git inside its own sandbox (never in this Lua).
local function spawn_author(prompt)
  return spawn_codex_sync(codex.unrestricted_codex_opts(prompt, "."))
end

local marker = engine.marker.for_namespace(authoring.NAMESPACE)
local repo = env_value("FKST_GITHUB_REPO") or ""
local bot_login = env_value("FKST_GITHUB_BOT_LOGIN") or ""

local discovery, lease = discovery_mod.build({
  github = production_github(),
  repo = repo,
  marker = marker,
  bot_login = bot_login,
  label = authoring.LABEL,
})

local catalog = catalog_mod.build({
  catalog_root = env_value("FKST_WORKFLOW_CATALOG_ROOT"),
})

local executor = executor_mod.build({
  marker = marker,
  repo = repo,
  spawn_author = spawn_author,
  step_id = records.STEP_ID,
  catalog_ids = catalog.catalog_ids,
})

local platform = {
  with_lock = function(_key, fn)
    return fn()
  end,
  lock_key = function(scope)
    return authoring.NAMESPACE .. "/" .. tostring(scope.origin)
  end,
  exec = exec_sync,
  discovery = discovery,
  lease = lease,
}

local intake_handlers = intake_mod.build({
  marker = marker,
  discovery = discovery,
  blueprint = records.BLUEPRINT,
  workflow_id = authoring.WORKFLOW_ID,
  repo = repo,
  materialization_tick_queue = authoring.MATERIALIZATION_TICK_QUEUE,
  consumes = { authoring.AUTHORING_REQUEST_QUEUE, authoring.TICK_QUEUE },
})

-- The kernel config, in the exact shape engine.make_departments consumes. The
-- department wrappers build saga.department directly from the kernel handlers this
-- config wraps (reconcile.handlers / the intake handler set) so each main.lua is
-- saga-shaped for the G10 saga-handler ratchet while copying zero engine logic.
local config = {
  namespace = authoring.NAMESPACE,
  executor = executor,
  completion = { reader = completion_mod.reader },
  catalog = catalog,
  platform = platform,
  package = "workflow-writer",
  tick_queue = authoring.MATERIALIZATION_TICK_QUEUE,
  materialize_next = {
    consumes = { authoring.MATERIALIZATION_TICK_QUEUE },
    produces = {
      "github-proxy.github_issue_comment_request",
    },
  },
  intake = {
    consumes = { authoring.AUTHORING_REQUEST_QUEUE, authoring.TICK_QUEUE },
    produces = {
      authoring.MATERIALIZATION_TICK_QUEUE,
      "github-proxy.github_issue_comment_request",
    },
    handlers = function()
      return intake_handlers
    end,
  },
  dead_letter = { package = "workflow-writer" },
}

local M = {}

-- The seams table reconcile.handlers consumes (namespace + the four seams + tick).
function M.seams()
  local bound = {
    namespace = config.namespace,
    executor = config.executor,
    completion = config.completion,
    catalog = config.catalog,
    platform = config.platform,
  }
  bound.tick_queue = config.tick_queue
  return bound
end

-- The OWN-intake handler set (workflow_writer_select department).
function M.intake_handlers()
  return intake_handlers
end

-- The lazy per-department closures, for callers that prefer the facade entry point.
function M.make_departments()
  return engine.make_departments(config)
end

return M
