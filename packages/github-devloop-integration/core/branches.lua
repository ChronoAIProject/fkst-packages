local base_ids = require("devloop.base_ids")
local strings = require("contract.strings")
local S = {}

local function bounded_lock_key(max_key_len, shared, prefix, repo, components)
  local safe_repo = base_ids.safe_repo(shared.require_safe_repo(repo))
  local separator_count = #components + 1
  -- Reserve separators, then split the remaining bytes evenly across checksummed branch components.
  local component_limit = math.floor((max_key_len - #prefix - #safe_repo - separator_count) / #components)
  local key_parts = { prefix, safe_repo }
  for _, component in ipairs(components) do
    local branch = shared.require_safe_branch(component.name, component.value)
    local checksum = strings.decimal_checksum(branch)
    local readable_limit = component_limit - #checksum - 1
    local readable = strings.sanitize_key(branch, false):gsub("/", "-"):sub(1, readable_limit)
    table.insert(key_parts, readable .. "-" .. checksum)
  end

  local key = table.concat(key_parts, "/")
  if not strings.is_path_safe_key(key, max_key_len) then
    error("github-devloop: lock-key-invalid: invalid branch lock key")
  end
  return key
end

function S.install(M)
  local shared = require("devloop.git_mechanics").helpers(M)
  local function package_lock_key(prefix, repo, components)
    return bounded_lock_key(M._max_key_len, shared, prefix, repo, components)
  end
  require("core.branches.branch_train").install(M, shared, package_lock_key)
  require("core.branches.pr_freshness").install(M, shared, package_lock_key)
end

return S
