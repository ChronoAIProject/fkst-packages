local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local ready = h.ready
local run_implement = h.run_implement
local mock_issue_implement = h.mock_issue_implement
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree = h.mock_existing_empty_implement_worktree
local mock_existing_implement_branch = h.mock_existing_implement_branch
local mock_git_push = h.mock_git_push
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local mock_bot_env = h.mock_bot_env
local mock_write_env = h.mock_write_env
local deterministic_branch_for = h.deterministic_branch_for
local find_raise = h.find_raise
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local conv_reconcile = require("devloop.convergence.reconcile")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local sink_inventory = require("core.restart.sink_inventory")
local restart_inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}

local proposal_id = "github-devloop/issue/owner/repo/42"
local pr_proposal_id = "github-devloop/pr/owner/repo/7"
local head_sha = "def456"
local base_sha = "abc123"

local function pr_list_json(branch)
  return '[{"number":7,"head":{"ref":"' .. branch .. '","sha":"' .. head_sha .. '"},"base":{"ref":"dev"},"state":"open"}]\n'
end

local function mock_pr_child_adoptable(branch)
  t.mock_command(core.gh_pr_list_head_base_cmd("owner/repo", branch, "dev"), {
    stdout = pr_list_json(branch),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_remote_implementation_branch(branch)
  t.mock_command("git fetch origin " .. tostring(branch), {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/origin/" .. tostring(branch) .. "^{commit}", {
    stdout = head_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_real_write_mode()
  for _ = 1, 6 do
    mock_write_env("1")
  end
end

local function command_index(needle, first_index)
  for index, call in ipairs(t.command_calls()) do
    if index >= (first_index or 1)
      and tostring(call.rendered or ""):find(needle, 1, true) ~= nil then
      return index
    end
  end
  return nil
end

local function rendered_calls(first_index)
  local calls = {}
  for index, call in ipairs(t.command_calls()) do
    if index >= first_index then table.insert(calls, tostring(call.rendered or "")) end
  end
  return table.concat(calls, " | ")
end

local function contains(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then return true end
  end
  return false
end

local function sink_probe_cases()
  local ready_apply = ready()
  local implementing_retry = ready()
  local impl_failed_retry = ready({ impl_retry_attempt = 2 })
  local blocked_open_pr = ready({ impl_retry_attempt = 2 })
  local open_pr_blocked_version = blocked_open_pr.dedup_key .. "/review-loop/3"
  blocked_open_pr.operator_reentry = {
    command = "reimplement", from_state = "blocked", pr_number = 7,
    state_version = open_pr_blocked_version, impl_version = blocked_open_pr.dedup_key,
  }
  local blocked_timeout = ready({ impl_retry_attempt = 2 })
  local timeout_blocked_version = conv_reconcile.timeout_reconcile_state_version(
    blocked_timeout.dedup_key, "implementing", 3
  )
  blocked_timeout.operator_reentry = {
    command = "reimplement", from_state = "blocked",
    terminal_reason = "implementing-timeout-without-pr",
    state_version = timeout_blocked_version, impl_version = blocked_timeout.dedup_key,
    timeout_round = 3,
  }
  return {
    {
      id = "r9-shadow-implement-success", event = ready_apply, labels = { "fkst-dev:ready" },
      comments = { core.state_marker(ready_apply.proposal_id, "ready", ready_apply.dedup_key) },
      owns = {
        codex = { "github-devloop/ready/entry/implementation_kicked_off/apply" },
        git = { "github-devloop/ready/entry/implementation_kicked_off/apply",
          "github-devloop/implementing/autonomous/revision_published/apply" },
      },
    },
    {
      id = "r9-shadow-implementing-liveness-retry", event = implementing_retry,
      labels = { "fkst-dev:implementing" }, no_visible_progress = true,
      comments = { core.state_marker(implementing_retry.proposal_id, "implementing", implementing_retry.dedup_key) },
      owns = { codex = { "github-devloop/ready/entry/implementation_kicked_off/idempotent" },
        git = { "github-devloop/ready/entry/implementation_kicked_off/idempotent" } },
    },
    {
      id = "r9-shadow-impl-failed-retry", event = impl_failed_retry,
      labels = { "fkst-dev:impl-failed" },
      comments = { core.state_marker(impl_failed_retry.proposal_id, "impl-failed", impl_failed_retry.dedup_key),
        core.impl_failure_marker(impl_failed_retry.proposal_id, impl_failed_retry.dedup_key, "codex-failed", 1) },
      owns = { codex = { "github-devloop/impl-failed/entry/retry-implementation/apply" },
        git = { "github-devloop/impl-failed/entry/retry-implementation/apply" } },
    },
    {
      id = "r9-shadow-reimplement-blocked-open-pr", event = blocked_open_pr,
      labels = { "fkst-dev:blocked" }, issue_read_count = 3,
      comments = { m_builders.pr_link_marker(blocked_open_pr.proposal_id, 7,
        "devloop-owner-repo-42-01HY", blocked_open_pr.dedup_key, "dev"),
        core.state_marker(blocked_open_pr.proposal_id, "blocked", open_pr_blocked_version) },
      owns = { codex = { "github-devloop/implementing/operator_reentry/reimplement_blocked_open_pr/apply" },
        git = { "github-devloop/implementing/operator_reentry/reimplement_blocked_open_pr/apply" } },
    },
    {
      id = "r9-shadow-reimplement-blocked-implementing-timeout-without-pr", event = blocked_timeout,
      labels = { "fkst-dev:blocked" }, issue_read_count = 3,
      comments = { core.state_marker(blocked_timeout.proposal_id, "implementing", blocked_timeout.dedup_key),
        core.state_marker(blocked_timeout.proposal_id, "blocked", timeout_blocked_version),
        conv_reconcile.timeout_reconcile_marker(blocked_timeout.proposal_id, blocked_timeout.dedup_key,
          "implementing", 3, "drop", { terminal_version = timeout_blocked_version,
            from_state = "implementing", from_version = blocked_timeout.dedup_key,
            reason_class = "state-output-obligation-timeout", source_ref = blocked_timeout.source_ref }) },
      owns = { codex = { "github-devloop/implementing/operator_reentry/reimplement_blocked_implementing_timeout_without_pr/apply" },
        git = { "github-devloop/implementing/operator_reentry/reimplement_blocked_implementing_timeout_without_pr/apply" } },
    },
  }
end

local function run_old_sink_probe(probe)
  local event = probe.event
  local branch = deterministic_branch_for(event)
  local first_call = #t.command_calls() + 1
  for _ = 1, probe.issue_read_count or 1 do
    mock_issue_implement(probe.labels, probe.comments)
  end
  if probe.no_visible_progress then
    t.mock_command("git fetch 'origin' '" .. branch .. "'", {
      stdout = "", stderr = "fatal: couldn't find remote ref", exit_code = 128,
    })
    t.mock_command("show-ref --verify --quiet", { stdout = "", stderr = "", exit_code = 1 })
  end
  mock_fresh_implement_worktree()
  mock_implement_codex(0, "implemented")
  mock_git_status(" M packages/github-devloop/core.lua\n")
  mock_git_commit(head_sha, branch)
  mock_git_push(branch)
  t.mock_command(core.gh_pr_list_head_base_cmd("owner/repo", branch, "dev"), {
    stdout = "[]\n", stderr = "", exit_code = 0,
  })
  t.mock_command("gh pr create", {
    stdout = "https://github.example/owner/repo/pull/7\n", stderr = "", exit_code = 0,
  })
  mock_pr_child_adoptable(branch)
  mock_bot_env()
  mock_real_write_mode()

  local result = run_implement(event, opts(probe.id, { FKST_GITHUB_WRITE = "1" }))
  local codex_index = command_index("codex exec", first_call)
  local push_index = command_index("push origin HEAD:refs/heads/" .. branch, first_call)
  t.eq(result.exit_code, 0, probe.id .. ": OLD path outcome: "
    .. tostring(result.error or result.stderr or "no error detail"))
  t.is_true(codex_index ~= nil and push_index ~= nil and codex_index < push_index,
    probe.id .. ": OLD dispatches implement codex before successful implementation git push; calls="
      .. rendered_calls(first_call))
end

local function visible_child_comments(event, branch)
  return {
    m_builders.pr_origin_marker(event.proposal_id, 42, branch, event.dedup_key, "dev")
      .. "\n" .. core.state_marker(event.proposal_id, "pr-open", event.dedup_key),
  }
end

local function visible_issue_comments(event, branch)
  return {
    core.state_marker(event.proposal_id, "implementing", event.dedup_key),
    m_builders.implementing_marker(event.proposal_id, event.dedup_key, branch, head_sha, "dev", base_sha),
    m_builders.pr_delegation_marker(event.proposal_id, pr_proposal_id, 7, event.dedup_key, "g1"),
  }
end

local function mock_linked_pr_view(comments, branch)
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = "owner/repo",
    number = 7,
    comments = comments,
    head = branch,
    head_sha = head_sha,
    base_branch = "dev",
    state = "OPEN",
  }, entity_read_mocks.pr_origin_selector)
end

local function find_body_raise(raises, queue, text)
  return find_raise(raises, queue, function(payload)
    return tostring(payload.body or ""):find(text, 1, true) ~= nil
  end)
end

local function first_line(body)
  return (tostring(body or ""):match("^[^\n]*"))
end

return {
  test_implement_success_visible_child_flips_parent_to_awaiting_pr = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:implementing" }, visible_issue_comments(event, branch), {
      title = "Implement decision recorder",
    })
    mock_linked_pr_view(visible_child_comments(event, branch), branch)
    mock_pr_child_adoptable(branch)
    mock_remote_implementation_branch(branch)
    mock_existing_implement_branch(head_sha)
    mock_bot_env()
    mock_real_write_mode()

    local result = run_implement(event, opts("saga-flip-visible-child", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    local comment = find_body_raise(result.raises, "github-proxy.github_issue_comment_request", 'state="awaiting-pr"')
    t.is_true(comment ~= nil)
    t.eq(first_line(comment.payload.body), "github-devloop parent issue advanced to awaiting-pr for delegated PR #7")
    t.is_true(tostring(comment.payload.body):find("fkst:github-devloop:pr-delegation:v1", 1, true) ~= nil)
    t.is_true(tostring(comment.payload.body):find('pr="7"', 1, true) ~= nil)
    local label = find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.is_true(label ~= nil)
    t.eq(label.payload.add_labels[1], "fkst-dev:awaiting-pr")
  end,

  test_implement_success_pre_await_missing_child_start_acks_without_parent_awaiting_pr = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" }, {
      core.state_marker(event.proposal_id, "ready", event.dedup_key),
    })
    mock_existing_empty_implement_worktree()
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(head_sha, branch)
    mock_git_push(branch)
    t.mock_command(core.gh_pr_list_head_base_cmd("owner/repo", branch, "dev"), {
      stdout = "[]\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh pr create", { stdout = "https://github.example/owner/repo/pull/7\n", stderr = "", exit_code = 0 })
    mock_pr_child_adoptable(branch)
    mock_bot_env()
    mock_real_write_mode()

    local result = run_implement(event, opts("saga-flip-child-start-not-visible", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.is_true(find_body_raise(result.raises, "github-proxy.github_pr_comment_request", 'state="pr-open"') ~= nil)
    t.is_true(find_body_raise(result.raises, "github-proxy.github_issue_comment_request", "fkst:github-devloop:pr-delegation:v1") ~= nil)
    t.eq(find_body_raise(result.raises, "github-proxy.github_issue_comment_request", 'state="awaiting-pr"'), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request", function(payload)
      return payload.add_labels[1] == "fkst-dev:awaiting-pr"
    end), nil)
    local push_index = command_index("push origin HEAD:refs/heads/" .. branch)
    local create_index = command_index("gh pr create")
    t.is_true(push_index ~= nil)
    t.is_true(create_index ~= nil)
    t.is_true(push_index < create_index)
  end,

  test_r9_shadow_old_ready_apply_reaches_shared_sinks = function()
    run_old_sink_probe(sink_probe_cases()[1])
  end,

  test_r9_shadow_old_implementing_liveness_retry_reaches_shared_sinks = function()
    run_old_sink_probe(sink_probe_cases()[2])
  end,

  test_r9_shadow_old_impl_failed_retry_reaches_shared_sinks = function()
    run_old_sink_probe(sink_probe_cases()[3])
  end,

  test_r9_shadow_old_blocked_open_pr_reentry_reaches_shared_sinks = function()
    run_old_sink_probe(sink_probe_cases()[4])
  end,

  test_r9_shadow_old_blocked_timeout_reentry_reaches_shared_sinks = function()
    run_old_sink_probe(sink_probe_cases()[5])
  end,

  test_r9_shadow_corpus_binds_every_reaching_old_probe = function()
    local probes = sink_probe_cases()
    local corpus = json.decode(file.read(
      "migration/intent_bounded_replay/corpus/implement-activation.json"
    ))
    local captures = corpus.captured_sink_effects
    t.eq(#captures, 2)
    local inventory_by_kind = {}
    for _, sink in ipairs(sink_inventory) do
      if sink.callsite.department == "implement"
        and (sink.effect_kind == "codex" or sink.effect_kind == "git") then
        inventory_by_kind[sink.effect_kind] = sink
      end
    end
    local entitlement_ids = {}
    for _, edge in ipairs(owner_pending_projection.edges(
      core.restart_package_name, core.restart_transition_table(), restart_inventories
    )) do
      for _, status in ipairs({ "apply", "idempotent" }) do
        local entitlement = edge.transition_effect_entitlements
          and edge.transition_effect_entitlements[status]
        if entitlement ~= nil then entitlement_ids[entitlement.id] = true end
      end
    end
    local captures_by_kind = {}
    local call_tokens = { codex = "workflow_codex.dispatch", git = "git_push" }
    for ordinal, capture in ipairs(captures) do
      captures_by_kind[capture.sink_kind] = capture
      local inventory = inventory_by_kind[capture.sink_kind]
      t.eq(capture.ordinal, ordinal)
      t.eq(capture.effect_id, inventory.id)
      t.eq(inventory.authority_class, "lifecycle-authoritative")
      for _, entitlement_id in ipairs(capture.owning_effect_entitlement_ids) do
        t.eq(entitlement_ids[entitlement_id], true)
      end
      local path, line_number = capture.old_callsite:match("^([^:]+):(%d+)$")
      local selected_line = nil
      local index = 0
      for line in (file.read(path) .. "\n"):gmatch("(.-)\n") do
        index = index + 1
        if index == tonumber(line_number) then selected_line = line break end
      end
      t.is_true(selected_line ~= nil
        and selected_line:find(call_tokens[capture.sink_kind], 1, true) ~= nil)
    end
    for _, probe in ipairs(probes) do
      for sink_kind, owned_ids in pairs(probe.owns) do
        local capture = captures_by_kind[sink_kind]
        t.is_true(contains(capture.old_probe_ids, probe.id), probe.id .. ": OLD probe is recorded")
        for _, entitlement_id in ipairs(owned_ids) do
          t.is_true(contains(capture.owning_effect_entitlement_ids, entitlement_id),
            probe.id .. ": reaching edge owns " .. sink_kind .. " sink")
        end
      end
    end
  end,

  test_implement_liveness_redrive_reaches_awaiting_pr = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:implementing" }, visible_issue_comments(event, branch), {
      title = "Implement decision recorder",
    })
    mock_linked_pr_view(visible_child_comments(event, branch), branch)
    mock_pr_child_adoptable(branch)
    mock_remote_implementation_branch(branch)
    mock_existing_implement_branch(head_sha)
    mock_bot_env()
    mock_real_write_mode()

    local redriven = run_implement(event, opts("saga-flip-liveness-redrive-to-awaiting-pr", { FKST_GITHUB_WRITE = "1" }))

    t.eq(redriven.exit_code, 0)
    local comment = find_body_raise(redriven.raises, "github-proxy.github_issue_comment_request", 'state="awaiting-pr"')
    t.is_true(comment ~= nil)
    t.is_true(tostring(comment.payload.body):find("fkst:github-devloop:pr-delegation:v1", 1, true) ~= nil)
    t.is_true(find_raise(redriven.raises, "github-proxy.github_issue_label_request", function(payload)
      return payload.add_labels[1] == "fkst-dev:awaiting-pr"
    end) ~= nil)
  end,
}
