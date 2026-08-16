local devloop_base = require("devloop.base")
local codex_jsonl = require("testkit_internal.codex_jsonl")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local replay_fields = require("devloop.replay_fields")
local devloop_state = require("devloop.state")
local replayer
local t = h.t
local core = h.core
replayer = assert(rawget(core, "replayer"))

local function mock_meta_codex(stdout)
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("codex exec", {
    stdout = codex_jsonl.final_message(stdout),
    stderr = "",
    exit_code = 0,
  })
end

local function origin_marker(version)
  return m_builders.pr_origin_marker(
    "github-devloop/issue/owner/repo/42",
    "42",
    "devloop-owner-repo-42-01HY",
    version,
    "dev"
  )
end

local function replay_raises(fn)
  local raised = {}
  local original = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  local ok, result = pcall(fn)
  devloop_logging.log_raise = original
  if not ok then error(result, 0) end
  return raised
end

return {
  test_review_meta_protocol_names_no_actionable_gap_without_approval_authority = function()
    local answer = h.action_label .. " no-actionable-gap\n"
      .. h.reason_label .. " The review found no implementation gap that can be fixed."
    local parsed = core.parse_review_meta_action(answer)

    t.eq(parsed.action, "no-actionable-gap")
    t.eq(parsed.reason, "The review found no implementation gap that can be fixed.")

    local prompt = core.build_review_meta_prompt(h.review_meta_event(), {
      title = "Review a pull request",
      comments = {},
    }, "Issue JSON: /tmp/context/issue.json\nPR diff patch: /tmp/context/diff.patch")
    t.is_true(prompt:find("- no-actionable-gap: no actionable implementation gap remains; return to canonical review without approving the PR.", 1, true) ~= nil)
    t.is_true(prompt:find("Only `review_result` may approve the PR or advance it to `merge-ready`.", 1, true) ~= nil)
  end,

  test_no_actionable_gap_returns_to_reviewing_before_review_result_can_make_merge_ready = function()
    local event = h.review_meta_event()
    local exit_version = devloop_state.next_review_meta_action_version(event.version)
    h.mock_issue_review_meta({ "fkst-dev:review-meta" }, {
      core.state_marker(event.proposal_id, "review-meta", event.version),
    })
    mock_meta_codex(h.action_label .. " no-actionable-gap\n"
      .. h.reason_label .. " No implementation change can address the remaining review disagreement.")

    local meta = h.run_review_meta(event, h.opts("review-meta-no-actionable-gap"))
    t.eq(meta.exit_code, 0)
    local meta_comment = h.find_raise(meta.raises, "github-proxy.github_pr_comment_request").payload
    local meta_label = h.find_raise(meta.raises, "github-proxy.github_issue_label_request").payload
    t.eq(meta_label.add_labels[1], "fkst-dev:reviewing")
    t.eq(meta_comment.handoff.kind, "github-devloop.reviewing")
    t.eq(meta_comment.handoff.version, exit_version)
    t.is_true(meta_comment.body:find('state="reviewing" version="' .. exit_version .. '"', 1, true) ~= nil)
    t.is_true(meta_comment.body:find('action="no-actionable-gap"', 1, true) ~= nil)
    t.is_nil(meta_comment.body:find("fkst:github-devloop:review-result:v1", 1, true))
    t.is_nil(meta_comment.body:find("fkst:github-devloop:merge-ready:v1", 1, true))
    t.eq(h.find_raise(meta.raises, "devloop_merge_ready"), nil)

    local acknowledged = h.run_comment_handoff_from_request(
      meta_comment,
      "IC_review_meta_no_actionable_gap_1",
      "review-meta-no-actionable-gap-handoff"
    )
    t.eq(acknowledged.exit_code, 0)
    local reviewing = h.find_raise(acknowledged.raises, "devloop_reviewing")
    t.is_true(reviewing ~= nil)
    t.eq(reviewing.payload.version, exit_version)
    t.eq(h.find_raise(acknowledged.raises, "devloop_merge_ready"), nil)

    h.mock_issue_review({ "fkst-dev:reviewing" }, {
      meta_comment.body,
    }, {
      title = "Implement the approved change",
      body = "Backing issue context",
    })
    h.mock_pr_origin({ origin_marker(event.version) }, "devloop-owner-repo-42-01HY", "def456")
    local review = h.run_review_pr(reviewing.payload, h.opts("review-meta-no-gap-fresh-review"))
    t.eq(review.exit_code, 0)
    local proposal = h.find_raise(review.raises, "devloop_review_request").payload
    local expected_review_id = devloop_base.pr_review_proposal_id("owner/repo", 7, exit_version, "def456")
    t.eq(proposal.proposal_id, expected_review_id)
    t.eq(h.find_raise(review.raises, "devloop_merge_ready"), nil)

    local approve = {
      schema = "consensus.consensus_reached.v1",
      proposal_id = proposal.proposal_id,
      decision = "approve",
      body = "Review consensus approves the current diff.",
      dedup_key = "consensus:" .. proposal.dedup_key,
      source_ref = entity_lib.pr_source_ref("owner/repo", 7),
    }
    h.mock_pr_origin({ origin_marker(event.version) }, "devloop-owner-repo-42-01HY", "def456")
    h.mock_issue_result({ "fkst-dev:reviewing" }, {
      meta_comment.body,
    })
    local approved = h.run_review_result(approve, h.opts("review-meta-no-gap-review-result"))
    t.eq(approved.exit_code, 0)
    local approval_comment = h.find_raise(approved.raises, "github-proxy.github_pr_comment_request").payload
    t.is_true(approval_comment.body:find('state="merge-ready" version="' .. exit_version .. '"', 1, true) ~= nil)
    t.is_true(approval_comment.body:find("fkst:github-devloop:review-result:v1", 1, true) ~= nil)
    t.is_true(approval_comment.body:find("fkst:github-devloop:merge-ready:v1", 1, true) ~= nil)
    t.eq(approval_comment.handoff.kind, "github-devloop.merge_ready")
  end,

  test_no_actionable_gap_replay_restores_only_canonical_reviewing = function()
    h.mock_bot_env()
    local event = h.review_meta_event()
    local exit_version = devloop_state.next_review_meta_action_version(event.version)
    local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
    local comments = {
      {
        body = core.state_marker(event.proposal_id, "review-meta", event.version),
        author_login = core._test_bot_login,
      },
      {
        body = m_builders.pr_link_marker(event.proposal_id, 7, branch, event.version, "dev"),
        author_login = core._test_bot_login,
      },
      {
        body = m_builders.review_meta_marker(event.proposal_id, event.dedup_key,
          "no-actionable-gap", exit_version, nil, "No actionable implementation gap remains.", {
            review_proposal_id = event.review_proposal_id,
            review_dedup_key = devloop_base.pr_review_consensus_dedup_key(event.review_proposal_id),
            reviewed_head_sha = "def456",
          }),
        author_login = core._test_bot_login,
      },
    }
    local issue = {
      repo = "owner/repo",
      number = 42,
      source_ref = entity_lib.issue_source_ref("owner/repo", 42),
    }
    local state = {
      state = "review-meta",
      version = event.version,
      proposal_id = event.proposal_id,
    }
    local link = {
      proposal_id = event.proposal_id,
      pr_number = 7,
      branch = branch,
      impl_version = event.version,
      base_branch = "dev",
    }
    local current_pr = {
      number = 7,
      state = "OPEN",
      head_ref_name = branch,
      base_ref_name = "dev",
      head_sha = "def456",
      comments = comments,
    }
    local row = replay_fields.restart_transition_row(core.restart_transition_table(), "review-meta")
    local raised = replay_raises(function()
      local result = replayer.replay_from_table_classified("liveness_scan", issue, state, row, {
        proposal_id = event.proposal_id,
        source_ref = entity_lib.pr_source_ref("owner/repo", 7),
        link = link,
        current = current_pr,
        current_pr = current_pr,
      })
      if result.issued ~= true then
        error("no-actionable-gap replay did not issue: " .. tostring(result.outcome)
          .. " reason=" .. tostring(result.reason), 0)
      end
    end)

    local comment = h.find_raise(raised, "github-proxy.github_pr_comment_request").payload
    local label = h.find_raise(raised, "github-proxy.github_issue_label_request").payload
    t.eq(comment.handoff.kind, "github-devloop.reviewing")
    t.eq(comment.handoff.version, exit_version)
    t.is_true(comment.body:find('state="reviewing" version="' .. exit_version .. '"', 1, true) ~= nil)
    t.is_nil(comment.body:find("fkst:github-devloop:review-result:v1", 1, true))
    t.is_nil(comment.body:find("fkst:github-devloop:merge-ready:v1", 1, true))
    t.eq(label.add_labels[1], "fkst-dev:reviewing")
    t.eq(h.find_raise(raised, "devloop_merge_ready"), nil)
  end,
}
