local saga_conformance = require("devloop.saga_conformance")
local parsers_misc = require("devloop.parsers.misc")
local parsers_pr = require("devloop.parsers.pr")
local base = require("devloop.base")
local M

-- fkst.toml conformance hook: function = "core.saga_conformance_errors" (delegates to typed devloop.saga_conformance.errors)
local function saga_conformance_errors()
  return saga_conformance.errors(M)
end

M = {
  saga_conformance_errors = saga_conformance_errors,
}

function M.parse_pr_view_merge(stdout)
  return parsers_pr.parse_pr_view_merge(stdout)
end

function M.rollup_failure_gate_sha(pr)
  return parsers_misc.rollup_failure_gate_sha(pr)
end


require("forge.github_debug_stamp").install(M, require("devloop.base").read_env)
require("devloop.commands").install(M)
require("forge.merge_commands").install(M)
local git_mechanics = require("devloop.git_mechanics")
local function dept_exec_argv(...) return exec_argv(...) end
M.git = require("forge.git").new(dept_exec_argv)
require("forge.merge").install(M, {
  github_handle = require("devloop.github_factory").production_handle,
  read_runtime_root_cmd = base.read_runtime_root_cmd,
  mkdir_p_cmd = base.mkdir_p_cmd,
  log_info = function(dept, proposal_id, tag, fields)
    return require("devloop.logging").log_line("info", dept, proposal_id, tag, fields)
  end,
  invalidate_pr_after_write = function(repo, pr_number)
    return require("devloop.github_proxy_entity_view").invalidate_entity_after_write(repo, "pr", pr_number)
  end,
  pr_view_projection = parsers_pr.parse_pr_view_merge,
})
require("devloop.logging").install(M)
local entity = require("devloop.entity")
M.linked_pr_surface_snapshot = function(...) return entity.linked_pr_surface_snapshot(M, ...) end
local github_proxy_entity_view = require("devloop.github_proxy_entity_view")
M.cached_entity_view = function(...) return github_proxy_entity_view.cached_entity_view(...) end
M.fetch_pr_view_origin = github_proxy_entity_view.fetch_pr_view_origin
M.invalidate_entity_after_write = github_proxy_entity_view.invalidate_entity_after_write
require("core.substrate_ref").install(M)

return M
