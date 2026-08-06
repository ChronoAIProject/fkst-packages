local owner_fact = require("devloop.sync_conflict_owner")
local routing = require("departments.implement.sync_conflict_owner")

local t = fkst.test

local REPO = "ChronoAIProject/fkst-packages"
local OWNER_ISSUE = 3204
local OWNER_BRANCH = "devloop/issue/ChronoAIProject/fkst-packages/3204/ready-github-devloop-issue-ChronoAIProject-fkst-packages-3204-intake-0768218242-3305069031"
local OWNER_HEAD = "c0e40e4e0a11ac5b845aaa8f8063994ee4bb5eac"

local function assert_errors(fn)
  local ok = pcall(fn)
  t.eq(ok, false)
end

local function trusted_current(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
  }
end

return {
  test_sync_conflict_owner_marker_round_trips_exact_owner = function()
    local marker = owner_fact.marker(REPO, OWNER_BRANCH, OWNER_HEAD)
    local parsed = owner_fact.find_marker(marker)

    t.eq(parsed.repo, REPO)
    t.eq(parsed.issue_number, OWNER_ISSUE)
    t.eq(parsed.proposal_id, "github-devloop/issue/ChronoAIProject/fkst-packages/3204")
    t.eq(parsed.branch, OWNER_BRANCH)
    t.eq(parsed.head_sha, OWNER_HEAD)
  end,

  test_sync_conflict_owner_marker_prefix_in_prose_is_not_a_fact = function()
    local body = "This discusses fkst:github-devloop-integration:sync-conflict-owner:v1 without an HTML marker."
    t.eq(owner_fact.has_marker(body), false)
    t.is_nil(owner_fact.find_marker(body))
  end,

  test_sync_conflict_owner_marker_rejects_non_owner_branch = function()
    assert_errors(function()
      owner_fact.marker(REPO, "integration", OWNER_HEAD)
    end)
  end,

  test_sync_conflict_owner_marker_rejects_mismatched_owner_identity = function()
    local marker = '<!-- fkst:github-devloop-integration:sync-conflict-owner:v1'
      .. ' repo="' .. REPO .. '"'
      .. ' issue="3205"'
      .. ' proposal="github-devloop/issue/ChronoAIProject/fkst-packages/3205"'
      .. ' branch="' .. OWNER_BRANCH .. '"'
      .. ' head_sha="' .. OWNER_HEAD .. '" -->'
    assert_errors(function()
      owner_fact.find_marker(marker)
    end)
  end,

  test_sync_conflict_owner_route_accepts_trusted_exact_owner = function()
    local route = routing.detect(
      trusted_current(owner_fact.marker(REPO, OWNER_BRANCH, OWNER_HEAD)),
      REPO,
      { ["fkst-test-bot"] = true }
    )

    t.eq(route.branch, OWNER_BRANCH)
    t.eq(route.issue_number, OWNER_ISSUE)
    t.eq(route.checkpoint.branch, OWNER_BRANCH)
    t.eq(route.checkpoint.head_sha, OWNER_HEAD)
  end,

  test_sync_conflict_owner_route_rejects_untrusted_author = function()
    local current = trusted_current(owner_fact.marker(REPO, OWNER_BRANCH, OWNER_HEAD))
    current.author_login = "contributor"
    assert_errors(function()
      routing.detect(current, REPO, { ["fkst-test-bot"] = true })
    end)
  end,

  test_sync_conflict_owner_route_rejects_repo_mismatch = function()
    assert_errors(function()
      routing.detect(
        trusted_current(owner_fact.marker(REPO, OWNER_BRANCH, OWNER_HEAD)),
        "other/repo",
        { ["fkst-test-bot"] = true }
      )
    end)
  end,
}
