local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local observation = require("testkit_internal.old_behavior_observation_support")
local sha256 = require("contract.sha256")
local t = h.t
local core = h.core
local opts = h.opts
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local author_policy = require("testkit_internal.github_author_policy")
local intake_class = require("core.intake_class")
local intake_service_class = require("core.intake_service_class")

local context_runtime_root = "/tmp/fkst-packages-test/github-devloop/runtime"
local context_tmp_dir = context_runtime_root .. "/context/.bundle-tmp.intake"
local intake_proposal_id = base_ids.proposal_id("owner/repo", 42)

local function encode_labels_json(labels)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, string.format('{"name":"%s"}', h.encode_json_string(label)))
  end
  return table.concat(rendered, ",")
end

local function comments_json(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, h.render_comment(comment))
  end
  return table.concat(rendered, ",")
end

local function issue_list_json(issues)
  local rendered = {}
  for _, issue in ipairs(issues or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"title":"%s","body":"%s","createdAt":"%s","updatedAt":"%s","labels":[%s],"assignees":[%s],"author":{"login":"%s"}}',
      issue.number,
      h.encode_json_string(issue.title or "Issue"),
      h.encode_json_string(issue.body or ""),
      h.encode_json_string(issue.created_at or "2026-06-03T01:00:00Z"),
      h.encode_json_string(issue.updated_at or "2026-06-03T01:02:03Z"),
      encode_labels_json(issue.labels or {}),
      issue.assignees_json or '{"login":"fkst-test-bot"}',
      h.encode_json_string(issue.author_login or "fkst-test-bot")
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]"
end


local function mock_intake_judge_view(labels, comments, extra)
  local fields = extra or {}
  local title = fields.title or "Add retry backoff to failed widget sync"
  local body = fields.body or "Implement exponential backoff for widget sync retries. Acceptance: unit tests cover 1s, 2s, and capped retries."
  local assignees_json = fields.assignees_json or '{"login":"fkst-test-bot"}'
  h.materialize_context_bundle({
    proposal_id = intake_proposal_id,
    dedup_key = devloop_base.intake_decision_dedup_key(intake_proposal_id, {
      title = title,
      body = body,
    }),
  }, context_runtime_root, context_tmp_dir)
  local stdout_with_assignees = string.format(
    '{"title":"%s","body":"%s","updatedAt":"%s","state":"%s","labels":[%s],"comments":[%s],"assignees":[%s],"author":{"login":"%s"}}\n',
    h.encode_json_string(title),
    h.encode_json_string(body),
    h.encode_json_string(fields.updated_at or "2026-06-03T01:02:03Z"),
    h.encode_json_string(fields.state or "OPEN"),
    encode_labels_json(labels or {}),
    comments_json(comments or {}),
    assignees_json,
    h.encode_json_string(fields.author_login or "fkst-test-bot")
  )
  entity_read_mocks.mock_issue_view_raw_selector(t, {}, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone", {
    stdout = stdout_with_assignees,
  }, 2)
  entity_read_mocks.mock_issue_view_raw_selector(t, {}, "title,body,updatedAt,labels,comments,state", {
    stdout = string.format(
      '{"title":"%s","body":"%s","updatedAt":"%s","state":"%s","labels":[%s],"comments":[%s],"author":{"login":"%s"}}\n',
      h.encode_json_string(title),
      h.encode_json_string(body),
      h.encode_json_string(fields.updated_at or "2026-06-03T01:02:03Z"),
      h.encode_json_string(fields.state or "OPEN"),
      encode_labels_json(labels or {}),
      comments_json(comments or {}),
      h.encode_json_string(fields.author_login or "fkst-test-bot")
    ),
  })
end

local function mock_recent_closed_class_siblings(issues)
  entity_read_mocks.mock_issue_list_raw_command(t, core.gh_issue_list_recent_closed_cmd("owner/repo", 30), {
    stdout = issue_list_json(issues or {
      { number = 80, title = "Widget sync retry patch", labels = { "fingerprint:widget-sync" } },
      { number = 81, title = "Widget sync retry overflow fix", labels = { "fingerprint:widget-sync" } },
      { number = 82, title = "Widget sync timeout fix", labels = { "fingerprint:widget-sync" } },
    }) .. "\n",
  })
end

local function mock_intake_class_lookup(issues)
  entity_read_mocks.mock_issue_list_raw_command(t, core.gh_issue_list_intake_cmd("owner/repo", 100), {
    stdout = issue_list_json(issues or {}) .. "\n",
  })
end

