local contract_time = require("contract.time")
local ci_repair_attempts = require("core.ci_repair_attempts")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local graph = require("testkit.graph")
local h = require("tests.devloop_helpers")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local payloads_builders = require("devloop.payloads.builders")
local payloads_shared = require("devloop.payloads.shared")
local requests_review = require("devloop.requests.review")
local v_fixing = require("devloop.validators.fixing")

local t = h.t
local core = h.core

local repo = "owner/repo"
local issue_number = 42
local pr_number = 7
local branch = "devloop-owner-repo-42-01HY"
local pushed_head = "feedface"
local ci_repo = "owner/timeout-ci"
local ci_issue_number = 43
local ci_pr_number = 8
local ci_branch = "devloop-owner-timeout-ci-43-01HY"
local ci_head = "c1fade"
local marker_created_at = "2026-06-03T00:00:00Z"
local timeout_now = "2026-06-03T02:01:00Z"
local ci_failure_key = "head:" .. ci_head .. "/checks:digest-0000000101"

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = marker_created_at,
  }
end

local function mock_env(selected_repo)
  for _ = 1, 32 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = selected_repo or repo,
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

local function drive_pr_to_fixing()
  local review = h.review_reached({
    decision = "reject",
    body = "Review consensus rejects the diff.",
    blocking_gap = "missing regression guard",
  })
  local reviewing_version = h.reviewing().version
  local producer_pr = {
    repo = repo,
    number = pr_number,
    comments = {
      trusted_comment(m_builders.pr_origin_marker(
        "github-devloop/issue/owner/repo/42",
        tostring(issue_number),
        branch,
        reviewing_version,
        "dev"
      )),
      trusted_comment(core.state_marker(
        "github-devloop/issue/owner/repo/42",
        "reviewing",
        reviewing_version
      )),
    },
    head = branch,
    head_sha = "def456",
    base_branch = "dev",
    state = "OPEN",
  }
  entity_read_mocks.mock_pr_view_raw_selector(
    t,
    producer_pr,
    entity_read_mocks.pr_origin_selector,
    { stdout = entity_read_mocks.pr_view_stdout(producer_pr) },
    1
  )

  local result = h.run_review_result(
    review,
    h.opts("fixing-timeout-receiver-drive-to-fixing")
  )
  t.eq(result.exit_code, 0)
  local request = h.find_raise(
    result.raises,
    "github-proxy.github_pr_comment_request"
  )
  t.is_true(request ~= nil)
  t.eq(request.payload.handoff.kind, "github-devloop.fixing")
  local handoff = h.run_comment_handoff_from_request(
    request.payload,
    "IC_fixing_timeout_receiver_1",
    "fixing-timeout-receiver-handoff"
  )
  local fixing = h.find_raise(
    handoff.raises,
    "github-devloop-pr.devloop_fixing"
  )
  t.is_true(fixing ~= nil)
  return fixing.payload, request.payload.body
end

local function drive_own_ci_to_fixing()
  local proposal_id = "github-devloop/issue/owner/timeout-ci/43"
  local reviewing_version = "ready/consensus-github-devloop/issue/owner/timeout-ci/43/2026-06-03T01-02-03Z"
  local review_proposal_id = devloop_base.pr_review_proposal_id(
    ci_repo, ci_pr_number, reviewing_version, ci_head)
  local merge_ready = payloads_builders.build_devloop_merge_ready_payload(
    proposal_id,
    ci_pr_number,
    reviewing_version,
    {
      review_proposal_id = review_proposal_id,
      review_dedup_key = "consensus:" .. review_proposal_id .. "/review",
      reviewed_head_sha = ci_head,
    },
    entity_lib.pr_source_ref(ci_repo, ci_pr_number)
  )
  local fix_version = core.fix_version_from_review_version(merge_ready.version)
  local request = requests_review.build_merge_gate_fix_comment_request(core.merge_gate_reason_class, core.output_language, ci_repo,
    ci_issue_number,
    merge_ready,
    fix_version,
    "own-ci-red",
    "ba5e9999",
    entity_lib.pr_source_ref(ci_repo, ci_pr_number),
    nil,
    {
      ci_failure_key = ci_failure_key,
      gate_failure_excerpt = "own-ci-red",
    }
  )
  local handoff = h.run_comment_handoff_from_request(
    request,
    "IC_fixing_timeout_own_ci_1",
    "fixing-timeout-own-ci-handoff"
  )
  local fixing = h.find_raise(
    handoff.raises,
    "github-devloop-pr.devloop_fixing"
  )
  t.is_true(fixing ~= nil)
  return fixing.payload, request.body
end

local function failed_rollup(head_sha)
  return '[{"__typename":"CheckRun","completedAt":"2026-06-03T01:20:00Z","conclusion":"FAILURE","detailsUrl":"https://example.invalid/checks/test","name":"test","startedAt":"2026-06-03T01:19:00Z","status":"COMPLETED","workflowName":"test","headSha":"'
    .. tostring(head_sha)
    .. '"}]'
end

