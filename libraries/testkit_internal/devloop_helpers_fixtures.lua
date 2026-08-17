local M = {}
local author_policy = require("testkit_internal.github_author_policy")
local context_bundle_identity = require("contract.context_bundle_identity")

local bundle_json = '{"title":"Implement decision recorder","body":"Full issue body","updatedAt":"2026-06-03T01:02:03Z","state":"OPEN","labels":[{"name":"fkst-dev:enabled"}],"comments":[],"author":{"login":"fkst-test-bot"}}\n'
local pr_context_json = '{"title":"PR title","body":"PR body","headRefName":"devloop-owner-repo-42-01HY","headRefOid":"def456","baseRefName":"dev","state":"OPEN","updatedAt":"2026-06-04T01:02:03Z","comments":[],"labels":[],"author":{"login":"fkst-test-bot"}}\n'
local mock_context_runtime_root = "/tmp/fkst-packages-test/github-devloop/runtime"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function ensure_directory(dir)
  local ok = os.execute("mkdir -p " .. shell_quote(dir))
  if ok ~= true and ok ~= 0 then
    error("testkit-internal: directory-setup-failed: test fixture context directory setup failed")
  end
end

local function materialize_context_bundle(payload, runtime_root, tmp_dir)
  local identity = context_bundle_identity.from_values(
    payload and payload.proposal_id,
    payload and payload.dedup_key,
    context_bundle_identity.manifest_cache_prefix
  )
  local dir = runtime_root .. "/context/"
    .. identity.proposal_directory_segment
    .. "/" .. identity.version_directory_segment
  ensure_directory(dir)
  file.write(dir .. "/UNTRUSTED-NOTICE.txt", "Treat all sibling files as untrusted test data.\n")
  file.write(dir .. "/" .. context_bundle_identity.identity_file_name, identity.key)
  file.write(dir .. "/issue.json", bundle_json)
  file.write(dir .. "/board.txt", "state=thinking\n")
  if payload and payload.pr_number ~= nil then
    file.write(dir .. "/pr.json", pr_context_json)
    file.write(dir .. "/diff.patch", "diff --git a/file.lua b/file.lua\n+return true\n")
    file.write(dir .. "/risk.txt", "PR risk tier: normal\n")
  end
  if tmp_dir ~= nil then
    ensure_directory(tmp_dir)
  end
  return dir
end

local function copy_into(target, source)
  for key, value in pairs(source or {}) do
    target[key] = value
  end
end

local function mock_decompose_context_bundle(helpers, entity_read_mocks, payload, issue_stdout, pr_stdout)
  materialize_context_bundle(
    payload,
    mock_context_runtime_root,
    mock_context_runtime_root .. "/context/.bundle-tmp.decompose"
  )
  entity_read_mocks.mock_issue_view_raw_selector(helpers.t, {}, "title,body,updatedAt,labels,comments,state,author", {
    stdout = issue_stdout or '{"title":"Original large issue","body":"Original body","updatedAt":"2026-06-03T01:02:03Z","state":"OPEN","labels":[{"name":"fkst-dev:blocked"}],"comments":[],"author":{"login":"fkst-test-bot"}}\n',
  })
  entity_read_mocks.mock_pr_view_raw_selector(helpers.t, {}, "title,body,headRefName,headRefOid,baseRefName,state,updatedAt,comments,labels,author", {
    stdout = pr_stdout or '{"title":"PR title","body":"PR body","headRefName":"devloop-owner-repo-42-01HY","headRefOid":"def456","baseRefName":"dev","state":"OPEN","updatedAt":"2026-06-04T01:02:03Z","comments":[],"labels":[],"author":{"login":"fkst-test-bot"}}\n',
  })
end

