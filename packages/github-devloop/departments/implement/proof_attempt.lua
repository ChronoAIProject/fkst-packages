local devloop_base = require("devloop.base")
local impl_failure = require("devloop.impl_failure")
local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")

local json = json
local M = {}

local schema = "github-devloop.lean-proof-result.v1"
local repair_reason = "lean-proof-repair-needed"

local common_keys = {
  schema = true,
  status = true,
  phase = true,
  proposal_id = true,
  implementation_version = true,
  attempt = true,
  target = true,
  declaration = true,
  checker_command = true,
}

local repair_keys = {
  last_obligation = true,
  attempted_approaches = true,
  search_evidence = true,
  remaining_blocker = true,
}

local function trim(value)
  return strings.trim(value or "")
end

local function bounded(value, limit)
  return strings.is_bounded_string(value, limit)
end

local function exact_field(value, expected, name)
  if expected ~= nil and tostring(value or "") ~= tostring(expected) then
    return nil, name .. " does not match the current proof attempt"
  end
  return true
end

local function validate_keys(value, include_repair)
  for key, _ in pairs(value) do
    if common_keys[key] ~= true and (not include_repair or repair_keys[key] ~= true) then
      return nil, "unsupported field " .. tostring(key)
    end
  end
  return true
end

local function string_list(value, name)
  if type(value) ~= "table" or #value == 0 then
    return nil, name .. " must be a non-empty string array"
  end
  local result = {}
  for index = 1, #value do
    if not bounded(value[index], devloop_base._max_key_len) then
      return nil, name .. " contains an invalid item"
    end
    result[index] = value[index]
  end
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key > #value or key ~= math.floor(key) then
      return nil, name .. " must be a dense array"
    end
  end
  return result
end

local function search_summary(value)
  if type(value) ~= "table" then
    return nil, "search_evidence must be an object"
  end
  for key, _ in pairs(value) do
    if key ~= "status" and key ~= "queries" and key ~= "detail" then
      return nil, "search_evidence contains an unsupported field"
    end
  end
  if value.status == "performed" then
    local queries, err = string_list(value.queries, "search_evidence.queries")
    if queries == nil then
      return nil, err
    end
    return "performed: " .. table.concat(queries, "; ")
  end
  if value.status == "unavailable" and bounded(value.detail, devloop_base._max_meta_reason_len) then
    return "unavailable: " .. value.detail
  end
  return nil, "search_evidence must record performed queries or verified tool absence"
end

function M.checker_command(target)
  return "lake env lean -E hasSorry " .. tostring(target or "")
end