local function mock_intake_codex(stdout)
  local ok = { stdout = "", stderr = "", exit_code = 0 }
  author_policy.mock_env(t, {
    env = {
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = "",
      FKST_GITHUB_AUTHORIZED_LOGINS = "",
    },
  }, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
    times = 4,
  })
  for _ = 1, 3 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = context_runtime_root,
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 2 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("mktemp -d", {
    stdout = context_tmp_dir .. "\n",
    stderr = "",
    exit_code = 0,
  })
  entity_read_mocks.mock_issue_board_digest_list_raw(t, "owner/repo", { stdout = "[]\n" })
  mock_recent_closed_class_siblings()
  t.mock_command("gh pr list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  for _ = 1, 3 do
    t.mock_command(" > ", { stdout = "", stderr = "", exit_code = 0 })
  end
  t.mock_command("python3 -c", { stdout = "", stderr = "", exit_code = 0 })
  for _ = 1, 3 do
    t.mock_command("test -r", { stdout = "", stderr = "", exit_code = 0 })
  end
  for _ = 1, 8 do
    t.mock_command("wc -c < ", { stdout = "1\n", stderr = "", exit_code = 0 })
  end
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", { stdout = stdout, stderr = "", exit_code = 0 })
end

local function candidate(extra)
  local value = payloads_builders.build_devloop_intake_candidate_payload("owner/repo", 42, "2026-06-03T01:02:03Z")
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local default_current = {
  title = "Add retry backoff to failed widget sync",
  body = "Implement exponential backoff for widget sync retries. Acceptance: unit tests cover 1s, 2s, and capped retries.",
}

local function decision_key(payload, current)
  return devloop_base.intake_decision_dedup_key(payload.proposal_id, current or default_current)
end

local function run_judge(payload, run_opts)
  author_policy.mock_env(t, run_opts, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
  })
  return t.run_department("departments/intake_judge/main.lua", {
    queue = "github-devloop-intake.devloop_intake_candidate",
    payload = payload,
  }, run_opts)
end

