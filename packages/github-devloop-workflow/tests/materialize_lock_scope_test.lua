local fixtures = require("tests.materialize_reconcile_helpers")
local devloop_logging = require("devloop.logging")
local materialization = require("core.materialization")
local t = fixtures.t

local function generated_first_blueprint()
  local blueprint = fixtures.blueprint()
  blueprint.steps = { blueprint.steps[2] }
  blueprint.steps[1].id = "first"
  return blueprint
end

local function blueprint_comment(blueprint)
  local built, err = fixtures.marker.build_blueprint_marker(
    fixtures.origin,
    blueprint.id,
    fixtures.digest.blueprint_digest(blueprint)
  )
  t.is_nil(err)
  return fixtures.comment(built)
end

local function terminal_comment(state, reason_code)
  local built, err = fixtures.marker.build_terminal_marker(fixtures.origin, state, reason_code)
  t.is_nil(err)
  return fixtures.comment(built)
end

-- github-proxy posts this before it creates a child, so it is the earliest visible
-- evidence that an overlapping run already reached the create.
local function create_intent_comment()
  return fixtures.parent_intent_comment({
    child_dedup = materialization.child_dedup_key(
      fixtures.origin,
      "first",
      materialization.EMPTY_PREDECESSOR_REF_DIGEST
    ),
  })
end

local function index_of(events, expected)
  for index, event in ipairs(events) do
    if event == expected then return index end
  end
  return nil
end

local function assert_before(events, earlier, later)
  local first, second = index_of(events, earlier), index_of(events, later)
  t.is_true(first ~= nil and second ~= nil and first < second)
end

