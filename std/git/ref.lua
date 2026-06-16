local M = {}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_head_argv()
  return { "git", "rev-parse", "--verify", "HEAD" }
end

function M.install(handle)
  function handle.read_head(opts)
    local options = opts or {}
    local result = handle._exec(read_head_argv(), tonumber(options.timeout) or 30, "git rev-parse HEAD")
    return trim(result.stdout)
  end
end

return M
