local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local m_claims = require("devloop.claims")
local state_labels = require("devloop.state_labels")
local C = {}

local function label_colors_for(add_labels)
  local colors = {}
  local has_color = false
  for _, label in ipairs(add_labels or {}) do
    local color = devloop_base._label_colors and devloop_base._label_colors[tostring(label)]
    if color ~= nil then
      colors[tostring(label)] = color
      has_color = true
    end
  end
  return has_color and colors or nil
end

function C.build_label_request(repo, issue_number, add_labels, remove_labels, dedup_key, source_ref)
  return m_claims.attach_issue_claim({
    schema = "github-proxy.label.v1",
    repo = repo,
    target_kind = "issue",
    target_number = issue_number,
    issue_number = issue_number,
    add_labels = add_labels or {},
    remove_labels = remove_labels or {},
    label_colors = label_colors_for(add_labels),
    dedup_key = dedup_key,
    source_ref = base_ids.normalize_source_ref(source_ref),
  }, source_ref)
end

local function state_marker_guard(proposal_id, state, version, marker_target)
  local guard = {
    namespace = "github-devloop",
    marker = "state",
    version = "v1",
    match = {
      proposal = tostring(proposal_id),
    },
    expected = {
      state = tostring(state),
      version = tostring(version),
    },
    order_by = {
      "marker_order_key",
      "version_order_key",
      "stage_rank",
    },
  }
  if marker_target ~= nil then
    guard.marker_target = {
      kind = tostring(marker_target.kind),
      number = marker_target.number,
    }
  end
  return guard
end

function C.build_state_label_request(repo, issue_number, to_state, proposal_id, state_marker_version, dedup_key_value, source_ref, current_labels, marker_target)
  if proposal_id == nil or state_marker_version == nil then
    error("github-devloop: state label request requires proposal_id and state marker version")
  end
  local add_labels, remove_labels
  if current_labels ~= nil then
    add_labels, remove_labels = state_labels.state_label_reconcile_changes(current_labels, to_state)
  else
    add_labels, remove_labels = state_labels.state_label_changes(to_state)
  end
  local guard_target = marker_target or {
    kind = "issue",
    number = issue_number,
  }
  return m_claims.attach_issue_claim({
    schema = "github-proxy.label.v1",
    repo = repo,
    target_kind = "issue",
    target_number = issue_number,
    issue_number = issue_number,
    require_marker_guard = true,
    expected_proposal_id = proposal_id,
    expected_state = to_state,
    expected_version = state_marker_version,
    marker_guard = state_marker_guard(proposal_id, to_state, state_marker_version, guard_target),
    add_labels = add_labels,
    remove_labels = remove_labels,
    label_colors = label_colors_for(add_labels),
    dedup_key = dedup_key_value,
    source_ref = base_ids.normalize_source_ref(source_ref),
  }, source_ref)
end

function C.build_thinking_label_request(issue, proposal)
  return C.build_state_label_request(
    issue.repo,
    issue.number,
    "thinking",
    proposal.proposal_id,
    tostring(proposal.effect_version or proposal.dedup_key),
    tostring(proposal.effect_version or proposal.dedup_key) .. "/label/thinking",
    issue.source_ref
  )
end

function C.build_result_label_request(repo, issue_number, reached)
  return C.build_state_label_request(
    repo,
    issue_number,
    "ready",
    reached.proposal_id,
    tostring(reached.effect_version or reached.dedup_key),
    C.result_label_dedup_key(reached),
    reached.source_ref
  )
end

function C.result_label_dedup_key(reached)
  return base_ids.dedup_key({
    tostring(reached.proposal_id),
    "label",
    tostring(reached.effect_version or reached.dedup_key),
  })
end

function C.build_result_state_label_request(repo, issue_number, reached, to_state)
  return C.build_state_label_request(
    repo,
    issue_number,
    to_state,
    reached.proposal_id,
    tostring(reached.effect_version or reached.dedup_key),
    C.result_label_dedup_key(reached),
    reached.source_ref
  )
end

function C.build_intake_enabled_label_request(M, repo, issue_number, candidate)
  local add_labels, remove_labels = M.intake_service_class_label_changes(candidate.service_class)
  table.insert(add_labels, 1, devloop_base._enabled_label)
  return C.build_label_request(
    repo,
    issue_number,
    add_labels,
    remove_labels,
    base_ids.dedup_key({
      "intake",
      "label",
      tostring(candidate.proposal_id),
      tostring(candidate.dedup_key),
    }),
    candidate.source_ref
  )
