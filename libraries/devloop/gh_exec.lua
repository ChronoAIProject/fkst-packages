local content_filter = require("forge.github.content_filter")
local stdout_policy = require("forge.github.stdout_policy")

local G = {}

local gh_program = table.concat({ "g", "h" })

local function gh_exec_opts(cmd_or_opts, timeout)
  local opts = {}
  if type(cmd_or_opts) == "table" then
    for key, value in pairs(cmd_or_opts) do
      opts[key] = value
    end
  else
    opts.cmd = cmd_or_opts
  end
  opts.timeout = opts.timeout or timeout or 30
  return opts
end

local function normalize_gh_argv_exec_opts(cmd_or_opts, timeout)
  local opts = gh_exec_opts(cmd_or_opts, timeout)
  if type(opts.argv) ~= "table" or opts.argv[1] ~= gh_program then
    error("github-devloop: GitHub exec requires GitHub argv")
  end
  return {
    argv = opts.argv,
    timeout = opts.timeout,
    stdout_policy = opts.stdout_policy,
  }
end

local function filter_stdout(result, policy, author_policy)
  stdout_policy.validate(policy)
  if not stdout_policy.is_content_json(policy) then
    return result
  end
  local whitelist = content_filter.policy_whitelist(author_policy)
  if whitelist == nil then return result end
  local filtered = content_filter.filter_gh_content_json(tostring(result.stdout or ""), whitelist, {})
  if filtered == result.stdout then
    return result
  end
  local copy = {}
  for key, value in pairs(result) do
    copy[key] = value
  end
  copy.stdout = filtered
  copy.content_redacted = true
  copy.stdout_policy = policy
  return copy
end

function G.gh_exec(cmd_or_opts, timeout, exec, policy, author_policy)
  local run = exec or exec_argv
  if type(run) ~= "function" then
    error("github-devloop: GitHub exec requires exec_argv")
  end
  local opts = normalize_gh_argv_exec_opts(cmd_or_opts, timeout)
  local effective_policy = policy or opts.stdout_policy
  stdout_policy.validate(effective_policy)
  return filter_stdout(run({ argv = opts.argv, timeout = opts.timeout }), effective_policy, author_policy)
end

return G
