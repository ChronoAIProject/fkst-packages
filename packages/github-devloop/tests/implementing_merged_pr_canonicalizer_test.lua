local entity_lib = require("devloop.entity")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local h = require("tests.devloop_helpers")
local entity_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")

local core = h.core
local t = h.t

local repo = "owner/repo"
local issue_number = 42
local pr_number = 7
local parent = "github-devloop/issue/owner/repo/42"
local child_pr = "github-devloop/pr/owner/repo/7"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local branch = devloop_base.implement_branch(repo, issue_number, version)
local base_branch = "dev"
local head_sha = "0123456789abcdef0123456789abcdef01234567"
local merge_commit_sha = "1111111111111111111111111111111111111111"

-- Incident evidence captured from the cited GitHub comments and target base 27650f79.
local INCIDENT_2828_DIAGNOSIS = {
  proposal_id = "github-devloop/issue/ChronoAIProject/fkst-packages/2828",
  repo = "ChronoAIProject/fkst-packages",
  issue_number = 2828,
  pr_number = 2832,
  selected_marker = {
    state = "implementing",
    version = "ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549/loop/1",
    created_at = "2026-07-28T04:33:29Z",
    source = {
      comment_id = "IC_kwDOSwWu288AAAABL_u8eQ",
      url = "https://github.com/ChronoAIProject/fkst-packages/issues/2828#issuecomment-5099994233",
      author_login = "ElonSG",
      marker_body = '<!-- fkst:github-devloop:state:v1 proposal="github-devloop/issue/ChronoAIProject/fkst-packages/2828" state="implementing" version="ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549/loop/1" stage_rank="600" marker_order_key="ready-consensus-github-devloo-002128467225/000000000001/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000600" -->',
    },
  },
  losing_marker = {
    state = "dependency_wait",
    version = "consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549/ready-split/1",
    created_at = "2026-07-30T02:44:44Z",
    source = {
      comment_id = "IC_kwDOSwWu288AAAABMYUS-w",
      url = "https://github.com/ChronoAIProject/fkst-packages/issues/2828#issuecomment-5125772027",
      author_login = "ElonSG",
      marker_body = '<!-- fkst:github-devloop:state:v1 proposal="github-devloop/issue/ChronoAIProject/fkst-packages/2828" state="dependency_wait" version="consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549/ready-split/1" stage_rank="500" marker_order_key="consensus-github-devloop-issu-001794078222/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000001/000000000500" effects="ready-split-canonicalized" -->',
    },
  },
  delegation = {
    created_at = "2026-07-28T05:41:44Z",
    source = {
      comment_id = "IC_kwDOSwWu288AAAABMAIOww",
      url = "https://github.com/ChronoAIProject/fkst-packages/issues/2828#issuecomment-5100408515",
      author_login = "ElonSG",
      marker_body = '<!-- fkst:github-devloop:pr-delegation:v1 proposal="github-devloop/issue/ChronoAIProject/fkst-packages/2828" pr_proposal="github-devloop/pr/ChronoAIProject/fkst-packages/2832" pr="2832" version="ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549/loop/1" delegation="g1" -->',
    },
  },
  pr_origin = {
    branch = "devloop/issue/ChronoAIProject/fkst-packages/2828/ready-consensus-github-devloop-issue-ChronoAIProject-fkst-packages-2828-intake-2050103549-loop-1-2779796620",
    base_branch = "integration-elonsg",
    created_at = "2026-07-28T05:41:40Z",
    source = {
      comment_id = "IC_kwDOSwWu288AAAABMAINWw",
      url = "https://github.com/ChronoAIProject/fkst-packages/pull/2832#issuecomment-5100408155",
      author_login = "ElonSG",
      marker_body = '<!-- fkst:github-devloop:pr-origin:v1 proposal="github-devloop/issue/ChronoAIProject/fkst-packages/2828" issue="2828" branch="devloop/issue/ChronoAIProject/fkst-packages/2828/ready-consensus-github-devloop-issue-ChronoAIProject-fkst-packages-2828-intake-2050103549-loop-1-2779796620" impl_version="ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549/loop/1" base_branch="integration-elonsg" -->',
    },
  },
  child_head = {
    sha = "760b0dc28bda1ab13c0f1d531be6530c7ca5a721",
    observed_at = "2026-08-03T08:47:32Z",
    source = {
      comment_id = "IC_kwDOSwWu288AAAABM8-wmg",
      url = "https://github.com/ChronoAIProject/fkst-packages/pull/2832#issuecomment-5164216474",
      author_login = "ElonSG",
      marker_body = '<!-- fkst:github-devloop:fix:v1 proposal="github-devloop/issue/ChronoAIProject/fkst-packages/2828" review_proposal="github-devloop/pr-review/ChronoAIProject-fkst-packages-2376452037/2832/ready-consensus-github-devloo-3203099212/81f5f09e5d811db0a2ebbcc2c1ace885eb21e4f8" review_dedup="consensus:github-devloop/pr-review/ChronoAIProject-fkst-packages-2376452037/2832/ready-consensus-github-devloo-3203099212/81f5f09e5d811db0a2ebbcc2c1ace885eb21e4f8/review" old_head_sha="81f5f09e5d811db0a2ebbcc2c1ace885eb21e4f8" new_head_sha="760b0dc28bda1ab13c0f1d531be6530c7ca5a721" -->',
    },
  },
  child_terminal = {
    state = "closed-unmerged",
    version = "ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549",
    observed_at = "2026-08-03T08:47:42Z",
    source = {
      comment_id = "5164218051",
      url = "https://github.com/ChronoAIProject/fkst-packages/pull/2832#issuecomment-5164218051",
      author_login = "ElonSG",
      marker_body = '<!-- fkst:github-devloop:state:v1 proposal="github-devloop/issue/ChronoAIProject/fkst-packages/2828" state="closed-unmerged" version="ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549" stage_rank="825" marker_order_key="ready-consensus-github-devloo-002128467225/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000825" -->',
    },
  },
  pre_fix_decision = {
    route = "maybe_canonicalize_implementing_merged_delegated_pr -> canonicalize_implementing_merged_delegated_pr",
    outcome = "skip-pending(canonical-child-pr-merged-missing)",
    reason = "delegated child PR is not canonically merged by GitHub",
    source = "27650f79ac600537390fcae5e22bd8a7cd0988cc:packages/github-devloop/core/awaiting_pr_replayer.lua:315",
  },
}

