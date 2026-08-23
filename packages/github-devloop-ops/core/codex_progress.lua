local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local progress_identity = require("devloop.codex_progress_identity")
local entity = require("devloop.entity")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}
local terminal_statuses = {
  done = true,
  failed = true,
}
local pr_roles = {
  consensus = true,
  fix = true,
  ["review-meta"] = true,
}

local function canonical_issue(row)
  local target = entity.parse_entity_proposal_id(row and row.proposal_id)
  if target == nil or target.kind ~= "issue" then
    return nil
  end
  if base_ids.proposal_id(target.repo, target.issue_number) ~= row.proposal_id then
    return nil
  end
  if tostring(target.issue_number):find("^[1-9]%d*$") == nil then
    return nil
  end
  return target
end

local function format_seconds(milliseconds)
  local rendered = string.format("%.3f", milliseconds / 1000)
  return rendered:gsub("0+$", ""):gsub("%.$", "") .. "s"
end

local function output_block(value)
  local neutralized = devloop_base.neutralize_untrusted_comment_text(value)
  if neutralized == "" then
    neutralized = "(no output yet)"
  end
  return strings.map_lines(neutralized, function(line)
    return "    " .. line
  end)
end

function M.replace_marker(proposal_id)
  return '<!-- fkst:github-devloop-ops:codex-progress:v1 proposal="'
    .. tostring(proposal_id) .. '"'
end

function M.marker(proposal_id, run_id, status, generation)
  local marker = M.replace_marker(proposal_id)
    .. ' run_id="' .. tostring(run_id)
    .. '" status="' .. tostring(status) .. '"'
  if generation ~= nil then
    marker = marker .. ' generation="' .. tostring(generation) .. '"'
  end
  return marker .. ' -->'
end

local function projected_request(row, target, body)
  local replace_marker = M.replace_marker(row.proposal_id)
  local source_ref = entity.issue_source_ref(target.repo, target.issue_number)
  local dedup_key = base_ids.dedup_key({
    "codex-progress",
    target.repo,
    target.issue_number,
    row.run_id,
    sha256.hex(body),
  })

  return {
    proposal_id = row.proposal_id,
    request = {
      schema = "github-proxy.v1",
      repo = target.repo,
      issue_number = target.issue_number,
      body = body,
      dedup_key = dedup_key,
      replace_marker = replace_marker,
      replace_snapshot = {
        run_id = row.run_id,
        status = row.status,
      },
      source_ref = source_ref,
    },
  }
end

function M.project_running_row(row, card_refreshed_at)
  if type(row) ~= "table"
    or row.role ~= "implement"
    or row.status ~= "running"
    or type(row.run_id) ~= "string"
    or row.run_id:find("^[%w._-]+$") == nil then
    return nil
  end
  local target = canonical_issue(row)
  if target == nil then
    return nil
  end

  local elapsed_ms = tonumber(row.elapsed_ms)
  local timeout_seconds = tonumber(row.timeout_seconds)
  if type(row.dept) ~= "string" or row.dept == ""
    or elapsed_ms == nil or elapsed_ms < 0
    or timeout_seconds == nil or timeout_seconds <= 0
    or type(row.started_at) ~= "string" or row.started_at == ""
    or type(card_refreshed_at) ~= "string" or card_refreshed_at == "" then
    error("github-devloop-ops: codex-progress-row-invalid: matching running row lacks display fields")
  end

  local marker = M.marker(row.proposal_id, row.run_id, row.status)
  local body = table.concat({
    "### Implementation progress",
    "",
    "- Run: `" .. row.run_id .. "`",
    "- Role: `" .. row.role .. "`",
    "- Department: `" .. row.dept .. "`",
    "- Elapsed: `" .. format_seconds(elapsed_ms) .. " / " .. tostring(timeout_seconds) .. "s`",
    "- Started: `" .. row.started_at .. "`",
    -- Names the card's own refresh instant, never codex activity: no engine field records when
    -- codex last wrote, so any such claim would be an observation-time proxy wearing codex's name.
    "- Card last updated: `" .. card_refreshed_at .. "`",
    "",
    "Output tail:",
    "",
    output_block(row.output_tail),
    "",
    marker,
  }, "\n")
  return projected_request(row, target, body)
end

