local S = {}
local parsers_pr = require("devloop.parsers.pr")
local parsers_issue = require("devloop.parsers.issue")
local sweep_bounds = require("devloop.sweep_bounds")

function S.install(M)
local default_observability_list_page_cap = 2
local default_observability_entity_cap = 25
local default_observability_call_timeout = 10
local default_observability_wall_clock_budget = 90

local function positive_integer(value, fallback, minimum, maximum)
  return sweep_bounds.sweep_positive_integer(value, fallback, minimum, maximum)
end

function M.observability_limits()
  return {
    list_page_cap = default_observability_list_page_cap,
    entity_cap = default_observability_entity_cap,
    call_timeout = default_observability_call_timeout,
    wall_clock_budget = default_observability_wall_clock_budget,
  }
end

function M.observability_deadline(now_seconds, limits)
  return sweep_bounds.sweep_deadline(now_seconds, limits)
end

function M.observability_remaining_seconds(deadline)
  return sweep_bounds.sweep_remaining_seconds(deadline)
end

function M.observability_call_timeout(limits, deadline)
  return sweep_bounds.sweep_call_timeout(limits, deadline)
end

function M.observability_has_budget(deadline)
  return sweep_bounds.sweep_has_budget(deadline)
end

function M.observability_deadline_deferred_result(error_class)
  return sweep_bounds.sweep_deadline_deferred_result(error_class or "observability command", "observability deadline exhausted")
end

function M.observability_result_deferred(result)
  return sweep_bounds.sweep_result_deferred(result)
end

local function log_segment(value)
  local text = tostring(value or "unknown")
  text = text:gsub("[^%w%._%-]", "-"):gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if text == "" then
    return "unknown"
  end
  return text
end

function M.observability_result_timeout(result)
  -- Ground truth for a call timeout is the engine's `timed_out` field on the exec
  -- result (per the exec_argv contract {stdout, stderr, exit_code, timed_out?}). When
  -- the engine reports it, trust it EXCLUSIVELY: a genuine failure with timed_out=false
  -- must still fail-closed even if it happens to exit 124 (and a free-text stderr match
  -- is never used). We fall back to exit-code 124 only when the field is absent, which
  -- in production it is not -- it is the `fkst.test` command mock that does not yet
  -- carry timed_out (substrate follow-up: propagate timed_out through the mock, then
  -- drop this fallback so exit_code is never consulted).
  if type(result) ~= "table" then
    return false
  end
  if result.timed_out ~= nil then
    return result.timed_out == true
  end
  return tonumber(result.exit_code) == 124
end

function M.observability_merge_deferred_reason(current, incoming)
  local next_reason = incoming
  if type(incoming) == "table" then
    next_reason = incoming.reason
  end
  next_reason = tostring(next_reason or "")
  if next_reason == "" then
    return current
  end
  if current == nil or current == "" or next_reason == "timeout" then
    return next_reason
  end
  if current == "timeout" then
    return current
  end
  if next_reason == "deadline" then
    return next_reason
  end
  return current
end

function M.observability_exec(cmd_or_opts, limits, deadline, error_class, exec)
  local result = sweep_bounds.sweep_exec(cmd_or_opts, limits, deadline, error_class or "observability command", exec)
  if sweep_bounds.sweep_result_deferred(result) then
    result.stderr = "observability deadline exhausted"
  end
  return result
end

function M.observability_display_read_cmd(cmd_or_opts, limits, deadline, error_class, exec)
  local label = error_class or "observability display read"
  local result = M.observability_exec(cmd_or_opts, limits, deadline, label, exec)
  if M.observability_result_deferred(result) then
    return result
  end
  if result.exit_code == 0 then
    return result
  end
  if M.observability_result_timeout(result) then
    if type(log) == "table" and type(log.warn) == "function" then
      log.warn("github-devloop dept=observability tag=OBSERVE_READ_DEFERRED"
        .. " reason=timeout"
        .. " error_class=" .. log_segment(label)
        .. " exit_code=" .. tostring(result.exit_code or ""))
    end
    local deferred = M.observability_deadline_deferred_result(label)
    deferred.reason = "timeout"
    deferred.stderr = tostring(result.stderr or "")
    deferred.exit_code = result.exit_code
    return deferred
  end
  error("github-devloop: observability-command-failed: " .. tostring(label) .. " failed: " .. tostring(result.stderr))
