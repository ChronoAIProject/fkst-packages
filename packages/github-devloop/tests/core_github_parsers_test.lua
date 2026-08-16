local parsers_misc = require("devloop.parsers.misc")
local parsers_pr = require("devloop.parsers.pr")
local parsers_issue = require("devloop.parsers.issue")
local h = require("tests.devloop_core_helpers")
local m_builders = require("devloop.markers.builders")
local github_view = require("forge.github_view")
local devloop_state = require("devloop.state")
local core = h.core
local t = h.t

local function assert_runtime_key(key)
  local text = tostring(key or "")
  t.is_true(text ~= "")
  for segment in text:gmatch("[^/]+") do
    t.is_true(segment ~= "")
    t.is_true(segment:find("^[A-Za-z0-9._-]+$") ~= nil)
    t.is_true(segment:find("^%.*$") == nil)
  end
end

local function assert_distinct_keys(keys)
  local seen = {}
  for _, key in ipairs(keys or {}) do
    assert_runtime_key(key)
    t.is_nil(seen[key])
    seen[key] = true
  end
end

local function list_helpers_without_observe_coalesce()
  return {
    core.gh_issue_list_intake_cmd("owner/repo", 100),
    core.gh_issue_list_decompose_children_cmd("owner/repo", "github-devloop/issue/owner/repo/42"),
    core.gh_issue_list_recent_closed_cmd("owner/repo", 30),
    core.gh_issue_list_wip_cmd("owner/repo"),
    core.gh_dashboard_issue_list_cmd("owner/repo", "fkst-dashboard"),
    core.gh_dashboard_issue_all_open_cmd("owner/repo"),
    core.gh_repo_labels_list_cmd("owner/repo"),
    core.gh_pr_list_freshness_cmd("owner/repo"),
    core.gh_pr_list_merge_queue_cmd("owner/repo", "dev"),
    core.gh_pr_list_head_base_cmd("owner/repo", "integration/dev", "dev"),
    core.gh_pr_list_head_cmd("owner/repo", "integration/dev"),
  }
end

