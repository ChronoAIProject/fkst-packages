local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
local m_builders = require("devloop.markers.builders")
local replay_fields = require("devloop.replay_fields")
local replayer = require("devloop.replayer")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

local function capture_raises(fn)
  local raised = {}
  local original = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  local ok, err = pcall(fn)
  devloop_logging.log_raise = original
  if not ok then
    error(err)
  end
  return raised
end

local function with_shared_replayer_registry(fn)
  local original = core.replayer_review_registry
  core.replayer_review_registry = {}
  local ok, err = pcall(fn)
  core.replayer_review_registry = original
  if not ok then
    error(err)
  end
end

return {
  test_shared_fixing_replay_head_renormalization_label_guards_pr_marker = function()
    local fix = h.fixing()
    local branch = devloop_base.implement_branch("owner/repo", "42", fix.version)
    local head_sha = "0123456789abcdef0123456789abcdef01234567"
    local issue = {
      repo = "owner/repo",
      number = 42,
      source_ref = entity_lib.issue_source_ref("owner/repo", 42),
    }
    local state = {
      state = "fixing",
      version = fix.version,
      proposal_id = fix.proposal_id,
    }
    local link = {
      proposal_id = fix.proposal_id,
      pr_number = fix.pr_number,
      branch = branch,
      impl_version = fix.version,
      base_branch = "dev",
    }
    local current_pr = {
      number = fix.pr_number,
      state = "OPEN",
      head_ref_name = branch,
      base_ref_name = "dev",
      head_sha = head_sha,
      comments = {},
    }
    local row = replay_fields.restart_transition_row(core.restart_transition_table(), "fixing")
    local raised
    with_shared_replayer_registry(function()
      raised = capture_raises(function()
        local issued = replayer.replay_from_table(core, "liveness_scan", issue, state, row, {
          proposal_id = fix.proposal_id,
          source_ref = entity_lib.pr_source_ref("owner/repo", fix.pr_number),
          link = link,
          current_pr = current_pr,
          snapshot = {
            comments = {
              core.state_marker(fix.proposal_id, "fixing", fix.version),
              m_builders.pr_link_marker(fix.proposal_id, fix.pr_number, branch, fix.version, "dev"),
            },
            prs = {
              { number = fix.pr_number, current = current_pr },
            },
            state = state,
          },
        })
        t.eq(issued, true)
      end)
    end)
    local label = h.find_raise(raised, "github-proxy.github_issue_label_request").payload
    t.eq(label.add_labels[1], "fkst-dev:reviewing")
    t.eq(label.marker_guard.expected.state, "reviewing")
    t.eq(label.marker_guard.marker_target.kind, "pr")
    t.eq(label.marker_guard.marker_target.number, fix.pr_number)
    t.eq(label.marker_guard.expected.version, core.next_fix_version(fix.version))
    t.eq(label.dedup_key, base_ids.dedup_key({
      "observe",
      "fixing",
      "renormalize",
      tostring(fix.proposal_id),
      tostring(core.next_fix_version(fix.version)),
      tostring(fix.pr_number),
    }))
  end,
}
