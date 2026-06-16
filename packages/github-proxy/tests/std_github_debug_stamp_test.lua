local debug_stamp = require("std.github_debug_stamp")
local t = fkst.test

return {
  test_debug_stamp_reads_code_version_from_git_port = function()
    local calls = {}
    local git = {
      read_head = function(opts)
        table.insert(calls, opts or {})
        return "ABCDEF1234567890\n"
      end,
    }

    local stamped = debug_stamp.append("Visible reply", {
      emitter = "github-proxy.comment",
      target = "issue:owner/repo#42",
    }, {
      read_env = function(name)
        t.eq(name, "FKST_DEBUG_STAMP")
        return "1"
      end,
      git = git,
    })

    t.eq(#calls, 1)
    t.eq(calls[1].timeout, 30)
    t.is_true(stamped:find('code_version="abcdef1234567890"', 1, true) ~= nil)
  end,
}
