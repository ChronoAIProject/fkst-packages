local M = {}
local root_ref = nil

local stalled_label = "fkst-dev:stalled"

local thresholds = {
  thinking = 30 * 60,
  ready = 30 * 60,
  implementing = 90 * 60,
  ["pr-open"] = 30 * 60,
  reviewing = 60 * 60,
  fixing = 90 * 60,
  merging = 30 * 60,
}

local nonterminal_states = {
  thinking = true,
  ready = true,
  implementing = true,
  ["pr-open"] = true,
  reviewing = true,
  fixing = true,
  merging = true,
}

local function root()
  return root_ref or M
end

local function is_leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function days_in_month(year, month)
  if month == 2 then
    return is_leap_year(year) and 29 or 28
  end
  if month == 4 or month == 6 or month == 9 or month == 11 then
    return 30
  end
  return 31
end

local function valid_timestamp_parts(year, month, day, hour, min, sec)
  if year == nil or month == nil or day == nil or hour == nil or min == nil or sec == nil then
    return false
  end
  if month < 1 or month > 12 then
    return false
  end
  if day < 1 or day > days_in_month(year, month) then
    return false
  end
  return hour >= 0 and hour <= 23 and min >= 0 and min <= 59 and sec >= 0 and sec <= 59
end

local function days_from_civil(year, month, day)
  if month <= 2 then
    year = year - 1
  end
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local shifted_month = month > 2 and month - 3 or month + 9
  local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
  return era * 146097 + day_of_era - 719468
end

local function timestamp_parts_to_epoch(year, month, day, hour, min, sec)
  if not valid_timestamp_parts(year, month, day, hour, min, sec) then
    return nil
  end
  return days_from_civil(year, month, day) * 86400 + hour * 3600 + min * 60 + sec
end

local function parse_timestamp_epoch(timestamp)
  local text = tostring(timestamp or "")
  local year, month, day, hour, min, sec = nil, nil, nil, nil, nil, nil
  for y, mo, d, h, mi, s in text:gmatch("(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d)[%-:](%d%d)[%-:](%d%d)Z") do
    year, month, day, hour, min, sec = y, mo, d, h, mi, s
  end
  if year == nil then
    return nil
  end
  return timestamp_parts_to_epoch(
    tonumber(year),
    tonumber(month),
    tonumber(day),
    tonumber(hour),
    tonumber(min),
    tonumber(sec)
  )
end

local function current_epoch()
  local current = now()
  if type(current) == "number" then
    return current
  end
  return parse_timestamp_epoch(current)
end

local function has_current_dependency_wait(comments, proposal_id, version)
  local core = root()
  if type(comments) ~= "table" then
    return false
  end
  local wait_pattern = "<!%-%- fkst:github%-devloop:dependency%-wait:v1.-%-%->"
  local cycle_pattern = "<!%-%- fkst:github%-devloop:dependency%-cycle:v1.-%-%->"
  for _, comment in ipairs(core._trusted_marker_comments(comments)) do
    local body = core._comment_body(comment)
    for marker in body:gmatch(wait_pattern) do
      if marker:match('proposal="([^"]+)"') == tostring(proposal_id)
        and marker:match('version="([^"]*)"') == tostring(version) then
        return true
      end
    end
    for marker in body:gmatch(cycle_pattern) do
      if marker:match('proposal="([^"]+)"') == tostring(proposal_id)
        and marker:match('version="([^"]*)"') == tostring(version) then
        return true
      end
    end
  end
  return false
end

local function has_stall_marker(comments, proposal_id, state, version)
  local core = root()
  if type(comments) ~= "table" then
    return false
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:stall%-detected:v1.-%-%->"
  for _, comment in ipairs(core._trusted_marker_comments(comments)) do
    for marker in core._comment_body(comment):gmatch(marker_pattern) do
      if marker:match('proposal="([^"]+)"') == tostring(proposal_id)
        and marker:match('state="([^"]+)"') == tostring(state)
        and marker:match('version="([^"]*)"') == tostring(version) then
        return true
      end
    end
  end
  return false
end

local function has_any_stall_marker_for_other_version(comments, proposal_id, state, version)
  local core = root()
  if type(comments) ~= "table" then
    return false
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:stall%-detected:v1.-%-%->"
  for _, comment in ipairs(core._trusted_marker_comments(comments)) do
    for marker in core._comment_body(comment):gmatch(marker_pattern) do
      if marker:match('proposal="([^"]+)"') == tostring(proposal_id) then
        local marker_state = marker:match('state="([^"]+)"')
        local marker_version = marker:match('version="([^"]*)"')
        if marker_state ~= tostring(state) or marker_version ~= tostring(version) then
          return true
        end
      end
    end
  end
  return false
