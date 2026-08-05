local core = require("core")
local context_bundle = require("devloop.context_bundle")
local forks = require("devloop.forks")
local parsers_issue = require("devloop.parsers.issue")

return {
  build_prompt = function(...)
    return core.build_implementation_decompose_prompt(...)
  end,
  context_fetch = function(args)
    return context_bundle.context_fetch_from_bundle(core, args)
  end,
  parse_issue_view = function(stdout)
    return parsers_issue.parse_issue_view_decompose(core, stdout)
  end,
  rederive_issue_is_open = function(...)
    return forks.rederive_issue_is_open(core, ...)
  end,
  with_github_debug_stamp = function(...)
    return core.with_github_debug_stamp(...)
  end,
}