function M.decode(raw, expected)
  local text = trim(raw)
  if text == "" or #text > devloop_base._max_impl_output_len then
    return nil, "typed result envelope is empty or exceeds the implementation receipt bound"
  end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" then
    return nil, "typed result envelope is not valid JSON"
  end
  if value.schema ~= schema then
    return nil, "schema must be " .. schema
  end
  if value.status ~= "complete" and value.status ~= "repair-needed" then
    return nil, "status must be complete or repair-needed"
  end
  local include_repair = value.status == "repair-needed"
  local keys_ok, keys_err = validate_keys(value, include_repair)
  if not keys_ok then
    return nil, keys_err
  end
  local attempt = impl_failure.valid_attempt(value.attempt)
  if attempt == nil then
    return nil, "attempt must be a positive bounded integer"
  end
  local expected_phase = attempt == 1 and "construction" or "strong-repair"
  if value.phase ~= expected_phase then
    return nil, "phase does not match the bounded implementation attempt"
  end
  if not bounded(value.proposal_id, devloop_base._max_key_len)
    or not bounded(value.implementation_version, devloop_base._max_dedup_len)
    or not strings.is_path_safe_key(value.target, devloop_base._max_key_len)
    or value.target:match("[^/]+%.lean$") == nil
    or not bounded(value.declaration, devloop_base._max_key_len)
    or not bounded(value.checker_command, devloop_base._max_key_len) then
    return nil, "typed result envelope contains an invalid common field"
  end

  expected = expected or {}
  for _, pair in ipairs({
    { "proposal_id", value.proposal_id, expected.proposal_id },
    { "implementation_version", value.implementation_version, expected.implementation_version },
    { "attempt", attempt, expected.attempt },
    { "phase", value.phase, expected.phase },
    { "target", value.target, expected.target },
    { "checker_command", value.checker_command, expected.checker_command },
  }) do
    local matches, err = exact_field(pair[2], pair[3], pair[1])
    if not matches then
      return nil, err
    end
  end

  local receipt = {
    schema = value.schema,
    status = value.status,
    phase = value.phase,
    proposal_id = value.proposal_id,
    implementation_version = value.implementation_version,
    attempt = attempt,
    target = value.target,
    declaration = value.declaration,
    checker_command = value.checker_command,
    raw = text,
  }
  if include_repair then
    if not bounded(value.last_obligation, devloop_base._max_meta_reason_len) then
      return nil, "last_obligation must be a bounded exact checker excerpt"
    end
    local approaches, approaches_err = string_list(value.attempted_approaches, "attempted_approaches")
    if approaches == nil then
      return nil, approaches_err
    end
    local summary, search_err = search_summary(value.search_evidence)
    if summary == nil then
      return nil, search_err
    end
    if not bounded(value.remaining_blocker, devloop_base._max_meta_reason_len) then
      return nil, "remaining_blocker must be a bounded string"
    end
    receipt.last_obligation = value.last_obligation
    receipt.attempted_approaches = approaches
    receipt.search_summary = summary
    receipt.remaining_blocker = value.remaining_blocker
  end
  return receipt, nil
end

local function receipt_text(body)
  local prefix_end = body:find("\n\n", 1, true)
  local state_start = body:find("\n\n<!-- fkst:github-devloop:state:v1", 1, true)
  if prefix_end == nil or state_start == nil or state_start <= prefix_end then
    return nil
  end
  return body:sub(prefix_end + 2, state_start - 1)
end

function M.previous_receipt(comments, expected)
  local best, best_raw = nil, nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments or {})) do
    local body = parsers_misc._comment_body(comment)
    local raw = receipt_text(body)
    if raw ~= nil then
      local receipt = M.decode(raw, {
        proposal_id = expected.proposal_id,
        target = expected.target,
        checker_command = expected.checker_command,
      })
      local failure = receipt ~= nil and impl_failure.fact(
        devloop_base._max_key_len,
        { comment },
        receipt.proposal_id,
        receipt.implementation_version
      ) or nil
      if receipt ~= nil
        and receipt.status == "repair-needed"
        and receipt.attempt < tonumber(expected.before_attempt or 1)
        and failure ~= nil
        and failure.reason == repair_reason
        and failure.attempt == receipt.attempt
        and (best == nil or receipt.attempt > best.attempt) then
        best = receipt
        best_raw = raw
      end
    end
  end
  return best, best_raw
end

local function command_detail(result)
  if type(result) ~= "table" then
    return "Lean checker returned no command result"
  end
  local detail = trim(result.stderr)
  if detail == "" then
    detail = trim(result.stdout)
  end
  return detail ~= "" and detail or "Lean checker exited without diagnostic output"
end

function M.verify_candidate(worktree, target, timeout, run)
  local execute = run or exec_argv
  if type(execute) ~= "function" then
    return { ok = false, reason = "lean-proof-checker-failed", detail = "exec_argv is unavailable" }
  end
  local result = execute({
    argv = { "lake", "env", "lean", "-E", "hasSorry", target },
    cwd = worktree,
    timeout = timeout,
  })
  if type(result) == "table" and tonumber(result.exit_code) == 0 then
    return { ok = true, result = result }
  end
  local detail = command_detail(result)
  local reason = detail:find("declaration uses 'sorry'", 1, true) ~= nil
    and "lean-proof-placeholder-detected" or "lean-proof-checker-failed"
  return { ok = false, reason = reason, detail = detail, result = result }
end

return M
