local devloop_base = require("devloop.base")
local graph = require("testkit.graph")
local gh_argv = require("testkit.gh_argv_mock")
local t = fkst.test
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local author_policy = require("testkit.github_author_policy")

local repo = "owner/repo"
local updated_at = "2026-06-03T01:02:03Z"
local intake_selector = "title,body,createdAt,updatedAt,labels,comments,state,assignees,author"
local state_selector = "title,createdAt,updatedAt,labels,state,comments,assignees,author"

local function encode_labels(labels)
  local encoded = {}
  for _, label in ipairs(labels or {}) do
    table.insert(encoded, string.format('{"name":"%s"}', label))
  end
  return table.concat(encoded, ",")
end

local function encode_assignees(assignees)
  local encoded = {}
  for _, login in ipairs(assignees or {}) do
    table.insert(encoded, string.format('{"login":"%s"}', login))
  end
  return table.concat(encoded, ",")
end

local function poll_issue(number, labels, assignees)
  return string.format(
    '[[{"number":%d,"title":"Crash replay issue","html_url":"https://github.example/owner/repo/issues/%d","updated_at":"%s","state":"open","author":{"login":"fkst-test-bot"},"labels":[%s],"assignees":[%s]}]]\n',
    number,
    number,
    updated_at,
    encode_labels(labels),
    encode_assignees(assignees)
  )
end

local function mock_env(claim_mode)
  author_policy.mock_env(t, nil, { times = 64 })
  for _ = 1, 64 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_CLAIM_MODE"), {
      stdout = claim_mode,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 3 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_PROXY_POLL_LABEL_PREFIX"', {
      stdout = "fkst-dev:",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_PROXY_REPLAY_BUDGET"', {
      stdout = "10",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_poll_round(number, labels, assignees)
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/issues?state=open&per_page=100'", {
    stdout = poll_issue(number, labels, assignees),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&per_page=100'", {
    stdout = "[[]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_view_command(number, selector, response)
  t.mock_command(
    "gh issue view " .. tostring(number) .. " --repo " .. repo .. " --json '" .. selector .. "'",
    response
  )
end

