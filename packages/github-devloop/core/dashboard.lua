local S = {}

function S.install(M)
local dashboard_title = "fkst-dev board"
local dashboard_marker_prefix = "<!-- fkst:dashboard:v1"
local max_dashboard_body_len = 12000
local max_dashboard_section_items = 40
local max_dashboard_title_len = 80

local topology_nodes = {
  {
    id = "gh",
    label = "GitHub",
    lane = "github-proxy",
    departments = { "github_poll", "github_comment", "github_pr_comment", "github_pr_open", "github_issue_label", "github_issue_create" },
  },
  {
    id = "poll",
    label = "poll",
    lane = "github-devloop",
    departments = { "intake_scan", "observe_issue", "observe_pr", "open_pr", "ensure_repo", "sync_scan", "rollup_scan", "observability" },
  },
  {
    id = "intake",
    label = "intake",
    lane = "github-devloop",
    departments = { "intake_judge" },
  },
  {
    id = "consensus",
    label = "consensus(3+meta)",
    lane = "consensus",
    departments = { "decide" },
  },
  {
    id = "implement",
    label = "implement",
    lane = "github-devloop",
    departments = { "consensus_result", "loop", "implement", "decompose", "reconcile" },
  },
  {
    id = "pr",
    label = "PR",
    lane = "github-devloop",
    departments = { "review_pr" },
  },
  {
    id = "review",
    label = "review consensus",
    lane = "github-devloop",
    departments = { "review_result", "review_loop", "review_meta", "fix", "sync_conflict" },
  },
  {
    id = "merge",
    label = "merge",
    lane = "github-devloop",
    departments = { "merge" },
  },
  {
    id = "rollup",
    label = "rollup",
    lane = "github-devloop",
    departments = { "rollup_merge" },
  },
  {
    id = "dev",
    label = "dev",
    lane = "github-devloop",
    departments = {},
  },
}

local topology_edges = {
  { "gh", "poll" },
  { "poll", "intake" },
  { "intake", "consensus" },
  { "consensus", "implement" },
  { "implement", "pr" },
  { "pr", "review" },
  { "review", "merge" },
  { "merge", "rollup" },
  { "rollup", "dev" },
}

local state_macro = {
  unmanaged = "poll",
  thinking = "consensus",
  ready = "implement",
  implementing = "implement",
  ["pr-open"] = "pr",
  reviewing = "review",
  ["merge-ready"] = "merge",
  merging = "merge",
  fixing = "review",
  ["review-meta"] = "review",
  ["impl-failed"] = "implement",
  blocked = "review",
  merged = "dev",
}

local function node_by_id()
  local map = {}
  for _, node in ipairs(topology_nodes) do
    map[node.id] = node
  end
  return map
end

local function known_department_map()
  local known = {}
  for _, node in ipairs(topology_nodes) do
    for _, dept in ipairs(node.departments or {}) do
      known[dept] = node.id
    end
  end
  return known
end

local function dept_name(value)
  local text = tostring(value or "")
  local name = text:match("departments/([^/]+)/main%.lua$")
    or text:match("departments[%.%/]([^%.%/]+)")
    or text:match("^([^:]+)$")
  return name
end

local function iter_graph_departments(graph, callback)
  if type(graph) ~= "table" then
    return
  end
  local departments = graph.departments or graph.nodes or graph.depts
  if type(departments) == "table" then
    for key, value in pairs(departments) do
      local name = nil
      if type(value) == "table" then
        name = value.name or value.id or value.department or value.path
      elseif type(value) == "string" then
        name = value
      end
      if name == nil and type(key) == "string" then
        name = key
      end
      local parsed = dept_name(name)
      if parsed ~= nil and parsed ~= "" then
        callback(parsed)
      end
    end
  end
end

local function optional_primitive(name)
  local value = _G and _G[name] or nil
  if type(value) == "function" then
    return value
  end
  return nil
end

local function safe_call_primitive(name)
  local primitive = optional_primitive(name)
  if primitive == nil then
    return nil, "unavailable"
  end
  local ok, result = pcall(primitive)
  if not ok then
    return nil, "failed"
  end
  if type(result) == "string" then
    local decoded_ok, decoded = pcall(function()
      return json.decode(result or "{}")
    end)
    if not decoded_ok then
      return nil, "failed"
    end
    return decoded, nil
  end
  return result, nil
end