end

local function stall_marker(proposal_id, state, version, threshold_seconds)
  return '<!-- fkst:github-devloop:stall-detected:v1 proposal="' .. tostring(proposal_id)
    .. '" state="' .. tostring(state)
    .. '" version="' .. tostring(version)
    .. '" threshold_seconds="' .. tostring(threshold_seconds)
    .. '" -->'
end

local function issue_source_ref(repo, issue_number)
  return {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
end

function M.stall_watch_threshold_seconds(state)
  return thresholds[state]
end

function M.is_stall_watch_state(state)
  return nonterminal_states[state] == true
end

function M.has_stall_detected_marker(comments, proposal_id, state, version)
  return has_stall_marker(comments, proposal_id, state, version)
end

function M.stall_detected_marker(proposal_id, state, version, threshold_seconds)
  return stall_marker(proposal_id, state, version, threshold_seconds)
end

function M.has_current_dependency_hold(comments, proposal_id, version)
  return has_current_dependency_wait(comments, proposal_id, version)
end

function M.stall_watch_assessment(issue)
  local core = root()
  local current = core.current_state(issue.comments, issue.proposal_id)
  if current == nil then
    return { action = "none", current = current, reason = "unmanaged-or-terminal" }
  end
  if not nonterminal_states[current.state] then
    if has_any_stall_marker_for_other_version(issue.comments, issue.proposal_id, current.state, current.version) then
      return { action = "clear", current = current, reason = "advanced-past-stall" }
    end
    return { action = "none", current = current, reason = "unmanaged-or-terminal" }
  end
  if current.state == "ready" and has_current_dependency_wait(issue.comments, issue.proposal_id, current.version) then
    return { action = "none", current = current, reason = "dependency-held" }
  end
  local threshold = thresholds[current.state]
  local transition_epoch = parse_timestamp_epoch(current.marker_created_at)
  local now_epoch = current_epoch()
  if transition_epoch == nil or now_epoch == nil then
    return { action = "none", current = current, reason = "missing-transition-timestamp" }
  end
  local age_seconds = now_epoch - transition_epoch
  if age_seconds < threshold then
    if has_any_stall_marker_for_other_version(issue.comments, issue.proposal_id, current.state, current.version) then
      return { action = "clear", current = current, reason = "advanced-past-stall" }
    end
    return { action = "none", current = current, reason = "below-threshold", age_seconds = age_seconds, threshold_seconds = threshold }
  end
  if has_stall_marker(issue.comments, issue.proposal_id, current.state, current.version) then
    return { action = "label-only", current = current, age_seconds = age_seconds, threshold_seconds = threshold }
  end
  return { action = "alert", current = current, age_seconds = age_seconds, threshold_seconds = threshold }
end

function M.build_stall_detected_comment_request(repo, issue_number, proposal_id, state, version, threshold_seconds, source_ref)
  local core = root()
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
    body = "github-devloop stall detected"
      .. "\n\nState: " .. tostring(state)
      .. "\nVersion: " .. tostring(version)
      .. "\nThreshold seconds: " .. tostring(threshold_seconds)
      .. "\n\n" .. stall_marker(proposal_id, state, version, threshold_seconds),
    dedup_key = core._dedup_key({
      "stall-detected",
      "comment",
      tostring(proposal_id),
      tostring(state),
      tostring(version),
    }),
    source_ref = core.normalize_source_ref(source_ref or issue_source_ref(repo, issue_number)),
  }
end

function M.build_stalled_label_request(repo, issue_number, proposal_id, state, version, source_ref)
  local core = root()
  return core.build_label_request(
    repo,
    issue_number,
    { stalled_label },
    {},
    core._dedup_key({ "stall-detected", "label", "set", tostring(proposal_id), tostring(state), tostring(version) }),
    source_ref or issue_source_ref(repo, issue_number)
  )
end

function M.build_stalled_label_clear_request(repo, issue_number, proposal_id, version, source_ref)
  local core = root()
  return core.build_label_request(
    repo,
    issue_number,
    {},
    { stalled_label },
    core._dedup_key({ "stall-detected", "label", "clear", tostring(proposal_id), tostring(version or "none") }),
    source_ref or issue_source_ref(repo, issue_number)
  )
end

function M.install(root_module)
  root_ref = root_module
  for k, v in pairs(M) do
    if k ~= "install" then
      root_module[k] = v
    end
  end
  root_module._stalled_label = stalled_label
end

return M
