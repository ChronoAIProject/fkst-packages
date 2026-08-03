local base_ids = require("devloop.base_ids")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local forge_validators = require("devloop.forge_validators")
local operator_commands = require("devloop.operator_commands")
local parsers_misc = require("devloop.parsers.misc")

local S = {}

local command_pattern = "<!%-%- fkst:github%-devloop%-ops:output%-obligation%-command:v1.-%-%->"
local receipt_pattern = "<!%-%- fkst:github%-devloop%-ops:output%-obligation%-resolution%-receipt:v1.-%-%->"

local command_names = {
  ["rereview"] = "rereview",
}
local function attr(marker, name)
  return tostring(marker or ""):match(tostring(name) .. '="([^"]*)"')
end

local function marker_attr(value, limit)
  local text = tostring(value or "")
  if limit ~= nil and #text > limit then
    text = base_ids.truncate_utf8(text, limit)
  end
  return text:gsub("\r", " ")
    :gsub("\n", " ")
    :gsub("&", "&amp;")
    :gsub('"', "&quot;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
end

local function source_lineage_fact(fact, source_issue)
  return operator_commands.output_obligation_source_lineage_fact(fact, source_issue)
end

local function current_source_terminal_matches(fact, source_issue)
  return operator_commands.output_obligation_current_source_terminal_matches(fact, source_issue)
end

local completed_resolutions = {
  ["source-closed"] = {
    decision = "source-closed",
    kind = "completed",
    reason = "source-closed",
  },
  ["rereview"] = {
    decision = "rereview",
    kind = "completed",
    reason = "rereview-reentered",
  },
}

local function resolution_receipt_marker(fact, resolution, max_dedup_len)
  return '<!-- fkst:github-devloop-ops:output-obligation-resolution-receipt:v1 escalation_dedup="'
    .. marker_attr(fact.dedup_key, max_dedup_len)
    .. '" terminal_version="' .. marker_attr(fact.terminal_version, max_dedup_len)
    .. '" decision="' .. marker_attr(resolution.decision, max_dedup_len)
    .. '" kind="' .. marker_attr(resolution.kind, max_dedup_len)
    .. '" reason="' .. marker_attr(resolution.reason, max_dedup_len) .. '" -->'
end

local function resolution_receipt_visible(comments, fact, resolution)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(receipt_pattern) do
      if attr(marker, "escalation_dedup") == tostring(fact.dedup_key)
        and attr(marker, "terminal_version") == tostring(fact.terminal_version)
        and attr(marker, "decision") == tostring(resolution.decision)
        and attr(marker, "kind") == tostring(resolution.kind)
        and attr(marker, "reason") == tostring(resolution.reason) then
        return true
      end
    end
  end
  return false
end

local function resolution_request(fact, resolution, max_dedup_len)
  local marker = resolution_receipt_marker(fact, resolution, max_dedup_len)
  return {
    schema = "github-proxy.v1",
    repo = fact.escalation_repo,
    issue_number = fact.escalation_issue_number,
    body = "github-devloop-ops output-obligation resolution: "
      .. resolution.decision .. " (" .. resolution.reason .. ")\n\n" .. marker,
    dedup_key = base_ids.dedup_key({
      "output-obligation-resolution",
      fact.dedup_key,
      fact.terminal_version,
      resolution.decision,
      resolution.kind,
      resolution.reason,
    }),
    source_ref = fact.escalation_source_ref,
  }
end

local function resolved_decision(M, fact, escalation_issue, resolution)
  if resolution_receipt_visible(escalation_issue and escalation_issue.comments, fact, resolution) then
    return {
      decision = resolution.decision,
      kind = resolution.kind,
      reason = resolution.reason,
      action = "close",
    }
  end
  return {
    decision = resolution.decision,
    kind = resolution.kind,
    reason = resolution.reason,
    action = "receipt",
    request = resolution_request(fact, resolution, M._max_dedup_len),
  }
end

local function command_correlation_marker(M, fact, decision, fields)
  local values = fields or {}
  return '<!-- fkst:github-devloop-ops:output-obligation-command:v1 escalation_dedup="'
    .. marker_attr(fact.dedup_key, M._max_dedup_len)
    .. '" terminal_version="' .. marker_attr(fact.terminal_version, M._max_dedup_len)
    .. '" decision="' .. marker_attr(decision, M._max_key_len)
    .. '" pr="' .. marker_attr(values.pr_number, M._max_key_len)
    .. '" head_sha="' .. marker_attr(values.head_sha, M._max_key_len)
    .. '" target_version="' .. marker_attr(values.target_version, M._max_dedup_len)
    .. '" authorization_epoch="' .. marker_attr(values.authorization_epoch, M._max_key_len)
    .. '" -->'
end

local function command_dedup_key(fact, decision, fields)
  local parts = {
    "output-obligation-command",
    fact.dedup_key,
    fact.terminal_version,
    decision,
  }
  local target = fields or {}
  if decision == "rereview" then
    table.insert(parts, target.pr_number)
    table.insert(parts, target.head_sha)
    table.insert(parts, target.target_version)
  else
    table.insert(parts, target.authorization_epoch)
  end
  return base_ids.dedup_key(parts)
end

local function build_command_decision(M, fact, decision, target, source_ref, fields)
  local command_name = command_names[decision]
  local request = operator_commands.build_operator_command_intent_request(
    target,
    command_name,
    command_dedup_key(fact, decision, fields),
    source_ref,
    command_correlation_marker(M, fact, decision, fields),
    operator_commands.build_output_obligation_command_guard(fact, decision, fields)
  )
  return {
    decision = decision,
    action = "command",
    request = request,
    target_version = fields and fields.target_version or nil,
  }
end

local function command_response_status(comments, command, expected_reason)
  local response = operator_commands.operator_command_response_fact(comments, command)
  if response == nil then
    return "pending", "command-response-pending"
  end
  if response.outcome == "refused" then
    return "refused", "command-refused"
  end
  if response.outcome ~= "applied" or response.reason ~= expected_reason then
    return "invalid", "command-not-applied"
  end
  return "applied", nil
end

local function correlated_command(comments, fact, decision)
  local found = nil
  local refused = {}
  local seen = {}
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(command_pattern) do
      if attr(marker, "escalation_dedup") == tostring(fact.dedup_key)
        and attr(marker, "terminal_version") == tostring(fact.terminal_version)
        and attr(marker, "decision") == tostring(decision) then
        local command = operator_commands.operator_command_fact({ comment }, command_names[decision])
        if command ~= nil then
          if seen[command.key] then
            return nil, "ambiguous-command", refused
          end
          seen[command.key] = true
          local metadata = {
            command = command,
            pr_number = tonumber(attr(marker, "pr")),
            head_sha = attr(marker, "head_sha"),
            target_version = attr(marker, "target_version"),
          }
          local status = command_response_status(comments, command, command_names[decision])
          if status == "refused" then
            table.insert(refused, metadata)
          elseif found ~= nil then
            return nil, "ambiguous-command", refused
          else
            found = metadata
          end
        end
      end
    end
  end
  if found == nil and #refused == 0 then
    return nil, "command-not-visible", refused
  end
  return found, nil, refused
end

local function applied_response(comments, command, expected_reason)
  local status, reason = command_response_status(comments, command, expected_reason)
  return status == "applied", reason
end

local function linked_pr_generation(source_fact, row)
  return operator_commands.output_obligation_linked_pr_generation(source_fact, row)
end

local function coherent_pr(fact, row)
  return operator_commands.output_obligation_coherent_pr(fact, row)
end

local function same_lineage_prs_quiescent(fact, source_fact, snapshot, excluded_pr_number)
  return operator_commands.output_obligation_same_lineage_prs_quiescent(
    fact,
    source_fact,
    snapshot,
    excluded_pr_number
  )
end

local function existing_rereview_command(snapshot, fact)
  local found = nil
  local refused = {}
  for _, row in ipairs(snapshot and snapshot.prs or {}) do
    local command, reason, row_refused = correlated_command(
      row.current and row.current.comments,
      fact,
      "rereview"
    )
    if reason == "ambiguous-command" then
      return nil, reason, refused
    end
    if command ~= nil then
      if found ~= nil then
        return nil, "ambiguous-command", refused
      end
      found = { row = row, metadata = command }
    end
    for _, metadata in ipairs(row_refused or {}) do
      table.insert(refused, metadata)
    end
  end
  return found, nil, refused
end

local function refused_rereview_matches_authorization(refused, authorization)
  local target = authorization and authorization.target or nil
  for _, metadata in ipairs(refused or {}) do
    if tostring(metadata.pr_number or "") == tostring(target and target.row.number or "")
      and metadata.head_sha == tostring(target and target.current_pr.head_sha or "")
      and metadata.target_version == tostring(authorization and authorization.target_version or "") then
      return true
    end
  end
  return false
end

local function decide_existing_rereview(M, fact, escalation_issue, snapshot, source_fact, existing)
  local generation, generation_reason = linked_pr_generation(source_fact, existing.row)
  if generation == nil then
    return { action = "wait", reason = generation_reason }
  end
  if generation ~= "same" then
    return { action = "wait", reason = "command-target-changed" }
  end
  local coherent, reason = coherent_pr(fact, existing.row)
  if coherent == nil then
    return { action = "wait", reason = reason }
  end
  local metadata = existing.metadata
  if tostring(metadata.pr_number or "") ~= tostring(coherent.row.number)
    or metadata.head_sha ~= coherent.current_pr.head_sha
    or not forge_validators.is_git_sha(metadata.head_sha)
    or metadata.target_version == nil
    or metadata.target_version == "" then
    return { action = "wait", reason = "command-target-changed" }
  end
  local applied, response_reason = applied_response(
    coherent.current_pr.comments,
    metadata.command,
    "rereview"
  )
  if not applied then
    return { action = "wait", reason = response_reason }
  end
  if not devloop_state.has_state_marker(
    coherent.current_pr.comments,
    fact.proposal_id,
    "reviewing",
    metadata.target_version
  ) then
    return { action = "wait", reason = "rereview-reentry-pending" }
  end
  local quiescent, quiescence_reason = same_lineage_prs_quiescent(
    fact,
    source_fact,
    snapshot,
    coherent.row.number
  )
  if not quiescent then
    return { action = "wait", reason = quiescence_reason }
  end
  return resolved_decision(M, fact, escalation_issue, completed_resolutions.rereview)
end

local function select_live_decision(M, fact, escalation_issue, source_issue, snapshot, source_fact)
  local rereview_command, rereview_command_reason, refused_rereview_commands = existing_rereview_command(
    snapshot,
    fact
  )
  if rereview_command_reason == "ambiguous-command" then
    return { action = "wait", reason = "ambiguous-command" }
  end
  if rereview_command ~= nil then
    if not current_source_terminal_matches(fact, source_issue) then
      return { action = "wait", reason = "source-terminal-changed" }
    end
    return decide_existing_rereview(M, fact, escalation_issue, snapshot, source_fact, rereview_command)
  end
  local authorization, authorization_reason = operator_commands.output_obligation_live_command_authorization(
    fact,
    source_issue,
    snapshot,
    source_fact
  )
  if authorization == nil then
    return { action = "wait", reason = authorization_reason }
  end
  if authorization.decision == "rereview"
    and refused_rereview_matches_authorization(refused_rereview_commands, authorization) then
    return { action = "wait", reason = "command-refused" }
  end
  if authorization.decision == "rereview" then
    local target = authorization.target
    return build_command_decision(
      M,
      fact,
      "rereview",
      { kind = "pr", repo = fact.source_repo, number = target.row.number },
      entity_lib.pr_source_ref(fact.source_repo, target.row.number),
      {
        pr_number = target.row.number,
        head_sha = target.current_pr.head_sha,
        target_version = authorization.target_version,
      }
    )
  end
  return resolved_decision(M, fact, escalation_issue, authorization)
end

function S.install(M)
  function M.output_obligation_resolution_receipt_marker(fact, decision)
    local resolution = completed_resolutions[decision or "source-closed"]
    if resolution == nil then
      error("github-devloop-ops: output-obligation-resolution-invalid-completed: completed resolution is invalid")
    end
    return resolution_receipt_marker(fact, resolution, M._max_dedup_len)
  end

  function M.output_obligation_resolution_decision(fact, escalation_issue, source_issue, linked_pr_snapshot)
    if type(fact) ~= "table" then
      return { action = "skip", reason = "invalid-escalation-fact" }
    end
    if tostring(source_issue and source_issue.state or ""):upper() == "CLOSED" then
      if source_lineage_fact(fact, source_issue) == nil then
        return { action = "skip", reason = "source-lineage-mismatch" }
      end
      return resolved_decision(M, fact, escalation_issue, completed_resolutions["source-closed"])
    end
    if tostring(source_issue and source_issue.state or ""):upper() ~= "OPEN" then
      return { action = "wait", reason = "source-not-open" }
    end
    local source_fact = source_lineage_fact(fact, source_issue)
    if source_fact == nil then
      return { action = "wait", reason = "source-lineage-mismatch" }
    end
    return select_live_decision(
      M,
      fact,
      escalation_issue,
      source_issue,
      linked_pr_snapshot or { comments = source_issue.comments, prs = {}, absent_prs = {} },
      source_fact
    )
  end
end

return S
