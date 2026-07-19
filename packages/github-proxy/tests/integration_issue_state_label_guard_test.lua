local h = require("tests.proxy_integration_helpers")
local devloop_state = require("devloop.state")
local t = h.t
local opts = h.opts
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_repo_label_list = h.mock_repo_label_list
local count_calls = h.count_calls

local proposal_id = "github-devloop/issue/owner/x/42"
local stale_version = "ready/consensus-github-devloop/issue/owner/x/42/2026-07-19T00-00-00Z"
local fresh_version = "ready/consensus-github-devloop/issue/owner/x/42/2026-07-19T00-05-00Z"

local function issue_claim(number)
  t.mock_command("gh api repos/owner/x/issues/" .. tostring(number or 42), {
    stdout = '{"assignees":[{"login":"fkst-test-bot"}]}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_comment_view(comments)
  local parts = {}
  for index, body in ipairs(comments or {}) do
    table.insert(parts, string.format(
      '{"id":%d,"body":"%s","user":{"login":"fkst-test-bot"}}',
      index,
      h.json_string(body)
    ))
  end
  t.mock_command("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100", {
    stdout = "[[" .. table.concat(parts, ",") .. "]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_comment_view(comments, number)
  local parts = {}
  for index, body in ipairs(comments or {}) do
    table.insert(parts, string.format(
      '{"id":%d,"body":"%s","user":{"login":"fkst-test-bot"}}',
      index,
      h.json_string(body)
    ))
  end
  t.mock_command("gh api --paginate --slurp repos/owner/x/issues/" .. tostring(number or 7) .. "/comments?per_page=100", {
    stdout = "[[" .. table.concat(parts, ",") .. "]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function state_marker_guard(state, version)
  return {
    namespace = "github-devloop",
    marker = "state",
    version = "v1",
    match = {
      proposal = proposal_id,
    },
    expected = {
      state = state,
      version = version,
    },
    order_by = {
      "marker_order_key",
      "version_order_key",
      "stage_rank",
    },
  }
end

local function label_event(add_labels, remove_labels, extra)
  local payload = {
    schema = "github-proxy.label.v1",
    repo = "owner/x",
    target_kind = "issue",
    target_number = 42,
    issue_number = 42,
    add_labels = add_labels or {},
    remove_labels = remove_labels or {},
    dedup_key = "github-devloop/issue/owner/x/42/label/test",
    source_ref = {
      kind = "external",
      ref = "owner/x#issue/42",
    },
    claim = {
      owner = "fkst-test-bot",
      source_ref = {
        kind = "external",
        ref = "owner/x#issue/42",
      },
    },
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return {
    queue = "github_issue_label_request",
    payload = payload,
  }
end

local function state_label_event(state, version, extra)
  local add_labels, remove_labels = devloop_state.state_label_changes(state)
  local payload = {
    expected_proposal_id = proposal_id,
    expected_state = state,
    expected_version = version,
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return label_event(add_labels, remove_labels, payload)
end

local function mock_label_apply()
  mock_repo_label_list({
    "fkst-dev:awaiting-pr",
    "fkst-dev:blocked",
    "fkst-dev:thinking",
    "manual-label",
  })
  t.mock_command("gh issue edit", { stdout = "", stderr = "", exit_code = 0 })
end

local function run_label(event, name, issue_number)
  mock_write_env("1")
  mock_bot_env()
  issue_claim(issue_number)
  return t.run_department("departments/github_issue_label/main.lua", event, opts(name, {
    FKST_GITHUB_WRITE = "1",
  }))
end

return {
  test_issue_state_label_rejects_unguarded_stale_write = function()
    mock_issue_comment_view({
      devloop_state.state_marker(proposal_id, "awaiting-pr", stale_version),
      devloop_state.state_marker(proposal_id, "blocked", fresh_version),
    })
    mock_label_apply()

    local result = run_label(state_label_event("awaiting-pr", stale_version), "issue-state-label-unguarded-stale")

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_issue_state_label_rejects_guarded_stale_write = function()
    mock_issue_comment_view({
      devloop_state.state_marker(proposal_id, "awaiting-pr", stale_version),
      devloop_state.state_marker(proposal_id, "blocked", fresh_version),
    })
    mock_label_apply()

    local result = run_label(state_label_event("awaiting-pr", stale_version, {
      marker_guard = state_marker_guard("awaiting-pr", stale_version),
    }), "issue-state-label-guarded-stale")

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100"), 1)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_issue_state_label_applies_when_guard_is_current = function()
    mock_issue_comment_view({
      devloop_state.state_marker(proposal_id, "awaiting-pr", stale_version),
      devloop_state.state_marker(proposal_id, "blocked", fresh_version),
    })
    mock_label_apply()

    local result = run_label(state_label_event("blocked", fresh_version, {
      marker_guard = state_marker_guard("blocked", fresh_version),
    }), "issue-state-label-guard-current")

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100"), 1)
    t.eq(count_calls("gh issue edit"), 1)
  end,

  test_issue_state_label_allows_bootstrap_when_no_marker_is_visible = function()
    mock_issue_comment_view({})
    mock_label_apply()

    local result = run_label(state_label_event("thinking", stale_version, {
      marker_guard = state_marker_guard("thinking", stale_version),
    }), "issue-state-label-bootstrap")

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100"), 1)
    t.eq(count_calls("gh issue edit"), 1)
  end,

  test_issue_state_label_rejects_stale_pr_owned_marker_target = function()
    mock_pr_comment_view({
      devloop_state.state_marker(proposal_id, "fixing", fresh_version),
    }, 8)
    mock_label_apply()

    local guard = state_marker_guard("merge-ready", stale_version)
    guard.marker_target = {
      kind = "pr",
      number = 8,
    }
    local result = run_label(state_label_event("merge-ready", stale_version, {
      target_number = 43,
      issue_number = 43,
      source_ref = {
        kind = "external",
        ref = "owner/x#issue/43",
      },
      claim = {
        owner = "fkst-test-bot",
        source_ref = {
          kind = "external",
          ref = "owner/x#issue/43",
        },
      },
      marker_guard = guard,
    }), "issue-state-label-pr-marker-target-stale", 43)

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/8/comments?per_page=100"), 1)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/43/comments?per_page=100"), 0)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_issue_non_state_label_applies_without_marker_guard = function()
    mock_label_apply()

    local result = run_label(label_event({ "manual-label" }, {}), "issue-non-state-label-unguarded")

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100"), 0)
    t.eq(count_calls("gh issue edit"), 1)
  end,
}
