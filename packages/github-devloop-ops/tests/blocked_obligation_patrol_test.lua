local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local conv_reconcile = require("devloop.convergence.reconcile")
local testing = require("testkit.testing")

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local ready_version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local blocked_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)

local function bot_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-06-03T01:10:03Z",
  }
end

local function state_comment(state, version)
  return bot_comment(core.state_marker(proposal_id, state, version))
end

local function timeout_comment()
  return bot_comment(conv_reconcile.timeout_reconcile_marker(proposal_id, ready_version, "ready", 3, "drop", {
    terminal_version = blocked_version,
    from_state = "ready",
    from_version = ready_version,
    age_minutes = 1441,
    budget_minutes = 1440,
    attempt = 3,
    attempt_limit = 3,
    driving_queue = "github-devloop.devloop_ready",
    reason_class = "state-output-obligation-timeout",
    source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
    },
  }))
end

local function timeout_comment_with(reason_class, terminal_version)
  return bot_comment(conv_reconcile.timeout_reconcile_marker(proposal_id, ready_version, "ready", 3, "drop", {
    terminal_version = terminal_version or blocked_version,
    from_state = "ready",
    from_version = ready_version,
    age_minutes = 1441,
    budget_minutes = 1440,
    attempt = 3,
    attempt_limit = 3,
    driving_queue = "github-devloop.devloop_ready",
    reason_class = reason_class,
    source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
    },
  }))
end

local function entity(extra_comments, fields)
  fields = fields or {}
  local comments = {
    state_comment(fields.state or "blocked", fields.version or blocked_version),
    fields.timeout_comment or timeout_comment(),
  }
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return {
    repo = repo,
    number = issue_number,
    proposal_id = proposal_id,
    comments = comments,
    current_state = require("devloop.entity").current_entity_state(comments, proposal_id),
  }
end

local function entity_for_version(terminal_version, extra_comments)
  return entity(extra_comments, {
    version = terminal_version,
    timeout_comment = timeout_comment_with("state-output-obligation-timeout", terminal_version),
  })
end

local function workflow_entity(extra_comments)
  local comments = {
    bot_comment('Workflow blocked.\n\n<!-- fkst:github-devloop-workflow:terminal:v1 origin="'
      .. proposal_id .. '" state="blocked" reason_code="child-fatal-implement-no-changes" -->'),
  }
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return {
    repo = repo,
    number = issue_number,
    proposal_id = proposal_id,
    comments = comments,
  }
end

local function created_marker(dedup_key, created_issue_number)
  return bot_comment('Opened sub-issue #' .. tostring(created_issue_number) .. ' for this task.\n\n'
    .. '<!-- fkst:github-proxy:issue-created:v1 dedup="' .. tostring(dedup_key)
    .. '" issue="' .. tostring(created_issue_number)
    .. '" -->')
end

local function intent_marker(dedup_key)
  return bot_comment('<!-- fkst:github-proxy:issue-create-intent:v1 dedup="' .. tostring(dedup_key) .. '" -->')
end

local function drain_marker(dedup_key, terminal_version, kind, attrs)
  attrs = attrs or {}
  local parts = {
    '<!-- fkst:github-devloop-ops:blocked-obligation-drain:v1 dedup="' .. tostring(dedup_key) .. '"',
    ' terminal_version="' .. tostring(terminal_version) .. '"',
    ' kind="' .. tostring(kind) .. '"',
  }
  for key, value in pairs(attrs) do
    table.insert(parts, ' ' .. tostring(key) .. '="' .. tostring(value) .. '"')
  end
  table.insert(parts, " -->")
  return bot_comment(table.concat(parts))
end

local function find_raise(raises, queue)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      return raised
    end
  end
  return nil
end

local function mock_observe_env()
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
end

local function with_observability_stubs(observed_entity, fn)
  local originals = {
    collect_observability_entities = core.collect_observability_entities,
    collect_recent_merged_prs = core.collect_recent_merged_prs,
    collect_recent_merged_issues = core.collect_recent_merged_issues,
    reap_orphan_prs = core.reap_orphan_prs,
    observe_conflict_hotspots = core.observe_conflict_hotspots,
    render_observability_dashboard = core.render_observability_dashboard,
    publish_observability_dashboard = core.publish_observability_dashboard,
    observability_topology_mermaid = core.observability_topology_mermaid,
  }

  core.collect_observability_entities = function()
    return {
      list = { observed_entity },
      counts = { blocked = 1 },
      stalls = {},
      state_gap_report = { edges = {} },
      now_seconds = now(),
    }
  end
  core.collect_recent_merged_prs = function() return {} end
  core.collect_recent_merged_issues = function() return {} end
  core.reap_orphan_prs = function() end
  core.observe_conflict_hotspots = function() return { facts = 0, hotspots = 0, raised = 0 } end
  core.render_observability_dashboard = function()
    return { hash = "test-dashboard-hash", body = "test dashboard" }
  end
  core.publish_observability_dashboard = function() return "dry-run" end
  core.observability_topology_mermaid = function() return nil end

  local ok, result = pcall(fn)
  for name, original in pairs(originals) do
    core[name] = original
  end
  if not ok then
    error(result)
  end
  return result
