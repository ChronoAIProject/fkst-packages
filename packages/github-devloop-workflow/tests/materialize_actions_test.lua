local actions = require("core.materialize.actions")
local base_ids = require("devloop.base_ids")
local marker = require("core.marker")
local t = fkst.test

local repo = "owner/repo"
local origin = base_ids.proposal_id(repo, 42)
local blueprint_fact = {
  origin = origin,
  workflow = "workflow-one",
  digest = "d-3588118930",
}

local function current_with_blueprint()
  return {
    comments = {
      {
        body = "This issue is managed by workflow workflow-one.\n\n"
          .. '<!-- fkst:github-devloop-workflow:blueprint:v1 origin="' .. origin
          .. '" workflow="workflow-one" digest="d-3588118930" -->',
        author_login = "fkst-test-bot",
      },
    },
  }
end

local function trusted_passthrough(_core, comments)
  return comments or {}
end

-- A valid materialization ledger entry (bounded digest strings + slot).
local function entry()
  return {
    blueprint_digest = "d-3588118930",
    slot = "implement",
    predecessor_ref_digest = "d-0000000000",
    gen_contract_digest = "d-2364386957",
    gen_spec_digest = "d-0975672535",
    child_dedup = "workflow/materialize/owner/repo/implement/d-0000000000",
    child_issue = "7",
    state = "created",
    origin = origin,
  }
end

local function has(s, sub)
  return tostring(s):find(sub, 1, true) ~= nil
end

