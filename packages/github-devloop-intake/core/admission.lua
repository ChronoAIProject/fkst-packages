local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local payloads_builders = require("devloop.payloads.builders")
local replay_authorization = require("core.replay_authorization")
local premise_correction = require("devloop.premise_correction")
local devloop_state = require("devloop.state")
local S = {}

function S.build_intake_replay_candidate(repo, issue, terminal)
  local proposal_id = base_ids.proposal_id(repo, tostring(issue.number))
  local effect_id = devloop_base.intake_decision_dedup_key(proposal_id, {
    title = issue.title,
    body = issue.body,
  })
  local successor_key = replay_authorization.successor_key(proposal_id, terminal)
  return payloads_builders.build_devloop_intake_candidate_payload(repo, tostring(issue.number), issue.updated_at, {
    effect_id = effect_id,
    dedup_key = successor_key,
  })
end

function S.build_premise_correction_candidate(repo, issue, correction)
  local proposal_id = base_ids.proposal_id(repo, tostring(issue.number))
  local base_effect_id = devloop_base.intake_decision_dedup_key(proposal_id, {
    title = issue.title,
    body = issue.body,
  })
  local effect_id = premise_correction.decision_dedup_key(base_effect_id, correction)
  return payloads_builders.build_devloop_intake_candidate_payload(repo, tostring(issue.number), issue.updated_at, {
    effect_id = effect_id,
    dedup_key = effect_id,
    premise_fingerprint = correction.premise_fingerprint,
    correction_fingerprint = correction.correction_fingerprint,
  })
end

function S.install(M)
function M.should_skip_known_intake_issue(labels)
  return devloop_base.is_intake_held(labels)
    or devloop_base.is_opted_in(labels)
    or devloop_state.has_active_issue_state(labels, nil, nil)
end

function M.build_intake_admission_candidate(repo, issue, delivery_version)
  local proposal_id = base_ids.proposal_id(repo, tostring(issue.number))
  local effect_id = devloop_base.intake_decision_dedup_key(proposal_id, {
    title = issue.title,
    body = issue.body,
  })
  return payloads_builders.build_devloop_intake_candidate_payload(repo, tostring(issue.number), issue.updated_at, {
    effect_id = effect_id,
    delivery_version = delivery_version,
  })
end

end

return S
