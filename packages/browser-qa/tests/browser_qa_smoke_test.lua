local browser_fake = require("browser_fake")
local inspect = require("departments.inspect.main")
local testing = require("testkit.testing")
local t = fkst.test

local function request_event()
  return {
    queue = "browser-qa.browser_qa_request",
    payload = {
      schema = "browser-qa.request.v1",
      repo = "owner/repo",
      pr_number = 42,
      url = "http://127.0.0.1:4173/dashboard",
      viewport = { width = 1280, height = 720 },
      dedup_key = "browser-qa/owner/repo/pr/42/dashboard/1280x720",
      source_ref = {
        kind = "external",
        ref = "owner/repo#pr/42",
      },
    },
  }
end

local function find_raise(result, queue)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue then
      return raised
    end
  end
  return nil
end

return {
  test_nonblank_render_emits_no_finding_or_comment = function()
    local model = browser_fake.model({
      navigation = {
        blank_render = false,
        console_error_count = 0,
        network_error_count = 0,
        screenshot_ref = {
          kind = "host-worktree",
          ref = ".fkst/artifacts/browser-qa/healthy.png",
        },
      },
    })
    local dept = inspect.make_department({ browser = browser_fake.new(model) })

    local result = testing.run_fake(dept, request_event())

    t.eq(#model.calls, 1)
    t.eq(#result.raises, 0)
  end,

  test_blank_render_emits_failed_result_and_pr_comment_intent = function()
    local model = browser_fake.model({
      navigation = {
        blank_render = true,
        console_error_count = 0,
        network_error_count = 0,
        screenshot_ref = {
          kind = "host-worktree",
          ref = ".fkst/artifacts/browser-qa/dashboard-1280x720.png",
        },
      },
    })
    local dept = inspect.make_department({ browser = browser_fake.new(model) })

    local result = testing.run_fake(dept, request_event())
    local finding = find_raise(result, "browser_qa_result")
    local comment = find_raise(result, "github-proxy.github_pr_comment_request")

    t.eq(#model.calls, 1)
    t.eq(model.calls[1].url, "http://127.0.0.1:4173/dashboard")
    t.eq(model.calls[1].viewport.width, 1280)
    t.eq(model.calls[1].viewport.height, 720)

    t.is_true(finding ~= nil)
    t.eq(finding.payload.schema, "browser-qa.result.v1")
    t.eq(finding.payload.status, "failed")
    t.eq(finding.payload.reason, "blank-render")
    t.eq(finding.payload.url, "http://127.0.0.1:4173/dashboard")
    t.eq(finding.payload.viewport.width, 1280)
    t.eq(finding.payload.viewport.height, 720)
    t.eq(finding.payload.repo, "owner/repo")
    t.eq(finding.payload.pr_number, 42)
    t.eq(finding.payload.console_error_count, 0)
    t.eq(finding.payload.network_error_count, 0)
    t.eq(finding.payload.screenshot_ref.kind, "host-worktree")
    t.eq(finding.payload.screenshot_ref.ref, ".fkst/artifacts/browser-qa/dashboard-1280x720.png")
    t.eq(finding.payload.source_ref.kind, "external")
    t.eq(finding.payload.source_ref.ref, "owner/repo#pr/42")
    t.eq(finding.payload.dedup_key, "browser-qa/owner/repo/pr/42/dashboard/1280x720/result/blank-render")
    t.is_nil(finding.payload.screenshot_bytes)

    t.is_true(comment ~= nil)
    t.eq(comment.payload.schema, "github-proxy.v1")
    t.eq(comment.payload.repo, "owner/repo")
    t.eq(comment.payload.pr_number, 42)
    t.eq(comment.payload.source_ref.kind, finding.payload.source_ref.kind)
    t.eq(comment.payload.source_ref.ref, finding.payload.source_ref.ref)
    t.eq(comment.payload.dedup_key, "browser-qa/owner/repo/pr/42/dashboard/1280x720/comment/blank-render")
    t.is_true(comment.payload.body:find("http://127.0.0.1:4173/dashboard", 1, true) ~= nil)
    t.is_true(comment.payload.body:find("1280x720", 1, true) ~= nil)
    t.is_true(comment.payload.body:find("blank-render", 1, true) ~= nil)
    t.is_true(comment.payload.body:find("host-worktree:.fkst/artifacts/browser-qa/dashboard-1280x720.png", 1, true) ~= nil)
    t.is_nil(comment.payload.screenshot_bytes)
  end,
}