return {
  test_command_helper_modules_keep_cohesive_exports = function()
    local validators = require("devloop.commands.validators")
    local observe_lists = require("devloop.commands.observe_lists")
    local git_ops = require("devloop.commands.git_ops")

    local validator_exports = {
      bounded_limit = true,
      validate_fields = true,
      require_safe_branch = true,
      require_safe_ref = true,
      require_safe_remote = true,
      require_safe_sha = true,
      require_positive_pr_number = true,
      is_label_name_valid = true,
      require_label_name = true,
      require_label_color = true,
      require_dashboard_label = true,
      install = true,
    }

    for key, value in pairs(validators) do
      t.eq(validator_exports[key], true, key)
      t.eq(type(value), "function", key)
    end

    for _, key in ipairs({
      "bounded_page_number",
      "observe_list_page_key",
      "observe_list_repo_key",
      "observe_list_label_key",
      "observe_list_read_coalesce",
      "read_coalesce_key_segment",
    }) do
      t.eq(type(observe_lists[key]), "function", key)
      t.eq(validators[key], nil, key)
    end

    for _, key in ipairs({
      "worktree_parent_dir",
      "run_mkdir",
      "run_path_is_directory",
    }) do
      t.eq(type(git_ops[key]), "function", key)
      t.eq(validators[key], nil, key)
    end
  end,

  test_gh_issue_view_state_command_and_parse = function()
    t.eq(
      core.gh_issue_list_intake_cmd("owner/repo", 50),
      "gh issue list --repo 'owner/repo' --state open --limit 50 --json number,title,body,updatedAt,labels,assignees,author"
    )
    t.eq(core.gh_issue_list_observe_cmd("owner/repo"), "gh api --paginate --slurp 'repos/owner/repo/issues?state=open&per_page=100'")
    t.eq(core.gh_pr_list_freshness_cmd("owner/repo"), "gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&per_page=100'")
    t.eq(core.gh_issue_list_observe_cmd("owner/repo", core._enabled_label), "gh api --paginate --slurp 'repos/owner/repo/issues?state=open&labels=fkst-dev%3Aenabled&per_page=100'")
    t.eq(core.gh_issue_list_observe_cmd("owner/repo", core._enabled_label, 2), "gh api 'repos/owner/repo/issues?state=open&labels=fkst-dev%3Aenabled&per_page=100&page=2'")
    t.eq(core.gh_pr_list_observe_cmd("owner/repo", 1), "gh api 'repos/owner/repo/pulls?state=open&per_page=100&page=1'")
    local issue_observe_opts = core.gh_exec_opts(core.gh_issue_list_observe_opts("owner/repo", core._enabled_label, 2), 60)
    t.eq(issue_observe_opts.cmd, core.gh_issue_list_observe_cmd("owner/repo", core._enabled_label, 2))
    t.eq(issue_observe_opts.timeout, 10)
    t.eq(issue_observe_opts.read_coalesce.key, "github-devloop/observe-list/v-owner/v-repo/issues/label/v-fkst-dev_3Aenabled/page/2")
    t.eq(issue_observe_opts.read_coalesce.ttl_seconds, 30)
    local pr_observe_opts = core.gh_exec_opts(core.gh_pr_list_observe_opts("owner/repo", 1, true), 60)
    t.eq(pr_observe_opts.cmd, core.gh_pr_list_observe_cmd("owner/repo", 1, true))
    t.eq(pr_observe_opts.timeout, 10)
    t.eq(pr_observe_opts.read_coalesce.key, "github-devloop/observe-list/v-owner/v-repo/prs/page/1")
    t.eq(pr_observe_opts.read_coalesce.ttl_seconds, 30)
    t.eq(
      core.gh_pr_list_head_base_cmd("owner/repo", "integration/dev", "dev"),
      "gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&head=owner%3Aintegration%2Fdev&per_page=100&base=dev'"
    )
    local intake = parsers_issue.parse_issue_list_intake('[[{"number":42,"title":"Fix","updated_at":"2026-06-03T01:02:03Z","labels":[{"name":"bug"}]}]]')
    t.eq(intake[1].number, 42)
    t.eq(intake[1].body, "")
    t.eq(intake[1].created_at, nil)
    t.eq(intake[1].updated_at, "2026-06-03T01:02:03Z")
    t.eq(intake[1].labels[1], "bug")
    local mixed = parsers_issue.parse_issue_list_intake('[[{"number":1,"pull_request":{"url":"https://api.example.test/pulls/1"}}],[{"number":2,"title":"Issue","updated_at":"2026-06-03T01:02:04Z","labels":[]}]]', 1)
    t.eq(#mixed, 1)
    t.eq(mixed[1].number, 2)
    t.eq(#parsers_issue.parse_issue_list_intake("[[]]"), 0)
    t.eq(#parsers_issue.parse_issue_list_observe("[[]]"), 0)
    t.eq(#parsers_pr.parse_pr_list_observe("[[]]"), 0)
    t.eq(#parsers_pr.parse_pr_list_head_base("[[]]"), 0)
    local freshness_prs, freshness_versions = parsers_pr.parse_pr_list_freshness(
      '[[{"number":7,"updated_at":"2026-06-03T02:03:04Z"}]]'
    )
    t.eq(#freshness_prs, 1)
    t.eq(freshness_prs[1].number, 7)
    t.eq(freshness_prs[1].updated_at, "2026-06-03T02:03:04Z")
    t.eq(freshness_versions.pr[7], "2026-06-03T02:03:04Z")
    local freshness_issues = parsers_issue.parse_issue_list_freshness(
      '{"data":{"repository":{"i42":{"number":42,"updatedAt":"2026-06-03T01:02:03Z"},"i43":null}}}'
    )
    t.eq(freshness_issues[42], "2026-06-03T01:02:03Z")
    t.eq(freshness_issues[43], nil)
    local rollup_prs = parsers_pr.parse_pr_list_head_base('[[{"number":9,"head":{"sha":"abc123","ref":"integration/dev"},"base":{"ref":"dev"},"state":"open"}]]')
    t.eq(rollup_prs[1].number, 9)
    t.eq(rollup_prs[1].head_sha, "abc123")
    t.eq(rollup_prs[1].head_ref_name, "integration/dev")
    t.eq(rollup_prs[1].base_ref_name, "dev")

    t.eq(
      core.gh_issue_view_state_cmd("owner/repo", 42),
      "gh issue view '42' --repo 'owner/repo' --json title,createdAt,updatedAt,labels,state,comments,assignees,author"
    )
    t.eq(
      core.gh_issue_view_result_cmd("owner/repo", 42),
      "gh issue view '42' --repo 'owner/repo' --json labels,comments"
    )

    local state = parsers_issue.parse_issue_view_state('{"createdAt":"2026-06-03T01:00:00Z","updatedAt":"2026-06-03T01:02:03Z","state":"OPEN","labels":[{"name":"fkst-dev:enabled"}],"comments":[{"body":"hello","author":{"login":"fkst-test-bot"}}]}')
    t.eq(state.state, "OPEN")
    t.eq(state.created_at, "2026-06-03T01:00:00Z")
    t.eq(state.updated_at, "2026-06-03T01:02:03Z")
    t.eq(state.labels[1], "fkst-dev:enabled")
    t.eq(parsers_misc.comment_body(state.comments[1]), "hello")
    t.eq(parsers_misc.comment_author_login(state.comments[1]), "fkst-test-bot")

    local proposal_id = "github-devloop/issue/owner/repo/42"
    local decision = "approve"
    local dedup_key = "consensus:github-devloop/issue/owner/repo/42/v1"
    local result = parsers_issue.parse_issue_view_result(
      '{"labels":["fkst-dev:ready"],"comments":[{"body":"'
        .. m_builders.result_marker(proposal_id, decision, dedup_key):gsub('"', '\\"')
        .. '","author":{"login":"fkst-test-bot"}}]}'
    )
    t.eq(devloop_state.has_terminal_label(result.labels), true)
    t.eq(devloop_state.has_result_marker(result.comments, proposal_id, decision, dedup_key), true)
  end,
  test_observe_list_read_coalesce_keys_are_injective_for_scope_segments = function()
    local keys = {
      core.gh_issue_list_observe_read_coalesce("owner/repo", "a_58_b", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/repo", "a:b", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/repo", "a%b", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/repo", "a_b", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/repo", "fkst-dev:enabled", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/repo", nil, 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/repo", "a:b", 2).key,
      core.gh_issue_list_observe_read_coalesce("owner/other", "a:b", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner_repo/name", "a:b", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/repo.name", "a:b", 1).key,
      core.gh_issue_list_observe_read_coalesce("./repo", "a:b", 1).key,
      core.gh_issue_list_observe_read_coalesce("../repo", "a:b", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/.", "a:b", 1).key,
      core.gh_issue_list_observe_read_coalesce("owner/..", "a:b", 1).key,
      core.gh_pr_list_observe_read_coalesce("owner/repo", 1).key,
      core.gh_pr_list_observe_read_coalesce("owner/repo", 2).key,
      core.gh_pr_list_observe_read_coalesce("owner/other", 1).key,
    }

    assert_distinct_keys(keys)
    t.eq(core.gh_issue_list_observe_read_coalesce("owner/repo", "a_58_b", 1).key:find("a_58_b", 1, true), nil)
    t.is_true(core.gh_issue_list_observe_read_coalesce("owner/repo", "a:b", 1).key:find("v-a_3Ab", 1, true) ~= nil)
    t.is_true(core.gh_issue_list_observe_read_coalesce("owner/repo", "a_58_b", 1).key
      ~= core.gh_issue_list_observe_read_coalesce("owner/repo", "a:b", 1).key)
  end,

  test_observe_list_read_coalesce_opts_share_timeout = function()
    local specs = {
      core.gh_exec_opts(core.gh_issue_list_observe_opts("owner/repo", core._enabled_label, 1, true), 30),
      core.gh_exec_opts(core.gh_issue_list_observe_opts("owner/repo", devloop_state.state_label("ready"), 1, true), 60),
      core.gh_exec_opts(core.gh_issue_list_observe_opts("owner/repo", nil, 1, true), 90),
      core.gh_exec_opts(core.gh_issue_list_observe_opts("owner/repo", core._enabled_label, 2), 30),
      core.gh_exec_opts(core.gh_pr_list_observe_opts("owner/repo", 1, true), 30),
      core.gh_exec_opts(core.gh_pr_list_observe_opts("owner/repo", 2), 60),
      core.gh_exec_opts(core.gh_issue_list_observe_opts("owner/repo", core._enabled_label), 60),
      core.gh_exec_opts(core.gh_pr_list_observe_opts("owner/repo"), 90),
    }

    for _, spec in ipairs(specs) do
      t.eq(spec.timeout, 10)
      t.eq(spec.read_coalesce.ttl_seconds, 30)
      assert_runtime_key(spec.read_coalesce.key)
    end
  end,

  test_non_observe_list_reads_do_not_carry_read_coalesce = function()
    for _, cmd in ipairs(list_helpers_without_observe_coalesce()) do
      t.is_nil(core.gh_exec_opts(cmd, 30).read_coalesce)
    end
  end,

  test_gh_issue_view_commands_match_existing_strings = function()
    local cases = {
      { core.gh_issue_view_intake_judge_cmd, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone" },
      { core.gh_issue_view_state_cmd, "title,createdAt,updatedAt,labels,state,comments,assignees,author" },
      { core.gh_issue_view_result_cmd, "labels,comments" },
      { core.gh_issue_view_loop_cmd, "title,updatedAt,labels,comments,state,author" },
      { core.gh_issue_view_meta_cmd, "title,labels,comments,author" },
      { core.gh_issue_view_implement_cmd, "title,body,labels,comments,state,author" },
      { core.gh_issue_view_open_pr_cmd, "title,labels,comments,assignees,author" },
      { core.gh_issue_view_reviewing_cmd, "labels,comments" },
      { core.gh_issue_view_review_cmd, "title,labels,comments,assignees,author" },
      { core.gh_issue_view_decompose_cmd, "title,body,labels,comments,author" },
      { core.gh_issue_view_fix_cmd, "title,labels,comments,author" },
      { core.gh_issue_view_review_loop_cmd, "title,labels,comments,assignees,author" },
      { core.gh_issue_view_merge_cmd, "title,labels,comments,state,assignees,author" },
      { core.gh_issue_view_observe_cmd, "title,body,comments,labels,state,stateReason,assignees,author" },
    }

    for _, case in ipairs(cases) do
      t.eq(case[1]("owner/repo", 42), "gh issue view '42' --repo 'owner/repo' --json " .. case[2])
    end
    t.eq(
      core.gh_check_run_rerequest_cmd("owner/repo", 123),
      "gh api --method POST 'repos/owner/repo/check-runs/123/rerequest'"
    )
    t.eq(
      core.gh_issue_list_decompose_children_cmd("owner/repo", "github-devloop/issue/owner/repo/42"),
      "gh issue list --repo 'owner/repo' --state all --limit 100 --search 'fkst:github-devloop:decompose-child:v1 github-devloop/issue/owner/repo/42' --json number,title,state,author,body,url"
    )
  end,
  test_intake_judge_parse_keeps_full_issue_body = function()
    local long_body = string.rep("body-line-", core.max_body_len() + 1) .. "FULL_BODY_TAIL"
    local parsed = parsers_issue.parse_issue_view_intake_judge(
      '{"title":"Long intake","body":"' .. long_body .. '","createdAt":"2026-06-03T01:00:00Z","updatedAt":"2026-06-03T01:02:03Z","state":"OPEN","labels":[{"name":"bug"}],"comments":[]}'
    )

    t.eq(parsed.title, "Long intake")
    t.eq(parsed.body, long_body)
    t.is_true(#parsed.body > core.max_body_len())
    t.is_true(parsed.body:find("FULL_BODY_TAIL", 1, true) ~= nil)
    t.eq(parsed.created_at, "2026-06-03T01:00:00Z")
    t.eq(parsed.updated_at, "2026-06-03T01:02:03Z")
    t.eq(parsed.state, "OPEN")
    t.eq(parsed.labels[1], "bug")
  end,
  test_meta_parse_omits_issue_body_snapshot = function()
    local long_body = string.rep("body-line-", core.max_body_len() + 1) .. "FULL_BODY_TAIL"
    local parsed = parsers_issue.parse_issue_view_meta(
      '{"title":"Long meta","body":"' .. long_body .. '","labels":[{"name":"bug"}],"comments":[]}'
    )

    t.eq(parsed.title, "Long meta")
    t.is_nil(parsed.body)
    t.eq(parsed.labels[1], "bug")
  end,
  test_decompose_parse_keeps_full_issue_body_for_lineage_only = function()
    local long_body = string.rep("body-line-", core.max_body_len() + 1) .. "FULL_BODY_TAIL"
    local parsed = parsers_issue.parse_issue_view_decompose(
      '{"title":"Long decompose","body":"' .. long_body .. '","labels":[{"name":"bug"}],"comments":[]}'
    )

    t.eq(parsed.title, "Long decompose")
    t.eq(parsed.body, long_body)
    t.is_true(#parsed.body > core.max_body_len())
    t.is_true(parsed.body:find("FULL_BODY_TAIL", 1, true) ~= nil)
  end,

  test_pr_view_origin_accepts_a_fully_snake_case_record = function()
    -- Aggregate characterization. Removing all 14 unpinned snake_case fallbacks from
    -- devloop.parsers.pr reddened only two tests, both written moments earlier: roughly a
    -- dozen `decoded.*` aliases were accepted by the code and guarded by nothing. This feeds
    -- one snake_case-only record and pins the whole projection at once.
    local o = parsers_pr.parse_pr_view_origin(table.concat({
      '{"number":41,"state":"OPEN"',
      ',"head_ref_oid":"c1","head_ref_name":"f/x"',
      ',"base_ref_name":"dev","base_ref_oid":"c0"',
      ',"updated_at":"2026-01-02T00:00:00Z","merged_at":"2026-01-03T00:00:00Z"',
      ',"head_repository":{"name":"repo"},"head_repository_owner":{"login":"owner"}',
      '}',
    }))
    t.eq(o.head_sha, "c1")
    t.eq(o.head_ref_name, "f/x")
    t.eq(o.base_ref_name, "dev")
    t.eq(o.base_ref_oid, "c0")
    t.eq(o.updated_at, "2026-01-02T00:00:00Z")
    t.eq(o.merged_at, "2026-01-03T00:00:00Z")
    t.eq(o.head_repository, "owner/repo")
  end,

  test_pr_parsers_accept_snake_case_base_ref_name = function()
    -- Third unguarded alias branch, found by mutation rather than by counting: removing all
    -- three `or pr.base_ref_name` fallbacks left the whole suite green (1421 passed, 0 failed).
    -- Test-file counts had suggested this field was well covered; it was not.
    local freshness = parsers_pr.parse_pr_list_freshness(
      '[[{"number":31,"headRefOid":"b1","head_ref_name":"f/a","base_ref_name":"dev","state":"OPEN"}]]')
    t.eq(freshness[1].base_ref_name, "dev")

    local promotions = parsers_pr.parse_pr_list_promotions(
      '[[{"number":32,"headRefOid":"b2","head_ref_name":"f/b","base_ref_name":"integration/x","state":"OPEN"}]]')
    t.eq(promotions[1].base_ref_name, "integration/x")

    local origin = parsers_pr.parse_pr_view_origin(
      '{"number":33,"headRefOid":"b3","base_ref_name":"dev","state":"OPEN"}')
    t.eq(origin.base_ref_name, "dev")
  end,

  test_draft_alias_acceptance_differs_between_devloop_and_forge = function()
    -- Characterization of a DIFFERENCE, which is the load-bearing fact for any later
    -- consolidation: the two layers do not accept the same shapes.
    --   devloop.parsers.pr:25       pr.isDraft or pr.is_draft or pr.draft   -- three
    --   forge.github_view:241-243   decoded.isDraft, falling back to is_draft -- two
    -- The bare `draft` key is accepted by devloop ONLY, and before this test no test fed it.
    local function freshness(json) return parsers_pr.parse_pr_list_freshness(json)[1] end
    t.eq(freshness('[[{"number":21,"headRefOid":"a1","state":"OPEN","isDraft":true}]]').is_draft, true)
    t.eq(freshness('[[{"number":22,"headRefOid":"a2","state":"OPEN","is_draft":true}]]').is_draft, true)
    t.eq(freshness('[[{"number":23,"headRefOid":"a3","state":"OPEN","draft":true}]]').is_draft, true)

    t.eq(github_view.parse_pr_view_merge('{"number":24,"isDraft":true}').is_draft, true)
    t.eq(github_view.parse_pr_view_merge('{"number":25,"is_draft":true}').is_draft, true)
    -- the asymmetry: forge does NOT read the bare key, so this must not become true
    t.is_true(github_view.parse_pr_view_merge('{"number":26,"draft":true}').is_draft ~= true)
  end,

  test_pr_parsers_accept_snake_case_head_ref_oid = function()
    -- Characterization, not aspiration. Five exported parsers read
    -- `pr.headRefOid or pr.head_ref_oid`, and before this test NO test fed the snake_case
    -- alias to any of them: consolidating the alias resolution would have dropped that branch
    -- with a fully green suite. This pins the branch that is currently accepted.
    local freshness_prs = parsers_pr.parse_pr_list_freshness(
      '[[{"number":11,"head_ref_oid":"snake111","head_ref_name":"f/a","base_ref_name":"dev","state":"OPEN"}]]')
    t.eq(freshness_prs[1].head_sha, "snake111")

    local merged_prs = parsers_pr.parse_pr_list_recent_merged(
      '[[{"number":12,"head_ref_oid":"snake222","merged_at":"2026-01-01T00:00:00Z","state":"MERGED"}]]')
    t.eq(merged_prs[1].head_sha, "snake222")

    local promotion_prs = parsers_pr.parse_pr_list_promotions(
      '[[{"number":13,"head_ref_oid":"snake333","head_ref_name":"f/c","base_ref_name":"dev","state":"OPEN"}]]')
    t.eq(promotion_prs[1].head_sha, "snake333")

    -- parse_pr_view_origin takes a single PR object, not a list; the other four take list stdout.
    local origin = parsers_pr.parse_pr_view_origin(
      '{"number":14,"head_ref_oid":"snake444","state":"OPEN"}')
    t.eq(origin.head_sha, "snake444")

    local head_base = parsers_pr.parse_pr_list_head_base(
      '[[{"number":15,"head_ref_oid":"snake555","head":{"ref":"f/e"},"base":{"ref":"dev"},"state":"open"}]]')
    t.eq(head_base[1].head_sha, "snake555")
  end,

  test_repository_name_precedence_differs_between_devloop_and_forge_by_design = function()
    -- Characterization of a DISAGREEMENT, not of a shared rule.
    --
    -- Two helpers normalise a repository name and resolve the SAME payload differently:
    --   forge.github_view.repo_name_with_owner   tries full_name     before nameWithOwner
    --   devloop.parsers.pr (file-local helper)   tries nameWithOwner before full_name
    --
    -- Each is right for the source it reads. forge is fed REST-shaped `head.repo`, which carries
    -- full_name; devloop is fed GraphQL-shaped `headRepository`, which carries nameWithOwner.
    -- libraries/devloop uses BOTH -- github_proxy_entity_view.lua:16 imports forge's, while
    -- parsers/pr.lua keeps its own -- so they look like duplicates and are not.
    --
    -- Reordering devloop's to match forge's, the exact edit an "extract the shared normaliser"
    -- refactor makes, left 2157 tests passing and none red. The divergence had no witness, so
    -- that refactor would have gone green while silently changing which field wins on any
    -- payload carrying both keys. This test exists to make it fail loudly instead.
    local both_keys = '{"number":21,"state":"OPEN","headRefOid":"sha21",'
      .. '"headRepository":{"nameWithOwner":"graphql/owner-repo","full_name":"rest/owner-repo"}}'

    local origin = parsers_pr.parse_pr_view_origin(both_keys)
    t.eq(origin.head_repository, "graphql/owner-repo")

    t.eq(
      github_view.repo_name_with_owner({
        nameWithOwner = "graphql/owner-repo",
        full_name = "rest/owner-repo",
      }),
      "rest/owner-repo"
    )
  end,
}
