local fixtures = require("tests.poll_outbound_test_helpers")
local h = fixtures.h
local sha256 = fixtures.sha256
local t = fixtures.t
local core = fixtures.core
local issue_list_json = fixtures.issue_list_json
local pr_list_json = fixtures.pr_list_json
local runtime_root = fixtures.runtime_root
local opts = fixtures.opts
local mock_repo_env = fixtures.mock_repo_env
local mock_proxy_replay_budget_env = fixtures.mock_proxy_replay_budget_env
local mock_poll_label_prefix_env = fixtures.mock_poll_label_prefix_env
local mock_write_env = fixtures.mock_write_env
local mock_bot_env = fixtures.mock_bot_env
local mock_issue_list = fixtures.mock_issue_list
local mock_pr_list = fixtures.mock_pr_list
local mock_poll = fixtures.mock_poll
local json_string = fixtures.json_string
local comment_json = fixtures.comment_json
local mock_comment_view = fixtures.mock_comment_view
local mock_comment_view_failure = fixtures.mock_comment_view_failure
local mock_comment_write = fixtures.mock_comment_write
local mock_pr_comment_view = fixtures.mock_pr_comment_view
local mock_pr_comment_write = fixtures.mock_pr_comment_write
local calls_matching = fixtures.calls_matching
local count_calls = fixtures.count_calls
local capture_comment_department_logs = fixtures.capture_comment_department_logs
local long_dedup = fixtures.long_dedup
local reviewing_marker = fixtures.reviewing_marker
local pr_json = fixtures.pr_json
local pr_list_many_json = fixtures.pr_list_many_json
local issue_json = fixtures.issue_json
local issue_list_from = fixtures.issue_list_from
local pr_list_from = fixtures.pr_list_from
local numbers = fixtures.numbers
local observed_issue_raises = fixtures.observed_issue_raises
local changed_raises = fixtures.changed_raises
local find_entity_raise = fixtures.find_entity_raise
local assert_observed_issue = fixtures.assert_observed_issue
local allocated_poll_epoch = fixtures.allocated_poll_epoch
local issue_comment_create = fixtures.issue_comment_create
local delivery_snapshot = fixtures.delivery_snapshot
local poll_delivery_payload_summary = fixtures.poll_delivery_payload_summary
local poll_delivery_source = fixtures.poll_delivery_source
local mock_poll_env = fixtures.mock_poll_env

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

  test_inbound_poll_reuses_stable_entity_version_dedup_keys_across_raise_paths = function()
    local run_opts = opts("stable-level-replay-dedup", { FKST_GITHUB_PROXY_REPLAY_BUDGET = "1" })
    local intake = '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"bug"}],"assignees":[]}'
    local managed = issue_json(42, "2026-06-03T01:02:00Z")

    local function poll(timestamp)
      mock_poll_env("1")
      mock_issue_list(issue_list_from({ managed, intake }))
      mock_pr_list("[]\n")
      local result = t.run_department("departments/github_poll/main.lua", {
        queue = "github_poll_tick",
        payload = {},
        ts = timestamp,
      }, run_opts)
      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 2)
      return result
    end

    poll("poll-stable-0")
    local first = poll("poll-stable-1")
    local second = poll("poll-stable-2")
    local first_changed = changed_raises(first.raises)
    local second_changed = changed_raises(second.raises)
    local first_observed = observed_issue_raises(first.raises)
    local second_observed = observed_issue_raises(second.raises)

    t.eq(#first_changed, 1)
    t.eq(#second_changed, 1)
    t.eq(first_changed[1].payload.number, 50)
    t.is_true(first_changed[1].payload.poll_token ~= second_changed[1].payload.poll_token)
    t.eq(first_changed[1].payload.dedup_key, second_changed[1].payload.dedup_key)
    t.eq(first_changed[1].payload.dedup_key, "owner/x#issue#50@2026-06-03T01:04:00Z")

    t.eq(#first_observed, 1)
    t.eq(#second_observed, 1)
    t.eq(first_observed[1].payload.number, 42)
    t.is_true(first_observed[1].payload.poll_token ~= second_observed[1].payload.poll_token)
    t.eq(first_observed[1].payload.dedup_key, second_observed[1].payload.dedup_key)
    t.eq(first_observed[1].payload.dedup_key, "owner/x#issue#42@2026-06-03T01:02:00Z")
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
    t.eq(second_observed[1].payload.dedup_key, "owner/x#issue#42@2026-06-03T01:02:00Z")

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

  test_inbound_poll_rearms_a_terminal_subscriber_while_a_sibling_is_live = function()
    local run_opts = opts("post-dlq-level-rearm", { FKST_GITHUB_PROXY_REPLAY_BUDGET = "1" })
    local intake = '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"bug"}],"assignees":[]}'
    local base_key = "owner/x#issue#50@2026-06-03T01:04:00Z"
    local terminal_id = "delivery/v3/raised/queue/github-proxy.github_entity_changed/dept/github-devloop-intake.admission/dedup/base"
    local rearm_key = base_key .. "/rearm/" .. sha256.hex(terminal_id)
    local terminal = {
      delivery_id = terminal_id,
      queue = "github-proxy.github_entity_changed",
      dept = "github-devloop.observe_issue",
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
      payload = poll_delivery_payload_summary(base_key),
      last_error_excerpt = nil,
    }
    mock_poll_env("1", "fkst-class:")
    mock_issue_list(issue_list_from({ intake }))
    mock_pr_list("[]\n")
    t.mock_observe(delivery_snapshot({ live }, { terminal }))
    local subscriber_rearmed = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-with-live-sibling",
    }, run_opts)
    t.eq(subscriber_rearmed.exit_code, 0)
    t.eq(#subscriber_rearmed.raises, 1)
    t.eq(subscriber_rearmed.raises[1].payload.dedup_key, rearm_key)
    t.eq(subscriber_rearmed.raises[1].payload.poll_token, allocated_poll_epoch("poll-with-live-sibling", 0))
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

}
