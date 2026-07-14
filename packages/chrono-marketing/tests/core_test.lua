local content = require("content_logic")
local core = require("core")
local t = fkst.test

local function entity()
  return {
    schema = "github-proxy.v1",
    type = "issue",
    state = "OPEN",
    repo = "owner/repo",
    number = 42,
    title = "Announce the dashboard",
    body = "Draft a launch post.",
    labels = { "fkst-company", "fkst-marketing" },
  }
end

local function drafted()
  return content.parse_content(
    '{"title":"Introducing the dashboard","channel":"social",'
      .. '"body_markdown":"The new dashboard ships today.","image_prompt":"a clean dashboard"}'
  )
end

return {
  test_is_marketing_request_filters_open_labeled_issues = function()
    t.is_true(content.is_marketing_request(entity()))
    local closed = entity()
    closed.state = "CLOSED"
    t.is_true(not content.is_marketing_request(closed))
    local unlabeled = entity()
    unlabeled.labels = { "documentation" }
    t.is_true(not content.is_marketing_request(unlabeled))
    t.is_true(not content.is_marketing_request({ type = "pr", state = "OPEN" }))
  end,

  test_parse_content_rejects_array_or_bad_channel = function()
    t.raises(function()
      content.parse_content("[]")
    end)
    t.raises(function()
      content.parse_content('{"title":"a","channel":"nope","body_markdown":"b"}')
    end)
  end,

  test_comment_request_maps_to_github_proxy_comment_seam = function()
    local request = content.request_from_entity(entity())
    local comment = content.comment_request(request, drafted())

    t.eq(comment.schema, "github-proxy.v1")
    t.eq(comment.repo, "owner/repo")
    t.eq(comment.issue_number, 42)
    t.is_true(comment.body:find("The new dashboard ships today.", 1, true) ~= nil)
    t.eq(comment.source_ref.kind, "repo-site")
  end,

  test_dedup_key_is_stable = function()
    local request = content.request_from_entity(entity())
    local d = drafted()
    t.eq(content.dedup_key(request, d), content.dedup_key(request, d))
  end,

  test_conformance_errors_is_empty = function()
    t.eq(#core.conformance_errors(), 0)
  end,
}