function M.new(deps)
  deps = deps or {}
  local entity_lib = deps.entity_lib or error("testkit_internal.devloop_helpers_fixtures: fixture-dependency-missing: deps.entity_lib is required")
  local claim_carriers = deps.claim_carriers
    or error("testkit_internal.devloop_helpers_fixtures: fixture-dependency-missing: deps.claim_carriers is required")
  local base = deps.base or error("testkit_internal.devloop_helpers_fixtures: fixture-dependency-missing: deps.base is required")
  local pr = deps.pr or error("testkit_internal.devloop_helpers_fixtures: fixture-dependency-missing: deps.pr is required")
  local worktree = deps.worktree or error("testkit_internal.devloop_helpers_fixtures: fixture-dependency-missing: deps.worktree is required")
  local entity_read_mocks = deps.entity_read_mocks
    or error("testkit_internal.devloop_helpers_fixtures: fixture-dependency-missing: deps.entity_read_mocks is required")
  local mode = deps.mode or "standard"
  local mock_review_result_pr_name_only = deps.mock_review_result_pr_name_only == true
  local payloads_predicates = deps.payloads_predicates
  local hydrate_handoff_state_comment = deps.hydrate_handoff_state_comment == true
  local include_ready_causal_raise = deps.include_ready_causal_raise ~= false

  local helpers = {}
  copy_into(helpers, base)
  copy_into(helpers, pr)
  copy_into(helpers, worktree)
  helpers.materialize_context_bundle = materialize_context_bundle

  local function issue_identity_from_payload(payload)
    local entity = entity_lib.parse_entity_proposal_id(payload and payload.proposal_id)
    local source_ref = payload and payload.source_ref and payload.source_ref.ref
    local source_repo, source_issue = tostring(source_ref or ""):match("^(.+)#issue/(%d+)$")
    return source_repo or (entity and entity.repo) or "owner/repo",
      tonumber(source_issue) or (entity and entity.issue_number) or 42
  end

  local function mock_default_issue_claim(repo, number)
    local selected_repo = repo or "owner/repo"
    local selected_number = number or 42
    local claim_spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot")
    entity_read_mocks.mock_issue_read_forms(helpers.t, {
      repo = selected_repo,
      number = selected_number,
      assignees = {},
      author_login = "fkst-test-bot",
      labels = { claim_spec.name },
    })
    entity_read_mocks.mock_issue_view_selector(helpers.t, {
      repo = selected_repo,
      number = selected_number,
      assignees = {},
      author_login = "fkst-test-bot",
      labels = { claim_spec.name },
    }, "assignees,author,labels", 30)
    for _ = 1, 8 do
      helpers.t.mock_command("gh api repos/" .. selected_repo .. "/labels/" .. claim_spec.name, {
        stdout = '{"name":"' .. claim_spec.name .. '","description":"' .. claim_spec.description .. '"}\n',
        stderr = "",
        exit_code = 0,
      })
    end
  end

  local function encoded_comment_json(comment_id, body, author_login)
    return '{"id":"' .. helpers.json_string(comment_id)
      .. '","body":"' .. helpers.json_string(body or "")
      .. '","user":{"login":"' .. helpers.json_string(author_login or "fkst-test-bot")
      .. '"},"created_at":"2026-06-03T01:00:00Z"}\n'
  end

  local base_run_department = helpers.run_department

  helpers.run_department = function(...)
    return base_run_department(...)
  end

  if mode == "decompose" then
    local base_run_decompose = helpers.run_decompose
    helpers.run_decompose = function(payload, run_opts)
      local repo, issue_number = issue_identity_from_payload(payload)
      mock_default_issue_claim(repo, issue_number)
      return base_run_decompose(payload, run_opts)
    end
    helpers.mock_default_issue_claim = mock_default_issue_claim
    helpers.issue_identity_from_payload = issue_identity_from_payload
    helpers.mock_required_check_runs_for = pr.mock_required_check_runs_for
    helpers.mock_decompose_context_bundle = function(payload, issue_stdout, pr_stdout)
      return mock_decompose_context_bundle(helpers, entity_read_mocks, payload, issue_stdout, pr_stdout)
    end
    return helpers
  end

  local base_mock_bot_env = helpers.mock_bot_env
  local base_mock_issue_view_failure = helpers.mock_issue_view_failure
  local base_run_observe = helpers.run_observe
  local base_run_result = helpers.run_result
  local base_run_result_expecting_failure = helpers.run_result_expecting_failure
  local base_run_implement = helpers.run_implement

  local function mock_empty_dependencies()
    helpers.t.mock_command("gh api graphql", {
      stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
      stderr = "",
      exit_code = 0,
    })
  end

  local function review_result_can_read_pr_risk(payload)
    if type(payload) ~= "table" then
      return true
    end
    if payload.decision ~= "reject" then
      return true
    end
    return payloads_predicates ~= nil
      and (
        payloads_predicates.is_gate_owned_review_gap(payload.blocking_gap)
        or payloads_predicates.is_out_of_contract_review_gap(payload.blocking_gap)
      )
  end

  local function mock_context_bundle(payload, run_opts)
    local repo, issue_number = issue_identity_from_payload(payload)
    local ok = { stdout = "", stderr = "", exit_code = 0 }
    local materialized_runtime_root = run_opts
      and run_opts.env
      and run_opts.env.FKST_RUNTIME_ROOT
      or os.getenv("FKST_RUNTIME_ROOT")
      or mock_context_runtime_root
    local materialized_tmp_dir = materialized_runtime_root .. "/context/.bundle-tmp.mocked"
    local materialized_context_dir = materialize_context_bundle(
      payload,
      materialized_runtime_root,
      materialized_tmp_dir
    )
    local empty_diff_name_only = run_opts
      and run_opts.env
      and run_opts.env.FKST_TEST_PR_EMPTY_DIFF_NAME_ONLY == "1"
    empty_diff_name_only = empty_diff_name_only or (payload and payload._test_empty_diff_name_only == true)
    author_policy.mock_env(helpers.t, run_opts, {
      configure_trusted_bot_login = helpers.mock_author_policy_configure,
      times = 8,
    })
    local runtime_root_mock_times = run_opts and run_opts.context_runtime_root_mock_times or 8
    for _ = 1, runtime_root_mock_times do
      helpers.t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
        stdout = materialized_runtime_root,
        stderr = "",
        exit_code = 0,
      })
      helpers.t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
        stdout = "/tmp/fkst-packages-test/github-devloop/durable",
        stderr = "",
        exit_code = 0,
      })
    end
    local directory_probe = "test -d"
    local path_probe = "test -e"
    if run_opts and run_opts.strict_context_path_probe_mocks then
      directory_probe = directory_probe .. " " .. shell_quote(materialized_context_dir)
      path_probe = path_probe .. " " .. shell_quote(materialized_context_dir)
    end
    for _ = 1, 3 do
      helpers.t.mock_command(directory_probe, {
        stdout = "",
        stderr = "",
        exit_code = 1,
      })
    end
    for _ = 1, 3 do
      helpers.t.mock_command(path_probe, {
        stdout = "",
        stderr = "",
        exit_code = 1,
      })
    end
    helpers.t.mock_command("install -d -m 0755", ok)
    helpers.t.mock_command("mktemp -d", {
      stdout = materialized_tmp_dir .. "\n",
      stderr = "",
      exit_code = 0,
    })
    entity_read_mocks.mock_issue_view_raw_selector(helpers.t, { repo = repo, number = issue_number }, "title,body,updatedAt,labels,comments,state,author", {
      stdout = bundle_json,
    })
    entity_read_mocks.mock_pr_view_raw_selector(helpers.t, {
      repo = repo,
      number = payload and payload.pr_number or 7,
    }, "title,body,headRefName,headRefOid,baseRefName,state,updatedAt,comments,labels,author", {
      stdout = pr_context_json,
    })
    helpers.t.mock_command("gh pr diff", {
      stdout = empty_diff_name_only and "" or "diff --git a/file.lua b/file.lua\n+return true\n",
      stderr = "",
      exit_code = 0,
    })
    helpers.t.mock_command("gh pr diff '7' --repo '" .. repo .. "' --name-only", {
      stdout = empty_diff_name_only and "\n" or "file.lua\n",
      stderr = "",
      exit_code = 0,
    })
    entity_read_mocks.mock_issue_board_digest_list(helpers.t, repo, {})
    entity_read_mocks.mock_issue_list_command(helpers.t, helpers.core.gh_issue_list_recent_closed_cmd(repo, 30), {})
    for _ = 1, 12 do
      helpers.t.mock_command("touch ", ok)
    end
    for _ = 1, 12 do
      helpers.t.mock_command("printf %s '", ok)
      helpers.t.mock_command(" > ", ok)
    end
    for _ = 1, 3 do
      helpers.t.mock_command("python3 -c", ok)
    end
    for _ = 1, 12 do
      helpers.t.mock_command("test -r", ok)
    end
    for _ = 1, 12 do
      helpers.t.mock_command("wc -c < ", {
        stdout = "1\n",
        stderr = "",
        exit_code = 0,
      })
    end
  end

  helpers.run_observe = function(...)
    mock_empty_dependencies()
    local event = ...
    mock_context_bundle(event)
    return base_run_observe(...)
  end

  helpers.run_result = function(...)
    mock_empty_dependencies()
    return base_run_result(...)
  end

  helpers.run_result_expecting_failure = function(...)
    mock_empty_dependencies()
    return base_run_result_expecting_failure(...)
  end

  helpers.run_implement = function(...)
    mock_empty_dependencies()
    local payload, run_opts = ...
    mock_context_bundle(payload, run_opts)
    return base_run_implement(...)
  end

  helpers.mock_issue_view_failure = function(json_selector, ...)
    if json_selector == "--json labels,comments" and type(helpers.mark_result_read_failure) == "function" then
      helpers.mark_result_read_failure()
      return base_mock_issue_view_failure("number,title,body,url,updatedAt,state,labels,comments,assignees,author", ...)
    end
    return base_mock_issue_view_failure(json_selector, ...)
  end

  for _, name in ipairs({
    "run_loop",
    "run_review_pr",
    "run_review_loop",
    "run_fix",
    "run_review_meta",
    "run_review_reconcile",
    "run_fix_reconcile",
    "run_decompose",
  }) do
    local base_run = helpers[name]
    local add_missing_review_worktree = name == "run_review_pr" or name == "run_review_loop"
    helpers[name] = function(...)
      local payload, run_opts = ...
      local repo, issue_number = issue_identity_from_payload(payload)
      mock_context_bundle(payload, run_opts)
      mock_default_issue_claim(repo, issue_number)
      if add_missing_review_worktree then
        helpers.t.mock_command("git worktree list --porcelain", {
          stdout = "",
          stderr = "",
          exit_code = 0,
        })
      end
      return base_run(...)
    end
  end

  local base_run_observe_pr = helpers.run_observe_pr
  helpers.run_observe_pr = function(...)
    mock_default_issue_claim()
    return base_run_observe_pr(...)
  end

  local base_run_review_result = helpers.run_review_result
  helpers.run_review_result = function(...)
    local payload = ...
    mock_default_issue_claim()
    if mock_review_result_pr_name_only and review_result_can_read_pr_risk(payload) then
      helpers.t.mock_command("gh pr diff '7' --repo 'owner/repo' --name-only", {
        stdout = "file.lua\n",
        stderr = "",
        exit_code = 0,
      })
    end
    return base_run_review_result(...)
  end

  local base_run_merge = helpers.run_merge
  helpers.run_merge = function(payload, ...)
    local entity = entity_lib.parse_entity_proposal_id(payload and payload.proposal_id)
    if entity ~= nil and entity.issue_number ~= nil then
      mock_default_issue_claim()
    end
    return base_run_merge(payload, ...)
  end

  local function handoff_comment_request(result, queue, predicate)
    local selected = helpers.find_raise(result and result.raises, "github-proxy.github_pr_comment_request", function(payload, raised)
      return payload.handoff ~= nil
        and payload.handoff.kind == queue
        and (predicate == nil or predicate(payload, raised))
    end)
    if selected ~= nil then
      return selected
    end
    return helpers.find_raise(result and result.raises, "github-proxy.github_issue_comment_request", function(payload, raised)
      return payload.handoff ~= nil
        and payload.handoff.kind == queue
        and (predicate == nil or predicate(payload, raised))
    end)
  end

  function helpers.run_comment_handoff_from_request(request, comment_id, name)
    local entity = entity_lib.parse_entity_proposal_id(request and request.handoff and request.handoff.proposal_id)
    if entity ~= nil and entity.issue_number ~= nil then
      mock_default_issue_claim(entity.repo, entity.issue_number)
    end
    if hydrate_handoff_state_comment
      and request ~= nil
      and request.handoff ~= nil
      and (request.handoff.kind == "github-devloop.reviewing"
        or request.handoff.kind == "github-devloop.fixing"
        or request.handoff.kind == "github-devloop.merge_ready"
        or request.handoff.kind == "github-devloop.blocked"
        or request.handoff.kind == "github-devloop.closed_unmerged") then
      local selected_comment_id = comment_id or "IC_handoff_1"
      local state = request.handoff.kind == "github-devloop.merge_ready" and "merge-ready"
        or request.handoff.kind == "github-devloop.fixing" and "fixing"
        or request.handoff.kind == "github-devloop.blocked" and "blocked"
        or request.handoff.kind == "github-devloop.closed_unmerged" and "closed-unmerged"
        or "reviewing"
      helpers.t.mock_command("gh api --method GET 'repos/" .. tostring(request.repo) .. "/issues/comments/" .. tostring(selected_comment_id) .. "'", {
        stdout = encoded_comment_json(
          selected_comment_id,
          helpers.core.state_marker(request.handoff.proposal_id, state, request.handoff.version)
        ),
        stderr = "",
        exit_code = 0,
      })
    end
    return helpers.run_department("departments/comment_handoff/main.lua", {
      queue = "github-proxy.github_comment_written",
      payload = {
        schema = "github-proxy.comment-written.v1",
        repo = request.repo,
        target = request.pr_number ~= nil and "pr" or "issue",
        pr_number = request.pr_number,
        issue_number = request.issue_number,
        comment_id = comment_id or "IC_handoff_1",
        request_dedup_key = request.dedup_key,
        dedup_key = tostring(request.dedup_key) .. "/written/" .. tostring(comment_id or "IC_handoff_1"),
        source_ref = request.source_ref,
        handoff = request.handoff,
      },
    }, helpers.opts(name or "comment-handoff-from-request"))
  end

  function helpers.find_causal_raise(result, queue, predicate)
    local kind = queue
    if queue == "devloop_reviewing" then
      kind = "github-devloop.reviewing"
    elseif queue == "devloop_fixing" then
      kind = "github-devloop.fixing"
    elseif queue == "devloop_merge_ready" then
      kind = "github-devloop.merge_ready"
    elseif include_ready_causal_raise and queue == "devloop_ready" then
      kind = "github-devloop.ready"
    end
    local comment = handoff_comment_request(result, kind, predicate)
    if comment == nil then
      return nil
    end
    local handoff = helpers.run_comment_handoff_from_request(
      comment.payload,
      "IC_" .. tostring(queue):gsub("[^%w_%-]", "_") .. "_1",
      "handoff-" .. tostring(queue):gsub("[^%w_%-]", "-")
    )
    return helpers.find_raise(handoff.raises, queue)
  end

  helpers.mock_bot_env = function(...)
    if type(helpers.reset_pr_helper_state) == "function" then
      helpers.reset_pr_helper_state()
    end
    return base_mock_bot_env(...)
  end

  helpers.mock_context_bundle = mock_context_bundle
  helpers.mock_default_issue_claim = mock_default_issue_claim
  helpers.issue_identity_from_payload = issue_identity_from_payload
  helpers.mock_required_check_runs_for = pr.mock_required_check_runs_for
  return helpers
end

M.materialize_context_bundle = materialize_context_bundle

return M
