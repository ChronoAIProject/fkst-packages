local S = {}

function S.install(M)

local watchdog_label = "fkst-watchdog"
local watchdog_window_seconds = 3600
local queue_starvation_threshold_minutes = 10
local intake_silence_threshold_minutes = 10
local snapshot_root_dir = "watchdog-incidents"
local snapshot_file_limit = 20000
local snapshot_log_tail_bytes = 12000

local detector_titles = {
  ["queue-starvation"] = "Self-diagnosis watchdog: merge queue starvation",
  ["intake-silence"] = "Self-diagnosis watchdog: intake silence",
  ["budget-breach"] = "Self-diagnosis watchdog: liveness budget breach",
}

local function window_id(now_seconds)
  local seconds = tonumber(now_seconds) or now()
  return os.date("!%Y-%m-%dT%HZ", math.floor(seconds / watchdog_window_seconds) * watchdog_window_seconds)
end

local function issue_source_ref(repo, issue_number)
  return {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
end

local function watchdog_source_ref(repo, detector)
  return {
    kind = "external",
    ref = tostring(repo) .. "#watchdog/" .. tostring(detector),
  }
end

local function entity_source_ref(repo, entity)
  if tonumber(entity and entity.issue_number) ~= nil then
    return issue_source_ref(repo, entity.issue_number)
  end
  return watchdog_source_ref(repo, entity and entity.proposal_id or "unknown")
end

local function short_title(entity)
  local title = tostring(entity and entity.title or "")
    :gsub("%c", " ")
    :gsub("%s+", " ")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
  title = M.neutralize_untrusted_comment_text(title)
  if title == "" then
    title = "(untitled)"
  end
  if #title > 120 then
    title = M.truncate_utf8(title, 117):gsub("%s+$", "") .. "..."
  end
  return title
end

local function format_entity_ref(entity)
  if tonumber(entity and entity.issue_number) ~= nil then
    return "#" .. tostring(entity.issue_number)
  end
  return tostring(entity and entity.proposal_id or "unknown")
end

local function detector_dedup_key(detector, identity, window)
  return M._dedup_key({
    "watchdog",
    tostring(detector or "unknown"),
    tostring(identity or "repo"),
    tostring(window or ""),
  })
end

local function read_runtime_root()
  local result = exec_sync({ cmd = M.read_runtime_root_cmd(), timeout = 30 })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("github-devloop: watchdog snapshot runtime root read failed")
  end
  local root = M._trim(result.stdout)
  if root == "" or root:find("[\r\n]") ~= nil then
    error("github-devloop: invalid FKST_RUNTIME_ROOT for watchdog snapshot")
  end
  return root:gsub("/+$", "")
end

local function snapshot_segment(value, fallback, limit)
  local segment = M.sanitize_key(tostring(value or ""), false):gsub("[/#]", "-"):gsub("%-+", "-")
  segment = segment:gsub("^%-+", ""):gsub("%-+$", ""):gsub("%.+$", "")
  if segment == "" then
    segment = fallback or "snapshot"
  end
  local max_len = tonumber(limit or 120)
  if #segment > max_len then
    local suffix = "-" .. M._decimal_checksum(segment)
    segment = M.truncate_utf8(segment, max_len - #suffix):gsub("%-+$", "") .. suffix
  end
  if segment == "" then
    return fallback or "snapshot"
  end
  return segment
end

local function snapshot_dir(root, window)
  return root .. "/" .. snapshot_root_dir .. "/" .. snapshot_segment(window, "window", 80)
end

local function snapshot_path(root, alert)
  local detector = snapshot_segment(alert and alert._watchdog_detector, "detector", 80)
  local dedup = tostring(alert and alert.dedup_key or "")
  return snapshot_dir(root, alert and alert._watchdog_window) .. "/" .. detector .. "-" .. M._decimal_checksum(dedup) .. ".md"
end

local function snapshot_log_path(root, alert)
  local detector = snapshot_segment(alert and alert._watchdog_detector, "detector", 80)
  local dedup = tostring(alert and alert.dedup_key or "")
  return snapshot_dir(root, alert and alert._watchdog_window) .. "/" .. detector .. "-" .. M._decimal_checksum(dedup) .. ".supervise.log"
end

local function bounded_supervise_log_path(path)
  local value = tostring(path or "")
  if value == "" or value:find("[%z\r\n]") ~= nil then
    return nil
  end
  if value:sub(1, 1) ~= "/" then
    return nil
  end
  return value
end

local function detector_body(detector, evidence, window)
  local lines = {
    "The self-diagnosis watchdog detected a deterministic anomaly.",
    "",
    "Detector: " .. tostring(detector or "unknown"),
    "Window: " .. tostring(window or ""),
    "",
    "Evidence:",
  }
  for _, line in ipairs(evidence or {}) do
    table.insert(lines, "- " .. M.neutralize_untrusted_comment_text(line))
  end
  table.insert(lines, "")
  table.insert(lines, "Required response:")
  table.insert(lines, "- Investigate through the normal issue -> PR -> review -> merge path.")
  table.insert(lines, "- Do not repair runtime state in place from this alert.")
  table.insert(lines, "")
  table.insert(lines, "This issue was filed by a read-only SRE-style watchdog rule.")
  local body = table.concat(lines, "\n")
  if #body > M._max_body_len then
    body = M.truncate_utf8(body, M._max_body_len)
  end
  return body
end

local function append_snapshot_path(body, path)
  local suffix = "\n\nEvidence snapshot: " .. tostring(path or "") .. "\n"
  local next_body = tostring(body or "") .. suffix
  if #next_body > M._max_body_len then
    return M.truncate_utf8(tostring(body or ""), M._max_body_len - #suffix) .. suffix
  end
  return next_body
end

local function snapshot_body(repo, alert)
  local lines = {
    "# Self-diagnosis watchdog evidence snapshot",
    "",
    "This file is a local evidence snapshot written before the watchdog filed the alert.",
    "",
    "repo: " .. tostring(repo or ""),
    "detector: " .. tostring(alert and alert._watchdog_detector or ""),
    "window: " .. tostring(alert and alert._watchdog_window or ""),
    "dedup_key: " .. tostring(alert and alert.dedup_key or ""),
    "source_ref: " .. tostring(alert and alert.source_ref and alert.source_ref.kind or "")
      .. ":" .. tostring(alert and alert.source_ref and alert.source_ref.ref or ""),
    "",
    "evidence:",
  }
  for _, line in ipairs(alert and alert._watchdog_evidence or {}) do
    table.insert(lines, "- " .. M.neutralize_untrusted_comment_text(line))
  end
  table.insert(lines, "")
  local body = table.concat(lines, "\n")
  if #body > snapshot_file_limit then
    body = M.truncate_utf8(body, snapshot_file_limit)
  end
  return body
end

local function copy_supervise_log_snapshot(path, target)
  local source = bounded_supervise_log_path(path)
  if source == nil then
    return nil
  end
  local cmd = "tail -c " .. tostring(snapshot_log_tail_bytes)
    .. " " .. M._shell_single_quote(source)
    .. " > " .. M._shell_single_quote(target)
  local result = exec_sync({ cmd = cmd, timeout = 30 })
  if type(result) == "table" and result.exit_code == 0 then
    return target
  end
  log.warn("github-devloop dept=observability tag=WATCHDOG_LOG_SNAPSHOT_SKIPPED"
    .. " path=" .. M._one_line(source)
    .. " reason=" .. M._one_line(result and result.stderr or "copy-failed"))
  return nil
end

local function ensure_snapshot_written(repo, alert)
  local root = read_runtime_root()
  local dir = snapshot_dir(root, alert and alert._watchdog_window)
  local path = snapshot_path(root, alert)
  local mkdir = exec_sync({ cmd = "install -d -m 0755 " .. M._shell_single_quote(dir), timeout = 30 })
  if type(mkdir) ~= "table" or mkdir.exit_code ~= 0 then
    error("github-devloop: watchdog snapshot directory setup failed")
  end
  file.write(path, snapshot_body(repo, alert))
  local log_path = copy_supervise_log_snapshot(M.read_env("FKST_DEVLOOP_SUPERVISE_LOG"), snapshot_log_path(root, alert))
  if log_path ~= nil then
    alert._watchdog_log_snapshot = log_path
  end
  return path
end

local function build_alert(repo, detector, identity, evidence, source_ref, window)
  local alert = {
    schema = "github-proxy.issue-create.v1",
    repo = repo,
    title = detector_titles[detector] or "Self-diagnosis watchdog alert",
    body = detector_body(detector, evidence, window),
    labels = { watchdog_label },
    dedup_key = detector_dedup_key(detector, identity, window),
    source_ref = M.normalize_source_ref(source_ref or watchdog_source_ref(repo, detector)),
  }
  alert._watchdog_detector = detector
  alert._watchdog_identity = identity
  alert._watchdog_window = window
  alert._watchdog_evidence = evidence
  return alert
end

local function latest_marker_seconds(entity)
  local updated = entity and entity.parent_issue and entity.parent_issue.updated_at
  if updated ~= nil and updated ~= "" then
    local updated_seconds = M.iso_timestamp_epoch_seconds(updated)
    if updated_seconds ~= nil then
      return updated_seconds
    end
  end
  local state = entity and entity.state or nil
  if type(state) ~= "table" then
    return nil
  end
  local seconds = M.iso_timestamp_epoch_seconds(state.marker_created_at)
  if seconds ~= nil then
    return seconds
  end
  local updated = M.version_updated_at(state.version)
  if updated ~= "" then
    return M.iso_timestamp_epoch_seconds(updated)
  end
  return nil
end

local function minutes_since(seconds, now_seconds)
  local current = tonumber(now_seconds)
  local past = tonumber(seconds)
  if current == nil or past == nil or current < past then
    return nil
  end
  return math.floor((current - past) / 60)
end

local function has_intake_decision(entity)
  if entity == nil or entity.state ~= nil then
    return true
  end
  local comments = entity.parent_issue and entity.parent_issue.comments or {}
  for _, comment in ipairs(M._trusted_marker_comments(comments)) do
    if M._comment_body(comment):find("fkst:github-devloop:intake-decision:v1", 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function add_queue_starvation_alert(alerts, repo, list, counts, now_seconds, window)
  if tonumber(counts and counts.merged or 0) > 0 then
    return
  end
  local candidates = {}
  for _, entity in ipairs(list or {}) do
    if entity.state ~= nil and entity.state.state == "merge-ready" then
      local age = M.liveness_state_age_minutes(entity.state, now_seconds)
      if age ~= nil and age > queue_starvation_threshold_minutes then
        table.insert(candidates, { entity = entity, age_minutes = age })
      end
    end
  end
  if #candidates == 0 then
    return
  end
  table.sort(candidates, function(a, b)
    return tostring(a.entity.proposal_id or "") < tostring(b.entity.proposal_id or "")
  end)
  local head = candidates[1]
  table.insert(alerts, build_alert(repo, "queue-starvation", "merge-ready", {
    "merge_ready_count=" .. tostring(#candidates),
    "merged_count=0",
    "threshold_minutes=" .. tostring(queue_starvation_threshold_minutes),
    "queue_head=" .. format_entity_ref(head.entity),
    "queue_head_age_minutes=" .. tostring(head.age_minutes),
    "queue_head_title=" .. short_title(head.entity),
  }, watchdog_source_ref(repo, "queue-starvation"), window))
end

local function add_intake_silence_alerts(alerts, repo, list, now_seconds, window)
  for _, entity in ipairs(list or {}) do
    if not has_intake_decision(entity) then
      local age = minutes_since(latest_marker_seconds(entity), now_seconds)
      if age ~= nil and age > intake_silence_threshold_minutes then
        table.insert(alerts, build_alert(repo, "intake-silence", entity.proposal_id, {
          "proposal_id=" .. tostring(entity.proposal_id or ""),
          "issue=" .. format_entity_ref(entity),
          "age_minutes=" .. tostring(age),
          "threshold_minutes=" .. tostring(intake_silence_threshold_minutes),
          "title=" .. short_title(entity),
        }, entity_source_ref(repo, entity), window))
      end
    end
  end
end

local function add_budget_breach_alerts(alerts, repo, stalls, window)
  for _, stall in ipairs(stalls or {}) do
    local entity = stall.entity
    local row = M.restart_transition_row(stall.state)
    local attempt = M.liveness_timeout_attempt(row, entity and entity.state)
    local limit = tonumber(row and row.on_timeout and row.on_timeout.escalate_after_attempts)
    if limit ~= nil and attempt >= limit then
      table.insert(alerts, build_alert(repo, "budget-breach", entity and entity.proposal_id, {
        "proposal_id=" .. tostring(entity and entity.proposal_id or ""),
        "issue=" .. format_entity_ref(entity),
        "state=" .. tostring(stall.state or ""),
        "age_minutes=" .. tostring(stall.age_minutes or ""),
        "threshold_minutes=" .. tostring(stall.threshold_minutes or ""),
        "timeout_attempt=" .. tostring(attempt),
        "escalate_after_attempts=" .. tostring(limit),
      }, entity_source_ref(repo, entity), window))
    end
  end
end

function M.watchdog_alerts(repo, list, counts, stalls, now_seconds)
  local window = window_id(now_seconds)
  local alerts = {}
  add_queue_starvation_alert(alerts, repo, list, counts, now_seconds, window)
  add_intake_silence_alerts(alerts, repo, list, now_seconds, window)
  add_budget_breach_alerts(alerts, repo, stalls, window)
  table.sort(alerts, function(a, b)
    return tostring(a.dedup_key or "") < tostring(b.dedup_key or "")
  end)
  return alerts
end

function M.raise_watchdog_alerts(repo, alerts)
  for _, alert in ipairs(alerts or {}) do
    local path = ensure_snapshot_written(repo, alert)
    alert.body = append_snapshot_path(alert.body, path)
    if alert._watchdog_log_snapshot ~= nil then
      alert.body = append_snapshot_path(alert.body, alert._watchdog_log_snapshot)
    end
    alert._watchdog_detector = nil
    alert._watchdog_identity = nil
    alert._watchdog_window = nil
    alert._watchdog_evidence = nil
    alert._watchdog_log_snapshot = nil
    log.info("github-devloop dept=observability tag=WATCHDOG_ALERT"
      .. " repo=" .. tostring(repo or "")
      .. " dedup_key=" .. tostring(alert.dedup_key or "")
      .. " snapshot=" .. M._one_line(path)
      .. " title=" .. M._one_line(alert.title))
    M.log_raise("observability", "watchdog", "github-proxy.github_issue_create_request", alert)
  end
end

end

return S
