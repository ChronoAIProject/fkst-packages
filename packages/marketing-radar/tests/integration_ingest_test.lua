local github_fake = require("forge.github_fake")
local ingest = require("departments.ingest.main")
local testing = require("testkit_internal.testing")
local t = fkst.test

local repo = "owner/repo"

local function source_ref(number)
  return {
    kind = "external",
    ref = repo .. "#issue/" .. tostring(number),
  }
end

local function issue(number, body)
  return {
    repo = repo,
    number = number,
    title = "untrusted title " .. tostring(number),
    body = body,
    state = "OPEN",
    updatedAt = "2026-07-29T00:00:00Z",
    comments = {},
    labels = {},
    source_ref = source_ref(number),
  }
end

local function event(number)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = number,
      updated_at = "2026-07-29T00:00:00Z",
      dedup_key = repo .. "#issue/" .. tostring(number) .. "@2026-07-29T00:00:00Z",
      source_ref = source_ref(number),
    },
    source_ref = source_ref(number),
  }
end

local function fake_department(issues)
  local model = github_fake.model({ issues = issues })
  return ingest.make_department({
    github = github_fake.new(model),
  })
end

local function raises_to(result, queue)
  local found = {}
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue then
      table.insert(found, raised)
    end
  end
  return found
end

return {
  test_ingest_rehydrates_sources_and_raises_weekly_content_outputs = function()
    local issues = {
      [repo .. "#issue/20"] = issue(20, table.concat({
        "config-ref: owner/repo#issue/10",
        "signal-ref: owner/repo#issue/11",
        "",
        "TOKEN=do-not-copy",
      }, "\n")),
      [repo .. "#issue/10"] = issue(10, "config secret do-not-copy"),
      [repo .. "#issue/11"] = issue(11, "signal body do-not-copy"),
    }
    local result = testing.run_fake(fake_department(issues), event(20))

    local creates = raises_to(result, "github-proxy.github_issue_create_request")
    local receipts = raises_to(result, "radar_weekly_content_generated")
    t.eq(#creates, 1)
    t.eq(#receipts, 1)
    t.eq(creates[1].payload.schema, "github-proxy.issue-create.v1")
    t.eq(creates[1].payload.source_ref.ref, "owner/repo#issue/20")
    t.eq(creates[1].payload.labels[1], "auto-twitter-marketing")
    t.is_true(creates[1].payload.body:find("do-not-copy", 1, true) == nil)
    t.eq(receipts[1].payload.issue_create_dedup_key, creates[1].payload.dedup_key)
    t.eq(receipts[1].payload.signal_source_ref.ref, "owner/repo#issue/11")
  end,

  test_ingest_source_read_failure_fails_closed = function()
    local issues = {
      [repo .. "#issue/20"] = issue(20, table.concat({
        "config-ref: owner/repo#issue/10",
        "signal-ref: owner/repo#issue/11",
      }, "\n")),
      [repo .. "#issue/10"] = issue(10, "config"),
    }
    local result = testing.run_fake_expecting_failure(fake_department(issues), event(20))

    t.is_true(tostring(result.failure.error):find("source-read-failed", 1, true) ~= nil)
    t.eq(#result.raises, 0)
  end,
}
