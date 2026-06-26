local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local entity_read_mocks = require("tests.entity_read_mock_helpers")

local function mock_repo_env(repo)
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = repo or "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
end

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

local function mock_issue_list(issues)
  entity_read_mocks.mock_issue_list_raw_command(t, core.gh_issue_list_intake_cmd("owner/repo", 100), {
    stdout = issue_list_json(issues) .. "\n",
  })
end

local function mock_intake_scan_view(fields)
  entity_read_mocks.mock_issue_view_selector(t, {
    number = fields.number,
    title = fields.title or "Issue",
    body = fields.body or "",
    updated_at = fields.updated_at or "2026-06-03T01:02:03Z",
    state = fields.state or "OPEN",
    labels = fields.labels or {},
    comments = fields.comments or {},
    assignees = fields.assignees or { "fkst-test-bot" },
    author_login = fields.author_login or "fkst-test-bot",
  }, "title,labels,comments,state,assignees,author")
end

local function mock_intake_judge_view(labels, comments, extra)
  local fields = extra or {}
  local assignees_json = fields.assignees_json or '{"login":"fkst-test-bot"}'
  local stdout_with_assignees = string.format(
    '{"title":"%s","body":"%s","updatedAt":"%s","state":"%s","labels":[%s],"comments":[%s],"assignees":[%s],"author":{"login":"%s"}}\n',
    h.encode_json_string(fields.title or "Add retry backoff to failed widget sync"),
    h.encode_json_string(fields.body or "Implement exponential backoff for widget sync retries. Acceptance: unit tests cover 1s, 2s, and capped retries."),
    h.encode_json_string(fields.updated_at or "2026-06-03T01:02:03Z"),
    h.encode_json_string(fields.state or "OPEN"),
    encode_labels_json(labels or {}),
    comments_json(comments or {}),
    assignees_json,
    h.encode_json_string(fields.author_login or "fkst-test-bot")
  )
  entity_read_mocks.mock_issue_view_raw_selector(t, {}, "title,body,updatedAt,labels,comments,state,assignees,author", {
    stdout = stdout_with_assignees,
  }, 2)
  entity_read_mocks.mock_issue_view_raw_selector(t, {}, "title,body,updatedAt,labels,comments,state", {
    stdout = string.format(
      '{"title":"%s","body":"%s","updatedAt":"%s","state":"%s","labels":[%s],"comments":[%s]}\n',
      h.encode_json_string(fields.title or "Add retry backoff to failed widget sync"),
      h.encode_json_string(fields.body or "Implement exponential backoff for widget sync retries. Acceptance: unit tests cover 1s, 2s, and capped retries."),
      h.encode_json_string(fields.updated_at or "2026-06-03T01:02:03Z"),
      h.encode_json_string(fields.state or "OPEN"),
      encode_labels_json(labels or {}),
      comments_json(comments or {})
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
  for _ = 1, 3 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 2 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("mktemp -d", {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime/context/.bundle-tmp.intake\n",
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
  local value = core.build_devloop_intake_candidate_payload("owner/repo", 42, "2026-06-03T01:02:03Z")
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local default_current = {
  title = "Add retry backoff to failed widget sync",
  body = "Implement exponential backoff for widget sync retries. Acceptance: unit tests cover 1s, 2s, and capped retries.",
}

local function decision_key(payload, current, command)
  return core.intake_decision_dedup_key(payload.proposal_id, current or default_current, command)
end

local function trusted_reintake_command(id)
  return {
    id = id or "IC_reintake_1",
    body = "fkst: reintake",
    author_login = core.trusted_bot_login(),
    created_at = "2026-06-04T03:00:00Z",
  }
end

local function run_scan(run_opts)
  return t.run_department("departments/intake_scan/main.lua", {
    queue = "devloop_intake_tick",
    payload = { schema = "github-devloop.intake-tick.v1" },
  }, run_opts)
end

local function run_judge(payload, run_opts)
  return t.run_department("departments/intake_judge/main.lua", {
    queue = "devloop_intake_candidate",
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

local function assert_decision_comment(payload, action, class, expected_key, reason_fragment)
  assert_common_issue_request(payload, "github-proxy.v1", core._dedup_key({
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
  for _, other in ipairs(core.intake_service_class_labels()) do
    if other ~= "fkst-class:" .. class then
      t.is_true(has_value(payload.remove_labels, other))
    end
  end
end

local function assert_enable_successor(raises, offset, payload, expected_key, service_class)
  local enabled_label = raises[offset].payload
  assert_common_issue_request(enabled_label, "github-proxy.label.v1", core._dedup_key({
    "intake",
    "label",
    payload.proposal_id,
    payload.dedup_key,
  }))
  t.eq(enabled_label.add_labels[1], "fkst-dev:enabled")
  t.eq(enabled_label.add_labels[2], "fkst-class:" .. service_class)
  t.eq(enabled_label.label_colors["fkst-dev:enabled"], "1D76DB")
  for _, other in ipairs(core.intake_service_class_labels()) do
    if other ~= "fkst-class:" .. service_class then
      t.is_true(has_value(enabled_label.remove_labels, other))
    end
  end

  local thinking_comment = raises[offset + 1].payload
  assert_common_issue_request(thinking_comment, "github-proxy.v1", core._dedup_key({
    payload.proposal_id,
    "comment",
    "thinking",
    expected_key,
  }))
  t.is_true(thinking_comment.body:find(core.state_marker(payload.proposal_id, "thinking", expected_key), 1, true) ~= nil)

  local thinking_label = raises[offset + 2].payload
  assert_common_issue_request(thinking_label, "github-proxy.label.v1", expected_key .. "/label/thinking")
  t.eq(thinking_label.add_labels[1], "fkst-dev:thinking")
  t.eq(thinking_label.label_colors["fkst-dev:thinking"], "8250DF")
  t.is_true(has_value(thinking_label.remove_labels, "fkst-dev:ready"))
  t.is_true(has_value(thinking_label.remove_labels, "fkst-dev:blocked"))

  local proposal = raises[offset + 3].payload
  t.eq(proposal.schema, "consensus.proposal.v1")
  t.eq(proposal.verdict_mode, "converge")
  t.eq(proposal.proposal_id, payload.proposal_id)
  t.eq(proposal.dedup_key, expected_key)
  t.eq(proposal.effect_version, expected_key)
  assert_source_ref(proposal)
  t.eq(proposal.intake_hand_off.kind, "own-intake-decision")
  t.eq(proposal.intake_hand_off.decision, "enable")
  t.eq(proposal.intake_hand_off.dedup_key, expected_key)
  assert_source_ref(proposal.intake_hand_off)
  t.is_true(tostring(proposal.content_fetch or ""):find("^runtime%-cache:") ~= nil)
end

local function assert_no_codex_or_issue_edit()
  t.eq(h.count_calls("codex exec"), 0)
  t.eq(h.count_calls("gh issue edit"), 0)
end

local function assert_scan_candidate_delivery_key(payload)
  local prefix = "intake-candidate/"
    .. tostring(payload.proposal_id)
    .. "/"
    .. tostring(payload.effect_id)
    .. "/"
  t.is_true(tostring(payload.dedup_key or ""):sub(1, #prefix) == prefix)
  local delivery_version = tostring(payload.dedup_key):sub(#prefix + 1)
  t.is_true(delivery_version:match("^%d+$") ~= nil)
  t.eq(payload.dedup_key, core.intake_candidate_delivery_dedup_key(
    payload.proposal_id,
    payload.effect_id,
    delivery_version
  ))
end

return {
  test_golden_scan_open_unmanaged_raises_candidate = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = {}, title = "Issue", body = "", updated_at = "2026-06-03T01:02:03Z" } })
    mock_intake_scan_view({ number = 42, labels = {}, title = "Issue", body = "" })

    local result = run_scan(opts("golden-scan-open-unmanaged"))

    t.eq(result.exit_code, 0)
    assert_queues(result.raises, { "devloop_intake_candidate" })
    local payload = result.raises[1].payload
    t.eq(payload.schema, "github-devloop.intake-candidate.v1")
    t.eq(payload.repo, "owner/repo")
    t.eq(payload.issue_number, "42")
    t.eq(payload.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(payload.effect_id, core.intake_decision_dedup_key(payload.proposal_id, { title = "Issue", body = "" }))
    assert_scan_candidate_delivery_key(payload)
    assert_source_ref(payload)
  end,

  test_golden_scan_refuses_reintake_without_existing_intake = function()
    local command = trusted_reintake_command("IC_reintake_no_marker")
    local command_fact = core.operator_command_fact({ command }, "reintake")
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = {} } })
    mock_intake_scan_view({ number = 42, labels = {}, comments = { command } })

    local result = run_scan(opts("golden-scan-reintake-refusal"))

    t.eq(result.exit_code, 0)
    assert_queues(result.raises, { "github-proxy.github_issue_comment_request" })
    local request = result.raises[1].payload
    assert_common_issue_request(request, "github-proxy.v1", core._dedup_key({
      "operator-command",
      "comment",
      command_fact.key,
      "refused",
      "reintake requires an existing intake decision",
    }))
    t.is_true(request.body:find("github-devloop operator command refused: reintake requires an existing intake decision", 1, true) ~= nil)
    t.is_true(request.body:find('command="reintake"', 1, true) ~= nil)
    t.is_true(request.body:find('outcome="refused"', 1, true) ~= nil)
  end,

  test_golden_scan_claim_skip_known_state_hold_and_foreign_assignee = function()
    local cases = {
      {
        name = "known-state",
        list = { number = 42, labels = { "fkst-dev:thinking" } },
        view = { number = 42, labels = { "fkst-dev:thinking" } },
      },
      {
        name = "hold",
        list = { number = 42, labels = { "fkst-dev:hold" } },
        view = { number = 42, labels = { "fkst-dev:hold" } },
      },
      {
        name = "foreign-assignee",
        list = { number = 42, labels = {} },
        view = { number = 42, labels = {}, assignees = { "other-bot" } },
      },
    }
    for _, case in ipairs(cases) do
      h.mock_bot_env()
      mock_repo_env()
      mock_issue_list({ case.list })
      mock_intake_scan_view(case.view)

      local result = run_scan(opts("golden-scan-skip-" .. case.name))

      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 0)
      assert_no_codex_or_issue_edit()
    end
  end,

  test_golden_judge_enable_trace = function()
    local payload = candidate()
    local expected_key = decision_key(payload)
    h.mock_bot_env()
    mock_intake_judge_view({}, {})
    mock_intake_codex("⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ expedite\n⟦FKST:REASON⟧ Clear bounded implementation task.")

    local result = run_judge(payload, opts("golden-judge-enable"))

    t.eq(result.exit_code, 0)
    assert_queues(result.raises, {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
      "consensus.proposal",
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
    assert_class_label(result.raises[2].payload, core._dedup_key({
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
    assert_common_issue_request(label, "github-proxy.label.v1", core._dedup_key({
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
    local class_key = core.intake_class_identity(reason, current, 42, siblings)
    h.mock_bot_env()
    mock_intake_judge_view({}, {}, current)
    mock_intake_codex("⟦FKST:INTAKE⟧ escalate-to-class\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ " .. reason)
    mock_recent_closed_class_siblings(siblings)
    mock_intake_class_lookup({})

    local result = run_judge(payload, opts("golden-judge-escalate"))

    t.eq(result.exit_code, 0)
    assert_queues(result.raises, {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
      "github-proxy.github_issue_create_request",
      "github-proxy.github_issue_label_request",
    })
    assert_decision_comment(result.raises[1].payload, "escalate-to-class", "standard", expected_key, "Rule of Three")
    local followup = result.raises[2].payload
    assert_common_issue_request(followup, "github-proxy.v1", core._dedup_key({
      "intake-class",
      "followup",
      payload.proposal_id,
      payload.dedup_key,
      "folded",
      "pending-create",
    }))
    t.is_true(followup.body:find('carrier="pending-create"', 1, true) ~= nil)
    local folded = result.raises[3].payload
    assert_common_issue_request(folded, "github-proxy.label.v1", core._dedup_key({
      "intake-class",
      "label",
      "folded",
      payload.proposal_id,
      payload.dedup_key,
    }))
    t.eq(folded.add_labels[1], "fkst-dev:blocked")
    t.eq(folded.label_colors["fkst-dev:blocked"], "1B1F23")
    t.is_true(has_value(folded.remove_labels, "fkst-dev:thinking"))
    t.is_true(has_value(folded.remove_labels, "fkst-dev:ready"))
    local create = result.raises[4].payload
    t.eq(create.schema, "github-proxy.issue-create.v1")
    t.eq(create.repo, "owner/repo")
    t.eq(create.dedup_key, core._dedup_key({ "intake-class", class_key }))
    t.eq(#create.labels, 0)
    t.eq(create.parent_comment_target.repo, "owner/repo")
    t.eq(create.parent_comment_target.issue_number, "42")
    t.is_true(create.body:find(core.intake_class_carrier_marker(class_key), 1, true) ~= nil)
    assert_source_ref(create)
    assert_class_label(result.raises[5].payload, core._dedup_key({
      "intake",
      "class-label",
      payload.proposal_id,
      payload.dedup_key,
    }), "standard")
  end,

  test_golden_judge_reintake_active_state_refusal = function()
    local command = trusted_reintake_command("IC_reintake_active")
    local base = candidate()
    local command_fact = core.operator_command_fact({ command }, "reintake")
    local payload = candidate({
      effect_id = decision_key(base, nil, command),
      reintake_command_created_at = command.created_at,
    })
    payload.dedup_key = core.intake_candidate_delivery_dedup_key(payload.proposal_id, payload.effect_id, payload.effect_id)
    h.mock_bot_env()
    mock_intake_judge_view({ "fkst-dev:thinking" }, {
      core.intake_decision_marker(payload.proposal_id, "decline", payload.effect_id, "standard"),
      command,
    })

    local result = run_judge(payload, opts("golden-judge-reintake-refusal"))

    t.eq(result.exit_code, 0)
    assert_queues(result.raises, { "github-proxy.github_issue_comment_request" })
    local request = result.raises[1].payload
    assert_common_issue_request(request, "github-proxy.v1", core._dedup_key({
      "operator-command",
      "comment",
      command_fact.key,
      "refused",
      "reintake requires no active devloop state",
    }))
    t.is_true(request.body:find("github-devloop operator command refused: reintake requires no active devloop state", 1, true) ~= nil)
    t.eq(h.count_calls("codex exec"), 0)
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
