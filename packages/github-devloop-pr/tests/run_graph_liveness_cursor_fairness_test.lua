local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local liveness_scan = require("devloop.liveness_scan")
local devloop_logging = require("devloop.logging")
local testing = require("testkit_internal.testing")
local liveness_scan_department = require("departments.liveness_scan.main")

local t = h.t
local core = h.core

local repo = "owner/repo"
local malformed_pr_number = 5
local target_pr_number = 7
local cursor_prefix = "github-devloop-pr/liveness-scan/pr-cursor/"
local malformed_issue_number = 41
local malformed_proposal_id = "github-devloop/issue/owner/repo/41"
local malformed_version = "ready/consensus-github-devloop/issue/owner/repo/41/2026-06-03T01-02-03Z/fix/1"

local function capture_log_lines(fn)
  local captured = {}
  local original_log_line = devloop_logging.log_line
  devloop_logging.log_line = function(level, dept, proposal_id, tag, fields)
    table.insert(captured, {
      level = level,
      dept = dept,
      proposal_id = proposal_id,
      tag = tag,
      fields = fields,
    })
  end
  local ok, result = pcall(fn)
  devloop_logging.log_line = original_log_line
  if not ok then
    error(result, 0)
  end
  return result, captured
end

local function has_log_field(fields, expected)
  for _, field in ipairs(fields or {}) do
    if field == expected then
      return true
    end
  end
  return false
end

local function has_log_field_containing(fields, expected)
  for _, field in ipairs(fields or {}) do
    if tostring(field):find(expected, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-06-03T01:00:00Z",
  }
end

local function mock_env(times)
  for _ = 1, times or 8 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_under_cap_pr_list()
  local stdout = '[{"number":3,"state":"open","updated_at":"2026-06-04T01:02:03Z"},'
    .. '{"number":7,"state":"open","updated_at":"2026-06-04T01:02:04Z"}]\n'
  for _ = 1, 2 do
    t.mock_command(core.gh_pr_list_observe_cmd(repo), {
      stdout = stdout,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh api 'repos/owner/repo/pulls/3'", {
      stdout = "",
      stderr = "command timed out",
      exit_code = 124,
    })
  end
end

local function mock_malformed_feedback_pr_list()
  local stdout = '[{"number":5,"state":"open","updated_at":"2026-06-04T01:02:03Z"},'
    .. '{"number":7,"state":"open","updated_at":"2026-06-04T01:02:04Z"}]\n'
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = stdout,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_ordered_poison_middle_pr_list()
  local stdout = '[{"number":3,"state":"open","updated_at":"2026-06-04T01:12:02Z"},'
    .. '{"number":5,"state":"open","updated_at":"2026-06-04T01:12:03Z"},'
    .. '{"number":7,"state":"open","updated_at":"2026-06-04T01:12:04Z"}]\n'
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = stdout,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_malformed_fixing_pr()
  local branch = "devloop-owner-repo-41-01HY"
  local comments = {
    trusted_comment(m_builders.pr_origin_marker(
      malformed_proposal_id,
      tostring(malformed_issue_number),
      branch,
      malformed_version,
      "dev"
    )),
    trusted_comment(core.state_marker(malformed_proposal_id, "fixing", malformed_version)),
    trusted_comment('<!-- fkst:github-devloop:review-meta:v1 proposal="' .. malformed_proposal_id
      .. '" dedup="review-meta-delivery" action="fix" version="' .. malformed_version
      .. '" gap="missing binding" -->'),
  }

  entity_read_mocks.mock_pr_read_forms(t, {
    repo = repo,
    number = malformed_pr_number,
    head = branch,
    head_sha = "119ef6fd",
    base_branch = "dev",
    state = "OPEN",
    updated_at = "2026-06-04T01:02:03Z",
    comments = comments,
    labels = {},
    register_all_views = true,
    times = 8,
  })
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = malformed_issue_number,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "assignees,author", 8)
end

