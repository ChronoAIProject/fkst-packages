local S = {}

function S.install(M)
local max_status_action_len = 280

local function is_terminal_state(state)
  return state == "merged" or state == "blocked" or state == "impl-failed"
end

local function status_card_marker(proposal_id)
  return '<!-- fkst:github-devloop:status-card:v1 proposal="' .. tostring(proposal_id) .. '" -->'
end

local function first_display_line(body)
  local text = tostring(body or "")
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = M._trim(line)
    if trimmed ~= ""
      and trimmed:find("<!-- fkst:", 1, true) == nil
      and trimmed:find("AI:FKST", 1, true) == nil then
      return trimmed
    end
  end
  return ""
end

local function compare_created_at(left, right)
  return tostring(left or "") > tostring(right or "")
end

function M.is_status_card_terminal_state(state)
  return is_terminal_state(state)
end

function M.status_card_marker(proposal_id)
  return status_card_marker(proposal_id)
end

function M.latest_status_action_summary(comments, proposal_id)
  local latest = nil
  local marker = status_card_marker(proposal_id)
  for _, comment in ipairs(M._trusted_marker_comments(comments or {})) do
    local body = M._comment_body(comment)
    if body:find("github-devloop", 1, true) ~= nil and body:find(marker, 1, true) == nil then
      local line = first_display_line(body)
      if line ~= "" then
        local created_at = M._comment_created_at(comment) or ""
        if latest == nil or compare_created_at(created_at, latest.created_at) then
          latest = {
            created_at = created_at,
            line = line,
          }
        end
      end
    end
  end
  if latest == nil then
    return "No recent codex action marker is visible."
  end
  local summary = M.neutralize_untrusted_comment_text(latest.line)
  if #summary > max_status_action_len then
    summary = summary:sub(1, max_status_action_len)
  end
  return summary
end

function M.build_status_card_comment_request(repo, issue_number, proposal_id, current, comments, source_ref)
  if type(current) ~= "table" or current.state == nil or current.version == nil then
    error("github-devloop: invalid status card state")
  end
  local body = "github-devloop status"
    .. "\n\nState: " .. tostring(current.state)
    .. "\nVersion: " .. tostring(current.version)
    .. "\nLoop round: " .. tostring(M.version_loop_round(current.version))
    .. "\nFix round: " .. tostring(M.version_fix_round(current.version))
    .. "\nReview loop round: " .. tostring(M.version_review_loop_round(current.version))
    .. "\nRecent codex action: " .. M.latest_status_action_summary(comments, proposal_id)
    .. "\n\n" .. status_card_marker(proposal_id)
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
    body = body,
    dedup_key = M._dedup_key({
      "status-card",
      "comment",
      tostring(proposal_id),
    }),
    upsert = true,
    source_ref = M.normalize_source_ref(source_ref),
  }
end
end

return S