local function compact_title(value)
  local title = tostring(value or ""):gsub("%c", " "):gsub("%s+", " ")
  title = title:gsub("^%s+", ""):gsub("%s+$", "")
  title = M.neutralize_untrusted_comment_text(title)
  if title == "" then
    title = "(untitled)"
  end
  if #title > max_dashboard_title_len then
    title = M.truncate_utf8(title, max_dashboard_title_len - 3):gsub("%s+$", "") .. "..."
  end
  return title
end

local function entity_issue_ref(entity)
  if tonumber(entity.issue_number) ~= nil then
    return "#" .. tostring(entity.issue_number)
  end
  return tostring(entity.proposal_id or "unknown")
end

local function entity_link(entity)
  local issue = entity_issue_ref(entity)
  if tonumber(entity.pr_number) ~= nil then
    return issue .. "/PR#" .. tostring(entity.pr_number)
  end
  return issue
end

local function format_duration(seconds)
  local total = tonumber(seconds)
  if total == nil or total < 0 then
    return "unknown"
  end
  total = math.floor(total)
  if total < 60 then
    return tostring(total) .. "s"
  end
  local minutes = math.floor(total / 60)
  local secs = total % 60
  if minutes < 60 then
    return tostring(minutes) .. "m" .. tostring(secs) .. "s"
  end
  local hours = math.floor(minutes / 60)
  local rest = minutes % 60
  return tostring(hours) .. "h" .. tostring(rest) .. "m"
end

local function format_age(age_minutes)
  if tonumber(age_minutes) == nil then
    return "age unknown"
  end
  local minutes = tonumber(age_minutes)
  if minutes < 60 then
    return tostring(minutes) .. "m"
  end
  local hours = math.floor(minutes / 60)
  local rest = minutes % 60
  if hours < 48 then
    return tostring(hours) .. "h " .. tostring(rest) .. "m"
  end
  local days = math.floor(hours / 24)
  local day_hours = hours % 24
  return tostring(days) .. "d " .. tostring(day_hours) .. "h"
end

local function entity_age_minutes(entity, now_seconds)
  if entity == nil or entity.state == nil then
    return nil
  end
  return M.stall_suspect_age_minutes(entity.state.version, now_seconds)
end

local function entity_line(entity, now_seconds)
  local state = entity.state and entity.state.state or "unmanaged"
  local parts = {
    "- " .. entity_issue_ref(entity),
    compact_title(entity.title),
    "-",
    tostring(state) .. ",",
    format_age(entity_age_minutes(entity, now_seconds)),
  }
  if tonumber(entity.pr_number) ~= nil then
    table.insert(parts, "(PR #" .. tostring(entity.pr_number) .. ")")
  end
  if entity.dependency_wait ~= nil then
    table.insert(parts, "[dependency-wait]")
  end
  return table.concat(parts, " ")
end

local function macro_buckets(list)
  local buckets = {}
  for _, node in ipairs(topology_nodes) do
    buckets[node.id] = { count = 0, entities = {}, last_age = nil }
  end
  for _, entity in ipairs(list or {}) do
    local state = entity.state and entity.state.state or "unmanaged"
    local macro = state_macro[state] or "poll"
    local bucket = buckets[macro]
    if bucket ~= nil then
      bucket.count = bucket.count + 1
      table.insert(bucket.entities, entity)
    end
  end
  return buckets
end

local function render_topology(lines, graph_status)
  table.insert(lines, "## Topology")
  table.insert(lines, "```mermaid")
  table.insert(lines, "flowchart LR")
  local lanes = { "github-proxy", "consensus", "github-devloop" }
  local nodes = node_by_id()
  for _, lane in ipairs(lanes) do
    table.insert(lines, "  subgraph " .. lane:gsub("%-", "_") .. " [" .. lane .. "]")
    for _, node in ipairs(topology_nodes) do
      if node.lane == lane then
        table.insert(lines, "    " .. node.id .. "[" .. node.label .. "]")
      end
    end
    table.insert(lines, "  end")
  end
  for _, edge in ipairs(topology_edges) do
    if nodes[edge[1]] ~= nil and nodes[edge[2]] ~= nil then
      table.insert(lines, "  " .. edge[1] .. " --> " .. edge[2])
    end
  end
  table.insert(lines, "```")
  if graph_status ~= nil then
    table.insert(lines, "- graph_json: " .. graph_status)
  end
end

local function entity_brief(entity)
  return entity_link(entity) .. " " .. compact_title(entity.title)
