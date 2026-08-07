local devloop_base = require("devloop.base")
local transition_version = require("contract.transition_version")
local t = fkst.test
local core = require("core")
local base_ids = require("devloop.base_ids")
local m_builders = require("devloop.markers.builders")
local state_comment = require("testkit_internal.projected_state_fixture").bind_state_comment(require("devloop.state"))

local repo = "owner/repo"
local origin_issue = 2133
local origin_blocker_issue = 2132
local first_child_issue = 2134
local revived_child_issue = 2137
local origin = base_ids.proposal_id(repo, origin_issue)
local first_child = base_ids.proposal_id(repo, first_child_issue)
local revived_child = base_ids.proposal_id(repo, revived_child_issue)
local first_pr = 2135
local revived_pr = 2139
local child_version = "ready/consensus-workflow-child/2026-07-10T20-18-00Z"
local head_sha = "0123456789abcdef0123456789abcdef01234567"
local integration_branch = "integration-elonsg"
local revived_branch = "devloop-owner-repo-2137-01HY"
local blocked_child_version = transition_version.next_blocked(child_version, "child-pr-blocked")

local function json_escape(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function comment_json(body, created_at, id)
  local id_field = id ~= nil and '"id":"' .. json_escape(id) .. '",' or ""
  return string.format(
    '{%s"body":"%s","createdAt":"%s","author":{"login":"fkst-test-bot"}}',
    id_field,
    json_escape(body),
    tostring(created_at or "2026-07-10T20:18:00Z")
  )
end

local function issue_json(number, title, labels, comments, state, body)
  local comment_parts = {}
  for index, item in ipairs(comments or {}) do
    comment_parts[index] = comment_json(item.body or item, item.created_at, item.id)
  end
  local label_parts = {}
  for index, label in ipairs(labels or {}) do
    label_parts[index] = string.format('{"name":"%s"}', json_escape(label))
  end
  return string.format(
    '{"number":%d,"title":"%s","body":"%s","state":"%s","createdAt":"2026-07-10T20:00:00Z","updatedAt":"2026-07-12T00:25:02Z","labels":[%s],"comments":[%s],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    number,
    json_escape(title),
    json_escape(body or "fixture"),
    tostring(state or "OPEN"),
    table.concat(label_parts, ","),
    table.concat(comment_parts, ",")
  )
end

local function rest_comments_json(comments)
  local parts = {}
  for index, item in ipairs(comments or {}) do
    parts[index] = string.format(
      '{"id":%d,"body":"%s","user":{"login":"fkst-test-bot"},"created_at":"%s"}',
      index,
      json_escape(item.body or item),
      tostring(item.created_at or "2026-07-10T20:18:00Z")
    )
  end
  return "[[" .. table.concat(parts, ",") .. "]]\n"
end

local function ownership_json()
  return '{"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n'
end

local function blocked_by_json(nodes)
  local rendered = {}
  for index, node in ipairs(nodes or {}) do
    rendered[index] = string.format(
      '{"number":%d,"state":"%s","stateReason":"%s","repository":{"nameWithOwner":"%s"}}',
      tonumber(node.number),
      tostring(node.state or "OPEN"),
      tostring(node.state_reason or ""),
      tostring(node.repo or repo)
    )
  end
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
    .. tostring(#rendered)
    .. ',"pageInfo":{"hasNextPage":false},"nodes":['
    .. table.concat(rendered, ",")
    .. ']}}}}}\n'
end

local function created_materialization_marker(blueprint, slot, predecessor_digest, child_issue)
  local spec = {
    title = slot.title,
    body = "Materialized workflow child fixture.",
  }
  local entry = core.materialization.write_generated_entry(
    origin,
    core.digest.blueprint_digest(blueprint),
    slot,
    predecessor_digest,
    spec
  )
  local built, err = core.marker.build_materialization_marker(
    origin,
    entry.blueprint_digest,
    entry.slot,
    entry.predecessor_ref_digest,
    entry.gen_contract_digest,
    entry.gen_spec_digest,
    entry.child_dedup,
    tostring(child_issue),
    "created"
  )
  t.is_nil(err)
  return built
end

local function workflow_history(include_revived_child, terminal_body)
  local blueprint = core.default_catalog.records()[2].blueprint
  local blueprint_digest = core.digest.blueprint_digest(blueprint)
  local blueprint_marker, blueprint_err = core.marker.build_blueprint_marker(origin, blueprint.id, blueprint_digest)
  t.is_nil(blueprint_err)
  local first_predecessor = core.materialization.EMPTY_PREDECESSOR_REF_DIGEST
  local second_predecessor = core.materialize_reconcile._private.predecessor_ref_digest({
    proposal_id = first_child,
    source_ref = { kind = "external", ref = repo .. "#issue/" .. tostring(first_child_issue) },
  })
  local comments = {
    { body = blueprint_marker },
    { body = created_materialization_marker(blueprint, blueprint.steps[1], first_predecessor, first_child_issue) },
  }
  if include_revived_child then
    comments[#comments + 1] = {
      body = created_materialization_marker(blueprint, blueprint.steps[2], second_predecessor, revived_child_issue),
    }
  end
  if terminal_body ~= nil then
    comments[#comments + 1] = { body = terminal_body, created_at = "2026-07-10T20:43:00Z" }
  end
  return comments, core.materialization.child_dedup_key(origin, blueprint.steps[2].id, second_predecessor)
end

local function child_history(proposal_id, issue_number, pr_number, merged)
  local body = ""
  if merged then
    body = m_builders.pr_delegation_marker(
      proposal_id,
      "github-devloop/pr/" .. repo .. "/" .. tostring(pr_number),
      pr_number,
      child_version,
      "g1"
    ) .. "\n" .. m_builders.merged_marker(core, proposal_id, pr_number, child_version, head_sha)
  end
  return issue_json(
    issue_number,
    "Workflow child",
    { merged and "fkst-dev:merged" or "fkst-dev:blocked" },
    { { body = body } }
  )
end

local function revived_child_body()
  return core.state_marker(revived_child, "blocked", blocked_child_version)
    .. "\n" .. m_builders.pr_delegation_marker(
      revived_child,
      "github-devloop/pr/" .. repo .. "/" .. tostring(revived_pr),
      revived_pr,
      child_version,
      "g1"
    )
end

local function revived_child_history(state)
  return issue_json(
    revived_child_issue,
    "Workflow child",
    { "fkst-dev:enabled", "fkst-dev:blocked" },
    { { body = revived_child_body() } },
    state
  )
end

local function stale_label_impl_failed_child_history()
  local body = core.state_marker(revived_child, "impl-failed", child_version)
    .. "\n"
    .. '<!-- fkst:github-devloop:impl-failure:v1 proposal="' .. revived_child
    .. '" reason="no-changes" dedup="' .. child_version .. '" -->'
  return issue_json(
    revived_child_issue,
    "Workflow child",
    { "fkst-dev:enabled", "fkst-dev:thinking" },
    { { body = body } },
    "OPEN"
  )
end

local function pr_origin_body()
  return m_builders.pr_origin_marker(
    revived_child,
    revived_child_issue,
    revived_branch,
    child_version,
    integration_branch
  )
end

local function pr_view_json(state)
  local merged_at = state == "MERGED" and "2026-07-12T00:25:02Z" or ""
  return string.format(
    '{"number":%d,"title":"Workflow child PR","body":"fixture","headRefName":"%s","headRefOid":"%s","baseRefName":"%s","state":"%s","updatedAt":"2026-07-12T00:25:02Z","mergedAt":"%s","comments":[%s],"labels":[],"author":{"login":"fkst-test-bot"},"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n',
    revived_pr,
    revived_branch,
    head_sha,
    integration_branch,
    state,
    merged_at,
    comment_json(pr_origin_body(), "2026-07-10T20:20:00Z")
  )
end

local function mock_origin_dependency(blocker_state)
  t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_MANAGED_SIBLING_REPOS"), {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(core.gh_blocked_by_cmd(repo, origin_issue), {
    stdout = blocked_by_json(blocker_state and {
      {
        number = origin_blocker_issue,
        state = blocker_state,
        state_reason = blocker_state == "CLOSED" and "COMPLETED" or "",
      },
    } or {}),
    stderr = "",
    exit_code = 0,
  })
  if blocker_state == nil then
    return
  end
  if blocker_state ~= "CLOSED" then
    t.mock_command(core.gh_blocked_by_cmd(repo, origin_blocker_issue), {
      stdout = blocked_by_json({}),
      stderr = "",
      exit_code = 0,
    })
  end
  local blocker_proposal = base_ids.proposal_id(repo, origin_blocker_issue)
  local blocker_milestone = blocker_state == "CLOSED" and "merged" or "ready"
  t.mock_command(core.gh_issue_view_observe_cmd(repo, origin_blocker_issue), {
    stdout = issue_json(
      origin_blocker_issue,
      "Workflow origin blocker",
      { "fkst-dev:" .. blocker_milestone },
      { { body = state_comment(blocker_proposal, blocker_milestone, "blocker-version") } },
      blocker_state
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_materialization_cycle(origin_comments, revived_state, pr_state, releases_claim, revived_stdout, blocker_state)
  mock_origin_dependency(blocker_state)
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues?state=open&per_page=100'", {
    stdout = '[[{"number":' .. tostring(origin_issue) .. ',"title":"Workflow origin","state":"OPEN","updatedAt":"2026-07-12T00:25:02Z"}]]\n',
    stderr = "",
    exit_code = 0,
  })
  local full_fields = "title,body,updatedAt,labels,comments,state,assignees,author"
  t.mock_command("gh issue view " .. tostring(origin_issue) .. " --repo " .. repo .. " --json '" .. full_fields .. "'", {
    stdout = issue_json(origin_issue, "Workflow origin", {}, origin_comments), stderr = "", exit_code = 0,
  })
  t.mock_command(core.gh_issue_view_claim_cmd(repo, origin_issue), {
    stdout = ownership_json(), stderr = "", exit_code = 0,
  })
  t.mock_command("gh issue view " .. tostring(first_child_issue) .. " --repo " .. repo .. " --json '" .. full_fields .. "'", {
    stdout = child_history(first_child, first_child_issue, first_pr, true), stderr = "", exit_code = 0,
  })
  if revived_state ~= nil then
    t.mock_command("gh issue view " .. tostring(revived_child_issue) .. " --repo " .. repo .. " --json '" .. full_fields .. "'", {
      stdout = revived_stdout or revived_child_history(revived_state), stderr = "", exit_code = 0,
    })
    if pr_state ~= nil then
      t.mock_command(core.gh_pr_view_origin_cmd(repo, revived_pr), {
        stdout = pr_view_json(pr_state), stderr = "", exit_code = 0,
      })
    end
  end
  if releases_claim then
    t.mock_command(core.gh_issue_view_claim_cmd(repo, origin_issue), {
      stdout = ownership_json(), stderr = "", exit_code = 0,
    })
  end
end

local function mock_env()
  for _ = 1, 9 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_WORKFLOW_CATALOG_ROOT"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_write_mode(value, times)
  for _ = 1, times or 1 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = value or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

return {
  t = t,
  core = core,
  base_ids = base_ids,
  repo = repo,
  origin_issue = origin_issue,
  revived_child_issue = revived_child_issue,
  origin = origin,
  revived_child = revived_child,
  revived_pr = revived_pr,
  child_version = child_version,
  head_sha = head_sha,
  integration_branch = integration_branch,
  revived_branch = revived_branch,
  json_escape = json_escape,
  issue_json = issue_json,
  rest_comments_json = rest_comments_json,
  ownership_json = ownership_json,
  blocked_by_json = blocked_by_json,
  workflow_history = workflow_history,
  revived_child_body = revived_child_body,
  pr_origin_body = pr_origin_body,
  pr_view_json = pr_view_json,
  stale_label_impl_failed_child_history = stale_label_impl_failed_child_history,
  mock_materialization_cycle = mock_materialization_cycle,
  mock_env = mock_env,
  mock_write_mode = mock_write_mode,
}
