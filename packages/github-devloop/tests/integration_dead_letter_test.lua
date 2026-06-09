local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local issue = h.issue
local ready = h.ready
local review_unresolved = h.review_unresolved
local reviewing = h.reviewing
local render_comment = h.render_comment
local find_raise = h.find_raise
local count_calls = h.count_calls

local function run_dead_letter(payload, run_opts)
  return t.run_department("departments/dead_letter/main.lua", {
    queue = "github-devloop.dead_letter",
    payload = payload,
  }, run_opts)
end

local function mock_dead_letter_issue(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  t.mock_command("--json labels,comments", {
    stdout = '{"labels":[],"comments":[' .. table.concat(rendered, ",") .. "]}\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_dead_letter_pr(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  t.mock_command("--json comments", {
    stdout = '{"comments":[' .. table.concat(rendered, ",") .. "]}\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_dead_letter_open_pr_issue_event_stale_skips_after_rederive = function()
    local event = issue({ labels = { "fkst-dev:implementing" } })
    local proposal_id = core.proposal_id(event.repo, event.number)
    mock_dead_letter_issue({
      core.state_marker(proposal_id, "reviewing", event.dedup_key),
    })

    local result = run_dead_letter({
      queue = "github-proxy.github_entity_changed",
      payload = event,
    }, opts("dead-letter-open-pr-stale"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh issue view"), 1)
  end,

  test_dead_letter_stale_ready_event_skips_after_rederive = function()
    local event = ready()
    mock_dead_letter_issue({
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
    })

    local result = run_dead_letter({
      queue = "devloop_ready",
      payload = event,
    }, opts("dead-letter-stale"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh issue view"), 1)
  end,

  test_dead_letter_parks_still_current_ready_event = function()
    local event = ready()
    mock_dead_letter_issue({
      core.state_marker(event.proposal_id, "ready", event.dedup_key),
    })

    local result = run_dead_letter({
      event = {
        queue = "devloop_ready",
        payload = event,
      },
    }, opts("dead-letter-park"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local parked = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.eq(parked.payload.repo, "owner/repo")
    t.eq(parked.payload.issue_number, "42")
    t.eq(parked.payload.source_ref.ref, "owner/repo#issue/42")
    t.eq(parked.payload.dedup_key, "dead-letter/comment/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z")
    t.is_true(parked.payload.body:find("fkst:github-devloop:dead%-letter:v1") ~= nil)
    t.is_true(parked.payload.body:find("Original queue: devloop_ready", 1, true) ~= nil)
  end,

  test_dead_letter_existing_park_marker_is_idempotent = function()
    local event = ready()
    mock_dead_letter_issue({
      core.state_marker(event.proposal_id, "ready", event.dedup_key),
      core.dead_letter_marker(event.proposal_id, "devloop_ready", event.dedup_key, "ready", event.dedup_key),
    })

    local result = run_dead_letter({
      queue = "devloop_ready",
      payload = event,
    }, opts("dead-letter-idempotent"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_dead_letter_parks_review_converge_on_pr_thread = function()
    local event = review_unresolved()
    local version = reviewing().version
    mock_dead_letter_pr({
      core.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", version, "dev"),
      core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", version),
    })

    local result = run_dead_letter({
      queue = "consensus.consensus_converge",
      payload = event,
    }, opts("dead-letter-pr-review"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local parked = find_raise(result.raises, "github-proxy.github_pr_comment_request")
    t.eq(parked.payload.repo, "owner/repo")
    t.eq(parked.payload.pr_number, "7")
    t.eq(parked.payload.source_ref.ref, "owner/repo#pr/7")
    t.is_true(parked.payload.body:find('proposal="github-devloop/issue/owner/repo/42"', 1, true) ~= nil)
    t.eq(count_calls("gh pr view"), 1)
  end,
}
