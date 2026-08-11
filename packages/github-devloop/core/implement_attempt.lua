local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local S = {}
local dispatch_live_run = require("devloop.dispatch_live_run")
local impl_failure = require("devloop.impl_failure")

function S.install(M)

function M.implement_exec_ref(proposal_id, dedup_key)
  return dispatch_live_run.dispatch_live_run_exec_ref("implement", proposal_id, dedup_key)
end

function M.implement_attempt_marker(proposal_id, dedup_key, attempt, started_at, exec_ref)
  local n = tonumber(attempt)
  if n == nil or n < 1 or n ~= math.floor(n) then
    error("github-devloop: invalid-attempt: invalid implement attempt")
  end
  local marker = '<!-- fkst:github-devloop:implement-attempt:v1 proposal="' .. tostring(proposal_id)
    .. '" dedup="' .. tostring(dedup_key)
    .. '" attempt="' .. tostring(n)
    .. '" started_at="' .. tostring(started_at or "")
    .. '"'
  if exec_ref ~= nil and exec_ref ~= "" then
    marker = marker .. ' exec_ref="' .. tostring(exec_ref) .. '"'
  end
  return marker .. " -->"
end

function M.latest_implement_attempt_fact(comments, proposal_id, dedup_key)
  return impl_failure.latest_implement_attempt_fact(comments, proposal_id, dedup_key)
end

function M.implement_attempt_count(comments, proposal_id, dedup_key)
  local fact = M.latest_implement_attempt_fact(comments, proposal_id, dedup_key)
  return fact and fact.attempt or 0
end

function M.implement_version_mismatch_marker(proposal_id, expected_version, current_version, attempt)
  local n = tonumber(attempt)
  if n == nil or n < 1 or n ~= math.floor(n) then
    error("github-devloop: invalid-attempt: invalid implement version mismatch attempt")
  end
  return '<!-- fkst:github-devloop:implement-version-mismatch:v1 proposal="' .. tostring(proposal_id)
    .. '" key="' .. devloop_base.implement_version_mismatch_key(expected_version, current_version)
    .. '" attempt="' .. tostring(n)
    .. '" -->'
end

function M.latest_implement_version_mismatch_fact(comments, proposal_id, expected_version, current_version)
  if type(comments) ~= "table" then
    return nil
  end
  local expected_key = devloop_base.implement_version_mismatch_key(expected_version, current_version)
  local marker_pattern = "<!%-%- fkst:github%-devloop:implement%-version%-mismatch:v1.-%-%->"
  local latest = nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local marker_proposal = marker:match('proposal="([^"]+)"')
      local marker_key = marker:match('key="([^"]+)"')
      local attempt = tonumber(marker:match('attempt="(%d+)"'))
      if marker_proposal == proposal_id
        and marker_key == expected_key
        and attempt ~= nil
        and attempt >= 1
        and (latest == nil or attempt > latest.attempt) then
        latest = {
          proposal_id = marker_proposal,
          key = marker_key,
          attempt = attempt,
        }
      end
    end
  end
  return latest
end

function M.implement_version_mismatch_attempt_count(comments, proposal_id, expected_version, current_version)
  local fact = M.latest_implement_version_mismatch_fact(comments, proposal_id, expected_version, current_version)
  return fact and fact.attempt or 0
end

-- Single source of truth for the implement version-mismatch delivery budget. When the
-- observed mismatch attempt count reaches (budget - 1) the NEXT implement delivery is a
-- terminal fail-closed(version-mismatch-budget) (see departments/implement/main.lua
-- handle_implementing_version_mismatch), so every further re-delivery is pure waste.
M.max_implement_version_mismatch_deliveries = 3

-- Anti-spin predicate for the implementing-lineage liveness re-drive. A codex-run-absent
-- re-drive of `implementing@version` hands implement a re-derived ready whose version is
-- implementation_attempt_version(version, impl_retry_attempt) — where impl_retry_attempt
-- comes from the latest implement-attempt fact (see libraries/devloop/replayer.lua
-- replay_implementing). When that re-derived version differs from the authoritative
-- `version`, implement fails its version check; once that mismatch has spent its delivery
-- budget the re-drive can NEVER converge and merely burns an implement slot each sweep
-- (the-omega-institute/trureturing#383). Returns true iff a re-drive at `version` is such
-- a guaranteed-terminal, budget-exhausted mismatch. Scoped to the exact `version`, so a
-- lineage that later advances to a fresh implementing version re-drives normally.
function M.implementing_version_mismatch_budget_exhausted(comments, proposal_id, version)
  if version == nil then
    return false
  end
  local attempt_fact = M.latest_implement_attempt_fact(comments, proposal_id, version)
  local impl_retry_attempt = tonumber(attempt_fact and attempt_fact.attempt)
  if impl_retry_attempt == nil then
    -- Mirror replay_implementing's fallback, but only when it is well-defined: a
    -- suffix-free lineage has no structured retry attempt (implementation_retry_attempt
    -- errors on round 0), so there is no guaranteed mismatch to anti-spin.
    local ok, derived = pcall(M.implementation_retry_attempt, version)
    if not ok or type(derived) ~= "number" then
      return false
    end
    impl_retry_attempt = derived
  end
  local ok, expected = pcall(M.implementation_attempt_version, version, impl_retry_attempt)
  if not ok or expected == nil or tostring(expected) == tostring(version) then
    return false
  end
  return M.implement_version_mismatch_attempt_count(comments, proposal_id, expected, version)
    >= (M.max_implement_version_mismatch_deliveries - 1)
end

end

return S
