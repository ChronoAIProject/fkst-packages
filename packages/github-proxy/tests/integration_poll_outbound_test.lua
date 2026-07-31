local h = require("tests.proxy_integration_helpers")
local sha256 = require("contract.sha256")
local t = h.t
local core = h.core
local issue_list_json = h.issue_list_json
local pr_list_json = h.pr_list_json
local runtime_root = h.runtime_root
local opts = h.opts
local mock_repo_env = h.mock_repo_env
local mock_proxy_replay_budget_env = h.mock_proxy_replay_budget_env
local mock_poll_label_prefix_env = h.mock_poll_label_prefix_env
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_issue_list = h.mock_issue_list
local mock_pr_list = h.mock_pr_list
local mock_poll = h.mock_poll
local json_string = h.json_string
local comment_json = h.comment_json
local mock_comment_view = h.mock_comment_view
local mock_comment_view_failure = h.mock_comment_view_failure
local mock_comment_write = h.mock_comment_write
local mock_pr_comment_view = h.mock_pr_comment_view
local mock_pr_comment_write = h.mock_pr_comment_write
local calls_matching = h.calls_matching
local count_calls = h.count_calls
local capture_comment_department_logs = h.capture_comment_department_logs
local long_dedup = h.long_dedup
local reviewing_marker = h.reviewing_marker
local pr_json = h.poll_pr_json
local pr_list_many_json = h.poll_pr_list_many_json
local issue_json = h.poll_issue_json
local issue_list_from = h.poll_issue_list_from
local pr_list_from = h.poll_pr_list_from
local numbers = h.changed_numbers
local observed_issue_raises = h.observed_issue_raises
local changed_raises = h.changed_raises
local find_entity_raise = h.find_entity_raise
local assert_observed_issue = h.assert_observed_issue

local function allocated_poll_epoch(timestamp, sub_epoch)
  return tostring(timestamp) .. "/sub-epoch/" .. tostring(sub_epoch)
end
local issue_comment_create = "gh api --method POST repos/owner/x/issues/42/comments"

local function delivery_snapshot(deliveries, dead_letters)
  return {
    schema_version = 1,
    generated_at_ms = 1785574920000,
    source = {
      durable_root = "/tmp/fkst-durable",
      database = "/tmp/fkst-durable/delivery.redb",
      read_semantics = "single read transaction",
      history_semantics = "mutable delivery queue snapshot",
    },
    limits = { max_deliveries = 10000, max_dead_letters = 10000 },
    truncated = { deliveries = false, dead_letters = false },
    queues = json.decode("[]"),
    deliveries = deliveries or json.decode("[]"),
    dead_letters = dead_letters or json.decode("[]"),
  }
end

local function poll_delivery_payload_summary(dedup_key)
  return {
    schema = "github-proxy.v1",
    dedup_key = dedup_key,
    digest = string.rep("b", 64),
    bytes = 128,
  }
end

local function poll_delivery_source()
  return {
    kind = "cron",
    reference = "github-proxy.github_poll/slot/1785574800000",
  }
end

local function mock_poll_env(replay_budget, label_prefix)
  mock_repo_env()
  mock_poll_label_prefix_env(label_prefix or "adapter-")
  if replay_budget ~= nil then
    mock_proxy_replay_budget_env(replay_budget)
  end
end