local function mock_issue_view(number, labels, assignees)
  local fields = {
    repo = repo,
    number = number,
    title = "Crash replay issue",
    body = "",
    updated_at = updated_at,
    state = "OPEN",
    labels = labels,
    comments = {},
    assignees = assignees,
    author_login = "fkst-test-bot",
  }
  mock_issue_view_command(number, intake_selector, {
    stdout = entity_read_mocks.issue_view_stdout(fields),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_claim_verification(number, labels, assignees, claim_mode)
  local selector = claim_mode == "label" and "assignees,author,labels" or "assignees,author"
  local fields = {
    repo = repo,
    number = number,
    labels = labels,
    assignees = assignees,
    author_login = "fkst-test-bot",
  }
  mock_issue_view_command(number, selector, {
    stdout = entity_read_mocks.issue_view_stdout(fields),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_judge_failure(number)
  mock_issue_view_command(number, intake_selector, {
    stdout = "",
    stderr = "forced terminal intake consumer failure",
    exit_code = 1,
  })
end

local function mock_observe_skip(number, labels, assignees)
  local fields = {
    repo = repo,
    number = number,
    title = "Crash replay issue",
    updated_at = updated_at,
    state = "OPEN",
    labels = labels,
    comments = {},
    assignees = assignees,
    author_login = "fkst-test-bot",
  }
  mock_issue_view_command(number, state_selector, {
    stdout = entity_read_mocks.issue_view_stdout(fields),
    stderr = "",
    exit_code = 0,
  })
end

local function poll_event(round)
  return {
    queue = "github-proxy.github_poll_tick",
    payload = {},
    ts = round,
    source_ref = {
      kind = "cron",
      reference = "claim-crash-replay/" .. tostring(round),
    },
  }
end

local function count_claim_writes(claim_mode)
  local count = 0
  local flag = claim_mode == "label" and "--add-label" or "--add-assignee"
  local value = claim_mode == "label" and "fkst-dev:claimed" or "fkst-test-bot"
  for _, call in ipairs(t.command_calls()) do
    if gh_argv.call_contains(call, flag, value) then
      count = count + 1
    end
  end
  return count
end

local function require_consumer_failure(trace, round)
  t.eq(trace.status, "quiescent")
  local step = graph.find_delivery(trace, {
    queue = "github-devloop-intake.devloop_intake_candidate",
    consumer = "github-devloop-intake-default.intake_judge",
  })
  if step == nil then
    local deliveries = {}
    for _, item in ipairs(trace.steps or {}) do
      table.insert(deliveries, table.concat({
        tostring(item.queue),
        tostring(item.consumer),
        tostring(item.exit_code),
        tostring(#(item.raises or {})),
        tostring(item.error),
      }, "->"))
    end
    local calls = {}
    for _, call in ipairs(t.command_calls()) do
      table.insert(calls, gh_argv.call_rendered(call))
    end
    error("missing intake consumer delivery round=" .. tostring(round)
      .. " trace=" .. table.concat(deliveries, ",")
      .. " calls=" .. table.concat(calls, "|"), 2)
  end
  t.eq(step.exit_code, 1)
end

local function run_claim_crash_replay(claim_mode, number)
  local claimed_labels = claim_mode == "label" and { "fkst-dev:claimed" } or {}
  local claimed_assignees = claim_mode == "label" and {} or { "fkst-test-bot" }
  mock_env(claim_mode)

  mock_poll_round(number, {}, {})
  mock_issue_view(number, {}, {})
  if claim_mode == "label" then
    t.mock_command("gh issue edit " .. tostring(number) .. " --repo " .. repo .. " --add-label fkst-dev:claimed", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  else
    t.mock_command("gh issue edit " .. tostring(number) .. " --repo " .. repo .. " --add-assignee fkst-test-bot", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  mock_claim_verification(number, claimed_labels, claimed_assignees, claim_mode)
  mock_judge_failure(number)
  mock_observe_skip(number, claimed_labels, claimed_assignees)
  local first = graph.run(poll_event(1), { max_steps = 8 })
  require_consumer_failure(first, 1)
  t.eq(count_claim_writes(claim_mode), 1)

  mock_poll_round(number, claimed_labels, claimed_assignees)
  mock_issue_view(number, claimed_labels, claimed_assignees)
  mock_judge_failure(number)
  mock_observe_skip(number, claimed_labels, claimed_assignees)
  local second = graph.run(poll_event(2), { max_steps = 8 })
  require_consumer_failure(second, 2)
  t.eq(count_claim_writes(claim_mode), 1)

  mock_poll_round(number, claimed_labels, claimed_assignees)
  mock_issue_view(number, claimed_labels, claimed_assignees)
  mock_judge_failure(number)
  mock_observe_skip(number, claimed_labels, claimed_assignees)
  local third = graph.run(poll_event(3), { max_steps = 8 })
  require_consumer_failure(third, 3)
  graph.assert_covers(third, {
    "github-proxy.github_entity_changed -> github-devloop-intake.admission",
    "github-devloop-intake.devloop_intake_candidate -> github-devloop-intake-default.intake_judge",
  })
  local replay = graph.require_raise(third, "github-proxy.github_entity_changed", function(raised)
    return tonumber(raised.payload and raised.payload.number) == number
  end)
  t.eq(replay.payload.dedup_key, repo .. "#issue#" .. tostring(number) .. "@" .. updated_at .. "/poll/3")
end

return {
  test_run_graph_replays_self_assignee_claim_after_repeated_consumer_failures = function()
    run_claim_crash_replay("assignee", 42)
  end,

  test_run_graph_replays_claim_label_after_repeated_consumer_failures = function()
    run_claim_crash_replay("label", 43)
  end,
}