local function comment(body, created_at, author_login, id)
  return {
    id = id,
    body = body,
    author_login = author_login or core._test_bot_login,
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
end

local function incident_2828_comment(fact)
  return comment(fact.source.marker_body,
    fact.created_at or fact.observed_at,
    fact.source.author_login,
    fact.source.comment_id)
end

local function incident_2828_emitted_comment(body, created_at)
  return comment(body, created_at, INCIDENT_2828_DIAGNOSIS.selected_marker.source.author_login)
end

local function incident_2828_authoritative_state()
  local selected = INCIDENT_2828_DIAGNOSIS.selected_marker
  local losing = INCIDENT_2828_DIAGNOSIS.losing_marker
  local previous_trusted_login = devloop_base.configured_trusted_bot_login()
  devloop_base.configure_trusted_bot_login(selected.source.author_login)
  local ok, state = pcall(devloop_state.current_state, {
    comment(selected.source.marker_body, selected.created_at,
      selected.source.author_login, selected.source.comment_id),
    comment(losing.source.marker_body, losing.created_at,
      losing.source.author_login, losing.source.comment_id),
  }, INCIDENT_2828_DIAGNOSIS.proposal_id)
  devloop_base.configure_trusted_bot_login(previous_trusted_login)
  if not ok then
    error(state)
  end
  return state
end

local function parent_comments(state, extra_comments)
  local comments = {
    comment(h.state_comment_request(parent, state or "implementing", version).body, "2026-06-03T01:02:03Z"),
    comment(m_builders.pr_delegation_marker(parent, child_pr, pr_number, version, "g1"), "2026-06-03T01:03:03Z"),
  }
  for _, extra in ipairs(extra_comments or {}) do
    table.insert(comments, extra)
  end
  return comments
end

local function pr_comments(child_state)
  local comments = {
    comment(m_builders.pr_origin_marker(parent, issue_number, branch, version, base_branch), "2026-06-03T01:04:03Z"),
  }
  if child_state ~= nil then
    table.insert(comments, comment(core.state_marker(parent, child_state, version), "2026-06-03T02:05:04Z"))
  end
  return comments
end

local function mock_env(write_mode, bot_login)
  h.mock_bot_env(bot_login)
  h.mock_write_env(write_mode or "")
  t.mock_command("gh api graphql", {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function issue_fields(state, labels, extra_comments)
  return {
    repo = repo,
    number = issue_number,
    labels = labels or { "fkst-dev:enabled", "fkst-dev:implementing" },
    comments = parent_comments(state, extra_comments),
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    times = 1,
    register_all_views = true,
  }
end

local function pr_fields(pr_state, merged_at, child_state)
  return {
    repo = repo,
    number = pr_number,
    comments = pr_comments(child_state),
    head = branch,
    head_sha = head_sha,
    merge_commit_sha = merge_commit_sha,
    state = pr_state,
    merged_at = merged_at,
    base_branch = base_branch,
    labels = {},
    times = 1,
    register_all_views = true,
  }
end

local function mock_terminal_child_reads(state, labels, extra_comments, child_state, pr_state)
  entity_mocks.mock_issue_read_forms(t, issue_fields(state, labels, extra_comments))
  local child = pr_fields(pr_state, nil, child_state)
  entity_mocks.mock_pr_read_forms(t, child)
  entity_mocks.mock_pr_view_selector(t, child, entity_mocks.pr_origin_selector, 1)
end

local function incident_2828_issue_fields(labels, extra_comments)
  local comments = {
    incident_2828_comment(INCIDENT_2828_DIAGNOSIS.selected_marker),
    incident_2828_comment(INCIDENT_2828_DIAGNOSIS.losing_marker),
    incident_2828_comment(INCIDENT_2828_DIAGNOSIS.delegation),
  }
  for _, extra in ipairs(extra_comments or {}) do
    table.insert(comments, extra)
  end
  return {
    repo = INCIDENT_2828_DIAGNOSIS.repo,
    number = INCIDENT_2828_DIAGNOSIS.issue_number,
    labels = labels,
    comments = comments,
    assignees = { INCIDENT_2828_DIAGNOSIS.selected_marker.source.author_login },
    author_login = INCIDENT_2828_DIAGNOSIS.selected_marker.source.author_login,
    times = 1,
    register_all_views = true,
  }
end

local function incident_2828_pr_fields()
  return {
    repo = INCIDENT_2828_DIAGNOSIS.repo,
    number = INCIDENT_2828_DIAGNOSIS.pr_number,
    comments = {
      incident_2828_comment(INCIDENT_2828_DIAGNOSIS.pr_origin),
      incident_2828_comment(INCIDENT_2828_DIAGNOSIS.child_head),
      incident_2828_comment(INCIDENT_2828_DIAGNOSIS.child_terminal),
    },
    head = INCIDENT_2828_DIAGNOSIS.pr_origin.branch,
    head_sha = INCIDENT_2828_DIAGNOSIS.child_head.sha,
    state = "CLOSED",
    base_branch = INCIDENT_2828_DIAGNOSIS.pr_origin.base_branch,
    labels = {},
    times = 1,
    register_all_views = true,
  }
end

local function mock_incident_2828_reads(labels, extra_comments)
  entity_mocks.mock_issue_read_forms(t, incident_2828_issue_fields(labels, extra_comments))
  local child = incident_2828_pr_fields()
  entity_mocks.mock_pr_read_forms(t, child)
  entity_mocks.mock_pr_view_selector(t, child, entity_mocks.pr_origin_selector, 1)
end

local function mock_reads(pr_state, merged_at, state, labels, extra_comments)
  entity_mocks.mock_issue_read_forms(t, issue_fields(state, labels, extra_comments))
  entity_mocks.mock_pr_read_forms(t, pr_fields(pr_state, merged_at))
  entity_mocks.mock_pr_view_selector(t, pr_fields(pr_state, merged_at), entity_mocks.pr_origin_selector, 1)
end

local function run_pr_observe(pr_state, merged_at)
  mock_env()
  mock_reads(pr_state, merged_at)
  return t.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = pr_number,
      state = pr_state,
      updated_at = "2026-06-03T02:03:04Z",
      dedup_key = "owner/repo#pr#7@2026-06-03T02:03:04Z",
      source_ref = entity_lib.pr_source_ref(repo, pr_number),
    },
  }, h.opts("implementing-merged-pr-canonicalizer"))
