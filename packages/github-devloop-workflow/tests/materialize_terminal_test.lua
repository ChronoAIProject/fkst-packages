local fixtures = require("tests.materialize_reconcile_helpers")
local base_ids = fixtures.base_ids
local core = fixtures.core
local digest = fixtures.digest
local materialization = fixtures.materialization
local materialize_reconcile = fixtures.materialize_reconcile
local marker = fixtures.marker
local testing = fixtures.testing
local t = fixtures.t
local repo = fixtures.repo
local origin_issue = fixtures.origin_issue
local origin = fixtures.origin
local blueprint = fixtures.blueprint
local blueprint_marker = fixtures.blueprint_marker
local comment = fixtures.comment
local issue = fixtures.issue
local event = fixtures.event
local generated_spec = fixtures.generated_spec
local build_entry = fixtures.build_entry
local generated_comment = fixtures.generated_comment
local created_comment = fixtures.created_comment
local label_projection_comment = fixtures.label_projection_comment
local comments_with = fixtures.comments_with
local parent_created_comment = fixtures.parent_created_comment
local parent_intent_comment = fixtures.parent_intent_comment
local child_body = fixtures.child_body
local child_body_with_blueprint = fixtures.child_body_with_blueprint
local raise_capture = fixtures.raise_capture
local run_with = fixtures.run_with
local only_queue = fixtures.only_queue

return {
  test_child_fatal_writes_blocked_terminal = function()
    local first_spec = generated_spec("first")
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
      }),
      child_statuses = { ["108"] = "fatal" },
    })
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_comment_request")
    t.is_nil(raised[1].payload.replace_marker)
    t.is_true(raised[1].payload.body:find("terminal:v1", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('state="created"', 1, true) == nil)
    t.is_true(raised[1].payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="child-fatal-first"', 1, true) ~= nil)
  end,

  test_stale_child_fatal_terminal_rederives_merged_children_and_completes = function()
    local first_spec = generated_spec("first")
    local second_spec = generated_spec("second")
    local first_ref = { kind = "external", ref = repo .. "#issue/108" }
    local blocked_terminal, terminal_err = marker.build_terminal_marker(origin, "blocked", "child-fatal-second")
    t.is_nil(terminal_err)
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
        created_comment("second", materialize_reconcile._private.predecessor_ref_digest({ source_ref = first_ref }), second_spec, 109),
        comment(blocked_terminal),
      }),
      child_statuses = {
        ["108"] = "result_ready",
        ["109"] = "result_ready",
      },
    })

    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_comment_request")
    t.is_true(raised[1].payload.body:find('state="done"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="all-slots-result-ready"', 1, true) ~= nil)
  end,

  test_non_first_no_changes_child_writes_blocked_terminal_with_why = function()
    local first_spec = generated_spec("first")
    local second_spec = generated_spec("second")
    local first_ref = { kind = "external", ref = repo .. "#issue/108" }
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
        created_comment("second", materialize_reconcile._private.predecessor_ref_digest({ source_ref = first_ref }), second_spec, 109),
      }),
      child_statuses = {
        ["108"] = "result_ready",
        ["109"] = {
          status = "fatal",
          detail = { impl_failed_reason = "no-changes" },
        },
      },
    })
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_comment_request")
    t.is_nil(raised[1].payload.replace_marker)
    t.is_true(raised[1].payload.body:find("terminal:v1", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="child-fatal-second-no-changes"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="all-slots-result-ready"', 1, true) == nil)
  end,

  test_all_slots_ready_writes_done_terminal = function()
    local first_spec = generated_spec("first")
    local second_spec = generated_spec("second")
    local first_ref = { kind = "external", ref = repo .. "#issue/108" }
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
        created_comment("second", materialize_reconcile._private.predecessor_ref_digest({ source_ref = first_ref }), second_spec, 109),
      }),
      child_statuses = {
        ["108"] = "result_ready",
        ["109"] = "result_ready",
      },
    })
    t.eq(#raised, 1)
    t.is_nil(raised[1].payload.replace_marker)
    t.is_true(raised[1].payload.body:find('state="done"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="all-slots-result-ready"', 1, true) ~= nil)
  end,

  test_impossible_ledger_writes_error_terminal = function()
    local spec = generated_spec("second")
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("second", materialization.EMPTY_PREDECESSOR_REF_DIGEST, spec, 109),
      }),
    })
    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('state="error"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="impossible-ledger"', 1, true) ~= nil)
  end,

  test_done_terminal_releases_and_closes_only_after_marker_and_label_are_visible = function()
    local first_spec = generated_spec("first")
    local second_spec = generated_spec("second")
    local first_ref = { kind = "external", ref = repo .. "#issue/108" }
    local released = nil
    local closed = nil
    local first = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
        created_comment("second", materialize_reconcile._private.predecessor_ref_digest({ source_ref = first_ref }), second_spec, 109),
      }),
      child_statuses = {
        ["108"] = "result_ready",
        ["109"] = "result_ready",
      },
      release_done_claim = function(_core, release_repo, release_issue, release_origin)
        released = {
          repo = release_repo,
          issue = release_issue,
          origin = release_origin,
        }
        return true
      end,
      close_done_origin = function()
        closed = true
        return true
      end,
    })
    local terminal_comments = only_queue(first, "github-proxy.github_issue_comment_request")
    t.eq(#terminal_comments, 1)
    t.eq(released, nil)
    t.eq(closed, nil)

    local projection = run_with({
      current = issue({
        comment(blueprint_marker()),
        comment(terminal_comments[1].payload.body),
      }),
      release_done_claim = function()
        released = true
        return true
      end,
      close_done_origin = function()
        closed = true
        return true
      end,
    })
    t.eq(#only_queue(projection, "github-proxy.github_issue_label_request"), 1)
    t.eq(released, nil)
    t.eq(closed, nil)

    local completed = run_with({
      current = issue({
        comment(blueprint_marker()),
        comment(terminal_comments[1].payload.body),
      }, { labels = { "fkst-dev:merged" } }),
      release_done_claim = function(_core, release_repo, release_issue, release_origin)
        released = {
          repo = release_repo,
          issue = release_issue,
          origin = release_origin,
        }
        return true
      end,
      close_done_origin = function(_core, close_repo, close_issue, close_origin)
        closed = {
          repo = close_repo,
          issue = close_issue,
          origin = close_origin,
        }
        return true
      end,
    })
    t.eq(#completed, 0)
    t.eq(released.repo, repo)
    t.eq(released.issue, origin_issue)
    t.eq(released.origin, origin)
    t.eq(closed.repo, repo)
    t.eq(closed.issue, origin_issue)
    t.eq(closed.origin, origin)
  end,

  test_later_hold_does_not_hide_done_terminal = function()
    local done_terminal, terminal_err = marker.build_terminal_marker(origin, "done", "all-slots-result-ready")
    t.is_nil(terminal_err)
    local hold, hold_err = marker.build_hold_marker(origin, "origin-delivery-unverified")
    t.is_nil(hold_err)
    local released = false
    local closed = false

    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        comment(done_terminal),
        comment(hold),
      }, { labels = { "fkst-dev:merged" } }),
      release_done_claim = function()
        released = true
        return true
      end,
      close_done_origin = function()
        closed = true
        return true
      end,
    })

    t.eq(#raised, 0)
    t.eq(released, true)
    t.eq(closed, true)
  end,
}
