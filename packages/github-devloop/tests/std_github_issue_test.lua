local gh = require("std.github")

return {
  test_read_issue_builds_exact_loop_command_and_parses = function()
    local seen
    local handle = gh.new(function(opts)
      seen = opts.cmd
      return {
        stdout = '{"state":"OPEN","title":"t","updatedAt":"2026-06-15T00:00:00Z","labels":[{"name":"fkst-dev:enabled"}],"comments":[{"id":1,"body":"b","author":{"login":"bot"},"createdAt":"2026-06-14T00:00:00Z"}],"assignees":[{"login":"dev"}],"author":{"login":"author"}}',
        stderr = "",
        exit_code = 0,
      }
    end)

    local issue = handle.read_issue({ kind = "external", ref = "owner/repo#issue/42" })

    assert(seen == "gh issue view '42' --repo 'owner/repo' --json title,updatedAt,labels,comments,state")
    assert(issue.number == 42)
    assert(issue.title == "t")
    assert(issue.updated_at == "2026-06-15T00:00:00Z")
    assert(issue.state == "OPEN")
    assert(issue.labels[1] == "fkst-dev:enabled")
    assert(issue.comments[1].author_login == "bot")
    assert(issue.assignees[1] == "dev")
    assert(issue.author_login == "author")
  end,
}