-- Drives one materialization tick over a single generated slot. `fresh` describes how
-- the origin issue looks on the commit re-read, so a case can move exactly one fact
-- and observe whether the buffered plan is still applied.
local function run_case(fresh)
  local blueprint = generated_first_blueprint()
  local planned_comments = { blueprint_comment(blueprint) }
  local fresh_comments = planned_comments
  for _, extra in ipairs((fresh or {}).comments or {}) do
    fresh_comments = fixtures.comments_with(fresh_comments, extra)
  end
  local planned_issue = fixtures.issue(planned_comments)
  local fresh_issue = fixtures.issue(fresh_comments, { labels = (fresh or {}).labels })

  local reads = 0
  local in_lock = false
  local events = {}
  local applied = 0
  local old_cas = devloop_logging.log_cas_decision
  devloop_logging.log_cas_decision = function(dept, proposal_id, current, from_state, to_state, outcome, reason)
    if tostring(outcome or ""):find("applied", 1, true) ~= nil then
      applied = applied + 1
    end
    return old_cas(dept, proposal_id, current, from_state, to_state, outcome, reason)
  end

  local ok, raised = pcall(fixtures.run_with, {
    blueprint = blueprint,
    read_issue = function()
      reads = reads + 1
      events[#events + 1] = "read-" .. tostring(reads) .. (in_lock and "-inside" or "-outside")
      return reads == 1 and planned_issue or fresh_issue
    end,
    verify_issue_claim = function()
      events[#events + 1] = in_lock and "claim-check-inside" or "claim-check-outside"
      return true
    end,
    dependency_gate = function()
      events[#events + 1] = in_lock and "dependency-inside" or "dependency-outside"
      return { ok = true, kind = "satisfied", reason = "satisfied", unmet = {} }
    end,
    search_created_issue = function()
      events[#events + 1] = in_lock and "child-search-inside" or "child-search-outside"
      return nil
    end,
    content_fetch = function()
      events[#events + 1] = in_lock and "content-fetch-inside" or "content-fetch-outside"
      return "context"
    end,
    spawn_codex = function()
      events[#events + 1] = in_lock and "generator-inside" or "generator-outside"
      return { exit_code = 0, stdout = '{"title":"Generated child","body":"Implement generated work."}' }
    end,
    with_lock = function(_key, fn)
      events[#events + 1] = "lock-enter"
      in_lock = true
      local locked_ok, result = pcall(fn)
      in_lock = false
      events[#events + 1] = "lock-exit"
      if not locked_ok then error(result, 0) end
      return result
    end,
  })
  devloop_logging.log_cas_decision = old_cas
  if not ok then error(raised, 0) end
  return events, raised, applied
end

-- Drives a tick whose origin already carries a done terminal, which is the path that
-- releases the assignee claim and closes the origin issue. `planned_labels` is what the
-- planning read sees, `fresh_labels` what the commit re-read sees.
local function run_done_cleanup_case(planned_labels, fresh_labels)
  local comments = {
    blueprint_comment(fixtures.blueprint()),
    terminal_comment("done", "all-slots-merged"),
  }
  local planned_issue = fixtures.issue(comments, { labels = planned_labels })
  local fresh_issue = fixtures.issue(comments, { labels = fresh_labels })
  local reads = 0
  local released, closed = false, false

  local raised = fixtures.run_with({
    read_issue = function()
      reads = reads + 1
      return reads == 1 and planned_issue or fresh_issue
    end,
    release_done_claim = function()
      released = true
      return true
    end,
    close_done_origin = function()
      closed = true
      return true
    end,
  })
  return released, closed, raised
end

return {
  -- The storm this pins: holding the origin transition lock across the source reads,
  -- the dependency gate and the slot generator (a codex run measured in minutes) is
  -- what tempfails observe_issue / admission / rollup_scan on the same issue.
  test_materialization_plans_reads_and_generator_before_the_commit_lock = function()
    local events, raised = run_case(nil)
    t.eq(#raised, 1)
    assert_before(events, "read-1-outside", "lock-enter")
    assert_before(events, "claim-check-outside", "lock-enter")
    assert_before(events, "dependency-outside", "lock-enter")
    assert_before(events, "child-search-outside", "lock-enter")
    assert_before(events, "content-fetch-outside", "lock-enter")
    assert_before(events, "generator-outside", "lock-enter")
    assert_before(events, "lock-enter", "read-2-inside")
  end,

  -- A terminal verdict that lands while the generator is running supersedes the plan.
  test_materialization_discards_plan_when_a_terminal_lands_during_planning = function()
    local _events, raised, applied = run_case({ comments = { terminal_comment("blocked", "child-fatal") } })
    t.eq(#raised, 0)
    t.eq(applied, 0)
  end,

  -- The race the lock exists to prevent: another actor materialized the slot while
  -- this plan was being computed, so replaying the plan would duplicate the child.
  test_materialization_discards_plan_when_a_materialization_fact_lands_during_planning = function()
    local created = fixtures.created_comment(
      "first",
      materialization.EMPTY_PREDECESSOR_REF_DIGEST,
      fixtures.generated_spec("first"),
      99
    )
    local _events, raised, applied = run_case({ comments = { created } })
    t.eq(#raised, 0)
    t.eq(applied, 0)
  end,

  -- Labels are deliberately outside currency: label projections are derived from the
  -- same trusted markers and are idempotent, so a relabel re-asserts marker truth
  -- instead of losing an update. Treating it as staleness would throw away a
  -- minutes-long generator run every time a projection landed.
  test_materialization_commits_plan_when_only_labels_moved = function()
    local _events, raised = run_case({ labels = { "triage" } })
    t.eq(#raised, 1)
  end,

  -- Two overlapping runs plan the same slot; the first one's create reaches
  -- github-proxy, which posts its create-intent marker. The second run's commit guard
  -- observes that marker and drops its plan instead of enqueueing the same child
  -- again. The currency token alone does not catch this: the intent marker is not a
  -- materialization fact, so nothing in the token moves.
  test_materialization_discards_plan_when_a_create_intent_lands_during_planning = function()
    local _events, raised, applied = run_case({ comments = { create_intent_comment() } })
    t.eq(#raised, 0)
    t.eq(applied, 0)
  end,

  -- github-proxy writes its create-intent marker before creating a child and never
  -- removes it, so a normally created child carries intent forever. The ledger
  -- catch-up for that child is a RECONCILE plan, not a create, and must publish: an
  -- intent-absence guard covering it would suppress every created child's follow-up
  -- reconciliation permanently.
  test_reconciliation_publishes_created_ledger_when_intent_marker_persists = function()
    local spec = fixtures.generated_spec("first")
    local entry = fixtures.build_entry("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, spec)
    local generator_calls = 0
    local raised = fixtures.run_with({
      current = fixtures.issue({
        fixtures.comment(fixtures.blueprint_marker()),
        fixtures.parent_intent_comment(entry),
        fixtures.parent_created_comment(entry, 108),
      }),
      read_created_issue = function(_repo, issue_number)
        t.eq(issue_number, "108")
        return {
          number = 108,
          title = spec.title,
          body = fixtures.child_body("first", spec, entry.child_dedup),
          author_login = "fkst-test-bot",
        }
      end,
      spawn_codex = function()
        generator_calls = generator_calls + 1
        return { exit_code = 0, stdout = '{"title":"Regenerated","body":"Regenerated body."}' }
      end,
    })
    local comments = fixtures.only_queue(raised, "github-proxy.github_issue_comment_request")
    t.eq(generator_calls, 0)
    t.eq(#fixtures.only_queue(raised, "github-proxy.github_issue_create_request"), 0)
    t.eq(#comments, 1)
    t.is_true(comments[1].payload.body:find('state="created"', 1, true) ~= nil)
    t.is_true(comments[1].payload.body:find('child_issue="108"', 1, true) ~= nil)
  end,

  -- The irreversible done cleanup is authorized by the merged label projection, which
  -- currency does not cover, so it re-validates that authorization at commit.
  test_done_cleanup_runs_while_the_merged_label_projection_still_holds = function()
    local released, closed = run_done_cleanup_case({ "fkst-dev:merged" }, { "fkst-dev:merged" })
    t.is_true(released)
    t.is_true(closed)
  end,

  test_done_cleanup_is_withheld_when_the_merged_label_projection_moved = function()
    local released, closed = run_done_cleanup_case({ "fkst-dev:merged" }, { "fkst-dev:thinking" })
    t.eq(released, false)
    t.eq(closed, false)
  end,
}