end

return {
  test_classifier_separates_blocked_output_obligation_from_dead_letter = function()
    local fact, reason = core.classify_output_obligation_failure({
      terminal_state = "blocked",
      reason_class = "state-output-obligation-timeout",
      proposal_id = proposal_id,
      terminal_version = blocked_version,
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    })

    t.eq(reason, nil)
    t.eq(fact.failure_kind, "OutputObligationFailure")
    t.eq(fact.reason_class, "state-output-obligation-timeout")
    t.eq(fact.terminal_state, "blocked")
    t.eq(fact.source_repo, repo)
    t.eq(fact.issue_number, tostring(issue_number))

    local dead_letter_decision = core.failure_triage_decision({
      terminal_state = "blocked",
      reason_class = "state-output-obligation-timeout",
      proposal_id = proposal_id,
      terminal_version = blocked_version,
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    })
    t.eq(dead_letter_decision.action, "skip")
    t.eq(dead_letter_decision.reason, "missing-queue")
  end,

  test_classifier_accepts_decompose_timeout_and_rejects_unstructured_or_stale_inputs = function()
    local fact = core.classify_output_obligation_failure({
      terminal_state = "blocked",
      reason_class = "decompose-output-obligation-timeout",
      proposal_id = proposal_id,
      terminal_version = blocked_version,
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    })
    t.eq(fact.failure_kind, "OutputObligationFailure")
    t.eq(fact.reason_class, "decompose-output-obligation-timeout")

    local not_blocked, reason = core.classify_output_obligation_failure({
      terminal_state = "ready",
      reason_class = "state-output-obligation-timeout",
      proposal_id = proposal_id,
      terminal_version = blocked_version,
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    })
    t.eq(not_blocked, nil)
    t.eq(reason, "not-blocked-terminal")

    local no_why
    no_why, reason = core.classify_output_obligation_failure({
      terminal_state = "blocked",
      proposal_id = proposal_id,
      terminal_version = blocked_version,
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    })
    t.eq(no_why, nil)
    t.eq(reason, "not-output-obligation")

    local malformed_ref
    malformed_ref, reason = core.classify_output_obligation_failure({
      terminal_state = "blocked",
      reason_class = "state-output-obligation-timeout",
      proposal_id = proposal_id,
      terminal_version = blocked_version,
      source_ref = { kind = "external", ref = "" },
    })
    t.eq(malformed_ref, nil)
    t.eq(reason, "missing-source-ref")

    local stale = entity({}, {
      version = "newer-blocked-version",
      timeout_comment = timeout_comment_with("state-output-obligation-timeout", blocked_version),
    })
    t.eq(#core.blocked_output_obligation_failures(stale), 0)
  end,

  test_classifier_accepts_canonical_workflow_child_fatal_terminal = function()
    local failures = core.blocked_output_obligation_failures(workflow_entity())
    t.eq(#failures, 1)
    t.eq(failures[1].failure_kind, "OutputObligationFailure")
    t.eq(failures[1].reason_class, "child-fatal-implement-no-changes")
    t.eq(failures[1].terminal_state, "blocked")
    t.eq(failures[1].terminal_version, "workflow-terminal/child-fatal-implement-no-changes")
  end,

  test_non_blocked_entity_ignores_workflow_terminal_marker = function()
    local active = entity({
      bot_comment('<!-- fkst:github-devloop-workflow:terminal:v1 origin="'
        .. proposal_id .. '" state="blocked" reason_code="child-fatal-implement-no-changes" -->'),
    }, {
      state = "ready",
      version = ready_version,
      timeout_comment = timeout_comment_with("state-output-obligation-timeout", blocked_version),
    })
    t.eq(#core.blocked_output_obligation_failures(active), 0)
  end,

  test_drain_edge_parser_accepts_each_supported_canonical_edge = function()
    local dedup_key = core.output_obligation_failure_dedup_key(repo, proposal_id, blocked_version, "state-output-obligation-timeout")

    local cases = {
      {
        kind = "superseded-by-escalation-issue",
        comment = created_marker(dedup_key, 2030),
        expect = "2030",
      },
      {
        kind = "waiting-on-existing-escalation-issue",
        comment = drain_marker(dedup_key, blocked_version, "waiting-on-existing-escalation-issue", { issue = "2031" }),
        expect = "2031",
      },
      {
        kind = "needs-human",
        comment = drain_marker(dedup_key, blocked_version, "needs-human", { reason = "operator-needed", evidence = "attempt-threshold" }),
        expect = "operator-needed",
      },
      {
        kind = "reopened-because-relevant-fix-merged",
        comment = drain_marker(dedup_key, blocked_version, "reopened-because-relevant-fix-merged", { commit = "abc1234" }),
        expect = "abc1234",
      },
      {
        kind = "explicitly-closed-by-policy",
        comment = drain_marker(dedup_key, blocked_version, "explicitly-closed-by-policy", { policy_id = "ops-policy-1" }),
        expect = "ops-policy-1",
      },
    }

    for _, case in ipairs(cases) do
      local edge = core.output_obligation_failure_drain_edge({ case.comment }, dedup_key, blocked_version)
      t.eq(edge.kind, case.kind)
      t.eq(edge.issue_id or edge.reason or edge.commit or edge.policy_id, case.expect)
    end
  end,

  test_drain_edge_conformance_reports_duplicate_malformed_mismatched_and_stale_markers = function()
    local dedup_key = core.output_obligation_failure_dedup_key(repo, proposal_id, blocked_version, "state-output-obligation-timeout")
    local mismatched = core.output_obligation_failure_dedup_key(repo, proposal_id, "old-terminal-version", "state-output-obligation-timeout")
    local cases = {
      {
        comments = { created_marker(dedup_key, 2030), created_marker(dedup_key, 2031) },
        needle = "ambiguous",
      },
      {
        comments = { drain_marker(dedup_key, blocked_version, "waiting-on-existing-escalation-issue") },
        needle = "malformed",
      },
      {
        comments = { drain_marker(mismatched, blocked_version, "needs-human", { reason = "r", evidence = "e" }) },
        needle = "mismatched",
      },
      {
        comments = { drain_marker(dedup_key, "old-terminal-version", "needs-human", { reason = "r", evidence = "e" }) },
        needle = "stale",
      },
      {
        comments = { drain_marker(dedup_key, blocked_version, "unsupported-kind", { evidence = "e" }) },
        needle = "unsupported",
      },
    }

    for _, case in ipairs(cases) do
      local errors = core.blocked_obligation_drain_conformance_errors(entity(case.comments))
      t.is_true(#errors > 0)
      t.is_true(table.concat(errors, "\n"):find(case.needle, 1, true) ~= nil)
    end
  end,

  test_matching_issue_create_intent_prevents_duplicate_while_in_flight = function()
    local version = blocked_version .. "/intent"
    local first = core.blocked_obligation_patrol_once(entity_for_version(version))
    local request = first[1].payload
    local second = core.blocked_obligation_patrol_once(entity_for_version(version, { intent_marker(request.dedup_key) }))
    t.eq(#second, 0)
  end,

  test_blocked_obligation_patrol_creates_one_issue_request_and_marks_existing_edge = function()
    local version = blocked_version .. "/issue-create"
    local first = core.blocked_obligation_patrol_once(entity_for_version(version))

    t.eq(#first, 1)
    local raised = first[1]
    t.eq(raised.queue, "github-proxy.github_issue_create_request")
    local request = raised.payload
    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.eq(request.repo, repo)
    t.eq(request.parent_comment_target.repo, repo)
    t.eq(request.parent_comment_target.issue_number, issue_number)
    t.eq(request.source_ref.ref, "owner/repo#issue/42")
    t.is_true(request.title:find("state-output-obligation-timeout", 1, true) ~= nil)
    t.is_true(request.body:find("`failure_kind`: `OutputObligationFailure`", 1, true) ~= nil)
    t.is_true(request.body:find("`reason_class`: `state-output-obligation-timeout`", 1, true) ~= nil)
    t.is_true(request.body:find("`parent`: `owner/repo#42`", 1, true) ~= nil)
    t.is_true(request.body:find("`proposal_id`: `" .. proposal_id .. "`", 1, true) ~= nil)

    local edge = core.output_obligation_failure_drain_edge({ created_marker(request.dedup_key, 2030) }, request.dedup_key)
    t.eq(edge.kind, "superseded-by-escalation-issue")
    t.eq(edge.issue_id, "2030")

    local second = core.blocked_obligation_patrol_once(entity_for_version(version, { created_marker(request.dedup_key, 2030) }))
    t.eq(#second, 0)
  end,

  test_two_blocked_entities_produce_distinct_deduped_requests = function()
    local first_version = blocked_version .. "/two-a"
    local other_proposal = "github-devloop/issue/owner/repo/43"
    local other_ready = "github-devloop/issue/owner/repo/43/2026-06-03T01-02-03Z"
    local other_blocked = conv_reconcile.timeout_reconcile_state_version(other_ready, "ready", 3)
    local other_comments = {
      bot_comment(core.state_marker(other_proposal, "blocked", other_blocked)),
      bot_comment(conv_reconcile.timeout_reconcile_marker(other_proposal, other_ready, "ready", 3, "drop", {
        terminal_version = other_blocked,
        from_state = "ready",
        from_version = other_ready,
        age_minutes = 1441,
        budget_minutes = 1440,
        attempt = 3,
        attempt_limit = 3,
        driving_queue = "github-devloop.devloop_ready",
        reason_class = "state-output-obligation-timeout",
        source_ref = { kind = "external", ref = "owner/repo#issue/43" },
      })),
    }
    local first = core.blocked_obligation_patrol_once(entity_for_version(first_version))
    local second = core.blocked_obligation_patrol_once({
      repo = repo,
      number = 43,
      proposal_id = other_proposal,
      comments = other_comments,
      current_state = require("devloop.entity").current_entity_state(other_comments, other_proposal),
    })
    t.eq(#first, 1)
    t.eq(#second, 1)
    t.is_true(first[1].payload.dedup_key ~= second[1].payload.dedup_key)
    t.eq(first[1].payload.parent_comment_target.issue_number, 42)
    t.eq(second[1].payload.parent_comment_target.issue_number, 43)
  end,

  test_covered_and_uncovered_entities_behave_independently = function()
    local version = blocked_version .. "/covered-mixed"
    local uncovered = core.blocked_obligation_patrol_once(entity_for_version(version))
    local covered = core.blocked_obligation_patrol_once(entity_for_version(version, { created_marker(uncovered[1].payload.dedup_key, 2030) }))
    t.eq(#covered, 0)
    t.eq(#uncovered, 1)
  end,

  test_repeated_escalation_beyond_threshold_drains_to_needs_human_comment = function()
    local handoff_version = blocked_version .. "/handoff"
    local handoff_entity = function()
      return entity({}, {
        version = handoff_version,
        timeout_comment = timeout_comment_with("state-output-obligation-timeout", handoff_version),
      })
    end
    local attempts = {}
    for _ = 1, core.output_obligation_human_handoff_threshold() + 1 do
      attempts = core.blocked_obligation_patrol_once(handoff_entity())
    end
    t.eq(#attempts, 1)
    t.eq(attempts[1].queue, "github-proxy.github_issue_comment_request")
    t.is_true(attempts[1].payload.body:find("needs-human", 1, true) ~= nil)
    t.is_true(attempts[1].payload.body:find("blocked-obligation-drain:v1", 1, true) ~= nil)
    local edge = core.output_obligation_failure_drain_edge({
      drain_marker(attempts[1].fact.dedup_key, handoff_version, "needs-human", {
        reason = "repeated-escalation-without-progress",
        evidence = "attempt-threshold",
      }),
    }, attempts[1].fact.dedup_key, handoff_version)
    t.eq(edge.kind, "needs-human")
  end,

  test_observability_patrol_raises_issue_request_for_blocked_obligation = function()
    mock_observe_env()
    local department = require("departments.observability.main")
    local version = blocked_version .. "/observability"

    local result = with_observability_stubs(entity_for_version(version), function()
      return testing.run_fake(department, {
        queue = "devloop_observe_tick",
        payload = { schema = "github-devloop.observe-tick.v1" },
      })
    end)

    local raised = find_raise(result.raises, "github-proxy.github_issue_create_request")
    t.is_true(raised ~= nil)
    t.eq(raised.payload.schema, "github-proxy.issue-create.v1")
    t.eq(raised.payload.repo, repo)
    t.eq(raised.payload.parent_comment_target.issue_number, issue_number)
    t.is_true(raised.payload.body:find("`failure_kind`: `OutputObligationFailure`", 1, true) ~= nil)
  end,
}
