local frontier = require("core.frontier")
local actions = require("core.materialize.actions")
local base_ids = require("devloop.base_ids")
local child_status = require("core.materialize.child_status")
local core = require("core")
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
local t = fkst.test

local repo = "owner/repo"

local function blueprint()
  return {
    schema = "fkst.workflow.v1",
    id = "workflow-one",
    version = "2026-07-02",
    summary = "A bounded workflow.",
    applies_when = "The origin issue asks for this workflow.",
    steps = {
      {
        id = "first",
        title = "First",
        content = {
          kind = "static",
          intent = "Do the first step.",
        },
      },
      {
        id = "second",
        title = "Second",
        content = {
          kind = "generated",
          generator = "Generate the second step.",
        },
      },
    },
  }
end

local function created(slot, child)
  return {
    state = "created",
    child_ref = child or {
      proposal_id = "child-" .. slot,
      source_ref = {
        kind = "external",
        ref = "owner/repo#issue/" .. slot,
      },
    },
  }
end

local function generated()
  return {
    state = "generated",
  }
end

local function status_map(map)
  return function(child)
    return map[child.proposal_id] or "running"
  end
end

local function comment(body)
  return {
    body = body,
    author_login = core._test_bot_login,
    created_at = "2026-07-04T00:00:00Z",
  }
end

local function child_comments_with_delegated_merged_pr(child_proposal_id, pr_number, version)
  local pr_proposal_id = "github-devloop/pr/" .. repo .. "/" .. tostring(pr_number)
  local head_sha = "0123456789abcdef0123456789abcdef01234567"
  return {
    comment(table.concat({
      core.state_marker(child_proposal_id, "merged", version),
      m_builders.pr_delegation_marker(child_proposal_id, pr_proposal_id, pr_number, version, "g1"),
      m_builders.merged_marker(core, child_proposal_id, pr_number, version, head_sha),
    }, "\n")),
  }
end

