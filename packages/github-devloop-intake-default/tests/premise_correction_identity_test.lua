local author_policy = require("testkit_internal.github_author_policy")
local devloop_base = require("devloop.base")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local intake_judge_department = require("departments.intake_judge.main")
local marker_builders = require("devloop.markers.builders")
local payloads_builders = require("devloop.payloads.builders")
local premise_correction = require("devloop.premise_correction")
local t = h.t

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local current = {
  title = "Automate deployment",
  body = "Use the repository fake deployment adapter.",
}
local decline_reason = "The deployment requires a production credential."

local function correction_fixture()
  local base_key = devloop_base.intake_decision_dedup_key(proposal_id, current)
  local premise = premise_correction.premise_fingerprint(proposal_id, base_key, decline_reason)
  local evidence = "The repository fake adapter removes the production-credential requirement."
  local correction_id = "IC_default_correction"
  local correction = premise_correction.correction_fingerprint(correction_id, evidence)
  local correction_key = premise_correction.decision_dedup_key(base_key, {
    premise_fingerprint = premise,
    correction_fingerprint = correction,
  })
  local candidate = payloads_builders.build_devloop_intake_candidate_payload(
    repo,
    issue_number,
    "2026-07-27T10:02:00Z",
    {
      effect_id = correction_key,
      dedup_key = correction_key,
      premise_fingerprint = premise,
      correction_fingerprint = correction,
    }
  )
  return {
    base_key = base_key,
    premise = premise,
    correction = correction,
    correction_key = correction_key,
    candidate = candidate,
    comments = {
      {
        id = "IC_default_decline",
        body = marker_builders.intake_decision_marker(
          proposal_id,
          "decline",
          base_key,
          "standard",
          premise
        ),
        author_login = devloop_base._test_bot_login,
        created_at = "2026-07-27T10:00:00Z",
      },
      {
        id = correction_id,
        body = evidence .. '\n\n<!-- fkst:premise-correction:v1 premise="' .. premise
          .. '" correction="' .. correction .. '" -->',
        author_login = "trusted-human",
        created_at = "2026-07-27T10:01:00Z",
      },
    },
  }
end

local function issue_fields(comments)
  return {
    repo = repo,
    number = issue_number,
    title = current.title,
    body = current.body,
    updated_at = "2026-07-27T10:02:00Z",
    state = "OPEN",
    labels = {},
    comments = comments,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }
end

local function mock_issue_reads(comments)
  local fields = issue_fields(comments)
  entity_read_mocks.mock_issue_view_selector(
    t,
    fields,
    "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone",
    2
  )
  entity_read_mocks.mock_issue_view_selector(
    t,
    fields,
    "title,body,updatedAt,labels,comments,state",
    1
  )
end