end

function M.observability_run_cmd(cmd_or_opts, limits, deadline, error_class, exec)
  local label = error_class or "observability command"
  local result = M.observability_exec(cmd_or_opts, limits, deadline, label, exec)
  if M.observability_result_deferred(result) then
    return result
  end
  if result.exit_code ~= 0 then
    error("github-devloop: observability-command-failed: " .. tostring(label) .. " failed: " .. tostring(result.stderr))
  end
  return result
end

local function bounded_page_cap(limit)
  return positive_integer(limit, default_observability_list_page_cap, 1, 10)
end

function M.observability_rotation_seed(event)
  return sweep_bounds.sweep_rotation_seed(event)
end

function M.observability_rotation_offset(count, seed)
  return sweep_bounds.sweep_rotation_offset(count, seed)
end

function M.observability_rotate(items, seed)
  return sweep_bounds.sweep_rotate(items, seed)
end

function M.observability_batch(items, seed, cap)
  return sweep_bounds.sweep_batch(items, seed, cap, default_observability_entity_cap)
end

function M.observability_page_window(total_pages, seed, cap)
  local total = tonumber(total_pages)
  if total == nil or total ~= math.floor(total) or total < 1 then
    total = 1
  end
  local bounded_cap = bounded_page_cap(cap)
  if bounded_cap > total then
    bounded_cap = total
  end
  local offset = M.observability_rotation_offset(total, seed)
  local pages = {}
  for i = 1, bounded_cap do
    table.insert(pages, ((offset + i - 1) % total) + 1)
  end
  table.sort(pages)
  return pages, math.max(0, total - #pages)
end

function M.observability_entity_candidates(issue_numbers, pr_numbers, seed, cap)
  local candidates = {}
  for _, number in ipairs(issue_numbers or {}) do
    table.insert(candidates, {
      kind = "issue",
      number = number,
      key = string.format("issue/%012d", tonumber(number) or 0),
    })
  end
  for _, number in ipairs(pr_numbers or {}) do
    table.insert(candidates, {
      kind = "pr",
      number = number,
      key = string.format("pr/%012d", tonumber(number) or 0),
    })
  end
  table.sort(candidates, function(a, b)
    return tostring(a.key or "") < tostring(b.key or "")
  end)
  local selected, deferred = M.observability_batch(candidates, seed, cap)
  return selected, deferred
end

function M.observability_sorted_numbers(items)
  local numbers = {}
  local seen = {}
  for _, item in ipairs(items or {}) do
    local number = tonumber(item and item.number)
    local state = tostring(item and item.state or ""):lower()
    if number ~= nil and number >= 1 and number % 1 == 0 and state == "open" and not seen[number] then
      seen[number] = true
      table.insert(numbers, number)
    end
  end
  table.sort(numbers)
  return numbers
end

function M.observability_total_pages_from_headers(stdout, item_count)
  local body = tostring(stdout or "")
  local header_end = body:find("\r\n\r\n", 1, true) or body:find("\n\n", 1, true)
  if header_end == nil then
    if tonumber(item_count) == 100 then
      return 2
    end
    return 1
  end
  local headers = body:sub(1, header_end - 1)
  local link = headers:match("[Ll][Ii][Nn][Kk]:%s*([^\r\n]+)")
  local last = link and link:match('[%?&]page=(%d+)>;%s*rel="last"')
  if last ~= nil then
    local n = tonumber(last)
    if n ~= nil and n >= 1 and n == math.floor(n) then
      return n
    end
  end
  local next_page = link and link:match('[%?&]page=(%d+)>;%s*rel="next"')
  if next_page ~= nil then
    local n = tonumber(next_page)
    if n ~= nil and n >= 2 and n == math.floor(n) then
      return n
    end
  end
  if tonumber(item_count) == 100 then
    return 2
  end
  return 1
end

local function response_body(stdout)
  local text = tostring(stdout or "")
  local marker = text:find("\r\n\r\n", 1, true)
  if marker ~= nil then
    return text:sub(marker + 4)
  end
  marker = text:find("\n\n", 1, true)
  if marker ~= nil then
    return text:sub(marker + 2)
  end
  return text
end

local function list_rotating_pages(first_cmd, page_cmd, parse, limits, deadline, seed, error_class, exec)
  local first = M.observability_display_read_cmd(first_cmd, limits, deadline, error_class, exec)
  if M.observability_result_deferred(first) then
    return {}, 1, first.reason
  end
  local first_parsed = parse(response_body(first.stdout))
  local total_pages = M.observability_total_pages_from_headers(first.stdout, #first_parsed)
  local pages, deferred_pages = M.observability_page_window(total_pages, seed, limits.list_page_cap)
  local items = {}
  local used_first = false
  for _, page in ipairs(pages) do
    local parsed = nil
    if page == 1 then
      parsed = first_parsed
      used_first = true
    else
      local listed = M.observability_display_read_cmd(page_cmd(page), limits, deadline, error_class, exec)
      if M.observability_result_deferred(listed) then
        return items, deferred_pages + 1, listed.reason
      end
      parsed = parse(listed.stdout)
    end
    for _, item in ipairs(parsed or {}) do
      table.insert(items, item)
    end
  end
  if not used_first and total_pages == 1 then
    for _, item in ipairs(first_parsed) do
      table.insert(items, item)
    end
  end
  return items, deferred_pages, nil
end

function M.observability_list_issue_candidates(repo, labels, limits, deadline, seed, exec)
  local items = {}
  local deferred_pages = 0
  local deferred_reason = nil
  for _, label in ipairs(labels or {}) do
    local listed, deferred, reason = list_rotating_pages(
      M.gh_issue_list_observe_opts(repo, label, 1, true),
      function(page)
        return M.gh_issue_list_observe_opts(repo, label, page)
      end,
      function(stdout)
        return parsers_issue.parse_issue_list_observe(stdout)
      end,
      limits,
      deadline,
      tostring(seed or "") .. "/issue/" .. tostring(label or ""),
      "observability issue list",
      exec
    )
    deferred_pages = deferred_pages + deferred
    deferred_reason = M.observability_merge_deferred_reason(deferred_reason, reason)
    for _, issue in ipairs(listed) do
      table.insert(items, issue)
    end
  end
  return items, deferred_pages, deferred_reason
end

function M.observability_list_pr_candidates(repo, limits, deadline, seed, exec)
  return list_rotating_pages(
    M.gh_pr_list_observe_opts(repo, 1, true),
    function(page)
      return M.gh_pr_list_observe_opts(repo, page)
    end,
    function(stdout)
      return parsers_pr.parse_pr_list_observe(stdout)
    end,
    limits,
    deadline,
    tostring(seed or "") .. "/pr",
    "observability PR list",
    exec
  )
end

function M.observability_deferred_log_line(fields)
  return table.concat({
    "github-devloop",
    "dept=observability",
    "tag=OBSERVE_DEFERRED",
    "reason=" .. tostring(fields and fields.reason or "batch-cap"),
    "listed_issues=" .. tostring(fields and fields.listed_issues or 0),
    "listed_prs=" .. tostring(fields and fields.listed_prs or 0),
    "processed_issues=" .. tostring(fields and fields.processed_issues or 0),
    "processed_prs=" .. tostring(fields and fields.processed_prs or 0),
    "deferred_issues=" .. tostring(fields and fields.deferred_issues or 0),
    "deferred_prs=" .. tostring(fields and fields.deferred_prs or 0),
    "entity_cap=" .. tostring(fields and fields.entity_cap or 0),
  }, " ")
end

end

return S