local function mock_target_fixing_pr()
  local event = h.fixing()
  local comments = {
    trusted_comment(m_builders.pr_origin_marker(
      event.proposal_id,
      "42",
      "devloop-owner-repo-42-01HY",
      event.version,
      "dev"
    )),
    trusted_comment(core.state_marker(event.proposal_id, "fixing", event.version)),
    trusted_comment(m_builders.review_result_marker(
      event.review_proposal_id,
      event.proposal_id,
      "reject",
      event.review_dedup_key,
      1,
      "missing regression guard"
    )),
    trusted_comment(m_builders.merge_gate_marker(
      event.proposal_id,
      target_pr_number,
      event.version,
      event.review_proposal_id,
      event.review_dedup_key,
      event.reviewed_head_sha,
      nil,
      "missing regression guard"
    )),
  }

  entity_read_mocks.mock_pr_read_forms(t, {
    repo = repo,
    number = target_pr_number,
    head = "devloop-owner-repo-42-01HY",
    head_sha = event.reviewed_head_sha,
    base_branch = "dev",
    state = "OPEN",
    updated_at = "2026-06-04T01:02:04Z",
    comments = comments,
    labels = {},
    register_all_views = true,
    times = 8,
  })
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = 42,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "assignees,author", 8)
end

local function mock_liveness_fixing_pr(pr_number, issue_number, updated_at, poison)
  local proposal_id = "github-devloop/issue/" .. repo .. "/" .. tostring(issue_number)
  local base_version = "ready/consensus-" .. proposal_id .. "/2026-06-03T01-02-03Z"
  local version = base_version .. "/fix/1"
  local branch = "devloop-owner-repo-" .. tostring(issue_number) .. "-01HY"
  local head_sha = ({ [3] = "abc333", [5] = "abc555", [7] = "abc777" })[pr_number]
  local review_proposal_id = devloop_base.pr_review_proposal_id(
    repo, pr_number, base_version, head_sha)
  local review_dedup_key = poison
      and "observe-pr-conflict/" .. proposal_id .. "/" .. base_version .. "/" .. tostring(pr_number)
    or devloop_base.pr_review_consensus_dedup_key(review_proposal_id)
  local feedback_marker = poison
      and ('<!-- fkst:github-devloop:review-meta:v1 proposal="' .. proposal_id
        .. '" dedup="review-meta-delivery" action="fix" version="' .. version
        .. '" gap="mergeable-conflicting" review_proposal="' .. review_proposal_id
        .. '" review_dedup="' .. review_dedup_key
        .. '" head_sha="' .. head_sha .. '" -->')
    or m_builders.merge_gate_marker(
      proposal_id,
      pr_number,
      version,
      review_proposal_id,
      review_dedup_key,
      head_sha,
      nil,
      "mergeable-conflicting"
    )
  local comments = {
    trusted_comment(m_builders.pr_origin_marker(
      proposal_id,
      tostring(issue_number),
      branch,
      version,
      "dev"
    )),
    trusted_comment(core.state_marker(proposal_id, "fixing", version)),
    trusted_comment(feedback_marker),
  }

  entity_read_mocks.mock_pr_read_forms(t, {
    repo = repo,
    number = pr_number,
    head = branch,
    head_sha = head_sha,
    base_branch = "dev",
    state = "OPEN",
    updated_at = updated_at,
    comments = comments,
    labels = {},
    register_all_views = true,
    times = 16,
  })
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "assignees,author", 16)
  return {
    pr_number = pr_number,
    proposal_id = proposal_id,
  }
end

local function liveness_tick(ts)
  return {
    queue = "github-devloop-pr.devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
      source_ref = { kind = "cron", ref = "github-devloop-pr/liveness-poll" },
    },
    ts = ts,
    source_ref = { kind = "cron", reference = "github-devloop-pr/liveness-poll" },
  }
end

local function with_no_codex_runs(fn)
  local original = fkst.codex_runs
  fkst.codex_runs = function()
    return { running = {}, recent = {} }
  end
  local ok, result = pcall(fn)
  fkst.codex_runs = original
  if not ok then
    error(result, 0)
  end
  return result
end

local function numbered_entities(numbers)
  local entities = {}
  for _, number in ipairs(numbers) do
    table.insert(entities, {
      number = number,
      state = "open",
      updated_at = "2026-06-04T01:02:03Z",
    })
  end
  return entities
end

local function raised_for_pr(result, queue, pr_number)
  return h.find_raise(result and result.raises, queue, function(payload)
    return tonumber(payload and payload.pr_number) == pr_number
  end)
end

local function count_deliveries(trace, queue, consumer)
  local count = 0
  for _, step in ipairs((trace and trace.steps) or {}) do
    if step.queue == queue and step.consumer == consumer then
      count = count + 1
    end
  end
  return count
end