end

function C.build_intake_tracking_label_request(M, repo, issue_number, candidate)
  local add_labels, remove_labels = M.intake_service_class_label_changes(candidate.service_class)
  table.insert(add_labels, 1, devloop_base._tracking_label)
  return C.build_label_request(
    repo,
    issue_number,
    add_labels,
    remove_labels,
    base_ids.dedup_key({
      "intake",
      "label",
      "tracking",
      tostring(candidate.proposal_id),
      tostring(candidate.dedup_key),
    }),
    candidate.source_ref
  )
end

function C.build_implementing_label_request(repo, issue_number, ready)
  return C.build_state_label_request(
    repo,
    issue_number,
    "implementing",
    ready.proposal_id,
    ready.dedup_key,
    base_ids.dedup_key({
      "implement",
      "label",
      "implementing",
      tostring(ready.dedup_key),
    }),
    ready.source_ref
  )
end

function C.build_impl_failed_label_request(repo, issue_number, ready, reason)
  return C.build_state_label_request(
    repo,
    issue_number,
    "impl-failed",
    ready.proposal_id,
    ready.dedup_key,
    base_ids.dedup_key({
      "implement",
      "label",
      "impl-failed",
      tostring(reason or "failed"),
      tostring(ready.dedup_key),
    }),
    ready.source_ref
  )
end

function C.build_reviewing_label_request(repo, issue_number, origin, pr_number, source_ref)
  return C.build_state_label_request(
    repo,
    issue_number,
    "reviewing",
    origin.proposal_id,
    origin.impl_version,
    base_ids.dedup_key({
      "observe-pr",
      "label",
      tostring(origin.proposal_id),
      tostring(origin.impl_version),
      tostring(pr_number),
    }),
    source_ref
  )
end

function C.build_pr_base_unmanaged_label_request(repo, issue_number, origin, pr_number, integration_branch, source_ref)
  return C.build_state_label_request(
    repo,
    issue_number,
    "blocked",
    origin.proposal_id,
    tostring(origin.impl_version or "") .. "/blocked/pr-base-unmanaged",
    base_ids.dedup_key({
      "observe-pr",
      "label",
      "pr-base-unmanaged",
      tostring(origin.proposal_id),
      tostring(origin.impl_version),
      tostring(pr_number),
      tostring(origin.base_branch),
      tostring(integration_branch),
    }),
    source_ref
  )
end

function C.build_review_result_label_request(repo, issue_number, issue_proposal_id, issue_version, reached, source_ref, marker_target)
  local to_state = reached.reflection_checkpoint and "review-meta"
    or reached.decision == "approve" and "merge-ready"
    or "fixing"
  return C.build_state_label_request(
    repo,
    issue_number,
    to_state,
    issue_proposal_id,
    issue_version,
    base_ids.dedup_key({
      "review-result",
      "label",
      tostring(issue_proposal_id),
      tostring(reached.proposal_id),
    }),
    source_ref,
    nil,
    marker_target
  )
end

function C.build_fix_reviewing_label_request(repo, issue_number, fix, new_head_sha, new_version)
  return C.build_state_label_request(
    repo,
    issue_number,
    "reviewing",
    fix.proposal_id,
    new_version or fix.version,
    base_ids.dedup_key({
      "fix",
      "label",
      tostring(fix.proposal_id),
      tostring(fix.review_dedup_key),
      tostring(new_head_sha),
    }),
    fix.source_ref,
    nil,
    { kind = "pr", number = fix.pr_number }
  )
end

function C.build_merge_head_reviewing_label_request(repo, issue_number, merge_ready, new_head_sha, new_version, source_ref)
  return C.build_state_label_request(
    repo,
    issue_number,
    "reviewing",
    merge_ready.proposal_id,
    new_version,
    base_ids.dedup_key({
      "merge",
      "label",
      "reviewing",
      tostring(merge_ready.proposal_id),
      tostring(new_version),
      tostring(new_head_sha),
    }),
    source_ref,
    nil,
    { kind = "pr", number = merge_ready.pr_number }
  )
end

return C