end

local function render_live_overlay(lines, list, now_seconds, graph)
  local buckets = macro_buckets(list)
  table.insert(lines, "")
  table.insert(lines, "## Live overlay")
  for _, node in ipairs(topology_nodes) do
    local bucket = buckets[node.id] or { count = 0, entities = {} }
    local details = {}
    for index, entity in ipairs(bucket.entities) do
      if index > 2 then
        table.insert(details, "+" .. tostring(#bucket.entities - 2) .. " more")
        break
      end
      table.insert(details, entity_brief(entity))
    end
    local last_age = "none"
    if #bucket.entities > 0 then
      table.sort(bucket.entities, function(a, b)
        return (entity_age_minutes(a, now_seconds) or 1000000000) < (entity_age_minutes(b, now_seconds) or 1000000000)
      end)
      last_age = format_age(entity_age_minutes(bucket.entities[1], now_seconds))
    end
    if #details == 0 then
      table.insert(details, "idle")
    end
    table.insert(lines, "- " .. node.label .. ": in-flight=" .. tostring(bucket.count)
      .. "; entities=" .. table.concat(details, ", ")
      .. "; last=" .. last_age)
  end
end

local function registry_job_entity(job)
  return tostring(job.entity or job.proposal_id or job.issue or job.pr or "unknown")
end

local function registry_role(job)
  return tostring(job.role or job.kind or job.dept or "codex")
end

local function registry_elapsed(job, now_seconds)
  if tonumber(job.elapsed_seconds) ~= nil then
    return tonumber(job.elapsed_seconds)
  end
  local started = job.started_at or job.startedAt or job.spawned_at or job.spawnedAt
  local started_seconds = M.iso_timestamp_epoch_seconds(started)
  if started_seconds ~= nil then
    return tonumber(now_seconds) - started_seconds
  end
  return nil
end

local function registry_duration(job)
  if tonumber(job.duration_seconds) ~= nil then
    return tonumber(job.duration_seconds)
  end
  if tonumber(job.elapsed_seconds) ~= nil then
    return tonumber(job.elapsed_seconds)
  end
  return nil
end

local function registry_outcome(job)
  local text = tostring(job.outcome or job.summary or job.output_excerpt or job.output or job.result or "")
  text = text:gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    text = "completed"
  end
  if #text > 120 then
    text = M.truncate_utf8(text, 117):gsub("%s+$", "") .. "..."
  end
  return M.neutralize_untrusted_comment_text(text)
end

local function normalize_registry(status)
  local running = {}
  local queued = {}
  local completed = {}
  if type(status) ~= "table" then
    return running, queued, completed, nil
  end
  for _, job in ipairs(status.running or status.active or {}) do
    if type(job) == "table" then
      table.insert(running, job)
    end
  end
  for _, job in ipairs(status.queued or status.pending or {}) do
    if type(job) == "table" then
      table.insert(queued, job)
    end
  end
  for _, job in ipairs(status.completed or status.recent_completed or status.finished or {}) do
    if type(job) == "table" then
      table.insert(completed, job)
    end
  end
  return running, queued, completed, status.resources or status.resource or status
end

local function render_now_working(lines, codex_status, now_seconds)
  local running, _, completed = normalize_registry(codex_status)
  table.insert(lines, "")
  table.insert(lines, "## Now working")
  if #running == 0 then
    table.insert(lines, "- None")
  else
    for _, job in ipairs(running) do
      table.insert(lines, "- " .. registry_role(job) .. " -> " .. registry_job_entity(job)
        .. "; elapsed=" .. format_duration(registry_elapsed(job, now_seconds)))
    end
  end
  table.insert(lines, "")
  table.insert(lines, "### Recent codex completions")
  if #completed == 0 then
    table.insert(lines, "- None")
  else
    local shown = 0
    for _, job in ipairs(completed) do
      if shown >= 10 then
        break
      end
      local marker = tostring(job.marker_url or job.url or "")
      local suffix = marker ~= "" and ("; marker=" .. marker) or ""
      table.insert(lines, "- " .. registry_role(job) .. " -> " .. registry_job_entity(job)
        .. "; duration=" .. format_duration(registry_duration(job))
        .. "; " .. registry_outcome(job) .. suffix)
      shown = shown + 1
    end
  end
end

local function median(values)
  if #values == 0 then
    return nil
  end
  table.sort(values)
  return values[math.floor((#values + 1) / 2)]
end

local function render_census(lines, list, counts, codex_status, now_seconds)
  local running, queued = normalize_registry(codex_status)
  local eligible = 0
  local dependency_held = 0
  local terminal = 0
  local dwell = {}
  for _, entity in ipairs(list or {}) do
    local state = entity.state and entity.state.state or "unmanaged"
    if state == "ready" or state == "fixing" or state == "merge-ready" or state == "review-meta" then
      eligible = eligible + 1
    end
    if entity.dependency_wait ~= nil then
      dependency_held = dependency_held + 1
    end
    if state == "merged" or state == "blocked" or state == "impl-failed" then
      terminal = terminal + 1
    end
    local age = entity_age_minutes(entity, now_seconds)
    if age ~= nil then
      dwell[state] = dwell[state] or {}
      table.insert(dwell[state], age)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "## Pipeline census")
  table.insert(lines, "- eligible=" .. tostring(eligible)
    .. "; dependency-held=" .. tostring(dependency_held)
    .. "; terminal=" .. tostring(terminal))
  table.insert(lines, "- codex queued=" .. tostring(#queued) .. "; running=" .. tostring(#running))
  local states = {}
  for state, _ in pairs(dwell) do
    table.insert(states, state)
  end
  table.sort(states)
  if #states == 0 then
    table.insert(lines, "- dwell: unknown")
  else
    local parts = {}
    for _, state in ipairs(states) do
      table.insert(parts, state .. "=" .. format_age(median(dwell[state])))
    end
    table.insert(lines, "- dwell median: " .. table.concat(parts, ", "))
  end
  table.insert(lines, "- poll-to-transition latency: bounded by 5m observability poll")

  local max_loop = 0
  local max_fix = 0
  local max_review_loop = 0
  for _, entity in ipairs(list or {}) do
    local version = entity.state and entity.state.version or ""
    max_loop = math.max(max_loop, M.version_loop_round(version))
    max_fix = math.max(max_fix, M.version_fix_round(version))
    max_review_loop = math.max(max_review_loop, M.version_review_loop_round(version))
  end
  table.insert(lines, "- rounds max: thinking=" .. tostring(max_loop)
    .. "; fix=" .. tostring(max_fix)
    .. "; review=" .. tostring(max_review_loop))
end

local function resource_value(resources, names)
  if type(resources) ~= "table" then
    return nil
  end
  for _, name in ipairs(names) do
    if resources[name] ~= nil then
      return resources[name]
    end
  end
  return nil
end

local function nested_resource(resources, names)
  local value = resource_value(resources, names)
  if type(value) == "table" then
    return value
  end
  return nil
end

local function format_pool(resources)
  local pool = nested_resource(resources, { "gh_rate_pool", "rate_pool" }) or resources
  local remaining = resource_value(pool, { "remaining", "tokens_remaining", "tokens" })
  local refill = resource_value(pool, { "refill", "refill_per_hour", "refill_rate" })
  if remaining ~= nil or refill ~= nil then
    return "remaining=" .. tostring(remaining or "?") .. ", refill=" .. tostring(refill or "?")
  end
  local plain = resource_value(resources, { "gh_rate_pool", "rate_pool" })
  if type(plain) == "string" or type(plain) == "number" then
    return tostring(plain)
  end
  return "not available"
end

local function format_quota(resources)
  local quota = nested_resource(resources, { "quota", "github_quota" }) or resources
  local graphql = resource_value(quota, { "graphql_remaining", "graphql" })
  local rest = resource_value(quota, { "rest_remaining", "rest" })
  if graphql ~= nil or rest ~= nil then
    return "GraphQL=" .. tostring(graphql or "?") .. ", REST=" .. tostring(rest or "?")
  end
  local plain = resource_value(resources, { "quota", "github_quota" })
  if type(plain) == "string" or type(plain) == "number" then
    return tostring(plain)
  end
  return "not available"
end

local function render_footer(lines, instance, generated_at, codex_status)
  local _, _, _, resources = normalize_registry(codex_status)
  table.insert(lines, "")
  table.insert(lines, "## Resources")
  local used = resource_value(resources, { "codex_used", "permits_used", "used" })
  local total = resource_value(resources, { "codex_total", "permits_total", "total" })
  if used ~= nil or total ~= nil then
    table.insert(lines, "- codex permits: " .. tostring(used or "?") .. "/" .. tostring(total or "?"))
  else
    table.insert(lines, "- codex permits: not available")
  end
  table.insert(lines, "- gh rate pool: " .. format_pool(resources))
  table.insert(lines, "- GraphQL/REST quota: " .. format_quota(resources))
  table.insert(lines, "- redb size: " .. tostring(resource_value(resources, { "redb_size", "durable_size" }) or "not available"))
  table.insert(lines, "- instance: " .. tostring(instance))
  table.insert(lines, "- generated-at: " .. generated_at)
end

function M.dashboard_topology_nodes()
  return topology_nodes
end

function M.dashboard_marker(hash, generated_at)
  return dashboard_marker_prefix
    .. ' version="' .. tostring(generated_at or "")
    .. '" hash="' .. tostring(hash or "")
    .. '" generated_at="' .. tostring(generated_at or "")
    .. '" -->'
end

function M.dashboard_marker_prefix()
  return dashboard_marker_prefix
end

function M.dashboard_validate_graph(graph)
  local known = known_department_map()
  local missing = {}
  iter_graph_departments(graph, function(name)
    if known[name] == nil then
      table.insert(missing, name)
    end
  end)
  table.sort(missing)
  return missing
end

function M.dashboard_read_graph()
  local graph, status = safe_call_primitive("graph_json")
  if graph == nil then
    return nil, status
  end
  local missing = M.dashboard_validate_graph(graph)
  if #missing > 0 then
    return graph, "missing aggregation: " .. table.concat(missing, ",")
  end
  return graph, "ok"
end

function M.dashboard_read_codex_status()
  local status = safe_call_primitive("codex_status")
  return status
end

function M.render_observability_dashboard(args)
  local list = args and args.entities or {}
  local counts = args and args.counts or {}
  local stalls = args and args.stalls or {}
  local now_seconds = args and args.now_seconds or now()
  local generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now_seconds)
  local instance = M.read_env("FKST_GITHUB_BOT_LOGIN") or "unknown"
  local graph = args and args.graph or nil
  local graph_status = args and args.graph_status or nil
  local codex_status = args and args.codex_status or nil

  local lines = {
    "# " .. dashboard_title,
    "",
    "Live read-only dashboard generated from trusted fkst-dev markers. Chinese: &#27492;&#30475;&#26495;&#21482;&#26159;&#21487;&#20449; marker &#30340;&#21482;&#35835;&#27966;&#29983;&#35270;&#22270;&#65292;&#19981;&#26159;&#20107;&#23454;&#28304;&#12290;",
    "",
  }
  render_topology(lines, graph_status)
  render_live_overlay(lines, list, now_seconds, graph)
  render_now_working(lines, codex_status, now_seconds)
  render_census(lines, list, counts, codex_status, now_seconds)

  table.insert(lines, "")
  table.insert(lines, "## Board by state")
  table.insert(lines, "Total: " .. tostring(#list))
  for _, state in ipairs(M._state_order) do
    table.insert(lines, "- " .. tostring(state) .. ": " .. tostring(counts[state] or 0))
  end
  if counts.unmanaged ~= nil then
    table.insert(lines, "- unmanaged: " .. tostring(counts.unmanaged))
  end

  table.insert(lines, "")
  table.insert(lines, "## Stall suspects")
  if #stalls == 0 then
    table.insert(lines, "- None")
  else
    local shown = 0
    for _, stall in ipairs(stalls) do
      if shown >= max_dashboard_section_items then
        table.insert(lines, "- ... " .. tostring(#stalls - shown) .. " more")
        break
      end
      table.insert(lines, entity_line(stall.entity, now_seconds)
        .. " (threshold " .. tostring(stall.threshold_minutes) .. "m)")
      shown = shown + 1
    end
  end

  render_footer(lines, instance, generated_at, codex_status)

  local stable = table.concat(lines, "\n")
  local hash = M._decimal_checksum(stable:gsub("%- generated%-at: [^\n]+", "- generated-at: <generated>"))
  local marker = M.dashboard_marker(hash, generated_at)
  local body = stable .. "\n\n" .. marker .. "\n"
  if #body > max_dashboard_body_len then
    local marker_suffix = "\n\n" .. marker .. "\n"
    body = M.truncate_utf8(body, max_dashboard_body_len - #marker_suffix) .. marker_suffix
  end
  return {
    body = body,
    hash = hash,
    version = generated_at,
    generated_at = generated_at,
  }
end
end

return S
