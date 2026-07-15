local github_fake = require("forge.github_fake")
local testing = require("testkit.testing")
local t = fkst.test

return {
  test_browser_qa_comment_is_observable_without_mutating_github_in_dry_run = function()
    local core = require("core")
    local comment = require("departments.github_pr_comment.main")
    local model = github_fake.model()
    local github = github_fake.new(model)
    local old_read_env = core.read_env
    local old_github = core.github
    local old_log = log
    local logs = {}
    core.read_env = function(name)
      if name == "FKST_GITHUB_WRITE" then
        return ""
      end
      return nil
    end
    core.github = function()
      return github
    end
    log = {
      info = function(message)
        table.insert(logs, tostring(message))
      end,
      warn = function(message)
        table.insert(logs, tostring(message))
      end,
      error = function(message)
        table.insert(logs, tostring(message))
      end,
    }

    local ok, result_or_err = pcall(testing.run_fake, comment, {
      queue = "github-proxy.github_pr_comment_request",
      payload = {
        schema = "github-proxy.v1",
        repo = "owner/repo",
        pr_number = 42,
        body = "Browser QA found a blank render.",
        dedup_key = "browser-qa/owner/repo/pr/42/dashboard/1280x720/comment/blank-render",
        source_ref = {
          kind = "external",
          ref = "owner/repo#pr/42",
        },
      },
    })

    core.read_env = old_read_env
    core.github = old_github
    log = old_log
    if not ok then
      error(result_or_err, 0)
    end

    t.eq(#model.writes, 0)
    t.eq(#result_or_err.raises, 0)
    local observed = false
    for _, message in ipairs(logs) do
      if message:find("mode=dry-run", 1, true) ~= nil
        and message:find("dedup_key=browser-qa/owner/repo/pr/42/dashboard/1280x720/comment/blank-render", 1, true) ~= nil then
        observed = true
      end
    end
    t.is_true(observed)
  end,
}
