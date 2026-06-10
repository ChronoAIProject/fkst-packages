local h = require("tests.devloop_helpers")
local core = h.core
local t = h.t

local function assert_preamble_slots(prompt)
  t.is_true(prompt:find("Write all output in English; quote code identifiers and cited originals verbatim.", 1, true) ~= nil)
  t.is_true(prompt:find("Before judging, identify the established theory or industry best practice governing this problem class", 1, true) ~= nil)
  t.is_true(prompt:find("Before judging, fetch and read the COMPLETE comment stream of the subject issue/PR via the source_ref", 1, true) ~= nil)
end

local function prompt_issue()
  return {
    title = "Implement decision recorder",
    body = "Issue body",
    comments = {
      { body = "Previous note", author_login = "fkst-test-bot" },
    },
  }
end

local function issue_list_json(count)
  local items = {}
  for n = 1, count do
    table.insert(items, string.format(
      '{"number":%d,"title":"Issue title number %d that is intentionally long enough to trim after sixty characters","labels":[{"name":"fkst-dev:thinking"}]}',
      n,
      n
    ))
  end
  return "[" .. table.concat(items, ",") .. "]"
end

local function pr_list_json(count)
  local items = {}
  for n = 1, count do
    table.insert(items, string.format(
      '{"number":%d,"title":"PR title number %d","labels":[{"name":"fkst-dev:reviewing"}]}',
      n + 100,
      n
    ))
  end
  return "[" .. table.concat(items, ",") .. "]"
end

local function mock_board_lists(issue_count, pr_count)
  t.mock_command("gh issue list --repo 'owner/repo' --state open --limit 100 --json number,title,labels", {
    stdout = issue_list_json(issue_count),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr list --repo 'owner/repo' --state open --limit 100 --json number,title,labels", {
    stdout = pr_list_json(pr_count),
    stderr = "",
    exit_code = 0,
  })
end

local function count_calls(needle)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find(needle, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function find_raise(raises, queue)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      return raised
    end
  end
  return nil
end

return {
  test_devloop_prompt_preamble_language_env = function()
    t.eq(core.read_env_command("FKST_OUTPUT_LANG"), 'printf %s "$FKST_OUTPUT_LANG"')
    t.eq(core.output_language(function(_cmd)
      return { stdout = "zh", stderr = "", exit_code = 0 }
    end), "zh")
    t.eq(core.output_language(function(_cmd)
      return { stdout = "unknown", stderr = "", exit_code = 0 }
    end), "en")
    t.is_true(core.prompt_preamble(function(_cmd)
      return { stdout = "zh", stderr = "", exit_code = 0 }
    end):find("Write all prose output in Simplified Chinese", 1, true) ~= nil)
  end,

  test_devloop_role_prompts_include_judgment_preamble = function()
    local issue = prompt_issue()
    local prompts = {
      core.build_intake_prompt("github-devloop/issue/owner/repo/42", issue),
      core.build_implement_prompt("github-devloop/issue/owner/repo/42", issue, "Approved framing."),
      core.build_fix_prompt({
        proposal_id = "github-devloop/issue/owner/repo/42",
        review_proposal_id = core.pr_review_proposal_id("owner/repo", 7, "version", "abcdef123456"),
        reviewed_head_sha = "abcdef123456",
      }, issue, "Review feedback.", "Approved framing."),
      core.build_decompose_prompt({
        proposal_id = "github-devloop/issue/owner/repo/42",
        source_ref = { kind = "external", ref = "owner/repo#pr/7" },
        round = 4,
      }, issue),
      core.build_review_meta_prompt({
        proposal_id = "github-devloop/issue/owner/repo/42",
        review_proposal_id = core.pr_review_proposal_id("owner/repo", 7, "version", "abcdef123456"),
      }, issue),
      core.build_sync_conflict_prompt({
        repo = "owner/repo",
        upstream_branch = "dev",
        integration_branch = "integration/dev",
        upstream_sha = "abcdef123456",
        integration_sha = "123456abcdef",
      }),
    }

    for _, prompt in ipairs(prompts) do
      assert_preamble_slots(prompt)
      t.is_nil(prompt:find("{{", 1, true))
    end
  end,

  test_board_digest_in_thinking_proposal_is_bounded_and_cached_per_tick = function()
    h.mock_bot_env()
    h.mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {})
    mock_board_lists(55, 10)

    local event = {
      queue = "github-proxy.github_entity_changed",
      ts = "2026-06-10T01:02:03Z",
      payload = h.issue(),
    }
    local opts = h.opts("board-digest-cache")
    local first = t.run_department("departments/observe_issue/main.lua", event, opts)
    h.mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {})
    local second = t.run_department("departments/observe_issue/main.lua", event, opts)
    local proposal = find_raise(first.raises, "consensus.proposal").payload

    t.is_true(proposal.body:find("> BEGIN UNTRUSTED ISSUE DATA", 1, true) ~= nil)
    t.is_true(proposal.body:find("Open items snapshot:", 1, true) ~= nil)
    t.is_true(proposal.body:find("#1 [fkst-dev:thinking] Issue title number 1", 1, true) ~= nil)
    t.is_nil(proposal.body:find("#101 ", 1, true))
    t.eq(count_calls("gh issue list --repo 'owner/repo' --state open --limit 100 --json number,title,labels"), 1)
    t.eq(count_calls("gh pr list --repo 'owner/repo' --state open --limit 100 --json number,title,labels"), 1)
    t.eq(find_raise(second.raises, "consensus.proposal").payload.body, proposal.body)
  end,
}
