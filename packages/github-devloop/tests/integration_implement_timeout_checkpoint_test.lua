local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local ready = h.ready
local run_implement = h.run_implement
local mock_issue_implement = h.mock_issue_implement
local deterministic_branch_for = h.deterministic_branch_for
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree_reuse = h.mock_existing_empty_implement_worktree_reuse
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_branch_diff_paths = h.mock_branch_diff_paths
local mock_git_commit = h.mock_git_commit
local mock_issue_view_failure = h.mock_issue_view_failure
local count_calls = h.count_calls
local find_raise = h.find_raise
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
local devloop_base = require("devloop.base")
local payloads_builders = require("devloop.payloads.builders")
local payloads_shared = require("devloop.payloads.shared")
local requests_lifecycle = require("devloop.requests.lifecycle")

local function stale_started_at()
  return tostring(now() - 7201)
end

local function mock_real_write_mode()
  for _ = 1, 6 do
    h.mock_write_env("1")
  end
end

local function mock_remote_branch(branch, head_sha)
  t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'" .. tostring(branch) .. "'^{commit}", {
    stdout = tostring(head_sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("cat-file -p", {
    stdout = "tree aaaaaaa\nparent bbbbbbb\n\nordinary implementation progress\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_missing_remote_branch(branch)
  t.mock_command("git fetch 'origin' '" .. tostring(branch) .. "'", {
    stdout = "",
    stderr = "missing remote branch",
    exit_code = 1,
  })
end

local function mock_harvest_worktree(event, branch)
  local durable_root = "/tmp/fkst-packages-test/github-devloop/durable"
  local stable_root = devloop_base.implementation_worktree_root(durable_root)
  local worktree = devloop_base.implement_worktree_path(stable_root, "owner/repo", 42, event.dedup_key)
  for _ = 1, 2 do
    t.mock_command("[ -d '" .. worktree .. "' ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree .. "\nHEAD abc123\nbranch refs/heads/" .. branch .. "\n\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_remote_checkpoint_worktree_reuse(event, branch, checkpoint_head)
  t.mock_command("git fetch 'origin' 'dev'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'dev'^{commit}", {
    stdout = "abc123\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("show-ref --verify --quiet", {
    stdout = "",
    stderr = "",
    exit_code = 1,
  })
  t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/durable",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git worktree list --porcelain", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("show-ref --verify --quiet", {
    stdout = "",
    stderr = "",
    exit_code = 1,
  })
  h.mock_force_clean("remote-checkpoint-worktree")
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  mock_remote_branch(branch, checkpoint_head)
  t.mock_command("git worktree add --force -B", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("reset --hard", {
    stdout = "HEAD is now at 1111111 checkpoint\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("clean -fd", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("merge --no-edit 'abc123'", {
    stdout = "Already up to date.\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show abc123:.fkst/substrate-ref", {
    stdout = "2222222222222222222222222222222222222222\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show", {
    stdout = "1111111111111111111111111111111111111111\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("add -A", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("commit -m 'chore: refresh fkst-substrate pin'", {
    stdout = "[devloop-owner-repo-42-01HY 9999999] chore: refresh fkst-substrate pin\n",
    stderr = "",
    exit_code = 0,
  })
  mock_harvest_worktree(event, branch)
end

local function mock_stale_local_branch_remote_checkpoint_reuse(event, branch, checkpoint_head)
  local durable_root = "/tmp/fkst-packages-test/github-devloop/durable"
  local stable_root = devloop_base.implementation_worktree_root(durable_root)
  local worktree = devloop_base.implement_worktree_path(stable_root, "owner/repo", 42, event.dedup_key)
  t.mock_command("git fetch 'origin' 'dev'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'dev'^{commit}", {
    stdout = "abc123\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("show-ref --verify --quiet", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
    stdout = durable_root,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git worktree list --porcelain", {
    stdout = "worktree " .. worktree
      .. "\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/"
      .. tostring(branch) .. "\n\n",
    stderr = "",
    exit_code = 0,
  })
  h.mock_force_clean(worktree)
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  mock_remote_branch(branch, checkpoint_head)
  t.mock_command("git worktree add --force -B", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("reset --hard", {
    stdout = "HEAD is now at 1111111 checkpoint\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("clean -fd", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("merge --no-edit 'abc123'", {
    stdout = "Already up to date.\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show abc123:.fkst/substrate-ref", {
    stdout = "2222222222222222222222222222222222222222\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show", {
    stdout = "1111111111111111111111111111111111111111\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("add -A", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("commit -m 'chore: refresh fkst-substrate pin'", {
    stdout = "[devloop-owner-repo-42-01HY 9999999] chore: refresh fkst-substrate pin\n",
    stderr = "",
    exit_code = 0,
  })
  mock_harvest_worktree(event, branch)
end

local function checkpoint_comment(result)
  return find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find("fkst:github-devloop:implement-checkpoint:v1", 1, true) ~= nil
  end)
end

local function mock_local_progress_read(head_sha, receipt_subject)
  t.mock_command("show-ref --verify --quiet", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("rev-list --count", {
    stdout = "1\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("rev-parse --verify refs/heads/", {
    stdout = head_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  mock_branch_diff_paths("packages/github-devloop/core.lua\n", receipt_subject)
end

local function mock_worktree_receipt_read(head_sha, receipt_subject)
  t.mock_command("rev-parse HEAD", {
    stdout = head_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("cat-file -p", {
    stdout = "tree aaaaaaa\nparent bbbbbbb\n\n"
      .. tostring(receipt_subject or "ordinary implementation progress") .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function deadline_redrive_ready(event)
  local payload = payloads_builders.build_devloop_ready_payload({
    proposal_id = event.proposal_id,
    dedup_key = core.ready_payload_inner_version(event.dedup_key),
    source_ref = event.source_ref,
    impl_retry_attempt = core.implementation_retry_attempt(event.dedup_key),
    redrive_delivery = {
      generation_key = "restart-liveness-v2/implementing/implementing.active/codex_run-v1/"
        .. "codex-run-deadline-expired/1786752597000",
      attempt = 1,
    },
  })
  t.eq(payload.dedup_key, payloads_shared.issue_redrive_delivery_dedup_key(
    payload.proposal_id, payload.implementation_version, payload.redrive_delivery))
  return payload
end

local function last_command_call_index(needle)
  local found = nil
  for index, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(needle, 1, true) ~= nil then
      found = index
    end
  end
  return found
end

return {
  test_fresh_runtime_redelivery_harvests_completed_result_without_second_codex = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local code_head = "1111111111111111111111111111111111111111"
    local result_head = "2222222222222222222222222222222222222222"
    local advanced_base_head = "3333333333333333333333333333333333333333"
    local merged_head = "4444444444444444444444444444444444444444"
    local resealed_head = "5555555555555555555555555555555555555555"
    local implementing_comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    }

    mock_issue_implement({ "fkst-dev:ready" }, nil, { times = 2 })
    mock_fresh_implement_worktree()
    mock_implement_codex(0, "completed implementation output")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(code_head, branch, nil, result_head)
    t.mock_command("rev-parse --abbrev-ref HEAD", {
      stdout = branch .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_issue_view_failure("title,body,labels,comments,state,author", "post-output source recheck failed")

    local first_opts = opts("implement-result-first-runtime")
    local first = run_implement(event, first_opts)

    t.eq(first.exit_code, 1)
    t.is_true(tostring(first.error):find("post-output source recheck failed", 1, true) ~= nil)
    t.eq(count_calls("codex exec"), 1)

    mock_issue_implement({ "fkst-dev:implementing" }, implementing_comments)
    mock_missing_remote_branch(branch)
    local worktree = mock_existing_empty_implement_worktree_reuse({
      base_head = advanced_base_head,
      branch = branch,
      ahead_count = "1",
      merge = { stdout = "Merge made by the 'ort' strategy.\n" },
    })
    mock_branch_diff_paths("packages/github-devloop/core.lua\n",
      "fkst: implementation result v1 " .. require("contract.sha256").hex(event.dedup_key))
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = result_head .. "\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse HEAD", {
      stdout = merged_head .. "\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("merge-base --is-ancestor", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    h.mock_result_checkpoint(resealed_head, branch)
    mock_implement_codex(0, "redelivery must not dispatch this result")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("3333333333333333333333333333333333333333", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, implementing_comments)

    local retry_opts = opts("implement-result-fresh-runtime")
    local retry = run_implement(event, retry_opts)

    t.is_true(first_opts.env.FKST_RUNTIME_ROOT ~= retry_opts.env.FKST_RUNTIME_ROOT,
      "completed-result replay must cross fresh runtime roots")
    t.eq(retry.exit_code, 0, tostring(retry.error))
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("commit --allow-empty -m"), 2)
    t.is_true(count_calls("diff --name-only") > 0,
      "completed implementation work must remain reachable while replay reconciles the base")
    local merge_index = last_command_call_index("merge --no-edit")
    local reseal_index = last_command_call_index("commit --allow-empty -m")
    local gate_index = last_command_call_index("scripts/run.sh test-affected")
    t.is_true(merge_index ~= nil, "completed-result replay must call merge_integration")
    t.is_true(reseal_index ~= nil, "completed-result replay must write a replacement receipt")
    t.is_true(gate_index ~= nil, "completed-result replay must enter harvest verification")
    t.is_true(merge_index < reseal_index and reseal_index < gate_index,
      "completed-result replay must merge, reseal, then run harvest verification")
    local final = find_raise(retry.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil, "completed-result replay must publish the harvested implementation")
    local fact = m_facts.implementing_fact({ final.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.base_sha, advanced_base_head)
    t.eq(fact.head_sha, resealed_head)
    t.is_true(tostring(final.payload.body):find(worktree, 1, true) ~= nil,
      "harvested implementation must retain the completed-result worktree")
  end,

  test_deadline_redrive_harvests_receipt_committed_during_replacement_preparation = function()
    local current = ready()
    local event = deadline_redrive_ready(current)
    local branch = deterministic_branch_for(current)
    local progress_head = "1111111111111111111111111111111111111111"
    local receipt_head = "2222222222222222222222222222222222222222"
    mock_issue_implement({ "fkst-dev:ready" }, nil, { times = 2 })
    mock_fresh_implement_worktree()
    mock_implement_codex(0, "completed implementation output")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(progress_head, branch, nil, receipt_head)
    t.mock_command("rev-parse --abbrev-ref HEAD", {
      stdout = branch .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_issue_view_failure("title,body,labels,comments,state,author", "post-output source recheck failed")
    local first_opts = opts("implement-deadline-redrive-orphan-runtime")
    local first = run_implement(event, first_opts)
    t.eq(first.exit_code, 1)
    local first_codex_calls = count_calls("codex exec")
    local first_gate_calls = count_calls("scripts/run.sh test-affected")

    local comments = {
      core.state_marker(current.proposal_id, "implementing", current.dedup_key),
      core.implement_attempt_marker(current.proposal_id, current.dedup_key, 1, stale_started_at()),
    }
    mock_issue_implement({ "fkst-dev:implementing" }, comments)
    mock_missing_remote_branch(branch)
    mock_existing_empty_implement_worktree_reuse(nil, branch, "1")
    t.mock_command("git show " .. branch .. ":.fkst/substrate-ref", {
      stdout = "1111111111111111111111111111111111111111\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = progress_head .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    mock_local_progress_read(progress_head)
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    mock_worktree_receipt_read(receipt_head, "fkst: implementation result v1 "
      .. require("contract.sha256").hex(current.dedup_key))
    mock_implement_codex(0, "deadline redrive must not replace a completed result")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("3333333333333333333333333333333333333333", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, comments)

    local run_opts = opts("implement-deadline-redrive-receipt-race")
    local result = run_implement(event, run_opts)

    t.is_true(first_opts.env.FKST_RUNTIME_ROOT ~= run_opts.env.FKST_RUNTIME_ROOT,
      "receipt harvest must cross fresh runtime roots")
    t.eq(result.exit_code, 0, tostring(result.error))
    t.eq(count_calls("codex exec"), first_codex_calls,
      "completed receipt must suppress replacement Codex")
    t.eq(count_calls("scripts/run.sh test-affected"), first_gate_calls + 1,
      "completed receipt must enter replacement harvest verification")
    local merge_index = last_command_call_index("merge --no-edit")
    local receipt_index = last_command_call_index("cat-file -p")
    local gate_index = last_command_call_index("scripts/run.sh test-affected")
    t.is_true(merge_index ~= nil and receipt_index ~= nil and gate_index ~= nil)
    t.is_true(merge_index < receipt_index and receipt_index < gate_index,
      "replacement must reread the durable receipt after preparation and before harvest")
    local final = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil, "deadline redrive must publish the completed version-bound result")
    local fact = m_facts.implementing_fact({ final.payload.body }, current.proposal_id, current.dedup_key)
    t.eq(fact.head_sha, receipt_head)
  end,

  test_completed_result_merge_conflict_reenters_resolution_before_harvest = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local code_head = "1111111111111111111111111111111111111111"
    local result_head = "2222222222222222222222222222222222222222"
    local advanced_base_head = "3333333333333333333333333333333333333333"
    local resolved_head = "4444444444444444444444444444444444444444"
    local resolved_receipt_head = "5555555555555555555555555555555555555555"
    local implementing_comments = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    }

    mock_issue_implement({ "fkst-dev:ready" }, nil, { times = 2 })
    mock_fresh_implement_worktree()
    mock_implement_codex(0, "completed implementation output")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(code_head, branch, nil, result_head)
    t.mock_command("rev-parse --abbrev-ref HEAD", {
      stdout = branch .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_issue_view_failure("title,body,labels,comments,state,author", "post-output source recheck failed")

    local first = run_implement(event, opts("implement-result-conflict-first-runtime"))
    t.eq(first.exit_code, 1)

    mock_issue_implement({ "fkst-dev:implementing" }, implementing_comments)
    mock_missing_remote_branch(branch)
    mock_existing_empty_implement_worktree_reuse({
      base_head = advanced_base_head,
      branch = branch,
      ahead_count = "1",
      merge = {
        stderr = "CONFLICT (content): merge conflict in packages/github-devloop/core.lua\n",
        exit_code = 1,
        unmerged_stdout = "100644 abc123 1\tpackages/github-devloop/core.lua\n",
      },
    })
    t.mock_command("git show " .. branch .. ":.fkst/substrate-ref", {
      stdout = "1111111111111111111111111111111111111111\n",
      stderr = "",
      exit_code = 0,
    })
    mock_branch_diff_paths("packages/github-devloop/core.lua\n",
      "fkst: implementation result v1 " .. require("contract.sha256").hex(event.dedup_key))
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = result_head .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_implement_codex(0, "resolved integration conflict")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit(resolved_head, branch, nil, resolved_receipt_head)
    mock_issue_implement({ "fkst-dev:implementing" }, implementing_comments)

    local retry = run_implement(event, opts("implement-result-conflict-replay-runtime"))

    t.eq(retry.exit_code, 0, tostring(retry.error))
    t.eq(count_calls("codex exec"), 2)
    local merge_index = last_command_call_index("merge --no-edit")
    local second_codex_index = last_command_call_index("codex exec")
    local gate_index = last_command_call_index("scripts/run.sh test-affected")
    t.is_true(merge_index ~= nil, "conflicted completed-result replay must call merge_integration")
    t.is_true(second_codex_index ~= nil, "conflicted completed-result replay must dispatch resolution")
    t.is_true(gate_index ~= nil, "resolved completed-result replay must enter harvest verification")
    t.is_true(merge_index < second_codex_index and second_codex_index < gate_index,
      "MERGE_SKEW resolution must complete before harvest verification")
    local final = find_raise(retry.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil, "resolved completed-result replay must publish the implementation")
    local fact = m_facts.implementing_fact({ final.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.base_sha, advanced_base_head)
    t.eq(fact.head_sha, resolved_receipt_head)
  end,

  test_checkpoint_request_identity_separates_divergent_reason_replays = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local function checkpoint_request(reason)
      return requests_lifecycle.build_implement_checkpoint_comment_request(core.implement_attempt_marker, core.output_language, "owner/repo",
        42,
        event,
        "/tmp/fkst-packages-test/github-devloop/runtime/worktrees/checkpoint-identity",
        branch,
        "1111111111111111111111111111111111111111",
        "dev",
        "abc123",
        1,
        "123",
        "implement/exec/checkpoint-identity",
        "checkpoint detail",
        reason
      )
    end

    local failed = checkpoint_request("codex-failed")
    local failed_replay = checkpoint_request("codex-failed")
    local verification_indeterminate = checkpoint_request("verification-indeterminate")

    t.eq(failed.dedup_key, failed_replay.dedup_key)
    t.is_true(failed.dedup_key ~= verification_indeterminate.dedup_key)
  end,

  test_dirty_timeout_progress_is_committed_before_verification_and_pushed_as_wip_checkpoint = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local checkpoint_head = "1111111111111111111111111111111111111111"
    mock_issue_implement({ "fkst-dev:ready" })
    mock_fresh_implement_worktree()
    mock_implement_codex(124, "partial progress remains dirty", "codex timed out")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    t.mock_command("rev-list --count", {
      stdout = "0\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
      stdout = "",
      stderr = "local verification failed",
      exit_code = 1,
    })
    mock_git_commit(checkpoint_head, branch)
    mock_real_write_mode()
    t.mock_command("push origin HEAD:refs/heads/" .. branch, {
      stdout = "pushed " .. branch .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    })

    local first = run_implement(event, opts("implement-dirty-timeout-checkpoint", { FKST_GITHUB_WRITE = "1" }))

    t.eq(first.exit_code, 0, "dirty timeout checkpoint pass exits successfully")
    t.eq(count_calls("impl-failed"), 0, "dirty timeout checkpoint pass does not terminalize")
    local checkpoint = checkpoint_comment(first)
    t.is_true(checkpoint ~= nil)
    local checkpoint_fact = m_facts.implement_checkpoint_fact(
      { checkpoint.payload.body },
      event.proposal_id,
      event.dedup_key
    )
    t.eq(checkpoint_fact.head_sha, checkpoint_head)
    t.eq(count_calls("push origin HEAD:refs/heads/"), 1)
    local verification_call = last_command_call_index("scripts/run.sh test-affected")
    local add_call = last_command_call_index("add -A")
    local commit_call = last_command_call_index("commit -m")
    t.is_true(verification_call ~= nil)
    t.is_true(add_call ~= nil and add_call < commit_call)
    t.is_true(commit_call ~= nil and commit_call < verification_call)
  end,

  test_timeout_self_committed_progress_is_pushed_as_wip_checkpoint = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" })
    mock_fresh_implement_worktree()
    mock_implement_codex(124, "partial progress committed", "codex timed out")
    mock_git_status("")
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "1111111111111111111111111111111111111111\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
      stdout = "",
      stderr = "local verification failed",
      exit_code = 1,
    })
    mock_real_write_mode()
    t.mock_command("push origin HEAD:refs/heads/" .. branch, {
      stdout = "pushed " .. branch .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    })

    local result = run_implement(event, opts("implement-timeout-checkpoint", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("push origin HEAD:refs/heads/"), 1)
    t.eq(count_calls("impl-failed"), 0)
    local checkpoint = checkpoint_comment(result)
    t.is_true(checkpoint ~= nil)
    local fact = m_facts.implement_checkpoint_fact({ checkpoint.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.branch, branch)
    t.eq(fact.head_sha, "1111111111111111111111111111111111111111")
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end), nil)
  end,

  test_retry_continues_from_wip_checkpoint_without_opening_pr_from_checkpoint_head = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local checkpoint_head = "1111111111111111111111111111111111111111"
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
      m_builders.implement_checkpoint_marker(event.proposal_id, event.dedup_key, branch, checkpoint_head, "dev", "abc123", 1),
    })
    mock_remote_branch(branch, checkpoint_head)
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    mock_remote_checkpoint_worktree_reuse(event, branch, checkpoint_head)
    mock_implement_codex(0, "finished from checkpoint")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("2222222222222222222222222222222222222222", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    })

    local result = run_implement(event, opts("implement-timeout-checkpoint-retry"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("git worktree add --force -B"), 1)
    t.eq(count_calls("git worktree add -b"), 0)
    local final = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil)
    local fact = m_facts.implementing_fact({ final.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.head_sha, "2222222222222222222222222222222222222222")
  end,

  test_unmarked_remote_progress_is_retried_not_handed_off = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local checkpoint_head = "1111111111111111111111111111111111111111"
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    })
    mock_remote_branch(branch, checkpoint_head)
    mock_remote_checkpoint_worktree_reuse(event, branch, checkpoint_head)
    mock_implement_codex(0, "finished from unmarked checkpoint")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("2222222222222222222222222222222222222222", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    })

    local result = run_implement(event, opts("implement-timeout-unmarked-remote-progress"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("git worktree add --force -B"), 1)
    local final = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil)
    local fact = m_facts.implementing_fact({ final.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.head_sha, "2222222222222222222222222222222222222222")
  end,

  test_exhausted_redrive_reuses_unmarked_local_progress_through_verification_and_publication = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 2, stale_started_at()),
    })
    mock_missing_remote_branch(branch)
    mock_existing_empty_implement_worktree_reuse(nil, branch, "1")
    mock_local_progress_read("1111111111111111111111111111111111111111")
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git show " .. branch .. ":.fkst/substrate-ref", {
      stdout = "1111111111111111111111111111111111111111\n",
      stderr = "",
      exit_code = 0,
    })
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "1111111111111111111111111111111111111111\n",
      stderr = "",
      exit_code = 0,
    })
    mock_worktree_receipt_read("1111111111111111111111111111111111111111")
    mock_implement_codex(0, "finished from local progress")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("2222222222222222222222222222222222222222", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 2, stale_started_at()),
    })

    local result = run_implement(event, opts("implement-timeout-unmarked-local-progress"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("git worktree add --force -B"), 0)
    t.eq(count_calls("scripts/run.sh test-affected"), 1)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('state="impl-failed"', 1, true) ~= nil
    end), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find('state="awaiting-pr"', 1, true) ~= nil
    end), nil)
    local final = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil)
    t.is_true(tostring(final.payload.body or ""):find("github-devloop implementation output published", 1, true) ~= nil)
    t.is_true(tostring(final.payload.body or ""):find("fkst:github-devloop:implement-attempt:v1", 1, true) ~= nil)
    t.is_true(tostring(final.payload.body or ""):find('attempt="3"', 1, true) ~= nil)
    local fact = m_facts.implementing_fact({ final.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.head_sha, "2222222222222222222222222222222222222222")
  end,

  test_retry_prefers_wip_checkpoint_over_stale_local_branch = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local checkpoint_head = "1111111111111111111111111111111111111111"
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
      m_builders.implement_checkpoint_marker(event.proposal_id, event.dedup_key, branch, checkpoint_head, "dev", "abc123", 1),
    })
    mock_remote_branch(branch, checkpoint_head)
    mock_local_progress_read(checkpoint_head)
    mock_stale_local_branch_remote_checkpoint_reuse(event, branch, checkpoint_head)
    mock_worktree_receipt_read(checkpoint_head)
    mock_implement_codex(0, "finished from checkpoint")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("2222222222222222222222222222222222222222", branch)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, stale_started_at()),
    })

    local result = run_implement(event, opts("implement-timeout-checkpoint-stale-local"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("git worktree add --force -B"), 1)
    t.eq(count_calls("git worktree add '"), 0)
    local final = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:implementing:v1", 1, true) ~= nil
    end)
    t.is_true(final ~= nil)
    local fact = m_facts.implementing_fact({ final.payload.body }, event.proposal_id, event.dedup_key)
    t.eq(fact.head_sha, "2222222222222222222222222222222222222222")
  end,
}
