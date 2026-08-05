local impl_failure = require("devloop.impl_failure")
local m_facts = require("devloop.markers.facts")
local S = {}
local strings = require("contract.strings")
local transition_version = require("contract.transition_version")

local valid_attempt = impl_failure.valid_attempt

function S.install(M)
M._max_impl_retry_attempts = impl_failure.MAX_RETRY_ATTEMPTS
M._max_impl_auto_retry_attempts = impl_failure.MAX_AUTO_RETRY_ATTEMPTS

function M.impl_failure_marker(proposal_id, dedup_key, reason, attempt, fault_class, retryable)
  local safe_reason = strings.sanitize_key(reason or "failed", M._max_key_len):gsub("/", "-")
  local safe_fault_class = impl_failure.valid_fault_class(fault_class)
  if safe_fault_class == nil then
    error("github-devloop: invalid-fault-class: invalid implementation failure fault class")
  end
  if type(retryable) ~= "boolean" then
    error("github-devloop: invalid-retry-disposition: implementation failure retryable must be boolean")
  end
  local attempt_field = ""
  if attempt ~= nil then
    local n = valid_attempt(attempt)
    if n == nil then
      error("github-devloop: invalid-attempt: invalid impl failure attempt")
    end
    attempt_field = '" attempt="' .. tostring(n)
  end
  return '<!-- fkst:github-devloop:impl-failure:v1 proposal="' .. tostring(proposal_id)
    .. '" reason="' .. safe_reason
    .. '" fault_class="' .. safe_fault_class
    .. '" retryable="' .. tostring(retryable)
    .. attempt_field
    .. '" dedup="' .. tostring(dedup_key)
    .. '" -->'
end

function M.impl_failure_fact(comments, proposal_id, dedup_key)
  return impl_failure.fact(M._max_key_len, comments, proposal_id, dedup_key)
end

function M.has_impl_failure_marker(comments, proposal_id, dedup_key)
  return M.impl_failure_fact(comments, proposal_id, dedup_key) ~= nil
end

function M.impl_failure_retry_allowed(fact)
  return impl_failure.retry_allowed(fact)
end

function M.next_impl_retry_attempt(fact)
  return impl_failure.next_retry_attempt(fact)
end

function M.implementation_base_version(version)
  return transition_version.strip_trailing_reimplement(version)
end

function M.implementation_branch_version(version, attempt)
  local replacement_round = transition_version.trailing_reimplement_round(version)
  local retry_attempt = attempt == nil and nil or valid_attempt(attempt)
  if attempt ~= nil and retry_attempt == nil then
    error("github-devloop: invalid-attempt: invalid implementation branch attempt")
  end
  if replacement_round == 1 and (retry_attempt == nil or retry_attempt == replacement_round) then
    return tostring(version or "")
  end
  if replacement_round ~= 0
    and retry_attempt ~= nil
    and replacement_round ~= retry_attempt
    and replacement_round + 1 ~= retry_attempt
  then
    error("github-devloop: invalid-version-lineage: implementation retry suffix does not match structured attempt")
  end
  return M.implementation_base_version(version)
end

function M.implementation_delegation_generation(version, attempt)
  local branch_version = M.implementation_branch_version(version, attempt)
  if transition_version.trailing_reimplement_round(branch_version) == 1 then
    return 2
  end
  return 1
end

function M.implementation_retry_attempt(version)
  return valid_attempt(transition_version.trailing_reimplement_round(version))
end

-- The `implementing` marker version is the ALREADY-wrapped ready dedup_key
-- ("ready/<inner>"), because build_devloop_ready_payload applies the
-- _dedup_key({"ready", ...}) wrapper when the ready event is first raised. A
-- liveness re-drive that re-raises devloop_ready must therefore pass the INNER
-- (unwrapped) version, so build_devloop_ready_payload reproduces exactly the
-- frozen marker version on re-wrap. Passing the wrapped version double-wraps it
-- ("ready/ready/<inner>") and the implement receiver rejects it as
-- skip-stale(version-mismatch) forever (issue #718 / #373). Fail closed if the
-- expected prefix is absent, so a malformed marker surfaces rather than
-- silently re-introducing a mismatch.
function M.ready_payload_inner_version(version)
  local text = tostring(version or "")
  local inner, replaced = text:gsub("^ready/", "", 1)
  if replaced == 0 then
    error("github-devloop: invalid-version-lineage: implementing marker version lacks the expected 'ready/' prefix: " .. text)
  end
  return inner
end

function M.implementation_attempt_version(version, attempt)
  local n = attempt == nil and nil or valid_attempt(attempt)
  if attempt ~= nil and n == nil then
    error("github-devloop: invalid-attempt: invalid implementation attempt version")
  end
  if transition_version.trailing_reimplement_round(
    M.implementation_branch_version(version, n)
  ) == 1 then
    return tostring(version or "")
  end
  local base = M.implementation_base_version(version)
  if n == nil or n <= 1 then
    return base
  end
  return transition_version.reimplement_at(base, n)
end

function M.has_implementation_fact_marker(comments, proposal_id, dedup_key)
  return m_facts.has_implementing_marker(comments, proposal_id, dedup_key)
    or M.has_impl_failure_marker(comments, proposal_id, dedup_key)
end
end

return S