local function json_escape(value)
  return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function comments_json(comments)
  local encoded = {}
  for _, item in ipairs(comments or {}) do
    encoded[#encoded + 1] = '{"body":"' .. json_escape(item.body) .. '","author":{"login":"' .. tostring(item.author_login or core._test_bot_login) .. '"},"createdAt":"' .. tostring(item.created_at or "2026-07-04T00:00:00Z") .. '"}'
  end
  return table.concat(encoded, ",")
end

local function issue_view_stdout(issue_number, state, comments)
  return '{"number":' .. tostring(issue_number)
    .. ',"title":"Child","body":"","createdAt":"2026-07-04T00:00:00Z","updatedAt":"2026-07-04T00:00:00Z","state":"' .. tostring(state or "OPEN")
    .. '","labels":[],"assignees":[],"author":{"login":"human"},"comments":[' .. comments_json(comments) .. ']}\n'
end

-- A delegated child whose PR is still OPEN (not merged): a pr-delegation marker but
-- NO merged marker on the child. Used to reproduce the premature-materialization
-- bug where an open PR's `mergedAt: null` (a non-nil json.decode sentinel) was read
-- as merged.
local function child_comments_delegated_open_pr(child_proposal_id, pr_number, version)
  local pr_proposal_id = "github-devloop/pr/" .. repo .. "/" .. tostring(pr_number)
  return {
    comment(table.concat({
      core.state_marker(child_proposal_id, "awaiting-pr", version),
      m_builders.pr_delegation_marker(child_proposal_id, pr_proposal_id, pr_number, version, "g1"),
    }, "\n")),
  }
end

local function pr_view_open_stdout(pr_number)
  return '{"number":' .. tostring(pr_number)
    .. ',"state":"OPEN","mergedAt":null,"title":"child pr","body":"",'
    .. '"headRefName":"feature","baseRefName":"workflow-dogfood","comments":[]}\n'
end

local tests = {
  test_slot_one_is_immediately_materializable = function()
    local action = frontier.compute_frontier(blueprint(), {}, status_map({}))
    t.eq(action.action, "materialize")
    t.eq(action.slot, "first")
    t.is_nil(action.predecessor)
  end,

  test_predecessor_running_waits = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
    }, status_map({ ["child-first"] = "running" }))
    t.eq(action.action, "wait")
    t.eq(action.why, "predecessor-running")
  end,

  test_predecessor_merged_materializes_next_slot = function()
    local predecessor = { proposal_id = "child-first" }
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", predecessor),
    }, status_map({ ["child-first"] = "result_ready" }))
    t.eq(action.action, "materialize")
    t.eq(action.slot, "second")
    t.eq(action.predecessor, predecessor)
  end,

  test_fatal_materialized_child_blocks_workflow = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
    }, status_map({ ["child-first"] = "fatal" }))
    t.eq(action.action, "terminal")
    t.eq(action.state, "blocked")
    t.eq(action.reason_code, "child-fatal")
  end,

  test_recoverable_materialized_child_waits = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
    }, status_map({ ["child-first"] = "recoverable" }))
    t.eq(action.action, "wait")
    t.eq(action.why, "child-recoverable")
  end,

  test_all_created_and_merged_is_done = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
      second = created("second", { proposal_id = "child-second" }),
    }, status_map({
      ["child-first"] = "result_ready",
      ["child-second"] = "result_ready",
    }))
    t.eq(action.action, "terminal")
    t.eq(action.state, "done")
  end,

  test_corrupt_blueprint_is_terminal_error = function()
    local action = frontier.compute_frontier({ schema = "wrong" }, {}, status_map({}))
    t.eq(action.action, "terminal")
    t.eq(action.state, "error")
    t.eq(action.reason_code, "corrupt-blueprint")
  end,

  test_impossible_ledger_is_terminal_error = function()
    local action = frontier.compute_frontier(blueprint(), {
      unknown_slot = { state = "created", child_ref = { proposal_id = "x" } },
    }, status_map({}))
    t.eq(action.action, "terminal")
    t.eq(action.state, "error")
    t.eq(action.reason_code, "impossible-ledger")
  end,

  test_created_before_predecessor_is_impossible_ledger = function()
    local action = frontier.compute_frontier(blueprint(), {
      second = created("second", { proposal_id = "child-second" }),
    }, status_map({ ["child-second"] = "running" }))
    t.eq(action.action, "terminal")
    t.eq(action.state, "error")
    t.eq(action.reason_code, "impossible-ledger")
  end,

  test_generated_without_created_is_still_frontier = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = generated(),
    }, status_map({}))
    t.eq(action.action, "materialize")
    t.eq(action.slot, "first")
    t.is_nil(action.predecessor)
  end,

  test_unknown_status_waits_without_materializing_next = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
    }, status_map({ ["child-first"] = "unknown" }))
    t.eq(action.action, "wait")
    t.eq(action.why, "predecessor-unknown")
  end,

  test_delegated_merged_child_materializes_next_slot = function()
    local child_issue = 90
    local child_proposal_id = base_ids.proposal_id(repo, child_issue)
    local version = "ready/consensus-github-devloop/issue/owner/repo/90/2026-07-04T00-00-00Z"
    local comments = child_comments_with_delegated_merged_pr(child_proposal_id, 92, version)
    local child_ref = actions.child_ref_for_entry(repo, { child_issue = child_issue })
    local reader = child_status.reader(core, {}, repo)

    t.is_nil(m_facts.pr_link_fact(comments, child_proposal_id))
    t.eq(m_facts.pr_delegation_fact(comments, child_proposal_id, nil).pr_number, 92)
    t.eq(m_facts.merged_fact(comments, child_proposal_id, 92, nil).pr_number, 92)

    t.mock_command("gh issue view", {
      stdout = issue_view_stdout(child_issue, "CLOSED", comments),
      stderr = "",
      exit_code = 0,
    })

    t.eq(reader(child_ref), "result_ready")

    local action = frontier.compute_frontier(blueprint(), actions.ledger_for_frontier(repo, {
      {
        state = "created",
        slot = "first",
        child_issue = tostring(child_issue),
      },
    }), reader)

    t.eq(action.action, "materialize")
    t.eq(action.slot, "second")
    t.eq(action.predecessor.proposal_id, child_proposal_id)
  end,

  -- Regression: a delegated child whose PR is still OPEN (mergedAt null) must be
  -- "running", NOT result_ready. json.decode turns a JSON null into a NON-NIL
  -- sentinel, so the old `merged_at ~= nil` native check wrongly read an open
  -- delegated PR as merged -> a still-implementing child was judged result_ready
  -- -> premature slot materialization + false workflow terminal-done. Found by
  -- real supervise dogfood 2026-07-04 (origins #135, #93; children #149/#152/#94).
  test_delegated_open_pr_child_is_running_not_ready = function()
    local child_issue = 149
    local child_proposal_id = base_ids.proposal_id(repo, child_issue)
    local version = "ready/consensus-github-devloop/issue/owner/repo/90/2026-07-04T00-00-00Z"
    local comments = child_comments_delegated_open_pr(child_proposal_id, 153, version)
    local child_ref = actions.child_ref_for_entry(repo, { child_issue = child_issue })
    local reader = child_status.reader(core, {}, repo)
    -- The delegation link resolves, but there is NO merged marker on the child.
    t.eq(m_facts.pr_delegation_fact(comments, child_proposal_id, nil).pr_number, 153)
    t.is_nil(m_facts.merged_fact(comments, child_proposal_id, 153, nil))
    t.mock_command("gh issue view", {
      stdout = issue_view_stdout(child_issue, "OPEN", comments),
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh pr view", {
      stdout = pr_view_open_stdout(153),
      stderr = "",
      exit_code = 0,
    })
    -- THE FIX: an open delegated PR (mergedAt null) must be "running", not
    -- result_ready. Without the fix this returned "result_ready", so the frontier
    -- materialized the next slot + wrote a false terminal-done while the child was
    -- still implementing.
    t.eq(reader(child_ref), "running")
  end,
}

return tests