return {
  test_poison_middle_isolated_without_losing_healthy_deliveries = function()
    mock_env(32)
    mock_ordered_poison_middle_pr_list()
    mock_ordered_poison_middle_pr_list()
    local healthy_before = mock_liveness_fixing_pr(3, 40, "2026-06-04T01:12:02Z", false)
    local poison = mock_liveness_fixing_pr(5, 41, "2026-06-04T01:12:03Z", true)
    local healthy_after = mock_liveness_fixing_pr(7, 42, "2026-06-04T01:12:04Z", false)
    local cursor_key = liveness_scan.liveness_scan_cursor_key(repo, cursor_prefix)
    cache_set(cursor_key, "0")
    local tick = liveness_tick(401)
    tick.attempt = 4

    with_no_codex_runs(function()
      local _, logs = capture_log_lines(function()
        return testing.run_fake(liveness_scan_department, tick)
      end)
      local error_fact = nil
      for _, entry in ipairs(logs) do
        if entry.tag == "ENTITY_FAILURE" then
          error_fact = entry
          break
        end
      end
      t.is_true(error_fact ~= nil)
      t.eq(error_fact.level, "error")
      t.eq(error_fact.dept, "liveness_scan")
      t.eq(error_fact.proposal_id, entity_lib.pr_proposal_id(repo, poison.pr_number))
      t.is_true(has_log_field(error_fact.fields,
        "error_class=fix-feedback-mismatched-review-dedup-key"))
      t.is_true(has_log_field(error_fact.fields,
        "source_ref=external:" .. repo .. "#pr/" .. tostring(poison.pr_number)))
      t.is_true(has_log_field(error_fact.fields,
        "queue=github-devloop-pr.devloop_liveness_tick"))
      t.is_true(has_log_field(error_fact.fields, "attempt=4"))
      t.is_true(has_log_field_containing(error_fact.fields,
        "github-devloop: fix-feedback-mismatched-review-dedup-key"))

      cache_set(cursor_key, "0")
      local trace = graph.run(tick, { max_steps = 8 })
      local scan_step = graph.require_delivery(trace, {
        queue = "github-devloop-pr.devloop_liveness_tick",
        consumer = "github-devloop-pr.liveness_scan",
      })
      t.eq(scan_step.exit_code, 0)

      graph.require_delivery(trace, {
        queue = "github-devloop-pr.devloop_observe_pr",
        consumer = "github-devloop-pr.observe_pr",
      })
      for _, healthy in ipairs({ healthy_before, healthy_after }) do
        graph.require_raise(trace, "github-proxy.github_pr_comment_request", function(raised)
          return tonumber(raised.payload and raised.payload.pr_number) == healthy.pr_number
            and tostring(raised.payload and raised.payload.body or ""):find(
              "fkst:github-devloop:timeout-attempt", 1, true) ~= nil
        end)
        graph.require_raise(trace, "github-devloop-pr.devloop_fixing", function(raised)
          return tonumber(raised.payload and raised.payload.pr_number) == healthy.pr_number
            and raised.payload.proposal_id == healthy.proposal_id
        end)
      end
      t.eq(count_deliveries(trace,
        "github-proxy.github_pr_comment_request", "github-proxy.github_pr_comment"), 2)
      t.eq(count_deliveries(trace,
        "github-devloop-pr.devloop_fixing", "github-devloop-pr.fix"), 2)
    end)
  end,

  test_overlapping_ticks_serialize_cursor_and_do_not_double_serve_head = function()
    mock_env()
    mock_under_cap_pr_list()
    mock_target_fixing_pr()

    local cursor_key = liveness_scan.liveness_scan_cursor_key(repo, cursor_prefix)
    cache_set(cursor_key, "0")
    local original_cache_get = cache_get
    local original_raise = raise
    local original_with_lock = with_lock
    local cursor_lock_held = false
    local overlap_started = false
    local nested_result = nil
    local active_raises = nil

    local function run_direct_tick(ts)
      local parent_raises = active_raises
      local captured = {}
      active_raises = captured
      local ok, err = pcall(liveness_scan_department.pipeline, liveness_tick(ts))
      active_raises = parent_raises
      return {
        exit_code = ok and 0 or 1,
        error = err,
        raises = captured,
      }
    end

    local function run_nested_tick()
      nested_result = run_direct_tick(302)
    end

    cache_get = function(key)
      local value = original_cache_get(key)
      if key == cursor_key and not cursor_lock_held and not overlap_started then
        overlap_started = true
        run_nested_tick()
      end
      return value
    end
    raise = function(queue, payload)
      if active_raises ~= nil then
        table.insert(active_raises, { queue = queue, payload = payload })
        return
      end
      return original_raise(queue, payload)
    end
    with_lock = function(key, fn)
      if key ~= cursor_key then
        return original_with_lock(key, fn)
      end
      cursor_lock_held = true
      local results = table.pack(pcall(original_with_lock, key, fn))
      cursor_lock_held = false
      if not overlap_started then
        overlap_started = true
        run_nested_tick()
      end
      if not results[1] then
        error(results[2], 0)
      end
      return table.unpack(results, 2, results.n)
    end

    local ok, err = pcall(function()
      with_no_codex_runs(function()
        local outer = run_direct_tick(301)
        t.eq(outer.exit_code, 0)
        if nested_result == nil then
          error("overlap tick was not scheduled")
        end
        t.eq(nested_result.exit_code, 0)
        local nested_queues = {}
        for _, raised in ipairs(nested_result.raises or {}) do
          table.insert(nested_queues, tostring(raised.queue))
        end
        local raised_summary = table.concat(nested_queues, ",")
        if raised_for_pr(nested_result, "github-proxy.github_pr_comment_request", target_pr_number) == nil then
          error("missing target timeout comment; nested queues=" .. raised_summary)
        end
        if raised_for_pr(nested_result, "devloop_fixing", target_pr_number) == nil then
          error("missing target fixing redrive; nested queues=" .. raised_summary)
        end

        local head_calls = 0
        for _, call in ipairs(t.command_calls()) do
          if call.rendered == "gh api repos/owner/repo/pulls/3" then
            head_calls = head_calls + 1
          end
        end
        t.eq(head_calls, 1)
        t.eq(original_cache_get(cursor_key), "0")
      end)
    end)
    cache_get = original_cache_get
    raise = original_raise
    with_lock = original_with_lock
    if not ok then
      error(err, 0)
    end
  end,

  test_exact_cap_completes_and_wraps_cursor = function()
    local exact_repo = "owner/exact-cap"
    local key = liveness_scan.liveness_scan_cursor_key(exact_repo, cursor_prefix)
    local numbers = {}
    for number = 1, liveness_scan.liveness_scan_limits().entity_cap do
      table.insert(numbers, number)
    end
    cache_set(key, "0")

    local activations, deferred, actual_key, cursor, total = liveness_scan.liveness_scan_activation_slice(
      exact_repo,
      "pr",
      numbered_entities(numbers),
      cursor_prefix
    )
    t.eq(#activations, 100)
    t.eq(deferred, 0)
    t.eq(total, 100)
    t.eq(actual_key, key)
    liveness_scan.liveness_scan_update_cursor(actual_key, cursor, total, #activations)
    t.eq(cache_get(key), "0")
  end,

  test_append_waits_for_wrap_then_joins_next_cursor_cycle = function()
    local append_repo = "owner/append"
    local key = liveness_scan.liveness_scan_cursor_key(append_repo, cursor_prefix)
    cache_set(key, "0")

    local first, _, first_key, first_cursor, first_total = liveness_scan.liveness_scan_activation_slice(
      append_repo,
      "pr",
      numbered_entities({ 1, 3 }),
      cursor_prefix
    )
    liveness_scan.liveness_scan_update_cursor(first_key, first_cursor, first_total, 1)
    t.eq(cache_get(key), "1:3")

    local remainder, _, remainder_key, remainder_cursor, remainder_total = liveness_scan.liveness_scan_activation_slice(
      append_repo,
      "pr",
      numbered_entities({ 1, 3, 5 }),
      cursor_prefix
    )
    t.eq(#remainder, 1)
    t.eq(remainder[1].entity.number, 3)
    liveness_scan.liveness_scan_update_cursor(remainder_key, remainder_cursor, remainder_total, 1)
    t.eq(cache_get(key), "0")

    local wrapped = liveness_scan.liveness_scan_activation_slice(
      append_repo,
      "pr",
      numbered_entities({ 1, 3, 5 }),
      cursor_prefix
    )
    t.eq(#wrapped, 3)
    t.eq(wrapped[3].entity.number, 5)
  end,

  test_removed_cursor_entity_resumes_above_stable_number = function()
    local removal_repo = "owner/removal"
    local key = liveness_scan.liveness_scan_cursor_key(removal_repo, cursor_prefix)
    cache_set(key, "0")

    local first, _, first_key, first_cursor, first_total = liveness_scan.liveness_scan_activation_slice(
      removal_repo,
      "pr",
      numbered_entities({ 1, 3, 5 }),
      cursor_prefix
    )
    liveness_scan.liveness_scan_update_cursor(first_key, first_cursor, first_total, 2)
    t.eq(cache_get(key), "3:5")

    local remainder, _, remainder_key, remainder_cursor, remainder_total = liveness_scan.liveness_scan_activation_slice(
      removal_repo,
      "pr",
      numbered_entities({ 1, 5 }),
      cursor_prefix
    )
    t.eq(#remainder, 1)
    t.eq(remainder[1].entity.number, 5)
    liveness_scan.liveness_scan_update_cursor(remainder_key, remainder_cursor, remainder_total, 1)
    t.eq(cache_get(key), "0")
  end,

  test_legacy_fix_feedback_reaches_review_meta_while_later_pr_progresses = function()
    mock_env()
    mock_malformed_feedback_pr_list()
    mock_malformed_fixing_pr()
    mock_target_fixing_pr()
    local cursor_key = liveness_scan.liveness_scan_cursor_key(repo, cursor_prefix)
    cache_set(cursor_key, "0")

    with_no_codex_runs(function()
      local trace = graph.run(liveness_tick(201), { max_steps = 12 })
      graph.assert_covers(trace, {
        "github-devloop-pr.devloop_liveness_tick -> github-devloop-pr.liveness_scan",
      })
      t.eq(trace.status, "quiescent")
      local scan_step = graph.require_delivery(trace, {
        queue = "github-devloop-pr.devloop_liveness_tick",
        consumer = "github-devloop-pr.liveness_scan",
      })
      local malformed_step = graph.require_delivery(trace, {
        queue = "github-devloop-pr.devloop_observe_pr",
        consumer = "github-devloop-pr.observe_pr",
      })
      t.eq(scan_step.exit_code, 0)
      t.eq(malformed_step.exit_code, 0)
      t.is_true(type(malformed_step.delivery_id) == "string" and malformed_step.delivery_id ~= "")
      t.eq(cache_get(cursor_key), "0")
      local remediation = graph.require_raise(
        trace, "github-proxy.github_pr_comment_request", function(raised)
          return tonumber(raised.payload and raised.payload.pr_number) == malformed_pr_number
            and tostring(raised.payload.body or ""):find(
              'state="review-meta"', 1, true) ~= nil
            and tostring(raised.payload.body or ""):find(
              "legacy-fix-feedback-unbound", 1, true) ~= nil
        end)
      local timeout_attempt = graph.require_raise(trace, "github-proxy.github_pr_comment_request", function(raised)
        return tonumber(raised.payload and raised.payload.pr_number) == target_pr_number
          and tostring(raised.payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
      end)
      t.eq(tonumber(remediation.payload.pr_number), malformed_pr_number)
      local fixing = graph.require_raise(trace, "github-devloop-pr.devloop_fixing", function(raised)
        return tonumber(raised.payload and raised.payload.pr_number) == target_pr_number
      end)
      t.eq(tonumber(timeout_attempt.payload.pr_number), target_pr_number)
      t.eq(fixing.queue, "github-devloop-pr.devloop_fixing")
    end)
  end,

  test_under_cap_deadline_scan_resumes_later_fixing_pr_on_next_tick = function()
    mock_env()
    mock_under_cap_pr_list()
    mock_target_fixing_pr()
    cache_set(liveness_scan.liveness_scan_cursor_key(repo, cursor_prefix), "0")

    with_no_codex_runs(function()
      local first = graph.run(liveness_tick(101), { max_steps = 1 })
      graph.assert_covers(first, {
        "github-devloop-pr.devloop_liveness_tick -> github-devloop-pr.liveness_scan",
      })
      t.eq(graph.find_raise(first, "github-proxy.github_pr_comment_request"), nil)

      local second = graph.require_quiescent(graph.run(liveness_tick(102), { max_steps = 3 }))
      graph.assert_covers(second, {
        "github-devloop-pr.devloop_liveness_tick -> github-devloop-pr.liveness_scan",
      })
      local timeout_attempt = graph.require_raise(second, "github-proxy.github_pr_comment_request", function(raised)
        return tonumber(raised.payload.pr_number) == target_pr_number
          and tostring(raised.payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
      end)
      t.eq(tonumber(timeout_attempt.payload.pr_number), target_pr_number)
      t.eq(graph.find_raise(second, "devloop_timeout_reconcile"), nil)
      t.eq(graph.find_raise(second, "github-devloop-pr.devloop_timeout_reconcile"), nil)
    end)
  end,
}