local function mock_frozen_pr(fixing, feedback_body, fields)
  local selected = fields or {}
  local selected_repo = selected.repo or repo
  local selected_issue_number = selected.issue_number or issue_number
  local selected_pr_number = selected.pr_number or pr_number
  local selected_branch = selected.branch or branch
  local current_head = selected.head_sha or pushed_head
  local updated_at = selected.updated_at or marker_created_at
  local comments = {
    trusted_comment(m_builders.pr_origin_marker(
      fixing.proposal_id,
      tostring(selected_issue_number),
      selected_branch,
      core._strip_latest_fix_version_suffix(fixing.version),
      "dev"
    )),
    trusted_comment(feedback_body),
  }
  if selected.completed_attempt == true then
    table.insert(comments, {
      body = ci_repair_attempts.comment_request(
        selected_repo,
        fixing,
        "no-fix",
        "No repaired revision was published."
      ).body,
      author_login = "fkst-test-bot",
      created_at = selected.attempt_created_at or "2026-06-03T01:30:00Z",
    })
  end

  t.mock_command(core.gh_pr_list_observe_cmd(selected_repo), {
    stdout = '[{"number":' .. tostring(selected_pr_number)
      .. ',"state":"open","updated_at":"' .. updated_at .. '"}]\n',
    stderr = "",
    exit_code = 0,
  })
  entity_read_mocks.mock_pr_read_forms(t, {
    repo = selected_repo,
    number = selected_pr_number,
    comments = comments,
    head = selected_branch,
    head_sha = current_head,
    base_branch = "dev",
    base_sha = "ba5e9999",
    state = "OPEN",
    updated_at = updated_at,
    labels = {},
    mergeable = "MERGEABLE",
    merge_state = selected.own_ci == true and "UNSTABLE" or "CLEAN",
    status_check_rollup_json = selected.own_ci == true and failed_rollup(current_head) or nil,
    register_all_views = true,
    times = 12,
  })
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = selected_repo,
    number = selected_issue_number,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "labels,author", 8)
  if selected.own_ci == true then
    h.mock_required_check_runs_for(current_head, "failure", selected_repo)
    h.mock_required_check_runs_for(current_head, "failure", selected_repo)
  else
    for _ = 1, 2 do
      t.mock_command("git fetch origin " .. selected_branch, {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("git rev-parse --verify 'FETCH_HEAD^{commit}'", {
        stdout = pushed_head .. "\n",
        stderr = "",
        exit_code = 0,
      })
    end
    t.mock_command("git rev-parse --verify refs/heads/" .. selected_branch, {
      stdout = pushed_head .. "\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function liveness_tick(now_value)
  local now_seconds = contract_time.iso_timestamp_epoch_seconds(now_value or timeout_now)
  return {
    queue = "github-devloop-pr.devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
      source_ref = {
        kind = "cron",
        ref = "github-devloop-pr/liveness-poll",
      },
    },
    ts = now_seconds,
    now_seconds = now_seconds,
    source_ref = {
      kind = "cron",
      reference = "github-devloop-pr/liveness-poll",
    },
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

local function find_step_raise(step, queue, predicate)
  for _, raised in ipairs(step and step.raises or {}) do
    if raised.queue == queue and (predicate == nil or predicate(raised)) then
      return raised
    end
  end
  return nil
end

local function next_redrive_payload(fixing, redrive_delivery)
  return payloads_builders.build_replayed_fixing_payload({
    proposal_id = fixing.proposal_id,
    impl_version = fixing.version,
  }, pr_number, fixing, entity_lib.pr_source_ref(repo, pr_number), redrive_delivery)
end

return {
  test_successive_fixing_redrives_deliver_distinct_marker_writes_to_github_proxy = function()
    h.reset_pr_helper_state()
    local fixing, feedback_body = drive_pr_to_fixing()
    mock_env(repo)
    mock_frozen_pr(fixing, feedback_body, {
      updated_at = "2026-06-03T00:00:01Z",
    })

    with_no_codex_runs(function()
      local trace = graph.require_quiescent(graph.run(
        liveness_tick("2026-06-03T02:01:01Z"), { max_steps = 8 }))
      graph.assert_covers(trace, {
        "github-devloop-pr.devloop_liveness_tick -> github-devloop-pr.liveness_scan",
        "github-devloop-pr.devloop_fixing -> github-devloop-pr.fix",
        "github-proxy.github_pr_comment_request -> github-proxy.github_pr_comment",
      })

      local redrive, scan_step = graph.require_raise(
        trace,
        "github-devloop-pr.devloop_fixing"
      )
      local fix_step = graph.require_delivery(trace, {
        queue = "github-devloop-pr.devloop_fixing",
        consumer = "github-devloop-pr.fix",
      })
      local first_proxy_step = graph.require_delivery(trace, {
        queue = "github-proxy.github_pr_comment_request",
        consumer = "github-proxy.github_pr_comment",
      })
      t.eq(scan_step.consumer, "github-devloop-pr.liveness_scan")
      t.eq(fix_step.status, "accepted")
      t.eq(fix_step.exit_code, 0)
      t.eq(first_proxy_step.status, "accepted")
      t.eq(first_proxy_step.exit_code, 0)
      t.eq(v_fixing.is_supported_fixing(redrive.payload), true)
      t.eq(redrive.payload.version, fixing.version)
      t.eq(redrive.payload.work_unit_key, fixing.work_unit_key)
      t.eq(redrive.payload.redrive_delivery.attempt, 1)

      local logical = payloads_builders.build_replayed_fixing_payload({
        proposal_id = fixing.proposal_id,
        impl_version = fixing.version,
      }, pr_number, fixing, entity_lib.pr_source_ref(repo, pr_number))
      t.eq(redrive.payload.dedup_key,
        payloads_shared.issue_redrive_delivery_dedup_key(
          fixing.proposal_id,
          logical.dedup_key,
          redrive.payload.redrive_delivery
        ))

      t.eq(find_step_raise(scan_step,
        "github-proxy.github_pr_comment_request",
        function(raised)
          local kind = raised.payload
            and raised.payload.handoff
            and raised.payload.handoff.kind
          return kind == "github-devloop.fixing"
            or kind == "github-devloop.reviewing"
        end), nil)
      local reviewing = find_step_raise(
        fix_step,
        "github-proxy.github_pr_comment_request",
        function(raised)
          return raised.payload
            and raised.payload.handoff
            and raised.payload.handoff.kind == "github-devloop.reviewing"
        end
      )
      t.is_true(reviewing ~= nil)

      local second_payload = next_redrive_payload(fixing, {
        generation_key = redrive.payload.redrive_delivery.generation_key,
        attempt = 2,
      })
      t.eq(v_fixing.is_supported_fixing(second_payload), true)
      mock_frozen_pr(fixing, feedback_body, {
        updated_at = "2026-06-03T00:00:01Z",
      })
      local second_trace = graph.require_quiescent(graph.run({
        queue = "github-devloop-pr.devloop_fixing",
        payload = second_payload,
        source_ref = {
          kind = second_payload.source_ref.kind,
          reference = second_payload.source_ref.ref,
        },
      }, { max_steps = 8 }))
      graph.assert_covers(second_trace, {
        "github-devloop-pr.devloop_fixing -> github-devloop-pr.fix",
        "github-proxy.github_pr_comment_request -> github-proxy.github_pr_comment",
      })
      local second_fix_step = graph.require_delivery(second_trace, {
        queue = "github-devloop-pr.devloop_fixing",
        consumer = "github-devloop-pr.fix",
      })
      local second_proxy_step = graph.require_delivery(second_trace, {
        queue = "github-proxy.github_pr_comment_request",
        consumer = "github-proxy.github_pr_comment",
      })
      local second_reviewing = find_step_raise(
        second_fix_step,
        "github-proxy.github_pr_comment_request",
        function(raised)
          return raised.payload
            and raised.payload.handoff
            and raised.payload.handoff.kind == "github-devloop.reviewing"
        end
      )
      t.is_true(second_reviewing ~= nil)
      t.eq(second_fix_step.status, "accepted")
      t.eq(second_fix_step.exit_code, 0)
      t.eq(second_proxy_step.status, "accepted")
      t.eq(second_proxy_step.exit_code, 0)
      t.eq(reviewing.payload.dedup_key, redrive.payload.dedup_key)
      t.eq(second_reviewing.payload.dedup_key, second_payload.dedup_key)
      t.is_true(reviewing.payload.dedup_key ~= second_reviewing.payload.dedup_key)
      t.eq(h.count_calls("codex exec"), 0)
    end)
  end,

  test_completed_own_ci_attempt_timeout_advances_to_next_fix_generation = function()
    h.reset_pr_helper_state()
    local fixing, feedback_body = drive_own_ci_to_fixing()
    mock_env(ci_repo)
    mock_frozen_pr(fixing, feedback_body, {
      repo = ci_repo,
      issue_number = ci_issue_number,
      pr_number = ci_pr_number,
      branch = ci_branch,
      head_sha = fixing.reviewed_head_sha,
      own_ci = true,
      completed_attempt = true,
      updated_at = "2026-06-03T00:00:02Z",
    })

    with_no_codex_runs(function()
      local trace = graph.require_quiescent(graph.run(
        liveness_tick("2026-06-03T02:01:02Z"), { max_steps = 8 }))
      local next_version = core.next_fix_version(fixing.version)
      local progress = graph.require_raise(
        trace,
        "github-proxy.github_pr_comment_request",
        function(raised)
          return raised.payload
            and raised.payload.handoff
            and raised.payload.handoff.kind == "github-devloop.fixing"
            and raised.payload.handoff.version == next_version
        end
      )
      t.eq(progress.payload.handoff.version, next_version)
      t.eq(progress.payload.handoff.ci_failure_key ~= nil, true)
      t.eq(graph.find_delivery(trace, {
        queue = "github-devloop-pr.devloop_fixing",
        consumer = "github-devloop-pr.fix",
      }), nil)
      t.eq(graph.find_raise(trace, "github-devloop-pr.devloop_fixing"), nil)
      t.eq(h.count_calls("codex exec"), 0)
    end)
  end,
}