return {
  test_inbound_poll_raises_issue_and_pr_then_cache_hit = function()
    local event = { queue = "github_poll_tick", ts = "2026-07-30T01:02:03Z", payload = {} }
    local run_opts = opts("inbound-cache-hit")

    mock_poll()
    local first = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(first.exit_code, 0)
    t.eq(first.raises[1].queue, "github_entity_changed")
    t.eq(first.raises[1].payload.type, "issue")
    t.eq(first.raises[1].payload.repo, "owner/x")
    t.eq(first.raises[1].payload.number, 42)
    t.eq(first.raises[1].payload.title, "Bridge issue")
    t.eq(first.raises[1].payload.updated_at, "2026-06-03T01:02:03Z")
    t.eq(first.raises[1].payload.labels[1], "adapter-enabled")
    t.eq(first.raises[1].payload.labels[2], "bug")
    t.is_nil(first.raises[1].payload.view_cache_key)
    t.eq(
      first.raises[1].payload.dedup_key,
      "owner/x#issue#42@2026-06-03T01:02:03Z"
    )
    t.eq(first.raises[1].payload.poll_token, allocated_poll_epoch(event.ts, 0))
    t.eq(first.raises[1].payload.source_ref.kind, "external")
    t.eq(first.raises[1].payload.source_ref.ref, "owner/x#issue/42")
    t.eq(first.raises[2].queue, "github_entity_changed")
    t.eq(first.raises[2].payload.type, "pr")
    t.eq(first.raises[2].payload.repo, "owner/x")
    t.eq(first.raises[2].payload.number, 7)
    t.eq(first.raises[2].payload.title, "Bridge PR")
    t.eq(first.raises[2].payload.url, "https://github.example/owner/x/pull/7")
    t.eq(first.raises[2].payload.state, "OPEN")
    t.eq(first.raises[2].payload.labels[1], "review")
    t.eq(first.raises[2].payload.updated_at, "2026-06-03T02:03:04Z")
    t.is_nil(first.raises[2].payload.view_cache_key)
    t.eq(first.raises[2].payload.dedup_key, "owner/x#pr#7@2026-06-03T02:03:04Z")
    t.eq(first.raises[2].payload.poll_token, allocated_poll_epoch(event.ts, 0))
    t.eq(first.raises[2].payload.source_ref.kind, "external")
    t.eq(first.raises[2].payload.source_ref.ref, "owner/x#pr/7")
    t.is_nil(first.raises[3])

    mock_poll()
    local second = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 1)
    t.eq(second.raises[1].queue, "github_entity_changed")
    t.eq(second.raises[1].payload.number, 42)
    t.eq(
      second.raises[1].payload.dedup_key,
      first.raises[1].payload.dedup_key
    )
    t.eq(second.raises[1].payload.poll_token, allocated_poll_epoch(event.ts, 1))
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues?state=open&per_page=100"), 2)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/pulls?state=open&per_page=100"), 2)
  end,

  test_inbound_poll_re_raises_when_updated_at_changes = function()
    local event = { queue = "github_poll_tick", payload = {} }
    local run_opts = opts("inbound-updated-at-change")

    mock_poll()
    local first = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 2)

    mock_poll(
      issue_list_json("2026-06-04T05:06:07Z"),
      pr_list_json("2026-06-04T06:07:08Z")
    )
    local changed = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(changed.exit_code, 0)
    t.eq(#changed.raises, 2)
    t.eq(changed.raises[1].payload.type, "issue")
    t.eq(changed.raises[1].payload.updated_at, "2026-06-04T05:06:07Z")
    t.eq(
      changed.raises[1].payload.dedup_key,
      "owner/x#issue#42@2026-06-04T05:06:07Z"
    )
    t.eq(changed.raises[2].payload.type, "pr")
    t.eq(changed.raises[2].payload.updated_at, "2026-06-04T06:07:08Z")
    t.eq(changed.raises[2].payload.dedup_key, "owner/x#pr#7@2026-06-04T06:07:08Z")
  end,

  test_inbound_poll_does_not_re_raise_closed_lifecycle_state_when_updated_at_changes = function()
    local event = { queue = "github_poll_tick", payload = {} }
    local run_opts = opts("inbound-closed-change")

    mock_poll()
    local first = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 2)
    t.eq(first.raises[1].payload.type, "issue")
    t.eq(first.raises[1].payload.state, "OPEN")

    mock_poll(
      "[]\n",
      pr_list_json()
    )
    local closed = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(closed.exit_code, 0)
    t.eq(#closed.raises, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues?state=open&per_page=100"), 2)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/pulls?state=open&per_page=100"), 2)
  end,

  test_inbound_poll_open_pr_coverage_is_not_limited_by_terminal_volume = function()
    local event = { queue = "github_poll_tick", payload = {} }

    mock_poll_env("100")
    mock_issue_list("[]\n")
    mock_pr_list(pr_list_many_json(35, 12, "2026-06-02T00:00:00Z"))
    local result = t.run_department("departments/github_poll/main.lua", event, opts("open-pr-coverage", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "100",
    }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 36)
    local target = find_entity_raise(result.raises, "pr", 12)
    t.is_true(target ~= nil)
    t.eq(target.queue, "github_entity_changed")
    t.eq(target.payload.updated_at, "2026-06-02T00:00:00Z")
    t.eq(target.payload.dedup_key, "owner/x#pr#12@2026-06-02T00:00:00Z")
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues?state=open&per_page=100"), 1)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/pulls?state=open&per_page=100"), 1)
    t.eq(calls_matching("--state all")[1], nil)
  end,

  test_inbound_poll_paces_cold_replay_and_continues_next_cycle = function()
    local event = { queue = "github_poll_tick", payload = {} }
    local run_opts = opts("replay-budget", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "2",
    })
    local issues = issue_list_from({
      issue_json(44, "2026-06-03T01:04:00Z"),
      issue_json(42, "2026-06-03T01:02:00Z"),
      issue_json(43, "2026-06-03T01:03:00Z"),
    })

    mock_poll_env("2")
    mock_issue_list(issues)
    mock_pr_list("[]\n")
    local first = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 2)
    t.eq(numbers(first.raises), "42,43")

    mock_poll_env("2")
    mock_issue_list(issues)
    mock_pr_list("[]\n")
    local second = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 3)
    t.eq(#changed_raises(second.raises), 1)
    t.eq(changed_raises(second.raises)[1].payload.number, 44)
    t.eq(#observed_issue_raises(second.raises), 2)
  end,

  test_inbound_poll_replay_budget_is_shared_across_issue_and_pr_lanes = function()
    local event = { queue = "github_poll_tick", payload = {} }
    local run_opts = opts("shared-replay-budget", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "2",
    })
    local issues = issue_list_from({
      issue_json(42, "2026-06-03T01:02:00Z"),
      issue_json(44, "2026-06-03T01:04:00Z"),
    })
    local prs = pr_list_from({
      pr_json(7, "2026-06-03T01:03:00Z"),
      pr_json(8, "2026-06-03T01:05:00Z"),
    })

    mock_poll_env("2")
    mock_issue_list(issues)
    mock_pr_list(prs)
    local first = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 2)
    t.eq(first.raises[1].payload.type, "issue")
    t.eq(first.raises[1].payload.number, 42)
    t.eq(first.raises[2].payload.type, "pr")
    t.eq(first.raises[2].payload.number, 7)

    mock_poll_env("2")
    mock_issue_list(issues)
    mock_pr_list(prs)
    local second = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 3)
    local changed = changed_raises(second.raises)
    t.eq(#changed, 2)
    t.eq(changed[1].payload.type, "issue")
    t.eq(changed[1].payload.number, 44)
    t.eq(changed[2].payload.type, "pr")
    t.eq(changed[2].payload.number, 8)
    t.eq(#observed_issue_raises(second.raises), 1)
  end,

  test_inbound_poll_replay_budget_tie_breaks_shared_lanes_deterministically = function()
    local event = { queue = "github_poll_tick", payload = {} }
    local run_opts = opts("shared-replay-budget-tie", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "2",
    })
    local timestamp = "2026-06-03T01:02:00Z"
    local issues = issue_list_from({
      issue_json(42, timestamp),
      issue_json(44, timestamp),
    })
    local prs = pr_list_from({
      pr_json(42, timestamp),
      pr_json(43, timestamp),
    })

    mock_poll_env("2")
    mock_issue_list(issues)
    mock_pr_list(prs)
    local first = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 2)
    t.eq(first.raises[1].payload.type, "issue")
    t.eq(first.raises[1].payload.number, 42)
    t.eq(first.raises[2].payload.type, "pr")
    t.eq(first.raises[2].payload.number, 42)

    mock_poll_env("2")
    mock_issue_list(issues)
    mock_pr_list(prs)
    local second = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 3)
    local changed = changed_raises(second.raises)
    t.eq(#changed, 2)
    t.eq(changed[1].payload.type, "pr")
    t.eq(changed[1].payload.number, 43)
    t.eq(changed[2].payload.type, "issue")
    t.eq(changed[2].payload.number, 44)
    t.eq(#observed_issue_raises(second.raises), 1)
  end,

  test_inbound_poll_defaults_cold_replay_budget_to_ten = function()
    local event = { queue = "github_poll_tick", payload = {} }
    local items = {}
    for number = 1, 11 do
      table.insert(items, issue_json(number, string.format("2026-06-03T01:%02d:00Z", number)))
    end

    mock_poll_env("")
    mock_issue_list(issue_list_from(items))
    mock_pr_list("[]\n")
    local result = t.run_department("departments/github_poll/main.lua", event, opts("default-replay-budget"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 10)
    t.eq(result.raises[1].payload.number, 1)
    t.eq(result.raises[10].payload.number, 10)
  end,

  test_inbound_poll_prioritizes_cached_fresh_changes_over_replay_budget = function()
    local event = { queue = "github_poll_tick", payload = {} }
    local run_opts = opts("fresh-before-replay", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "1",
    })

    mock_poll_env("1")
    mock_issue_list(issue_list_from({
      issue_json(42, "2026-06-03T01:02:00Z"),
    }))
    mock_pr_list("[]\n")
    local seeded = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(seeded.exit_code, 0)
    t.eq(#seeded.raises, 1)

    mock_poll_env("1")
    mock_issue_list(issue_list_from({
      issue_json(43, "2026-06-03T01:03:00Z"),
      issue_json(42, "2026-06-03T01:05:00Z"),
      issue_json(44, "2026-06-03T01:04:00Z"),
    }))
    mock_pr_list("[]\n")
    local changed = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(changed.exit_code, 0)
    t.eq(#changed.raises, 2)
    t.eq(numbers(changed.raises), "42,43")
  end,

  test_inbound_poll_prioritizes_cold_intake_candidates_over_replay_budget = function()
    local event = { queue = "github_poll_tick", payload = {}, ts = "poll-cold" }
    local run_opts = opts("cold-intake-before-replay", { FKST_GITHUB_PROXY_REPLAY_BUDGET = "1" })
    mock_poll_env("1")
    local intake = '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"bug"}],"assignees":[]}'
    mock_issue_list(issue_list_from({ issue_json(42, "2026-06-03T01:02:00Z"), issue_json(43, "2026-06-03T01:03:00Z"), intake }))
    mock_pr_list("[]\n")
    local result = t.run_department("departments/github_poll/main.lua", event, run_opts)
    t.eq(result.exit_code, 0) t.eq(#result.raises, 2)
    t.eq(numbers(result.raises), "50,42")
    t.eq(result.raises[1].queue, "github_entity_changed")
    t.eq(result.raises[1].payload.schema, "github-proxy.v1")
    t.eq(result.raises[1].payload.type, "issue")
    t.eq(result.raises[1].payload.repo, "owner/x")
    t.eq(result.raises[1].payload.number, 50)
    t.eq(result.raises[1].payload.state, "OPEN")
    t.eq(result.raises[1].payload.labels[1], "bug")
    t.eq(result.raises[1].payload.dedup_key, "owner/x#issue#50@2026-06-03T01:04:00Z")
    t.eq(result.raises[1].payload.source_ref.kind, "external")
    t.eq(result.raises[1].payload.source_ref.ref, "owner/x#issue/50")
  end,

  test_inbound_poll_level_replays_every_open_unassigned_issue_regardless_of_configured_prefix = function()
    local run_opts = opts("stateless-intake-level-replay", { FKST_GITHUB_PROXY_REPLAY_BUDGET = "1" })
    local intake = '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"bug"}],"assignees":[]}'
    local managed = issue_json(42, "2026-06-03T01:02:00Z")

    mock_poll_env("1", "fkst-class:")
    mock_issue_list(issue_list_from({ managed, intake }))
    mock_pr_list("[]\n")
    local first = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-1",
    }, run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 2)
    t.eq(numbers(first.raises), "50,42")
    t.eq(first.raises[1].payload.dedup_key, "owner/x#issue#50@2026-06-03T01:04:00Z")
    t.eq(first.raises[2].payload.dedup_key, "owner/x#issue#42@2026-06-03T01:02:00Z")

    mock_poll_env("1", "fkst-class:")
    mock_issue_list(issue_list_from({ managed, intake }))
    mock_pr_list("[]\n")
    local second = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-2",
    }, run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 2)
    local second_changed = changed_raises(second.raises)
    t.eq(#second_changed, 1)
    t.eq(second_changed[1].payload.number, 50)
    t.eq(second_changed[1].payload.dedup_key, first.raises[1].payload.dedup_key)
    local second_observed = observed_issue_raises(second.raises)
    t.eq(#second_observed, 1)
    t.eq(second_observed[1].payload.dedup_key, "github-issue-observed/owner/x/42/2026-06-03T01:02:00Z")

    mock_poll_env("1", "fkst-class:")
    mock_issue_list(issue_list_from({
      '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"fkst-class:expedite"},{"name":"bug"}],"assignees":[]}',
      managed,
    }))
    mock_pr_list("[]\n")
    local labelled = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-3",
    }, run_opts)
    t.eq(labelled.exit_code, 0)
    t.eq(#labelled.raises, 2)
    local labelled_changed = changed_raises(labelled.raises)
    t.eq(#labelled_changed, 1)
    t.eq(labelled_changed[1].payload.number, 50)
    t.eq(labelled_changed[1].payload.dedup_key, first.raises[1].payload.dedup_key)
    local labelled_observed = observed_issue_raises(labelled.raises)
    t.eq(#labelled_observed, 1)
    t.eq(labelled_observed[1].payload.dedup_key, second_observed[1].payload.dedup_key)

    mock_poll_env("1", "fkst-class:")
    mock_issue_list(issue_list_from({
      '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"fkst-class:expedite"},{"name":"bug"}],"assignees":[]}',
      managed,
    }))
    mock_pr_list("[]\n")
    local cached_labelled = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-4",
    }, run_opts)
    t.eq(cached_labelled.exit_code, 0)
    t.eq(#cached_labelled.raises, 2)
    local cached_labelled_changed = changed_raises(cached_labelled.raises)
    t.eq(#cached_labelled_changed, 1)
    t.eq(cached_labelled_changed[1].payload.number, 50)
    t.eq(cached_labelled_changed[1].payload.dedup_key, first.raises[1].payload.dedup_key)
    local cached_labelled_observed = observed_issue_raises(cached_labelled.raises)
    t.eq(#cached_labelled_observed, 1)
    t.eq(cached_labelled_observed[1].payload.dedup_key, second_observed[1].payload.dedup_key)
  end,

  test_inbound_poll_rearms_a_permanent_delivery_once_and_reuses_the_live_generation = function()
    local run_opts = opts("post-dlq-level-rearm", { FKST_GITHUB_PROXY_REPLAY_BUDGET = "1" })
    local intake = '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"bug"}],"assignees":[]}'
    local base_key = "owner/x#issue#50@2026-06-03T01:04:00Z"
    local terminal_id = "delivery/v3/raised/queue/github-proxy.github_entity_changed/dept/github-devloop-intake.admission/dedup/base"
    local rearm_key = base_key .. "/rearm/" .. sha256.hex(terminal_id)
    local terminal = {
      delivery_id = terminal_id,
      queue = "github-proxy.github_entity_changed",
      dept = "github-devloop-intake.admission",
      source = poll_delivery_source(),
      observed_at_ms = 1785574800000,
      not_before_ms = 1785574800000,
      dead_at_ms = 1785574860000,
      attempts = 3,
      redrive_count = 3,
      replayable = false,
      permanent = true,
      payload = poll_delivery_payload_summary(base_key),
      error_excerpt = "transient admission failure",
    }

    mock_poll_env("1", "fkst-class:")
    mock_issue_list(issue_list_from({ intake }))
    mock_pr_list("[]\n")
    t.mock_observe(delivery_snapshot(json.decode("[]"), { terminal }))
    local rearmed = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-after-dlq",
    }, run_opts)
    t.eq(rearmed.exit_code, 0)
    t.eq(#rearmed.raises, 1)
    t.eq(rearmed.raises[1].payload.dedup_key, rearm_key)
    t.eq(rearmed.raises[1].payload.poll_token, allocated_poll_epoch("poll-after-dlq", 0))

    local live = {
      delivery_id = "live-rearm-delivery",
      queue = "github-proxy.github_entity_changed",
      dept = "github-devloop-intake.admission",
      source = poll_delivery_source(),
      status = "in-flight",
      observed_at_ms = 1785574920000,
      not_before_ms = 1785574920000,
      attempt = 0,
      redrive_count = 0,
      lease_generation = 1,
      lease_until_ms = 1785574950000,
      fence_token = "live-rearm-delivery#1",
      subscriber_absent_since_ms = nil,
      payload = poll_delivery_payload_summary(rearm_key),
      last_error_excerpt = nil,
    }
    mock_poll_env("1", "fkst-class:")
    mock_issue_list(issue_list_from({ intake }))
    mock_pr_list("[]\n")
    t.mock_observe(delivery_snapshot({ live }, { terminal }))
    local coalesced = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-while-rearmed",
    }, run_opts)
    t.eq(coalesced.exit_code, 0)
    t.eq(#coalesced.raises, 1)
    t.eq(coalesced.raises[1].payload.dedup_key, rearm_key)
    t.eq(coalesced.raises[1].payload.poll_token, allocated_poll_epoch("poll-while-rearmed", 0))
  end,

  test_inbound_poll_emits_fresh_entity_when_delivery_rearm_snapshot_is_truncated = function()
    local run_opts = opts("truncated-rearm-keeps-fresh-polling", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "1",
    })
    local intake = '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"bug"}],"assignees":[]}'
    local truncated = delivery_snapshot(json.decode("[]"), json.decode("[]"))
    truncated.truncated.dead_letters = true

    mock_poll_env("1", "fkst-class:")
    mock_issue_list(issue_list_from({ intake }))
    mock_pr_list("[]\n")
    t.mock_observe(truncated)
    local result = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-with-truncated-rearm-snapshot",
    }, run_opts)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github_entity_changed")
    t.eq(result.raises[1].payload.number, 50)
    t.eq(result.raises[1].payload.dedup_key, "owner/x#issue#50@2026-06-03T01:04:00Z")
  end,

  test_inbound_poll_rejects_invalid_replay_budget = function()
    mock_poll_env("0")
    mock_issue_list()
    mock_pr_list()

    local result = t.run_department("departments/github_poll/main.lua", { queue = "github_poll_tick", payload = {} }, opts("invalid-replay-budget", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "0",
    }))
    t.eq(result.exit_code, 1)
  end,

  test_inbound_poll_continues_when_issue_list_fails = function()
    mock_repo_env()
    mock_issue_list("", 2, "forced issue list failure")
    mock_pr_list()

    local result = t.run_department("departments/github_poll/main.lua", { queue = "github_poll_tick", payload = {} }, opts("issue-list-fails"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github_entity_changed")
    t.eq(result.raises[1].payload.type, "pr")
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues?state=open&per_page=100"), 1)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/pulls?state=open&per_page=100"), 1)
  end,

  test_inbound_poll_continues_when_pr_list_fails = function()
    mock_repo_env()
    mock_issue_list()
    mock_pr_list("", 2, "forced pr list failure")

    local result = t.run_department("departments/github_poll/main.lua", { queue = "github_poll_tick", payload = {} }, opts("pr-list-fails"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github_entity_changed")
    t.eq(result.raises[1].payload.type, "issue")
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues?state=open&per_page=100"), 1)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/pulls?state=open&per_page=100"), 1)
  end,

  test_inbound_poll_rate_limit_failure_errors_for_retry = function()
    mock_repo_env()
    mock_issue_list("", 1, "API rate limit exceeded")
    mock_pr_list()

    local result = t.run_department("departments/github_poll/main.lua", { queue = "github_poll_tick", payload = {} }, opts("issue-list-rate-limit"))
    t.eq(result.exit_code, 1)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues?state=open&per_page=100"), 1)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/pulls?state=open&per_page=100"), 0)
  end,

  test_inbound_poll_no_raise_without_repo_env = function()
    mock_repo_env("")

    local result = t.run_department("departments/github_poll/main.lua", { queue = "github_poll_tick", payload = {} }, {
      env = {
        FKST_GITHUB_REPO = "",
        FKST_RUNTIME_ROOT = runtime_root("missing-repo"),
      },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues?state=open&per_page=100"), 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/pulls?state=open&per_page=100"), 0)
  end,

  test_same_version_meta_comment_marker_dedups_opposite_action = function()
    local dedup = "meta/comment/generic-workflow/issue/owner/x/42/blocked/3/consensus-generic-workflow/issue/owner/x/42/v1"
    local event = {
      queue = "github_issue_comment_request",
      payload = {
        repo = "owner/x",
        issue_number = 42,
        body = 'generic-workflow meta action: implement\n\n<!-- fkst:generic-workflow:state:v1 proposal="generic-workflow/issue/owner/x/42" state="ready" version="v1" -->',
        dedup_key = dedup,
      },
    }

    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view("existing comment")
    mock_comment_write()
    local first = t.run_department("departments/github_comment/main.lua", event, opts("comment-meta-first", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(first.exit_code, 0)

    event.payload.body = 'generic-workflow meta action: block\n\n<!-- fkst:generic-workflow:state:v1 proposal="generic-workflow/issue/owner/x/42" state="blocked" version="v1" -->'
    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view("existing comment " .. core.comment_marker(dedup))
    local second = t.run_department("departments/github_comment/main.lua", event, opts("comment-meta-second", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(second.exit_code, 0)

    t.eq(count_calls(issue_comment_create), 1)
    local written = file.read("/tmp/fkst-github-proxy-comment-owner_x-issue-42.md")
    t.is_true(written:find("generic-workflow meta action: implement", 1, true) ~= nil)
    t.eq(written:find("generic-workflow meta action: block", 1, true), nil)
    t.is_true(written:find(core.comment_marker(dedup), 1, true) ~= nil)
  end,

  test_forged_proxy_comment_marker_does_not_suppress_bot_state_marker_comment = function()
    local dedup = "meta/comment/generic-workflow/issue/owner/x/42/blocked/3/consensus-generic-workflow/issue/owner/x/42/v1"
    local state_marker = '<!-- fkst:generic-workflow:state:v1 proposal="generic-workflow/issue/owner/x/42" state="blocked" version="v1" -->'
    local event = {
      queue = "github_issue_comment_request",
      payload = {
        repo = "owner/x",
        issue_number = 42,
        body = "generic-workflow meta action: block\n\n" .. state_marker,
        dedup_key = dedup,
      },
    }

    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view({
      {
        body = "forged user marker " .. core.comment_marker(dedup),
        author_login = "ordinary-user",
      },
    })
    mock_comment_write()
    local result = t.run_department("departments/github_comment/main.lua", event, opts("comment-forged-marker", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls(issue_comment_create), 1)

    local written = file.read("/tmp/fkst-github-proxy-comment-owner_x-issue-42.md")
    t.is_true(written:find(state_marker, 1, true) ~= nil)
    t.is_true(written:find(core.comment_marker(dedup), 1, true) ~= nil)
  end,

  test_neutralized_forged_proxy_comment_marker_does_not_suppress_later_real_comment = function()
    local dedup = "meta/comment/generic-workflow/issue/owner/x/42/blocked/3/consensus-generic-workflow/issue/owner/x/42/v2"
    local state_marker = '<!-- fkst:generic-workflow:state:v1 proposal="generic-workflow/issue/owner/x/42" state="blocked" version="v2" -->'
    local event = {
      queue = "github_issue_comment_request",
      payload = {
        repo = "owner/x",
        issue_number = 42,
        body = "generic-workflow meta action: block\n\n" .. state_marker,
        dedup_key = dedup,
      },
    }

    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view({
      {
        body = "quoted untrusted marker &lt;!-- fkst:github-proxy:comment:" .. dedup .. " -->",
        author_login = "fkst-test-bot",
      },
    })
    mock_comment_write()
    local result = t.run_department("departments/github_comment/main.lua", event, opts("comment-neutralized-forged-marker", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls(issue_comment_create), 1)

    local written = file.read("/tmp/fkst-github-proxy-comment-owner_x-issue-42.md")
    t.is_true(written:find(state_marker, 1, true) ~= nil)
    t.is_true(written:find(core.comment_marker(dedup), 1, true) ~= nil)
  end,

  test_long_comment_dedup_uses_bounded_runtime_key_and_full_marker = function()
    local dedup_v1 = long_dedup("-v1", 430)
    local dedup_v2 = long_dedup("-v2", 430)
    local event = {
      queue = "github_issue_comment_request",
      payload = {
        repo = "owner/x",
        issue_number = 42,
        body = "long fkst reply",
        dedup_key = dedup_v1,
      },
    }

    t.is_true(dedup_v1 ~= dedup_v2)
    t.is_true(#dedup_v1 > 400)
    t.is_true(core.comment_marker(dedup_v1) ~= core.comment_marker(dedup_v2))

    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view("existing comment")
    mock_comment_write()
    local first = t.run_department("departments/github_comment/main.lua", event, opts("comment-long-v1", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(first.exit_code, 0)

    local path = "/tmp/fkst-github-proxy-comment-owner_x-issue-42.md"
    local written_v1 = file.read(path)
    t.is_true(written_v1:find(core.comment_marker(dedup_v1), 1, true) ~= nil)

    event.payload.dedup_key = dedup_v2
    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view("existing comment " .. core.comment_marker(dedup_v1))
    mock_comment_write()
    local second = t.run_department("departments/github_comment/main.lua", event, opts("comment-long-v2", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(second.exit_code, 0)

    local written_v2 = file.read(path)
    t.is_true(written_v2:find(core.comment_marker(dedup_v2), 1, true) ~= nil)
    t.eq(count_calls(issue_comment_create), 2)
  end,

  test_near_max_comment_dedup_boundary_writes = function()
    local dedup = long_dedup("-max", 512)
    local event = {
      queue = "github_issue_comment_request",
      payload = {
        repo = "owner/x",
        issue_number = 42,
        body = "max dedup reply",
        dedup_key = dedup,
      },
    }

    t.eq(#dedup, 512)
    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view("existing comment")
    mock_comment_write()
    local result = t.run_department("departments/github_comment/main.lua", event, opts("comment-long-max", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(result.exit_code, 0)

    local written = file.read("/tmp/fkst-github-proxy-comment-owner_x-issue-42.md")
    t.is_true(written:find(core.comment_marker(dedup), 1, true) ~= nil)
    t.eq(count_calls(issue_comment_create), 1)
  end,

  test_comment_request_uses_payload_repo = function()
    local event = {
      queue = "github_issue_comment_request",
      payload = {
        repo = "owner/payload",
        issue_number = 42,
        body = "payload repo reply",
        dedup_key = "payload-repo-reply",
      },
    }

    mock_repo_env("owner/env")
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view("existing comment")
    mock_comment_write()
    local result = t.run_department("departments/github_comment/main.lua", event, opts("comment-payload-repo", {
      FKST_GITHUB_REPO = "owner/env",
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(result.exit_code, 0)

    local view_calls = calls_matching("gh api --paginate --slurp repos/owner/payload/issues/42/comments?per_page=100")
    t.eq(#view_calls, 1)
    t.is_true(view_calls[1].rendered:find("repos/owner/payload/issues/42/comments", 1, true) ~= nil)
    local comment_calls = calls_matching("gh api --method POST")
    t.eq(#comment_calls, 1)
    t.is_true(comment_calls[1].rendered:find("repos/owner/payload/issues/42/comments", 1, true) ~= nil)
  end,

  test_comment_real_write_failure_errors_for_retry = function()
    local event = {
      queue = "github_issue_comment_request",
      payload = {
        repo = "owner/x",
        issue_number = 42,
        body = "fkst reply",
        dedup_key = "reply-failure",
      },
    }

    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view("existing comment")
    t.mock_command("gh api --method POST repos/owner/x/issues/42/comments --field body=/tmp/fkst-github-proxy-comment-owner_x-issue-42.md", {
      stdout = "",
      stderr = "forced comment failure",
      exit_code = 1,
    })

    local result = t.run_department("departments/github_comment/main.lua", event, opts("comment-write-fails", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(result.exit_code, 1)
    t.eq(count_calls(issue_comment_create), 1)
  end,

  test_comment_real_write_view_failure_errors_for_retry = function()
    local event = {
      queue = "github_issue_comment_request",
      payload = {
        repo = "owner/x",
        issue_number = 42,
        body = "fkst reply",
        dedup_key = "reply-view-failure",
      },
    }

    mock_repo_env()
    mock_write_env("1")
    mock_bot_env()
    mock_comment_view_failure()

    local result = t.run_department("departments/github_comment/main.lua", event, opts("comment-view-fails", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(result.exit_code, 1)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100"), 1)
    t.eq(count_calls(issue_comment_create), 0)
  end,
}