function M.project_terminal_row(row)
  if type(row) ~= "table"
    or row.role ~= "implement"
    or terminal_statuses[row.status] ~= true
    or type(row.run_id) ~= "string"
    or row.run_id:find("^[%w._-]+$") == nil then
    return nil
  end
  local target = canonical_issue(row)
  if target == nil then
    return nil
  end

  local elapsed_ms = tonumber(row.elapsed_ms)
  local exit_code = row.exit_code == nil and nil or tonumber(row.exit_code)
  if type(row.dept) ~= "string" or row.dept == ""
    or elapsed_ms == nil or elapsed_ms < 0
    or type(row.started_at) ~= "string" or row.started_at == ""
    or (row.exit_code ~= nil and exit_code == nil) then
    error("github-devloop-ops: codex-progress-row-invalid: matching terminal row lacks display fields")
  end

  local body_lines = {
    "### Implementation result",
    "",
    "- Run: `" .. row.run_id .. "`",
    "- Role: `" .. row.role .. "`",
    "- Department: `" .. row.dept .. "`",
    "- Outcome: `" .. row.status .. "`",
    "- Started: `" .. row.started_at .. "`",
  }
  if row.ended_at_ms ~= nil then
    table.insert(body_lines, "- Duration: `" .. format_seconds(elapsed_ms) .. "`")
  end
  if exit_code ~= nil then
    table.insert(body_lines, "- Exit code: `" .. tostring(exit_code) .. "`")
  end
  for _, line in ipairs({
    "",
    "Output tail:",
    "",
    output_block(row.output_tail),
    "",
    M.marker(row.proposal_id, row.run_id, row.status),
  }) do
    table.insert(body_lines, line)
  end

  return projected_request(row, target, table.concat(body_lines, "\n"))
end

local function pr_candidate(row, statuses)
  if type(row) ~= "table"
    or pr_roles[row.role] ~= true
    or statuses[row.status] ~= true
    or type(row.run_id) ~= "string"
    or row.run_id:find("^[%w._-]+$") == nil then
    return nil
  end
  return progress_identity.parse_label(row.label)
end

local function validate_pr_display_row(row, card_refreshed_at)
  local elapsed_ms = tonumber(row.elapsed_ms)
  local started_at_ms = tonumber(row.started_at_ms)
  local exit_code = row.exit_code == nil and nil or tonumber(row.exit_code)
  if type(row.dept) ~= "string" or row.dept == ""
    or type(row.proposal_id) ~= "string" or row.proposal_id == ""
    or elapsed_ms == nil or elapsed_ms < 0
    or started_at_ms == nil or started_at_ms < 0 or started_at_ms % 1 ~= 0
    or type(row.started_at) ~= "string" or row.started_at == ""
    or (row.exit_code ~= nil and exit_code == nil) then
    error("github-devloop-ops: codex-progress-row-invalid: matching PR row lacks display fields")
  end
  if row.status == "running" then
    local timeout_seconds = tonumber(row.timeout_seconds)
    if timeout_seconds == nil or timeout_seconds <= 0
      or type(card_refreshed_at) ~= "string" or card_refreshed_at == "" then
      error("github-devloop-ops: codex-progress-row-invalid: matching running PR row lacks display fields")
    end
  end
end

local function pr_generation(cohort)
  local latest_started_at_ms = nil
  for _, row in ipairs(cohort) do
    local started_at_ms = tonumber(row.started_at_ms)
    if latest_started_at_ms == nil or started_at_ms > latest_started_at_ms then
      latest_started_at_ms = started_at_ms
    end
  end
  return latest_started_at_ms
end

local function row_order(left, right)
  if left.run_id ~= right.run_id then
    return left.run_id < right.run_id
  end
  if left.role ~= right.role then
    return left.role < right.role
  end
  return tostring(left.dedup_key or "") < tostring(right.dedup_key or "")
end

local function newest_row(rows)
  local newest = nil
  for _, row in ipairs(rows) do
    local row_ms = tonumber(row.ended_at_ms) or tonumber(row.started_at_ms) or -1
    local newest_ms = newest
      and (tonumber(newest.ended_at_ms) or tonumber(newest.started_at_ms) or -1)
      or -1
    if newest == nil
      or row_ms > newest_ms
      or (row_ms == newest_ms and row.run_id > newest.run_id) then
      newest = row
    end
  end
  return newest
end

local function row_observed_ms(row)
  return tonumber(row.ended_at_ms) or tonumber(row.started_at_ms) or -1
end

local function select_pr_cohort(group)
  local prefer_running = false
  for _, candidate in pairs(group.cohorts) do
    prefer_running = prefer_running or #candidate.running > 0
  end

  local selected = nil
  local selected_reference = nil
  for _, candidate in pairs(group.cohorts) do
    local rows = prefer_running and candidate.running or candidate.recent
    local reference = newest_row(rows)
    if reference ~= nil
      and (selected == nil
        or row_observed_ms(reference) > row_observed_ms(selected_reference)
        or (row_observed_ms(reference) == row_observed_ms(selected_reference)
          and reference.run_id > selected_reference.run_id)
        or (row_observed_ms(reference) == row_observed_ms(selected_reference)
          and reference.run_id == selected_reference.run_id
          and candidate.id > selected.id)) then
      selected = candidate
      selected_reference = reference
    end
  end
  if selected == nil then
    return {}, nil
  end

  local cohort = {}
  local seen = {}
  local function append(row)
    if seen[row.run_id] ~= true then
      seen[row.run_id] = true
      table.insert(cohort, row)
    end
  end

  for _, row in ipairs(selected.running) do
    append(row)
  end
  for _, row in ipairs(selected.recent) do
    append(row)
  end

  table.sort(cohort, row_order)
  return cohort, selected.snapshot_id
