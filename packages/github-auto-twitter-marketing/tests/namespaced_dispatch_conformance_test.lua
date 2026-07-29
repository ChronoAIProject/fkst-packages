local conformance = require("testkit.namespaced_dispatch_conformance")
local github_fake = require("forge.github_fake")
local t = fkst.test

local function source_ref()
  local reference = "owner/repo#issue/42"
  return {
    kind = "external",
    ref = reference,
    reference = reference,
  }
end

local function event_payload()
  return {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    title = "Auto Twitter marketing",
    state = "OPEN",
    labels = { "auto-twitter-marketing" },
    updated_at = "2026-07-24T09:00:00Z",
    source_ref = source_ref(),
    dedup_key = "owner/repo#issue#42@2026-07-24T09:00:00Z",
  }
end

local function github()
  local model = github_fake.model({
    issues = {
      ["owner/repo#issue/42"] = {
        number = 42,
        title = "Auto Twitter marketing",
        body = "type: strategy\nproject: chronoai\naccount: main\n",
        updatedAt = "2026-07-24T09:00:00Z",
        state = "OPEN",
        labels = { "auto-twitter-marketing" },
        comments = {},
        author = { login = "fkst-test-bot" },
      },
    },
  })
  return github_fake.new(model)
end

local function load_department()
  local old_pipeline = pipeline
  local module = require("departments.import_issue.main")
  pipeline = old_pipeline
  return {
    path = "departments/import_issue/main.lua",
    module = module.make_department({ github = github() }),
  }
end

local function load_sink_department(name)
  local module = require("departments." .. name .. ".main")
  return {
    path = "departments/" .. name .. "/main.lua",
    module = module,
  }
end

local departments = conformance.loaded_departments({
  load_department(),
  load_sink_department("optional_receipt_sink"),
  load_sink_department("strategy_import_sink"),
  load_sink_department("weekly_content_sink"),
})

local function payload_for_queue(_path, queue)
  if queue == "github-proxy.github_comment_written" then
    return {
      schema = "github-proxy.comment-written.v1",
      comment_id = "comment-1",
      source_ref = source_ref(),
      dedup_key = "github-comment-written/1",
    }
  end
  if queue == "x-publisher.x_published" then
    return {
      schema = "x-publisher.x-published.v1",
      artifact_id = "auto-twitter-marketing/chronoai/2026-W31/schedule",
      status = "published",
      source_ref = source_ref(),
      dedup_key = "x-published/1",
    }
  end
  if queue == "strategy_imported" or queue == "github-auto-twitter-marketing.strategy_imported" then
    return {
      schema = "auto-twitter-marketing.strategy-imported.v1",
      artifact_id = "auto-twitter-marketing/chronoai/strategy",
      project = "chronoai",
      source_ref = source_ref(),
      dedup_key = "owner/repo#issue#42@2026-07-24T09:00:00Z",
    }
  end
  if queue == "weekly_content_imported" or queue == "github-auto-twitter-marketing.weekly_content_imported" then
    return {
      schema = "auto-twitter-marketing.weekly-content-imported.v1",
      artifact_id = "auto-twitter-marketing/chronoai/2026-W31/weekly-content",
      project = "chronoai",
      week = "2026-W31",
      source_ref = source_ref(),
      dedup_key = "owner/repo#issue#43@2026-07-24T09:00:00Z",
    }
  end
  if queue ~= "github-proxy.github_issue_changed" and queue ~= "github-proxy.github_issue_observed" then
    error("github-auto-twitter-marketing: no fixture for queue " .. tostring(queue))
  end
  local payload = event_payload()
  if queue == "github-proxy.github_issue_observed" then
    payload.schema = "github-proxy.issue-observed.v1"
    payload.labels = nil
    payload.title = nil
  end
  return payload
end

return {
  test_all_departments_accept_production_namespaced_consumed_queues = function()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "github-auto-twitter-marketing",
      package_root = "packages/github-auto-twitter-marketing",
      departments = departments,
      payload_for_queue = payload_for_queue,
    })
  end,
}
