local core = require("core")
local saga = require("workflow.saga")
local state_labels = require("devloop.state_labels")

local spec = {
  consumes = { "github_issue_label_request" },
  published_seam = { "github_issue_label_request" },
  produces = {},
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function describe_labels(add_labels, remove_labels)
  return "add=[" .. table.concat(add_labels, ",") .. "] remove=[" .. table.concat(remove_labels, ",") .. "]"
end

local function label_list(labels)
  return table.concat(labels or {}, ",")
end

local function contains_state_label(labels)
  for _, label in ipairs(labels or {}) do
    if state_labels.is_state_label(label) then
      return true
    end
  end
  return false
end

local function is_state_label_write(kind, add_labels, remove_labels)
  return kind == "issue"
    and (contains_state_label(add_labels) or contains_state_label(remove_labels))
end

local function marker_target(payload, default_kind, default_number)
  local target = payload.marker_guard and payload.marker_guard.marker_target
  if target == nil then
    return default_kind, default_number
  end
  local kind = tostring(target.kind or "")
  if kind ~= "issue" and kind ~= "pr" then
    return nil, nil
  end
  local number = target.number
  if number == nil then
    return nil, nil
  end
  return kind, number
end

local function same_entity(left_kind, left_number, right_kind, right_number)
  return tostring(left_kind) == tostring(right_kind)
    and tostring(left_number) == tostring(right_number)
end

local function target_kind(payload)
  local kind = tostring(payload.target_kind or "issue")
  if kind ~= "issue" and kind ~= "pr" then
    return nil
  end
  return kind
end

local function target_number(payload, kind)
  if kind == "pr" then
    return payload.target_number or payload.pr_number or payload.issue_number
  end
  return payload.target_number or payload.issue_number
end

local function log_outbound(payload, repo, add_labels, remove_labels, write_env)
  local mode = write_env == "1" and "real" or "dry-run"
  local kind = target_kind(payload) or "issue"
  local number = target_number(payload, kind)
  local fields = {
    "mode=" .. mode,
    "repo=" .. tostring(repo),
    "add=" .. label_list(add_labels),
    "remove=" .. label_list(remove_labels),
    "dedup_key=" .. tostring(payload.dedup_key),
  }
  if kind == "pr" then
    table.insert(fields, 3, "target_kind=pr")
    table.insert(fields, 4, "target_number=" .. tostring(number))
  else
    table.insert(fields, 3, "issue=" .. tostring(number))
  end
  if mode == "dry-run" then
    table.insert(fields, "reason=FKST_GITHUB_WRITE!=1")
  end
  core.log_line("info", "github_issue_label", "OUTBOUND", fields)
end

local function log_skip(payload, repo, add_labels, remove_labels, reason)
  local kind = target_kind(payload) or "issue"
  local number = target_number(payload, kind)
  local fields = {
    "reason=" .. tostring(reason),
    "repo=" .. tostring(repo),
    "add=" .. label_list(add_labels),
    "remove=" .. label_list(remove_labels),
    "dedup_key=" .. tostring(payload.dedup_key),
  }
  if kind == "pr" then
    table.insert(fields, 3, "target_kind=pr")
    table.insert(fields, 4, "target_number=" .. tostring(number))
  else
    table.insert(fields, 3, "issue=" .. tostring(number))
  end
  core.log_line("info", "github_issue_label", "SKIP", fields)
end

local function marker_guard_allows_write(payload, repo, kind, number, add_labels, remove_labels)
  local state_label_write = is_state_label_write(kind, add_labels, remove_labels)
  if payload.marker_guard == nil then
    if payload.require_marker_guard == true or kind == "pr" or state_label_write then
      log_skip(payload, repo, add_labels, remove_labels, "marker-guard-required")
      return false
    end
    return true
  end
  local bot_login = core.assert_trusted_bot_configured()
  local guard_kind, guard_number = marker_target(payload, kind, number)
  if guard_kind == nil then
    log_skip(payload, repo, add_labels, remove_labels, "invalid-marker-target")
    return false
  end
  local comments = core.fetch_marker_guard_comments(repo, guard_kind, guard_number)
  local ok, reason = core.marker_guard_current(comments, payload.marker_guard, bot_login)
  if not ok then
    if state_label_write
      and reason == "marker-guard-missing"
      and same_entity(kind, number, guard_kind, guard_number) then
      return true
    end
    log_skip(payload, repo, add_labels, remove_labels, reason or "marker-guard-failed")
    return false
  end
  return true
end

local function act(event)
  local payload = event.payload or {}
  if payload.schema ~= "github-proxy.label.v1" then
    log.warn("github-proxy: unsupported label request schema")
    return
  end
  local kind = target_kind(payload)
  if kind == nil then
    log.warn("github-proxy: label request has invalid target_kind")
    return
  end
  local number = target_number(payload, kind)
  if number == nil or payload.dedup_key == nil then
    log.warn("github-proxy: label request missing target number or dedup_key")
    return
  end

  local repo = payload.repo or core.read_env("FKST_GITHUB_REPO")
  if repo == nil or repo == "" then
    log.warn("github-proxy: label request missing repo")
    return
  end

  local add_labels = core.normalize_labels(payload.add_labels)
  local remove_labels = core.normalize_labels(payload.remove_labels)
  if #add_labels == 0 and #remove_labels == 0 then
    log.warn("github-proxy: label request has no label changes")
    return
  end

  with_lock(core.entity_label_lock_key(repo, kind, number), function()
    local write_env = core.read_env("FKST_GITHUB_WRITE")
    log_outbound(payload, repo, add_labels, remove_labels, write_env)
    if write_env ~= "1" then
      log.info("github-proxy dry-run: would set labels on " .. tostring(kind)
        .. " " .. tostring(repo) .. "#" .. tostring(number) .. " "
        .. describe_labels(add_labels, remove_labels))
      return
    end
    if kind == "issue"
      and not core.verify_issue_claim_before_write(payload, repo, number, "github_issue_label") then
      return
    end
    if not marker_guard_allows_write(payload, repo, kind, number, add_labels, remove_labels) then
      return
    end
    if kind == "pr" then
      if payload.issue_number ~= nil
        and not core.verify_issue_claim_before_write(payload, repo, payload.issue_number, "github_issue_label") then
        return
      end
    end

    local changed = kind == "pr"
      and core.apply_entity_labels(repo, kind, number, add_labels, remove_labels, payload.label_colors)
      or core.apply_issue_labels(repo, number, add_labels, remove_labels, payload.label_colors)
    if changed ~= true then
      log_skip(payload, repo, add_labels, remove_labels, "no-effective-label-change")
    end
  end)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "github_issue_label",
})
