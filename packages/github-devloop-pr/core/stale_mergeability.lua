local check_runs = require("forge.github.check_runs")
local git_mechanics = require("devloop.git_mechanics")
local pr_safety = require("devloop.pr_safety")

local C = {}

function C.should_wait(M, pr, branches, mergeable_reason)
  if not check_runs.is_not_mergeable_reason(mergeable_reason) then
    return false, "not-stale-mergeability"
  end
  local base_head, base_reason = git_mechanics.current_base_head(M.git, branches.integration)
  if base_head == nil then
    return false, base_reason
  end
  local head_sha = tostring(pr and pr.head_sha or "")
  if not pr_safety.is_safe_head_sha(head_sha) then
    return false, "unsafe-pr-head"
  end
  local result = git_mechanics.git_is_ancestor(M.git, base_head, head_sha, 30)
  if result.exit_code == 0 then
    return true, "current-base-contained"
  end
  return false, "current-base-not-contained"
end

return C