local function assert_queues(raises, expected)
  t.eq(#raises, #expected)
  for index, queue in ipairs(expected) do
    t.eq(raises[index].queue, queue)
  end
end

local function assert_source_ref(payload, ref)
  t.eq(payload.source_ref.kind, "external")
  t.eq(payload.source_ref.ref, ref or "owner/repo#issue/42")
end

local function assert_issue_claim(payload)
  t.eq(payload.claim.owner, "fkst-test-bot")
  assert_source_ref(payload.claim, "owner/repo#issue/42")
end

local function has_value(values, expected)
  for _, value in ipairs(values or {}) do
    if tostring(value) == tostring(expected) then
      return true
    end
  end
  return false
end

local function assert_common_issue_request(payload, schema, dedup_key)
  t.eq(payload.schema, schema)
  t.eq(payload.repo, "owner/repo")
  t.eq(tostring(payload.issue_number), "42")
  t.eq(payload.dedup_key, dedup_key)
  assert_source_ref(payload)
  assert_issue_claim(payload)
end

local function assert_folded_label_guard(payload, candidate)
  t.eq(payload.require_marker_guard, true)
  t.eq(payload.expected_proposal_id, candidate.proposal_id)
  t.eq(payload.expected_state, "blocked")
  t.eq(payload.expected_version, candidate.dedup_key)
  t.eq(payload.marker_guard.namespace, "github-devloop")
  t.eq(payload.marker_guard.marker, "state")
  t.eq(payload.marker_guard.version, "v1")
  t.eq(payload.marker_guard.match.proposal, candidate.proposal_id)
  t.eq(payload.marker_guard.expected.state, "blocked")
  t.eq(payload.marker_guard.expected.version, candidate.dedup_key)
  t.eq(payload.marker_guard.marker_target.kind, "issue")
  t.eq(tostring(payload.marker_guard.marker_target.number), "42")
end

local function assert_decision_comment(payload, action, class, expected_key, reason_fragment)
  assert_common_issue_request(payload, "github-proxy.v1", base_ids.dedup_key({
    "intake",
    "comment",
    "github-devloop/issue/owner/repo/42",
    expected_key,
  }))
  t.is_true(payload.body:find('decision="' .. action .. '"', 1, true) ~= nil)
  t.is_true(payload.body:find('class="' .. class .. '"', 1, true) ~= nil)
  t.is_true(payload.body:find('dedup="' .. expected_key .. '"', 1, true) ~= nil)
  if reason_fragment ~= nil then
    t.is_true(payload.body:find(reason_fragment, 1, true) ~= nil)
  end
end

local function assert_class_label(payload, expected_key, class)
  assert_common_issue_request(payload, "github-proxy.label.v1", expected_key)
  t.eq(payload.target_kind, "issue")
  t.eq(tostring(payload.target_number), "42")
  t.eq(payload.add_labels[1], "fkst-class:" .. class)
  t.is_nil(payload.label_colors)
  for _, other in ipairs(intake_service_class.intake_service_class_labels()) do
    if other ~= "fkst-class:" .. class then
      t.is_true(has_value(payload.remove_labels, other))
    end
  end
end

local function assert_enable_successor(raises, offset, payload, expected_key, service_class)
  local enabled_label = raises[offset].payload
  assert_common_issue_request(enabled_label, "github-proxy.label.v1", base_ids.dedup_key({
    "intake",
    "label",
    payload.proposal_id,
    payload.dedup_key,
  }))
  t.eq(enabled_label.add_labels[1], "fkst-dev:enabled")
  t.eq(enabled_label.add_labels[2], "fkst-class:" .. service_class)
  t.eq(enabled_label.label_colors["fkst-dev:enabled"], "1D76DB")
  for _, other in ipairs(intake_service_class.intake_service_class_labels()) do
    if other ~= "fkst-class:" .. service_class then
      t.is_true(has_value(enabled_label.remove_labels, other))
    end
  end

  local request = raises[offset + 1].payload
  t.eq(request.schema, "github-devloop.execution-request.v1")
  t.eq(request.proposal_id, payload.proposal_id)
  t.eq(request.dedup_key, expected_key)
  t.eq(request.service_class, service_class)
  assert_source_ref(request)
  t.eq(request.origin.package, "github-devloop-intake-default")
  t.eq(request.origin.route, "default")
  t.eq(request.origin.decision, "enable")
end

local function assert_no_codex_or_issue_edit()
  t.eq(h.count_calls("codex exec"), 0)
  t.eq(h.count_calls("gh issue edit"), 0)
end

return {
  test_golden_judge_enable_trace = function()
    local payload = candidate()
    local expected_key = decision_key(payload)
    h.mock_bot_env()
    mock_intake_judge_view({}, {})
    mock_intake_codex("⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ expedite\n⟦FKST:REASON⟧ Clear bounded implementation task.")

    local result = run_judge(payload, opts("golden-judge-enable"))

    t.eq(result.exit_code, 0)
    t.eq(sha256.hex(observation.canonical_json(result.raises)), "de2638a2ad7ccff538541e829aa1ad627d12d80b2b0b39dd035bb8a1cfb8c3a9")
    assert_queues(result.raises, {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
      "github-devloop.devloop_execute_request",
    })
    assert_decision_comment(result.raises[1].payload, "enable", "expedite", expected_key, "Clear bounded implementation task.")
    assert_enable_successor(result.raises, 2, payload, expected_key, "expedite")
  end,

  test_golden_judge_decline_trace = function()
    local payload = candidate()
    local current = {
      title = default_current.title,
      body = "Rotate production credentials after human confirmation.",
    }
    local expected_key = decision_key(payload, current)
    h.mock_bot_env()
    mock_intake_judge_view({ "fkst-class:background" }, {}, {
      body = current.body,
    })
    mock_intake_codex("⟦FKST:INTAKE⟧ decline\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Requires production credentials and human confirmation.")

    local result = run_judge(payload, opts("golden-judge-decline"))

    t.eq(result.exit_code, 0)
    assert_queues(result.raises, {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
    })
    assert_decision_comment(result.raises[1].payload, "decline", "standard", expected_key, "Requires production credentials")
    assert_class_label(result.raises[2].payload, base_ids.dedup_key({
      "intake",
      "class-label",
      payload.proposal_id,
      payload.dedup_key,
    }), "standard")
  end,

  test_golden_judge_track_trace = function()
    local payload = candidate()
    local expected_key = decision_key(payload)
    h.mock_bot_env()
    mock_intake_judge_view({}, {})
    mock_intake_codex("⟦FKST:INTAKE⟧ track\n⟦FKST:CLASS⟧ background\n⟦FKST:REASON⟧ Umbrella tracker issue; individual waves should be separate proposals.")

    local result = run_judge(payload, opts("golden-judge-track"))

    t.eq(result.exit_code, 0)
    assert_queues(result.raises, {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
    })
    assert_decision_comment(result.raises[1].payload, "track", "background", expected_key, "Acknowledged as a tracking umbrella")
    local label = result.raises[2].payload
    assert_common_issue_request(label, "github-proxy.label.v1", base_ids.dedup_key({
      "intake",
      "label",
      "tracking",
      payload.proposal_id,
      payload.dedup_key,
    }))
    t.eq(label.add_labels[1], "fkst-dev:tracking")
    t.eq(label.add_labels[2], "fkst-class:background")
    t.eq(label.label_colors["fkst-dev:tracking"], "C5DEF5")
    t.is_true(has_value(label.remove_labels, "fkst-class:expedite"))
    t.is_true(has_value(label.remove_labels, "fkst-class:standard"))
  end,

  test_golden_judge_escalate_to_class_trace = function()
    local payload = candidate()
    local current = {
      title = "Fix widget sync retry overflow again",
      body = "Third recurrence after #80 and #81; decide whether this needs a class-level retry policy.",
    }
    local reason = "Cites #80 and #81 as prior siblings; Rule of Three requires class-level retry policy."
    local expected_key = decision_key(payload, current)
    local siblings = {
      { number = 80, title = "Widget sync retry patch", labels = { "fingerprint:widget-sync" } },
      { number = 81, title = "Widget sync retry overflow fix", labels = { "fingerprint:widget-sync" } },
      { number = 82, title = "Widget sync timeout fix", labels = { "fingerprint:widget-sync" } },
    }
    local class_key = intake_class.intake_class_identity(reason, current, 42, siblings)
    h.mock_bot_env()
    mock_intake_judge_view({}, {}, current)
    mock_intake_codex("⟦FKST:INTAKE⟧ escalate-to-class\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ " .. reason)
    mock_recent_closed_class_siblings(siblings)
    mock_intake_class_lookup({})

    local result = run_judge(payload, opts("golden-judge-escalate"))

    t.eq(result.exit_code, 0)
    t.eq(sha256.hex(observation.canonical_json(result.raises)), "fc3960eeb292e9aef975532b40d37b2e78efd8f71ce7db33a04fd504aacd18ad")
    assert_queues(result.raises, {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
      "github-proxy.github_issue_create_request",
      "github-proxy.github_issue_label_request",
    })
    assert_decision_comment(result.raises[1].payload, "escalate-to-class", "standard", expected_key, "Rule of Three")
    local followup = result.raises[2].payload
    assert_common_issue_request(followup, "github-proxy.v1", base_ids.dedup_key({
      "intake-class",
      "followup",
      payload.proposal_id,
      payload.dedup_key,
      "folded",
      "pending-create",
    }))
    t.is_true(followup.body:find('carrier="pending-create"', 1, true) ~= nil)
    local folded = result.raises[3].payload
    assert_common_issue_request(folded, "github-proxy.label.v1", base_ids.dedup_key({
      "intake-class",
      "label",
      "folded",
      payload.proposal_id,
      payload.dedup_key,
    }))
    t.eq(folded.add_labels[1], "fkst-dev:blocked")
    t.eq(folded.label_colors["fkst-dev:blocked"], "1B1F23")
    assert_folded_label_guard(folded, payload)
    t.is_true(has_value(folded.remove_labels, "fkst-dev:thinking"))
    t.is_true(has_value(folded.remove_labels, "fkst-dev:ready"))
    local create = result.raises[4].payload
    t.eq(create.schema, "github-proxy.issue-create.v1")
    t.eq(create.repo, "owner/repo")
    t.eq(create.dedup_key, base_ids.dedup_key({ "intake-class", class_key }))
    t.eq(#create.labels, 0)
    t.eq(create.parent_comment_target.repo, "owner/repo")
    t.eq(create.parent_comment_target.issue_number, "42")
    t.is_true(create.body:find(intake_class.intake_class_carrier_marker(class_key), 1, true) ~= nil)
    assert_source_ref(create)
    assert_class_label(result.raises[5].payload, base_ids.dedup_key({
      "intake",
      "class-label",
      payload.proposal_id,
      payload.dedup_key,
    }), "standard")
  end,

  test_golden_judge_skip_foreign_hold_and_foreign_assignee = function()
    local unsupported = run_judge({ schema = "foreign.v1" }, opts("golden-judge-skip-foreign-payload"))
    t.eq(unsupported.exit_code, 0)
    t.eq(#unsupported.raises, 0)
    assert_no_codex_or_issue_edit()

    local invalid_ref = candidate({ source_ref = { kind = "external", ref = "not-an-issue-ref" } })
    local invalid = run_judge(invalid_ref, opts("golden-judge-skip-foreign-source"))
    t.eq(invalid.exit_code, 0)
    t.eq(#invalid.raises, 0)
    assert_no_codex_or_issue_edit()

    h.mock_bot_env()
    mock_intake_judge_view({ "fkst-dev:hold" }, {})
    local held = run_judge(candidate(), opts("golden-judge-skip-hold"))
    t.eq(held.exit_code, 0)
    t.eq(#held.raises, 0)
    assert_no_codex_or_issue_edit()

    h.mock_bot_env()
    mock_intake_judge_view({}, {}, { assignees_json = '{"login":"other-bot"}' })
    local claimed = run_judge(candidate(), opts("golden-judge-skip-foreign-assignee"))
    t.eq(claimed.exit_code, 0)
    t.eq(#claimed.raises, 0)
    assert_no_codex_or_issue_edit()
  end,
}
