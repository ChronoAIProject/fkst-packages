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

local function assert_common_issue_request(payload, schema, dedup_key)
  t.eq(payload.schema, schema)
  t.eq(payload.repo, "owner/repo")
  t.eq(tostring(payload.issue_number), "42")
  t.eq(payload.dedup_key, dedup_key)
  assert_source_ref(payload)
  assert_issue_claim(payload)
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
}
