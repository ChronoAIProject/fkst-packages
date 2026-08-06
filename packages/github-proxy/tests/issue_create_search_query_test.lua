-- Regression guard for the issue-create dedup search query.
--
-- The dedup search asks GitHub for an existing issue carrying the issue-create
-- marker. GitHub search parses a token that begins with "-" as a NOT operator,
-- so a query wrapped in the HTML comment delimiters "<!--" / "-->" is
-- unsatisfiable: it returns an empty match set with a zero exit status. The
-- search therefore answered "no such issue" for every dedup key and failed open
-- into duplicate issue creation while emitting no error fact.
--
-- The written marker keeps its comment delimiters -- it must stay invisible in
-- rendered markdown -- and only the query drops them. Exactness is unaffected
-- because the caller still matches the full marker against the returned body.
-- `contract.external_pr_bridge` already separates its marker from its search
-- query the same way; issue-create was the deviant.
local h = require("tests.proxy_integration_helpers")
local core = require("core")
local t = fkst.test

local dedup_keys = {
  "decompose/generic-workflow/issue/owner/x/42/v1/1/123",
  "sync-conflict-escalation/sync-conflict-lineage/owner/x/integration/devloop/issue/owner/x/3204/ready/c0e40e4e",
  "github-devloop/fork/owner/x/issue/3133/v1",
}

local function contains(haystack, needle)
  return tostring(haystack):find(needle, 1, true) ~= nil
end

return {
  test_issue_create_search_query_omits_search_operator_delimiters = function()
    for _, key in ipairs(dedup_keys) do
      local query = core.issue_create_search_query(key)
      t.eq(contains(query, "<!--"), false)
      t.eq(contains(query, "-->"), false)
      t.eq(query:sub(1, 1), "f")
    end
  end,

  test_issue_create_search_query_is_substring_of_written_marker = function()
    for _, key in ipairs(dedup_keys) do
      local marker = core.issue_create_marker(key)
      local query = core.issue_create_search_query(key)
      -- Recall: whatever we search for must literally occur in what we wrote.
      t.eq(contains(marker, query), true)
      t.eq(contains(query, tostring(key)), true)
      -- Precision is still carried by the full delimited marker.
      t.eq(contains(marker, "<!-- "), true)
      t.eq(contains(marker, " -->"), true)
    end
  end,

  -- Behavioural lock: the department must put the operator-free query on the
  -- wire. Asserting the pure function alone would not have caught the original
  -- defect, because the existing search mock matches on the "gh issue list"
  -- prefix and never inspected the query it was answering.
  test_issue_create_department_searches_with_an_operator_free_query = function()
    local payload = {
      schema = "github-proxy.issue-create.v1",
      repo = "owner/x",
      title = "Split blocked PR into smaller work",
      body = "Parent: #42",
      labels = { "triage" },
      dedup_key = "decompose/generic-workflow/issue/owner/x/42/v1/1/123",
      source_ref = { kind = "external", ref = "owner/x#issue/42" },
    }
    h.mock_write_env("1")
    h.mock_bot_env()
    t.mock_command("gh issue list", { stdout = "[]\n", stderr = "", exit_code = 0 })
    t.mock_command("gh issue create", {
      stdout = "https://github.com/owner/x/issues/99\n",
      stderr = "",
      exit_code = 0,
    })

    t.run_department("departments/github_issue_create/main.lua", {
      queue = "github_issue_create_request",
      payload = payload,
    }, h.opts("issue-create-search-query-on-the-wire", { FKST_GITHUB_WRITE = "1" }))

    local searches = h.calls_matching("gh issue list")
    t.eq(#searches, 1)
    local rendered = tostring(searches[1].rendered)
    t.eq(contains(rendered, core.issue_create_search_query(payload.dedup_key)), true)
    t.eq(contains(rendered, "<!--"), false)
    t.eq(contains(rendered, "-->"), false)
  end,
}
