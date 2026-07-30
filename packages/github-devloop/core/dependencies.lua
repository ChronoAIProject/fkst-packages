local base_ids = require("devloop.base_ids")
local dependency_gate = require("devloop.dependency_gate")
local forge_validators = require("devloop.forge_validators")
local parsers_misc = require("devloop.parsers.misc")
local devloop_state = require("devloop.state")
local M = {}
local transition_version = require("contract.transition_version")

local function dependency_unmet_field(unmet_numbers)
  local parts = {}
  for _, number in ipairs(unmet_numbers or {}) do
    if forge_validators.is_positive_pr_number(number) then
      local next_value = tostring(math.floor(tonumber(number)))
      local candidate = #parts == 0 and next_value or (table.concat(parts, ",") .. "," .. next_value)
      if #candidate > 200 then
        break
      end
      table.insert(parts, next_value)
    end
  end
  return table.concat(parts, ",")
end

local function marker_attr(marker, name)
  return tostring(marker or ""):match(name .. '="([^"]*)"')
end

local function safe_dependency_attr(value)
  local text = tostring(value or "")
  text = text:gsub("<!%-%- fkst:[^\n]*%-%->", " ")
  text = text:gsub("&lt;!%-%- fkst:[^\n]*%-%-&gt;", " ")
  text = text:gsub("%c", " "):gsub('"', "'"):gsub("[<>]", ""):gsub("%s+", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if #text > 240 then
    text = base_ids.truncate_utf8(text, 240)
  end
  return text
end

local function decode_dependency_attr(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if value:find("%c") ~= nil or value:find("[<>]") ~= nil or value:find('"', 1, true) ~= nil then
    return nil
  end
  return value
end

function M.dependency_wait_marker(proposal_id, version, unmet_numbers, hold_kind, reason)
  return '<!-- fkst:github-devloop:dependency-wait:v1 proposal="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" hold_kind="' .. safe_dependency_attr(hold_kind or "waiting")
    .. '" reason="' .. safe_dependency_attr(reason or "waiting-on-dependency")
    .. '" unmet="' .. dependency_unmet_field(unmet_numbers)
    .. '" -->'
end

function M.dependency_cycle_marker(proposal_id, version)
  return '<!-- fkst:github-devloop:dependency-cycle:v1 proposal="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" -->'
end

function M.dependency_unresolvable_marker(proposal_id, version, unmet_numbers, hold_kind, reason)
  return '<!-- fkst:github-devloop:dependency-unresolvable:v1 proposal="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" hold_kind="' .. safe_dependency_attr(hold_kind or "unresolvable")
    .. '" reason="' .. safe_dependency_attr(reason or "gh-failed")
    .. '" unmet="' .. dependency_unmet_field(unmet_numbers)
    .. '" -->'
end

function M.dependency_release_marker(proposal_id, version)
  return '<!-- fkst:github-devloop:dependency-release:v1 proposal="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" -->'
end

function M.ready_split_canonicalized_marker(proposal_id, from_version, to_version, derived_state, reason)
  return '<!-- fkst:github-devloop:ready-split-canonicalized:v1 proposal="' .. tostring(proposal_id)
    .. '" from_version="' .. safe_dependency_attr(from_version)
    .. '" to_version="' .. safe_dependency_attr(to_version)
    .. '" derived_state="' .. safe_dependency_attr(derived_state)
    .. '" reason="' .. safe_dependency_attr(reason or "ready_split_rederive")
    .. '" -->'
end

function M.dependency_void_marker(proposal_id, version, blocker_number, reason)
  return '<!-- fkst:github-devloop:dependency-void:v1 proposal="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" blocker="' .. dependency_unmet_field({ blocker_number })
    .. '" reason="' .. safe_dependency_attr(reason or "not_planned")
    .. '" -->'
end

function M.dependency_waiver_marker(proposal_id, version, blocker_number, reason)
  return '<!-- fkst:github-devloop:dependency-waiver:v1 proposal="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" blocker="' .. dependency_unmet_field({ blocker_number })
    .. '" reason="' .. safe_dependency_attr(reason or "dependency-waiver")
    .. '" -->'
end

function M.dependency_gate_note_markers(proposal_id, version, gate_result)
  local lines = {}
  if type(gate_result) ~= "table" or type(gate_result.notes) ~= "table" then
    return ""
  end
  for _, note in ipairs(gate_result.notes) do
    if type(note) == "table" and note.kind == "dependency-void" then
      table.insert(lines, M.dependency_void_marker(proposal_id, version, note.blocker_number, note.reason))
    elseif type(note) == "table" and note.kind == "dependency-waiver" then
      table.insert(lines, M.dependency_waiver_marker(proposal_id, version, note.blocker_number, note.reason))
    end
  end
  return table.concat(lines, "\n")
end

function M.dependency_gate_has_notes(gate_result)
  return type(gate_result) == "table"
    and type(gate_result.notes) == "table"
    and #gate_result.notes > 0
end

function M.dependency_hold_fact(comments, proposal_id)
  if type(comments) ~= "table" then
    return nil
  end
  local current = devloop_state.current_state(comments, proposal_id)
  if type(current) ~= "table" or current.version == nil then
    return nil
  end
  local wait_pattern = "<!%-%- fkst:github%-devloop:dependency%-wait:v1.-%-%->"
  local cycle_pattern = "<!%-%- fkst:github%-devloop:dependency%-cycle:v1.-%-%->"
  local unresolvable_pattern = "<!%-%- fkst:github%-devloop:dependency%-unresolvable:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    local body = parsers_misc._comment_body(comment)
    local hold_kind = body:match("github%-devloop dependency hold:%s*([^\n]+)")
    local reason = body:match("Reason:%s*([^\n]+)")
    for marker in body:gmatch(wait_pattern) do
      if marker_attr(marker, "proposal") == tostring(proposal_id)
        and marker_attr(marker, "version") == tostring(current.version) then
        return {
          proposal_id = tostring(proposal_id),
          version = tostring(current.version),
          marker_kind = "dependency-wait",
          hold_kind = decode_dependency_attr(marker_attr(marker, "hold_kind")) or hold_kind or "waiting",
          reason = decode_dependency_attr(marker_attr(marker, "reason")) or reason or "waiting-on-dependency",
          comment_created_at = parsers_misc._comment_created_at(comment),
        }
      end
    end
    for marker in body:gmatch(cycle_pattern) do
      if marker_attr(marker, "proposal") == tostring(proposal_id)
        and marker_attr(marker, "version") == tostring(current.version) then
        return {
          proposal_id = tostring(proposal_id),
          version = tostring(current.version),
          marker_kind = "dependency-cycle",
          hold_kind = hold_kind or "cycle",
          reason = reason or "dependency-cycle",
          comment_created_at = parsers_misc._comment_created_at(comment),
        }
      end
    end
    for marker in body:gmatch(unresolvable_pattern) do
      if marker_attr(marker, "proposal") == tostring(proposal_id)
        and marker_attr(marker, "version") == tostring(current.version) then
        return {
          proposal_id = tostring(proposal_id),
          version = tostring(current.version),
          marker_kind = "dependency-unresolvable",
          hold_kind = decode_dependency_attr(marker_attr(marker, "hold_kind")) or hold_kind or "unresolvable",
          reason = decode_dependency_attr(marker_attr(marker, "reason")) or reason or "gh-failed",
          comment_created_at = parsers_misc._comment_created_at(comment),
        }
      end
    end
  end
  return nil
end

function M.dependency_release_fact(comments, proposal_id, version)
  if type(comments) ~= "table" then
    return nil
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:dependency%-release:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local marker_proposal = marker:match('proposal="([^"]+)"')
      local marker_version = marker:match('version="([^"]*)"')
      if marker_proposal == tostring(proposal_id)
        and marker_version == tostring(version) then
        return {
          proposal_id = marker_proposal,
          version = marker_version,
          comment_created_at = parsers_misc._comment_created_at(comment),
        }
      end
    end
  end
  return nil
end

function M.ready_split_canonicalized_fact(comments, proposal_id, from_version)
  if type(comments) ~= "table" then
    return nil
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:ready%-split%-canonicalized:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local marker_proposal = marker:match('proposal="([^"]+)"')
      local marker_from = marker:match('from_version="([^"]*)"')
      if marker_proposal == tostring(proposal_id)
        and marker_from == tostring(from_version) then
        return {
          proposal_id = marker_proposal,
          from_version = marker_from,
          to_version = decode_dependency_attr(marker_attr(marker, "to_version")),
          derived_state = decode_dependency_attr(marker_attr(marker, "derived_state")),
          reason = decode_dependency_attr(marker_attr(marker, "reason")),
          comment_created_at = parsers_misc._comment_created_at(comment),
        }
      end
    end
  end
  return nil
end

function M.ready_split_version(version)
  return transition_version.next_ready_split(version)
end

function M.install(root_module)
  local resolver = dependency_gate.new(root_module)
  for k, v in pairs(resolver) do
    M[k] = v
  end
  for k, v in pairs(M) do
    if k ~= "install" then
      root_module[k] = v
    end
  end
end

return M
