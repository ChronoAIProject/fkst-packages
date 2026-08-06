local t = require("tests.devloop_core_helpers").t
local devloop_pr = require("devloop.parsers.pr")
local forge_pr_view = require("forge.github_view")

local function merge_view()
  return {
    title = "Product title",
    body = "Product body",
    headRefName = "feature/merge-view",
    headRefOid = "abc123",
    baseRefName = "integration-elonsg",
    baseRefOid = "def456",
    state = "OPEN",
    updatedAt = "2026-08-06T01:02:03Z",
    mergedAt = nil,
    mergeCommit = { oid = "fed987" },
    labels = { { name = "product-label" } },
    comments = {
      {
        id = "IC_1",
        body = "merge fact",
        author = { login = "fkst-bot" },
        createdAt = "2026-08-06T01:01:00Z",
      },
    },
    headRepository = { nameWithOwner = "ChronoAIProject/fkst-packages" },
    isCrossRepository = false,
    isDraft = false,
    mergeable = "MERGEABLE",
    mergeStateStatus = "CLEAN",
    statusCheckRollup = {
      { name = "test", status = "COMPLETED", conclusion = "SUCCESS" },
    },
  }
end

return {
  test_forge_pr_merge_view_contains_only_merge_mechanics_fields = function()
    local parsed = forge_pr_view.parse_pr_view_merge(merge_view())

    t.eq(parsed.head_ref_name, "feature/merge-view")
    t.eq(parsed.head_sha, "abc123")
    t.eq(parsed.base_ref_name, "integration-elonsg")
    t.eq(parsed.state, "OPEN")
    t.eq(parsed.head_repository, "ChronoAIProject/fkst-packages")
    t.eq(parsed.is_cross_repository, false)
    t.eq(parsed.is_draft, false)
    t.eq(parsed.mergeable, "MERGEABLE")
    t.eq(parsed.merge_state_status, "CLEAN")
    t.eq(parsed.status_check_rollup[1].name, "test")
    t.eq(parsed.comments[1].author_login, "fkst-bot")

    t.is_nil(parsed.title)
    t.is_nil(parsed.body)
    t.is_nil(parsed.base_ref_oid)
    t.is_nil(parsed.updated_at)
    t.is_nil(parsed.merge_commit_sha)
    t.is_nil(parsed.labels)
    t.is_nil(parsed.status_check_rollup_present)
  end,

  test_devloop_pr_merge_projection_preserves_product_fields = function()
    local parsed = devloop_pr.parse_pr_view_merge(merge_view())

    t.eq(parsed.title, "Product title")
    t.eq(parsed.body, "Product body")
    t.eq(parsed.base_ref_oid, "def456")
    t.eq(parsed.updated_at, "2026-08-06T01:02:03Z")
    t.eq(parsed.merge_commit_sha, "fed987")
    t.eq(parsed.labels[1], "product-label")
    t.eq(parsed.head_ref_name, "feature/merge-view")
    t.eq(parsed.status_check_rollup_present, true)
    t.eq(parsed.status_check_rollup[1].conclusion, "SUCCESS")
    t.eq(parsed.comments[1].body, "merge fact")
  end,
}