end

local function run_issue_observe(pr_state, merged_at, state)
  mock_env()
  mock_reads(pr_state, merged_at, state)
  return t.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Implement decision recorder",
      state = "OPEN",
      updated_at = "2026-06-03T02:03:04Z",
      dedup_key = "owner/repo#issue#42@2026-06-03T02:03:04Z",
      source_ref = entity_lib.issue_source_ref(repo, issue_number),
    },
  }, h.opts("implementing-merged-pr-canonicalizer-issue-poll"))
end

local function run_issue_close_poll(canonicalization_body)
  h.mock_bot_env()
  for _ = 1, 4 do
    h.mock_write_env("1")
  end
  t.mock_command("gh api graphql", {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = base_branch,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = base_branch,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue close", {
    stdout = "closed\n",
    stderr = "",
    exit_code = 0,
  })
  mock_reads("MERGED", "2026-06-03T02:05:04Z", "awaiting-pr", { "fkst-dev:enabled", "fkst-dev:awaiting-pr" }, {
    comment(canonicalization_body, "2026-06-03T02:06:04Z"),
  })
  return t.run_department("departments/observe_issue/main.lua", {
    queue = "devloop_observe_issue",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Implement decision recorder",
      state = "OPEN",
      updated_at = "2026-06-03T02:10:04Z",
      dedup_key = "owner/repo#issue#42@2026-06-03T02:10:04Z",
      source_ref = entity_lib.issue_source_ref(repo, issue_number),
    },
  }, h.opts("implementing-merged-pr-canonicalizer-close-poll"))
