local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local entity = require("devloop.entity")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}
local terminal_statuses = {
  done = true,
  failed = true,
}

local function valid_started_at_ms(value)
  return type(value) == "number"
    and value == value
    and value >= 0
    and value < math.huge
    and value % 1 == 0
end

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

function M.marker(proposal_id, started_at_ms, run_id, status)
  return M.replace_marker(proposal_id)
    .. ' started_at_ms="' .. tostring(started_at_ms)
    .. '" run_id="' .. tostring(run_id)
    .. '" status="' .. tostring(status)
    .. '" -->'
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
        run_generation = {
          started_at_ms = row.started_at_ms,
          run_id = row.run_id,
        },
        status = row.status,
      },
      source_ref = source_ref,
    },
  }
end

function M.project_running_row(row)
  if type(row) ~= "table"
    or row.role ~= "implement"
    or row.status ~= "running"
    or type(row.run_id) ~= "string"
    or row.run_id:find("^[%w._-]+$") == nil
    or not valid_started_at_ms(row.started_at_ms) then
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
    or timeout_seconds == nil or timeout_seconds <= 0 then
    error("github-devloop-ops: codex-progress-row-invalid: matching running row lacks display fields")
  end

  local marker = M.marker(row.proposal_id, row.started_at_ms, row.run_id, row.status)
  local body = table.concat({
    "### Implementation progress",
    "",
    "- Run: `" .. row.run_id .. "`",
    "- Role: `" .. row.role .. "`",
    "- Department: `" .. row.dept .. "`",
    "- Elapsed: `" .. format_seconds(elapsed_ms) .. " / " .. tostring(timeout_seconds) .. "s`",
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
    or row.run_id:find("^[%w._-]+$") == nil
    or not valid_started_at_ms(row.started_at_ms) then
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
    M.marker(row.proposal_id, row.started_at_ms, row.run_id, row.status),
  }) do
    table.insert(body_lines, line)
  end

  return projected_request(row, target, table.concat(body_lines, "\n"))
end

return M