end

local function aggregate_status(cohort)
  local failed = false
  for _, row in ipairs(cohort) do
    if row.status == "running" then
      return "running"
    end
    failed = failed or row.status == "failed"
  end
  return failed and "failed" or "done"
end

local function append_pr_run(lines, row)
  table.insert(lines, "")
  table.insert(lines, "#### Run `" .. row.run_id .. "`")
  table.insert(lines, "")
  table.insert(lines, "- Role: `" .. row.role .. "`")
  table.insert(lines, "- Department: `" .. row.dept .. "`")
  table.insert(lines, "- Outcome: `" .. row.status .. "`")
  table.insert(lines, "- Started: `" .. row.started_at .. "`")
  if row.status == "running" then
    table.insert(lines, "- Elapsed: `" .. format_seconds(tonumber(row.elapsed_ms))
      .. " / " .. tostring(row.timeout_seconds) .. "s`")
  elseif row.ended_at_ms ~= nil then
    table.insert(lines, "- Duration: `" .. format_seconds(tonumber(row.elapsed_ms)) .. "`")
  end
  if row.exit_code ~= nil then
    table.insert(lines, "- Exit code: `" .. tostring(tonumber(row.exit_code)) .. "`")
  end
  table.insert(lines, "")
  table.insert(lines, "Output tail:")
  table.insert(lines, "")
  table.insert(lines, output_block(row.output_tail))
end

local function pr_body(target_proposal_id, cohort, snapshot_id, status, generation, card_refreshed_at)
  local lines = {
    status == "running" and "### Pull request Codex progress" or "### Pull request Codex result",
    "",
    "- Runs: `" .. tostring(#cohort) .. "`",
    "- Outcome: `" .. status .. "`",
  }
  if status == "running" then
    table.insert(lines, "- Card last updated: `" .. card_refreshed_at .. "`")
  end
  for _, row in ipairs(cohort) do
    append_pr_run(lines, row)
  end
  table.insert(lines, "")
  table.insert(lines, M.marker(target_proposal_id, snapshot_id, status, generation))
  return table.concat(lines, "\n")
end

local function projected_pr_request(target_proposal_id, target, snapshot_id, status, generation, body)
  return {
    queue = "github-proxy.github_pr_comment_request",
    proposal_id = target_proposal_id,
    request = {
      schema = "github-proxy.v1",
      repo = target.repo,
      pr_number = target.pr_number,
      body = body,
      dedup_key = base_ids.dedup_key({
        "codex-progress",
        "pr",
        target.repo,
        target.pr_number,
        snapshot_id,
        sha256.hex(body),
      }),
      replace_marker = M.replace_marker(target_proposal_id),
      replace_snapshot = {
        run_id = snapshot_id,
        status = status,
        generation = generation,
      },
      source_ref = entity.pr_source_ref(target.repo, target.pr_number),
    },
  }
end

function M.project_pr_cards(running, recent, card_refreshed_at)
  if type(running) ~= "table" or type(recent) ~= "table" then
    error("github-devloop-ops: codex-progress-invalid: PR projection requires run sets")
  end
  local groups = {}
  local function collect(row, statuses, field)
    local identity = pr_candidate(row, statuses)
    if identity == nil then
      return
    end
    local key = identity.target_proposal_id
    groups[key] = groups[key] or {
      target = identity.target,
      cohorts = {},
    }
    local cohort = groups[key].cohorts[identity.cohort_id]
    if cohort == nil then
      cohort = {
        id = identity.cohort_id,
        snapshot_id = identity.snapshot_id,
        running = {},
        recent = {},
      }
      groups[key].cohorts[identity.cohort_id] = cohort
    end
    table.insert(cohort[field], row)
  end
  for _, row in ipairs(running) do
    collect(row, { running = true }, "running")
  end
  for _, row in ipairs(recent) do
    collect(row, terminal_statuses, "recent")
  end

  local keys = {}
  for key, _ in pairs(groups) do
    table.insert(keys, key)
  end
  table.sort(keys)

  local projected = {}
  for _, key in ipairs(keys) do
    local group = groups[key]
    local cohort, snapshot_id = select_pr_cohort(group)
    if #cohort > 0 then
      for _, row in ipairs(cohort) do
        validate_pr_display_row(row, card_refreshed_at)
      end
      local status = aggregate_status(cohort)
      local generation = pr_generation(cohort)
      local body = pr_body(key, cohort, snapshot_id, status, generation, card_refreshed_at)
      table.insert(projected, projected_pr_request(
        key,
        group.target,
        snapshot_id,
        status,
        generation,
        body
      ))
    end
  end
  return projected
end

return M