end

local function run_terminal_child_poll(state, labels, extra_comments, child_state, pr_state, fixture)
  mock_env()
  mock_terminal_child_reads(state, labels, extra_comments, child_state, pr_state)
  return t.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Implement decision recorder",
      state = "OPEN",
      updated_at = "2026-06-03T02:10:04Z",
      dedup_key = "owner/repo#issue#42@2026-06-03T02:10:04Z",
      source_ref = entity_lib.issue_source_ref(repo, issue_number),
    },
  }, h.opts(fixture))
end

local function run_incident_2828_terminal_child_poll(labels, extra_comments, fixture)
  local trusted_login = INCIDENT_2828_DIAGNOSIS.selected_marker.source.author_login
  local previous_trusted_login = devloop_base.configured_trusted_bot_login()
  devloop_base.configure_trusted_bot_login(trusted_login)
  local ok, result = pcall(function()
    mock_env(nil, trusted_login)
    mock_incident_2828_reads(labels, extra_comments)
    return t.run_department("departments/observe_issue/main.lua", {
      queue = "github-proxy.github_entity_changed",
      payload = {
        schema = "github-proxy.v1",
        type = "issue",
        repo = INCIDENT_2828_DIAGNOSIS.repo,
        number = INCIDENT_2828_DIAGNOSIS.issue_number,
        title = "github-devloop-intake throughput collapse",
        state = "OPEN",
        updated_at = "2026-08-03T08:47:42Z",
        dedup_key = "ChronoAIProject/fkst-packages#issue#2828@2026-08-03T08:47:42Z",
        source_ref = entity_lib.issue_source_ref(
          INCIDENT_2828_DIAGNOSIS.repo,
          INCIDENT_2828_DIAGNOSIS.issue_number
        ),
      },
    }, h.opts(fixture))
  end)
  devloop_base.configure_trusted_bot_login(previous_trusted_login)
  if not ok then
    error(result)
  end
  return result