local function mock_intake_codex(run_opts)
  local ok = { stdout = "", stderr = "", exit_code = 0 }
  author_policy.mock_env(t, run_opts, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
    times = 4,
  })
  for _ = 1, 3 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/premise-correction-identity/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 2 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", ok)
  t.mock_command("mktemp -d", {
    stdout = "/tmp/fkst-packages-test/premise-correction-identity/runtime/context/.bundle-tmp.intake\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  t.mock_command("gh pr list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  for _ = 1, 3 do
    t.mock_command(" > ", ok)
  end
  t.mock_command("python3 -c", ok)
  for _ = 1, 3 do
    t.mock_command("test -r", ok)
  end
  for _ = 1, 8 do
    t.mock_command("wc -c < ", { stdout = "1\n", stderr = "", exit_code = 0 })
  end
  t.mock_command("mkdir -p", ok)
  t.mock_command("codex exec", {
    stdout = "⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ The corrected evidence supports autonomous implementation.",
    stderr = "",
    exit_code = 0,
  })
end

local function run_judge(candidate, comments, name, with_codex)
  local run_opts = h.opts(name)
  h.mock_bot_env()
  mock_issue_reads(comments)
  if with_codex then
    mock_intake_codex(run_opts)
  end
  author_policy.mock_env(t, run_opts, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
  })
  return t.run_department("departments/intake_judge/main.lua", {
    queue = "github-devloop-intake.devloop_intake_candidate",
    payload = candidate,
    ts = "2026-07-27T10:02:00Z",
  }, run_opts)
end

local function run_judge_with_logs(candidate, comments, name)
  local run_opts = h.opts(name)
  h.mock_bot_env()
  mock_issue_reads(comments)
  author_policy.mock_env(t, run_opts, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
  })

  local raises = {}
  local logs = {}
  local old_raise = raise
  local old_log = log
  raise = function(queue, payload)
    table.insert(raises, { queue = queue, payload = payload })
  end
  log = {
    info = function(message) table.insert(logs, tostring(message)) end,
    warn = function(message) table.insert(logs, tostring(message)) end,
    error = function(message) table.insert(logs, tostring(message)) end,
  }

  local ok, err = pcall(intake_judge_department.pipeline, {
    queue = "github-devloop-intake.devloop_intake_candidate",
    payload = candidate,
    ts = "2026-07-27T10:02:00Z",
  })
  raise = old_raise
  log = old_log
  if not ok then
    error(err, 0)
  end
  return {
    exit_code = 0,
    raises = raises,
  }, table.concat(logs, "\n")
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
  test_real_default_executor_preserves_correction_bound_identity = function()
    local fixture = correction_fixture()
    local result = run_judge(
      fixture.candidate,
      fixture.comments,
      "premise-correction-identity-positive",
      true
    )

    t.eq(result.exit_code, 0)
    local decision = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    local emitted_key = decision ~= nil
      and decision.payload.body:match('dedup="([^"]+)"')
      or "NO_INTAKE_DECISION"
    t.eq(emitted_key, fixture.correction_key)
    t.is_true(emitted_key ~= fixture.base_key)
    local execute = find_raise(result.raises, "github-devloop.devloop_execute_request")
    t.is_true(execute ~= nil)
    t.eq(execute.payload.dedup_key, fixture.correction_key)
    t.eq(h.count_calls("codex exec"), 1)
  end,

  test_real_default_executor_rejects_changed_source_correction = function()
    local fixture = correction_fixture()
    local changed_evidence = "The source correction changed after candidate creation."
    local changed_id = "IC_default_correction_changed"
    local changed_correction = premise_correction.correction_fingerprint(changed_id, changed_evidence)
    fixture.comments[2] = {
      id = changed_id,
      body = changed_evidence .. '\n\n<!-- fkst:premise-correction:v1 premise="' .. fixture.premise
        .. '" correction="' .. changed_correction .. '" -->',
      author_login = "trusted-human",
      created_at = "2026-07-27T10:01:30Z",
    }

    local result = run_judge(
      fixture.candidate,
      fixture.comments,
      "premise-correction-identity-source-changed",
      false
    )

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("codex exec"), 0)
  end,

  test_real_default_executor_rejects_mismatched_candidate_effect_id = function()
    local fixture = correction_fixture()
    fixture.candidate.effect_id = fixture.base_key

    local result = run_judge(
      fixture.candidate,
      fixture.comments,
      "premise-correction-identity-effect-mismatch",
      false
    )

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("codex exec"), 0)
  end,

  test_real_default_executor_replays_correction_bound_enable_successors = function()
    local fixture = correction_fixture()
    table.insert(fixture.comments, {
      id = "IC_default_enable",
      body = marker_builders.intake_decision_marker(
        proposal_id,
        "enable",
        fixture.correction_key,
        "standard"
      ),
      author_login = devloop_base._test_bot_login,
      created_at = "2026-07-27T10:02:00Z",
    })

    local result, logs = run_judge_with_logs(
      fixture.candidate,
      fixture.comments,
      "premise-correction-identity-enable-successor-replay"
    )

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    local label = find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.is_true(label ~= nil)
    t.eq(label.payload.add_labels[1], "fkst-dev:enabled")
    local execute = find_raise(result.raises, "github-devloop.devloop_execute_request")
    t.is_true(execute ~= nil)
    t.eq(execute.payload.dedup_key, fixture.correction_key)
    t.eq(fixture.candidate.effect_id, fixture.correction_key)
    t.is_true(logs:find("outcome=applied(visible-intake-fact)", 1, true) ~= nil)
    t.is_true(logs:find("skip-stale(premise-correction-changed)", 1, true) == nil)
    t.eq(h.count_calls("codex exec"), 0)
  end,
}