local function contains(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then
      return true
    end
  end
  return false
end

return {
  -- Regression: the materialization marker comment dedup_key must be
  -- DETERMINISTIC and derived from the slot/digests/state — not a Lua table
  -- address (tostring of the components table collapsed to "table: 0x...",
  -- which made replayed marker writes non-idempotent). Found by real dogfood.
  test_materialization_comment_dedup_deterministic_no_table_address = function()
    local e = entry()
    local r1 = actions.materialization_comment_request(repo, 1, origin, e, "created", "7")
    local r2 = actions.materialization_comment_request(repo, 1, origin, e, "created", "7")
    t.eq(r1.dedup_key, r2.dedup_key)
    t.is_true(not has(r1.dedup_key, "table"))
    t.is_true(not has(r1.dedup_key, "0x"))
    t.is_nil(r1.replace_marker)
    t.is_true(not has(r1.body, "fkst:github-devloop-workflow:blueprint:v1"))
    t.is_true(has(r1.body, "fkst:github-devloop-workflow:materialization:v1"))
    t.is_true(has(r1.body, "Materialized the `implement` step as sub-issue #7."))
    t.is_true(r1.body:find("Materialized the `implement` step as sub-issue #7.\n\n<!-- fkst:github-devloop-workflow:materialization:v1", 1, true) == 1)
    t.is_true(not has(r1.body, "Implement the website feature"))
    local parsed = marker.parse_materialization_marker(r1.body, origin, "implement")
    t.eq(parsed.state, "created")
    t.eq(parsed.child_issue, "7")
    local expected_marker, marker_err = marker.build_materialization_marker(
      origin,
      e.blueprint_digest,
      e.slot,
      e.predecessor_ref_digest,
      e.gen_contract_digest,
      e.gen_spec_digest,
      e.child_dedup,
      "7",
      "created"
    )
    t.is_nil(marker_err)
    t.eq(r1.body, "Materialized the `implement` step as sub-issue #7.\n\n" .. expected_marker)
  end,

  test_materialization_comment_dedup_varies_by_state = function()
    local e = entry()
    local generated = actions.materialization_comment_request(repo, 1, origin, e, "generated", "")
    local created = actions.materialization_comment_request(repo, 1, origin, e, "created", "7")
    t.is_true(generated.dedup_key ~= created.dedup_key)
    t.is_true(not has(created.dedup_key, "table"))
    t.is_true(has(generated.body, "Generated the `implement` step for materialization."))
    t.eq(marker.parse_materialization_marker(generated.body, origin, "implement").state, "generated")
  end,

  test_terminal_comment_dedup_deterministic_no_table_address = function()
    local r1 = actions.terminal_request(repo, 1, origin, "done", "all-slots-merged")
    local r2 = actions.terminal_request(repo, 1, origin, "done", "all-slots-merged")
    t.eq(r1.dedup_key, r2.dedup_key)
    t.is_true(not has(r1.dedup_key, "table"))
    t.is_true(r1.dedup_key ~= actions.terminal_request(repo, 1, origin, "blocked", "child-fatal").dedup_key)
    t.is_nil(r1.replace_marker)
    t.is_true(not has(r1.body, "fkst:github-devloop-workflow:materialization:v1"))
    t.is_true(has(r1.body, "fkst:github-devloop-workflow:terminal:v1"))
    t.is_true(has(r1.body, 'monotonic="true"'))
    t.is_true(has(r1.body, "Workflow complete: every step merged."))
    t.is_true(r1.body:find("Workflow complete: every step merged.\n\n<!-- fkst:github-devloop-workflow:terminal:v1", 1, true) == 1)
    local parsed = marker.parse_terminal_marker(r1.body, origin)
    t.eq(parsed.state, "done")
    t.eq(parsed.reason_code, "all-slots-merged")
    local expected_marker, marker_err = marker.build_terminal_marker(origin, "done", "all-slots-merged")
    t.is_nil(marker_err)
    t.eq(r1.body, "Workflow complete: every step merged.\n\n" .. expected_marker)
    local blocked = actions.terminal_request(repo, 1, origin, "blocked", "child-fatal")
    t.is_true(has(blocked.body, "Workflow blocked: child-fatal."))
    t.is_true(has(blocked.body, 'monotonic="false"'))
    t.eq(marker.parse_terminal_marker(blocked.body, origin).state, "blocked")
  end,

  test_terminal_projection_state_maps_open_terminal_dispositions = function()
    local cases = {
      { state = "blocked", expected_label = "fkst-dev:blocked" },
      { state = "error", expected_label = "fkst-dev:blocked" },
    }
    for _, case in ipairs(cases) do
      local projection_state = actions.terminal_projection_state({
        state = case.state,
        reason_code = "terminal-reason",
      })
      t.eq("fkst-dev:" .. projection_state, case.expected_label)
    end
  end,

  test_done_label_request_remains_guarded_by_the_terminal_marker = function()
    local request = actions.done_label_request(
      repo,
      42,
      origin,
      { "fkst-dev:enabled", "fkst-dev:thinking", "manual-label" }
    )

    t.eq(request.schema, "github-proxy.label.v1")
    t.eq(request.add_labels[1], "fkst-dev:merged")
    t.is_true(contains(request.remove_labels, "fkst-dev:thinking"))
    t.is_true(not contains(request.remove_labels, "manual-label"))
    t.eq(request.marker_guard.marker, "terminal")
    t.eq(request.marker_guard.expected.state, "done")
    t.eq(request.marker_guard.order_by[1], "monotonic")
  end,

  test_label_projection_is_quiet_when_the_advisory_label_is_current = function()
    local request = actions.label_projection_request(repo, 42, origin, {
      origin = origin,
      state = "blocked",
      generation = 1,
    }, { "fkst-dev:enabled", "fkst-dev:blocked" })

    t.is_nil(request)
  end,

  test_label_projection_marker_dedup_allows_only_one_fact_per_generation = function()
    local blocked = actions.label_projection_marker_request(repo, 42, origin, "blocked", 2)
    local thinking = actions.label_projection_marker_request(repo, 42, origin, "thinking", 2)

    t.eq(blocked.dedup_key, thinking.dedup_key)
    t.is_true(has(blocked.body, 'state="blocked"'))
    t.is_true(has(thinking.body, 'state="thinking"'))
    t.is_true(has(blocked.body, 'generation="2"'))
  end,

  test_label_projection_request_binds_active_write_to_its_generation = function()
    local active_request = actions.label_projection_request(repo, 42, origin, {
      origin = origin,
      state = "thinking",
      generation = 2,
    }, { "fkst-dev:enabled", "fkst-dev:blocked", "manual-label" })

    t.eq(active_request.add_labels[1], "fkst-dev:thinking")
    t.is_true(contains(active_request.remove_labels, "fkst-dev:blocked"))
    t.is_true(not contains(active_request.remove_labels, "manual-label"))
    t.eq(active_request.marker_guard.marker, "label-projection")
    t.eq(active_request.marker_guard.expected.state, "thinking")
    t.eq(active_request.marker_guard.expected.generation, "2")
    t.eq(active_request.marker_guard.order_by[1], "generation")
  end,

  test_issue_create_keeps_origin_parent_comment_target = function()
    local req = actions.issue_create_request(repo, 42, origin, "d-3588118930", "implement", entry(), {
      title = "Implement the website feature",
      body = "Implement the requested page.",
    })
    t.eq(req.parent, 42)
    t.eq(req.parent_comment_target.repo, repo)
    t.eq(req.parent_comment_target.issue_number, 42)
    t.is_true(has(req.body, "fkst:github-devloop-workflow:lineage:v1"))
    t.is_true(has(req.body, "Implement the requested page."))
  end,

  test_spec_from_created_issue_strips_lineage_and_proxy_marker = function()
    local req = actions.issue_create_request(repo, 42, origin, "d-3588118930", "implement", entry(), {
      title = "Implement the website feature",
      body = "Implement the requested page.",
    })
    local issue = {
      number = 7,
      title = req.title,
      body = req.body .. "\n\n<!-- fkst:github-proxy:issue-create:" .. entry().child_dedup .. " -->\n",
      author_login = "fkst-test-bot",
    }
    local spec = actions.spec_from_created_issue(issue, origin, "d-3588118930", "implement", entry().child_dedup)
    t.eq(spec.title, "Implement the website feature")
    t.eq(spec.body, "Implement the requested page.")
  end,

  test_trusted_issue_create_intent_is_detected = function()
    local current = {
      comments = {
        {
          body = '<!-- fkst:github-proxy:issue-create-intent:v1 dedup="' .. entry().child_dedup .. '" -->',
          author_login = "fkst-test-bot",
        },
      },
    }
    t.is_true(actions.has_trusted_issue_create_intent(nil, current, entry().child_dedup, trusted_passthrough))
    t.is_true(not actions.has_trusted_issue_create_intent(nil, current, "other", trusted_passthrough))
  end,
}