end

local function find_raise(raises, queue, predicate)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue and (predicate == nil or predicate(raised.payload or {}, raised)) then
      return raised
    end
  end
  return nil
end

local function count_calls(needle)
  return h.count_calls(needle)
end

return {
  test_incident_2828_sources_are_verifiable = function()
    t.eq(INCIDENT_2828_DIAGNOSIS.selected_marker.source.comment_id,
      "IC_kwDOSwWu288AAAABL_u8eQ")
    t.eq(INCIDENT_2828_DIAGNOSIS.selected_marker.source
      and INCIDENT_2828_DIAGNOSIS.selected_marker.source.url,
      "https://github.com/ChronoAIProject/fkst-packages/issues/2828#issuecomment-5099994233")
    t.eq(INCIDENT_2828_DIAGNOSIS.selected_marker.source.author_login, "ElonSG")
    t.eq(INCIDENT_2828_DIAGNOSIS.losing_marker.source.comment_id,
      "IC_kwDOSwWu288AAAABMYUS-w")
    t.eq(INCIDENT_2828_DIAGNOSIS.losing_marker.source
      and INCIDENT_2828_DIAGNOSIS.losing_marker.source.url,
      "https://github.com/ChronoAIProject/fkst-packages/issues/2828#issuecomment-5125772027")
    t.eq(INCIDENT_2828_DIAGNOSIS.losing_marker.source.author_login, "ElonSG")
    t.eq(INCIDENT_2828_DIAGNOSIS.child_terminal.source.comment_id, "5164218051")
    t.eq(INCIDENT_2828_DIAGNOSIS.child_terminal.source
      and INCIDENT_2828_DIAGNOSIS.child_terminal.source.url,
      "https://github.com/ChronoAIProject/fkst-packages/pull/2832#issuecomment-5164218051")
    t.eq(INCIDENT_2828_DIAGNOSIS.child_terminal.source.author_login, "ElonSG")
  end,

  test_incident_2828_authoritative_diagnosis_is_recorded = function()
    local state = incident_2828_authoritative_state()

    t.eq(state.state, "implementing")
    t.eq(state.version,
      "ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2828/intake/2050103549/loop/1")
  end,

  test_pr_entity_change_merged_child_canonicalizes_implementing_parent_to_awaiting_pr = function()
    local result = run_pr_observe("MERGED", "2026-06-03T02:05:04Z")

    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('state="awaiting-pr"', 1, true) ~= nil
    end)
    t.is_true(comment_raise ~= nil)
    t.is_true(tostring(comment_raise.payload.body):find("fkst:github-devloop:pr-delegation:v1", 1, true) ~= nil)
    t.is_true(tostring(comment_raise.payload.body):find('pr_proposal="' .. child_pr .. '"', 1, true) ~= nil)
    local label_raise = find_raise(result.raises, "github-proxy.github_issue_label_request", function(payload)
      return payload.add_labels[1] == "fkst-dev:awaiting-pr"
    end)
    t.is_true(label_raise ~= nil)
    t.eq(count_calls("gh issue close 42 --repo owner/repo"), 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_issue_poll_merged_child_canonicalizes_implementing_parent_then_parent_poll_closes = function()
    local result = run_issue_observe("MERGED", "2026-06-03T02:05:04Z")

    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('state="awaiting-pr"', 1, true) ~= nil
    end)
    t.is_true(comment_raise ~= nil)
    t.is_true(tostring(comment_raise.payload.body):find("fkst:github-devloop:pr-delegation:v1", 1, true) ~= nil)
    t.is_true(tostring(comment_raise.payload.body):find('pr_proposal="' .. child_pr .. '"', 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)

    local close_result = run_issue_close_poll(comment_raise.payload.body)
    t.eq(close_result.exit_code, 0)
    local close_comment = find_raise(close_result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('state="merged"', 1, true) ~= nil
    end)
    t.is_true(close_comment ~= nil)
    t.eq(count_calls("gh issue close 42 --repo owner/repo --reason completed"), 1)
  end,

  test_issue_poll_closed_unmerged_child_recovers_missing_handoff_then_reimplements_once = function()
    local first = run_incident_2828_terminal_child_poll(
      { "fkst-dev:enabled", "fkst-dev:implementing" },
      nil,
      "implementing-closed-unmerged-canonicalize"
    )

    t.eq(first.exit_code, 0)
    local canonicalization = find_raise(first.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('state="awaiting-pr"', 1, true) ~= nil
    end)
    t.is_true(canonicalization ~= nil)
    t.is_true(tostring(canonicalization.payload.body):find(
      'proposal="' .. INCIDENT_2828_DIAGNOSIS.proposal_id .. '"', 1, true) ~= nil)
    t.is_true(tostring(canonicalization.payload.body):find(
      "Delegated PR: #" .. tostring(INCIDENT_2828_DIAGNOSIS.pr_number), 1, true) ~= nil)

    local second = run_incident_2828_terminal_child_poll(
      { "fkst-dev:enabled", "fkst-dev:awaiting-pr" },
      { incident_2828_emitted_comment(canonicalization.payload.body, "2026-08-03T08:48:42Z") },
      "awaiting-pr-closed-unmerged-resume"
    )

    t.eq(second.exit_code, 0)
    local resumed = find_raise(second.raises, "github-proxy.github_issue_comment_request", function(payload)
      local body = tostring(payload.body or "")
      return body:find('state="ready"', 1, true) ~= nil
        and body:find("/reimplement/1", 1, true) ~= nil
    end)
    t.is_true(resumed ~= nil)

    local third = run_incident_2828_terminal_child_poll(
      { "fkst-dev:enabled", "fkst-dev:ready" },
      {
        incident_2828_emitted_comment(canonicalization.payload.body, "2026-08-03T08:48:42Z"),
        incident_2828_emitted_comment(resumed.payload.body, "2026-08-03T08:49:42Z"),
      },
      "ready-closed-unmerged-idempotent-repoll"
    )

    t.eq(third.exit_code, 0)
    t.eq(find_raise(third.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(find_raise(third.raises, "github-proxy.github_issue_label_request"), nil)
  end,

  test_issue_poll_blocked_child_recovers_missing_handoff_then_blocks_parent = function()
    local first = run_terminal_child_poll(
      "implementing",
      { "fkst-dev:enabled", "fkst-dev:implementing" },
      nil,
      "blocked",
      "OPEN",
      "implementing-blocked-child-canonicalize"
    )

    t.eq(first.exit_code, 0)
    local canonicalization = find_raise(first.raises, "github-proxy.github_issue_comment_request", function(payload)
      local body = tostring(payload.body or "")
      return body:find('state="awaiting-pr"', 1, true) ~= nil
        and body:find("after child blocked state", 1, true) ~= nil
    end)
    t.is_true(canonicalization ~= nil)

    local second = run_terminal_child_poll(
      "awaiting-pr",
      { "fkst-dev:enabled", "fkst-dev:awaiting-pr" },
      { comment(canonicalization.payload.body, "2026-06-03T02:11:04Z") },
      "blocked",
      "OPEN",
      "awaiting-pr-blocked-child-resume"
    )

    t.eq(second.exit_code, 0)
    local blocked = find_raise(second.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('state="blocked"', 1, true) ~= nil
    end)
    t.is_true(blocked ~= nil)
  end,

  test_issue_poll_open_child_with_json_null_merged_at_does_not_canonicalize_parent = function()
    local result = run_issue_observe("OPEN", nil)

    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(count_calls("gh issue close 42 --repo owner/repo"), 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_pr_entity_change_open_child_with_json_null_merged_at_does_not_canonicalize_parent = function()
    local result = run_pr_observe("OPEN", nil)

    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(count_calls("gh issue close 42 --repo owner/repo"), 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,
}
