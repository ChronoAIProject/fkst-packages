local M = {}

local function active_at(read_count, threshold)
  return (read_count or 0) >= threshold
end

function M.rollup(fixture, read_count, head_sha)
  local fresh_reclassification = active_at(read_count, 2)
  local verified_path = active_at(read_count, 3)
  local verified_fresh = active_at(read_count, 4)
  local verified_classifier = verified_path and fixture.verified_classifier_kind or nil
  local ci_unknown = (fixture.reclassification_unknown and fresh_reclassification)
    or verified_classifier == "CI_UNKNOWN"
  local integration_red = (fixture.reclassification_integration_red and fresh_reclassification)
    or (fixture.rollup_fresh_integration_red and fresh_reclassification)
    or (fixture.verified_fresh_integration_red and verified_fresh)
    or verified_classifier == "INTEGRATION_RED"
  local external_red = verified_classifier == "EXTERNAL_CI_RED"
  local reclassification_pending = fixture.reclassification_pending and fresh_reclassification
  local verified_red = fixture.verified_ci_red and verified_path
  local failure = fixture.classification_red or fixture.classification_external
    or fixture.status_gate_red or verified_red or ci_unknown or integration_red or external_red
    or verified_classifier == "CHECKS_PENDING"
  local status = reclassification_pending and "IN_PROGRESS" or "COMPLETED"
  local conclusion = failure and '"FAILURE"' or '"SUCCESS"'
  if status == "IN_PROGRESS" then conclusion = "null" end
  if fixture.verified_ci_wait and verified_path then
    status = "IN_PROGRESS"
    conclusion = "null"
  end
  local name = ci_unknown and "fkst-host-policy" or (external_red and "external-check" or "test")
  return status, conclusion, name, integration_red and fixture.other_head or head_sha
end

function M.commit_check_runs(fixture, read_count, head_sha)
  local fresh_reclassification = active_at(read_count, 2)
  local verified_path = active_at(read_count, 3)
  local verified_fresh = active_at(read_count, 4)
  local verified_classifier = verified_path and fixture.verified_classifier_kind or nil
  local ci_unknown = (fixture.reclassification_unknown and fresh_reclassification)
    or verified_classifier == "CI_UNKNOWN"
  if ci_unknown then
    return '{"total_count":2,"check_runs":[{"name":"fkst-host-policy","status":"completed","conclusion":"failure","head_sha":"'
      .. tostring(head_sha) .. '"},{"name":"fast-gates","status":"completed","conclusion":"failure","head_sha":"'
      .. tostring(head_sha) .. '"}]}\n'
  end
  local pending = fixture.verified_ci_wait or fixture.reclassification_pending
    or verified_classifier == "CHECKS_PENDING"
  local fresh_non_own = (fixture.rollup_fresh_integration_red and fresh_reclassification)
    or (fixture.verified_fresh_integration_red and verified_fresh)
  local required_red = (fixture.classification_red or fixture.status_gate_red) and not fresh_non_own
    or (fixture.verified_ci_red and verified_path and not fresh_non_own)
  local status = pending and "in_progress" or "completed"
  local conclusion = pending and "null" or ('"' .. (required_red and "failure" or "success") .. '"')
  return '{"total_count":1,"check_runs":[{"name":"test","status":"' .. status
    .. '","conclusion":' .. conclusion .. ',"head_sha":"' .. tostring(head_sha) .. '"}]}\n'
end

function M.delegation_fixtures(ctx)
  local array = ctx.array
  local version = ctx.version
  local fix_version = ctx.fix_version
  return array({
    {
      disposition = "rollup-red-fresh-integration-red-holds", status = "rejected",
      reason = "integration-ci-red", cas = "hold", target = "hold", source_line = 564,
      current_state = "merge-ready", current_version = version, status_gate_red = true,
      rollup_fresh_integration_red = true, capture_classification = true,
      expected_admission = "not-own-ci", expected_classification = "INTEGRATION_RED",
      expected_error = "merge-ci-wait", effects = array({ "comment:pr:merge-ci-wait" }),
    },
    {
      disposition = "verified-own-ci-fresh-integration-red-holds", status = "rejected",
      reason = "integration-ci-red", cas = "hold", target = "hold", source_line = 672,
      current_state = "merge-ready", current_version = version, verified_ci_red = true,
      verified_fresh_integration_red = true, capture_classification = true,
      expected_admission = "not-own-ci", expected_classification = "INTEGRATION_RED",
      verified_return = "own-ci-red", expected_error = "merge-ci-wait",
      effects = array({ "comment:pr:merge-ci-wait" }),
    },
    {
      disposition = "fix-loop-max-rounds-blocked", status = "admitted",
      reason = "own-ci-fix-loop-max-rounds", cas = "applied(fix-loop-max-rounds)",
      target = "blocked", source_line = 106,
      evidence_path = "packages/github-devloop-pr/core/fix_rounds.lua",
      current_state = "merge-ready", current_version = fix_version,
      payload = ctx.merge_payload_for_fix(), mergeable_reason = "merge-state-blocked",
      ci_merge_reason = "own-ci-red", classification_red = true,
      capture_classification = true, fix_terminate = true,
      expected_admission = "terminate", expected_classification = "OWN_CI_RED",
      expected_classification_reason = "own-ci-red",
      effects = array({
        "queue:github-devloop-pr.devloop_fix_reconcile",
        "queue:github-devloop-decompose.devloop_decompose",
      }),
    },
    {
      disposition = "hold-ci-wait", status = "rejected",
      reason = "checks-pending", cas = "hold", target = "hold", source_line = 674,
      evidence_path = "packages/github-devloop-pr/core/merge_executor.lua",
      current_state = "merge-ready", current_version = version,
      verified_classifier_kind = "CHECKS_PENDING", expected_verified_classification = "CHECKS_PENDING",
      verified_return = "checks-pending", expected_error = "merge-ci-wait",
      effects = array({ "comment:pr:merge-ci-wait" }),
    },
    {
      disposition = "verified-classifier-ci-unknown-holds", status = "rejected",
      reason = "ci-unknown", cas = "hold", target = "hold", source_line = 49,
      evidence_path = "libraries/forge/merge/verified_merge.lua",
      current_state = "merge-ready", current_version = version,
      verified_classifier_kind = "CI_UNKNOWN", expected_verified_classification = "CI_UNKNOWN",
      verified_return = "ci-unknown", expected_error = "merge-ci-wait",
      effects = array({ "comment:pr:merge-ci-wait" }),
    },
    {
      disposition = "verified-classifier-integration-red-holds", status = "rejected",
      reason = "integration-ci-red", cas = "hold", target = "hold", source_line = 49,
      evidence_path = "libraries/forge/merge/verified_merge.lua",
      current_state = "merge-ready", current_version = version,
      verified_classifier_kind = "INTEGRATION_RED", expected_verified_classification = "INTEGRATION_RED",
      verified_return = "integration-ci-red", expected_error = "merge-ci-wait",
      effects = array({ "comment:pr:merge-ci-wait" }),
    },
    {
      disposition = "verified-classifier-external-red-holds", status = "rejected",
      reason = "external-ci-red", cas = "hold", target = "hold", source_line = 49,
      evidence_path = "libraries/forge/merge/verified_merge.lua",
      current_state = "merge-ready", current_version = version,
      verified_classifier_kind = "EXTERNAL_CI_RED", expected_verified_classification = "EXTERNAL_CI_RED",
      verified_return = "external-ci-red", expected_error = "merge-ci-wait",
      effects = array({ "comment:pr:merge-ci-wait" }),
    },
  })
end

return M
