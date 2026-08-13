local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local entity = require("devloop.entity")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}

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

function M.marker(proposal_id)
  return '<!-- fkst:github-devloop-ops:codex-progress:v1 proposal="'
    .. tostring(proposal_id) .. '" -->'
end

function M.publication_enabled(write_mode)
  return write_mode == "dry-run"
end

function M.project_running_row(row)
  if type(row) ~= "table"
    or row.role ~= "implement"
    or row.status ~= "running"
    or type(row.run_id) ~= "string"
    or row.run_id == "" then
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

  local marker = M.marker(row.proposal_id)
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
      real_write_allowed = false,
      replace_marker = marker,
      source_ref = source_ref,
    },
  }
end

return M
