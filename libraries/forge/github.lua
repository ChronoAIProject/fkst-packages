local exec_wrap = require("forge.github.exec")
local result = require("forge.github.result")

local M = {}

local function make_handle(exec, opts)
  assert(type(exec) == "function", "forge.github.new requires an exec function")
  local options = opts or {}
  local handle = {}
  local trusted_author_policy = options.trusted_author_policy
  local function direct_exec(argv, timeout, context, stdout_policy)
    return exec_wrap.run(exec, argv, timeout, context, stdout_policy, trusted_author_policy)
  end
  handle._trusted_author_policy = trusted_author_policy
  function handle._exec(argv, timeout, context, stdout_policy)
    return direct_exec(argv, timeout, context, stdout_policy)
  end
  require("forge.github.issue").install(handle)
  require("forge.github.entities").install(handle)
  require("forge.github.comments").install(handle)
  require("forge.github.graphql").install(handle)
  require("forge.github.workflows").install(handle)
  return handle
end

M.gh_result = result.gh_result

function M.new(exec, opts)
  return make_handle(exec, opts)
end

return M
