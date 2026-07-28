local h = require("tests.proxy_integration_helpers")
local t = h.t

local repo = "owner/x"
local issue_number = 42
local updated_at = "2026-06-03T01:02:03Z"
local coalescing_run_opts = h.opts("poll-observation-coalescing")
local truncated_run_opts = h.opts("poll-observation-truncated")

local function source_row()
  return {
    kind = "external",
    reference = repo .. "#issue/" .. tostring(issue_number),
  }
end

local function observe_snapshot(deliveries, dead_letters)
  return {
    schema_version = 1,
    generated_at_ms = 1781830860000,
    source = {
      durable_root = "/tmp/fkst-durable",
      database = "/tmp/fkst-durable/delivery.redb",
      read_semantics = "single read transaction",
      history_semantics = "delivery queue snapshot only",
    },
    limits = { max_deliveries = 10000, max_dead_letters = 10000 },
    truncated = { deliveries = false, dead_letters = false },
    queues = json.decode("[]"),
    deliveries = deliveries or json.decode("[]"),
    dead_letters = dead_letters or json.decode("[]"),
  }
end

local function terminal_row()
  return {
    delivery_id = "delivery/v3/intake/42",
    queue = "github-devloop-intake.devloop_intake_candidate",
    dept = "github-devloop-intake-default.intake_judge",
    source = source_row(),
    attempts = 1,
    permanent = true,
    replayable = false,
    dead_at_ms = 1781830861000,
  }
end

local function live_row()
  return {
    delivery_id = "live-intake-42",
    queue = "github-devloop-intake.devloop_intake_candidate",
    dept = "github-devloop-intake-default.intake_judge",
    source = source_row(),
    status = "retrying",
  }
end

local function mock_poll(snapshot)
  t.mock_observe(snapshot)
  h.mock_repo_env()
  h.mock_poll_label_prefix_env("fkst-dev:")
  h.mock_proxy_replay_budget_env("1")
  h.mock_issue_list(string.format(
    '[[{"number":%d,"title":"Managed issue","html_url":"https://github.example/owner/x/issues/%d","updated_at":"%s","state":"open","labels":[{"name":"fkst-dev:blocked"}],"assignees":[{"login":"fkst-test-bot"}]}]]\n',
    issue_number,
    issue_number,
    updated_at
  ))
  h.mock_pr_list("[[]]\n")
end

local function mock_mixed_poll(snapshot)
  t.mock_observe(snapshot)
  h.mock_repo_env()
  h.mock_poll_label_prefix_env("fkst-dev:")
  h.mock_proxy_replay_budget_env("1")
  h.mock_issue_list(string.format(
    '[[{"number":%d,"title":"Managed issue","html_url":"https://github.example/owner/x/issues/%d","updated_at":"%s","state":"open","labels":[{"name":"fkst-dev:blocked"}],"assignees":[{"login":"fkst-test-bot"}]},{"number":43,"title":"Fresh issue","html_url":"https://github.example/owner/x/issues/43","updated_at":"%s","state":"open","labels":[],"assignees":[]}]]\n',
    issue_number,
    issue_number,
    updated_at,
    updated_at
  ))
  h.mock_pr_list("[[]]\n")
end

local function poll(ts, snapshot)
  mock_poll(snapshot)
  local result = t.run_department("departments/github_poll/main.lua", {
    queue = "github_poll_tick",
    payload = {},
    ts = ts,
  }, coalescing_run_opts)
  if result.exit_code ~= 0 then
    error(result.error)
  end
  t.eq(#result.raises, 1)
  t.eq(result.raises[1].queue, "github_issue_observed")
  return result.raises[1].payload.dedup_key
end

return {
  test_observation_key_tracks_authoritative_replay_lineage_instead_of_poll_time = function()
    mock_poll(observe_snapshot())
    local seeded = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-seed",
    }, coalescing_run_opts)
    t.eq(seeded.exit_code, 0)
    t.eq(seeded.raises[1].queue, "github_entity_changed")

    local absent_first = poll("poll-1", observe_snapshot())
    local absent_second = poll("poll-2", observe_snapshot())
    t.eq(absent_first, "intake-replay-observation/external/owner/x#issue/42/terminal-absent/inactive")
    t.eq(absent_second, absent_first)

    local terminal_live = poll("poll-3", observe_snapshot({ live_row() }, { terminal_row() }))
    t.eq(
      terminal_live,
      "intake-replay-observation/external/owner/x#issue/42/terminal/delivery/v3/intake/42/attempts/1/live-present"
    )

    local terminal_inactive = poll("poll-4", observe_snapshot(nil, { terminal_row() }))
    t.eq(
      terminal_inactive,
      "intake-replay-observation/external/owner/x#issue/42/terminal/delivery/v3/intake/42/attempts/1/inactive"
    )
    t.is_true(terminal_inactive ~= terminal_live)
  end,

  test_truncated_observation_preserves_fresh_work_and_skips_recovery = function()
    mock_poll(observe_snapshot())
    local seeded = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-truncated-seed",
    }, truncated_run_opts)
    t.eq(seeded.exit_code, 0)
    t.eq(seeded.raises[1].queue, "github_entity_changed")

    local truncated = observe_snapshot()
    truncated.truncated.dead_letters = true
    mock_mixed_poll(truncated)
    local result = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-truncated",
    }, truncated_run_opts)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github_entity_changed")
    t.eq(result.raises[1].payload.number, 43)
  end,
}
