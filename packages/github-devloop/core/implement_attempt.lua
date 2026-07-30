local parsers_misc = require("devloop.parsers.misc")
local S = {}
local dispatch_live_run = require("devloop.dispatch_live_run")

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
  if type(comments) ~= "table" then
    return nil
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:implement%-attempt:v1.-%-%->"
  local latest = nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local marker_proposal = marker:match('proposal="([^"]+)"')
      local marker_dedup = marker:match('dedup="([^"]*)"')
      local attempt = tonumber(marker:match('attempt="(%d+)"'))
      local started_at = marker:match('started_at="([^"]*)"')
      local exec_ref = marker:match('exec_ref="([^"]*)"')
      if marker_proposal == proposal_id
        and marker_dedup == tostring(dedup_key)
        and attempt ~= nil
        and attempt >= 1
        and (latest == nil or attempt > latest.attempt) then
        latest = {
          proposal_id = marker_proposal,
          dedup_key = marker_dedup,
          attempt = attempt,
          started_at = started_at,
          exec_ref = exec_ref,
        }
      end
    end
  end
  return latest
end

function M.implement_attempt_count(comments, proposal_id, dedup_key)
  local fact = M.latest_implement_attempt_fact(comments, proposal_id, dedup_key)
  return fact and fact.attempt or 0
end

end

return S
