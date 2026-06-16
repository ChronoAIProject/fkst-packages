local shell = require("std.github.shell")

local M = {}

local function is_git_sha(value)
  return type(value) == "string" and value:find("^[0-9A-Fa-f]+$") ~= nil and #value >= 6 and #value <= 64
end

local function assert_branch(value)
  if not shell.is_git_ref_safe(value) then
    error("std.git: invalid branch")
  end
end

local function assert_sha(value, label)
  if not is_git_sha(value) then
    error("std.git: invalid " .. tostring(label or "sha"))
  end
end

function M.install(handle)
  function handle.push_branch(branch, timeout)
    assert_branch(branch)
    return handle._exec({ "git", "push", "-u", "origin", tostring(branch) }, timeout or 120, "git push")
  end

  function handle.show_ref_branch(branch, timeout)
    assert_branch(branch)
    return handle._exec({ "git", "show-ref", "--verify", "refs/heads/" .. tostring(branch) }, timeout or 30, "git show-ref")
  end

  function handle.is_ancestor(maybe_ancestor_sha, descendant_sha, timeout)
    assert_sha(maybe_ancestor_sha, "ancestor sha")
    assert_sha(descendant_sha, "descendant sha")
    local ok, result_or_error = handle._exec_result(
      { "git", "merge-base", "--is-ancestor", tostring(maybe_ancestor_sha), tostring(descendant_sha) },
      timeout or 30,
      "git merge-base"
    )
    if ok then
      return true
    end
    if type(result_or_error) == "table"
      and type(result_or_error.result) == "table"
      and tonumber(result_or_error.result.exit_code) == 1 then
      return false
    end
    error(result_or_error)
  end
end

return M
