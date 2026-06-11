local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_observe_tick" },
  produces = { "github-proxy.github_entity_changed" },
  fanout = { "devloop_observe_tick" },
  stall_window = "2m",
}

local function run_cmd(cmd, timeout, context)
  local result = core.gh_exec({ cmd = cmd, timeout = timeout or 30 })
  if result.exit_code ~= 0 then
    error("github-devloop: " .. tostring(context) .. " failed: " .. tostring(result.stderr))
  end
  return result
end

local function read_repo()
  local repo = core.read_env("FKST_GITHUB_REPO")
  if repo == nil or core.safe_repo(repo) ~= tostring(repo) then
    return nil
  end
  return repo
end

local function sorted_numbers(items)
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

local function issue_source_ref(repo, issue_number)
  return core.issue_source_ref(repo, issue_number)
end

local function pr_source_ref(repo, pr_number)
  return core.pr_source_ref(repo, pr_number)
end

local function observe_issue_payload(repo, issue_number, issue)
  local updated_at = issue.updated_at or issue.updatedAt or ""
  return {
    schema = "github-proxy.v1",
    type = "issue",
    repo = repo,
    number = tonumber(issue_number),
    title = tostring(issue.title or ""),
    updated_at = tostring(updated_at),
    dedup_key = tostring(repo) .. "#issue#" .. tostring(issue_number) .. "@" .. tostring(updated_at),
    source_ref = issue_source_ref(repo, issue_number),
  }
end

local function observe_pr_payload(repo, pr_number, pr)
  local updated_at = pr.updated_at or pr.updatedAt or pr.head_sha or ""
  return {
    schema = "github-proxy.v1",
    type = "pr",
    repo = repo,
    number = tonumber(pr_number),
    updated_at = tostring(updated_at),
    dedup_key = tostring(repo) .. "#pr#" .. tostring(pr_number) .. "@" .. tostring(updated_at),
    source_ref = pr_source_ref(repo, pr_number),
  }
end

local function intake_class_from_issue_comments(comments, repo, issue_number)
  local proposal_id = core.proposal_id(repo, issue_number)
  local fact = core.intake_decision_fact(comments, proposal_id)
  if fact ~= nil and fact.decision == "enable" then
    return fact.class
  end
  return "standard"
end

local function collect_issue_entities(repo, issue_numbers, entities)
  for _, issue_number in ipairs(issue_numbers or {}) do
    local view = run_cmd(core.gh_issue_view_observe_cmd(repo, issue_number), 30, "gh observe-scan issue view")
    local issue = core.parse_issue_view_observe(view.stdout)
    if tostring(issue.state or ""):upper() == "OPEN" then
      table.insert(entities, {
        kind = "issue",
        number = tonumber(issue_number),
        class = intake_class_from_issue_comments(issue.comments, repo, issue_number),
        fifo = tostring(issue.updated_at or "") .. "/issue/" .. tostring(issue_number),
        proposal_id = core.proposal_id(repo, issue_number),
        payload = observe_issue_payload(repo, issue_number, issue),
      })
    end
  end
end

local function collect_pr_entities(repo, pr_numbers, entities)
  for _, pr_number in ipairs(pr_numbers or {}) do
    local view = run_cmd(core.gh_pr_view_observe_cmd(repo, pr_number), 30, "gh observe-scan PR view")
    local pr = core.parse_pr_view_origin(view.stdout)
    local origin = core.pr_origin_fact(pr.comments) or core.pr_native_origin(repo, pr_number, pr)
    local class = "standard"
    if origin.issue_number ~= nil then
      local issue_view = run_cmd(core.gh_issue_view_result_cmd(repo, origin.issue_number), 30, "gh observe-scan origin issue view")
      local issue = core.parse_issue_view_result(issue_view.stdout)
      class = intake_class_from_issue_comments(issue.comments, repo, origin.issue_number)
    end
    if tostring(pr.state or ""):upper() == "OPEN" then
      table.insert(entities, {
        kind = "pr",
        number = tonumber(pr_number),
        class = class,
        fifo = tostring(pr.updated_at or "") .. "/pr/" .. tostring(pr_number),
        proposal_id = origin.proposal_id,
        payload = observe_pr_payload(repo, pr_number, pr),
      })
    end
  end
end

function pipeline(event)
  core.log_entry("observe_scan", event, "github-devloop/observe", "tick")
  core.assert_trusted_bot_configured()

  local repo = read_repo()
  if repo == nil then
    core.log_cas_decision("observe_scan", "github-devloop/observe", { state = nil, version = nil }, "tick", "entity", "skip-invalid-repo", "FKST_GITHUB_REPO is missing or invalid")
    return
  end

  local issue_candidates = {}
  local labels = { core._enabled_label }
  for _, state in ipairs(core._state_order) do
    table.insert(labels, core.state_label(state))
  end
  for _, label in ipairs(labels) do
    local list = run_cmd(core.gh_issue_list_observe_cmd(repo, label), 60, "gh observe-scan issue list")
    for _, issue in ipairs(core.parse_issue_list_observe(list.stdout)) do
      table.insert(issue_candidates, issue)
    end
  end

  local pr_list = run_cmd(core.gh_pr_list_observe_cmd(repo), 60, "gh observe-scan PR list")
  local entities = {}
  collect_issue_entities(repo, sorted_numbers(issue_candidates), entities)
  collect_pr_entities(repo, sorted_numbers(core.parse_pr_list_observe(pr_list.stdout)), entities)

  core.sort_by_intake_class(entities, function(item)
    return item.class
  end, function(item)
    return item.fifo
  end)

  for _, entity in ipairs(entities) do
    core.log_apply("observe_scan", entity.proposal_id, nil, nil, { add = {}, remove = {} }, {
      "github-proxy.github_entity_changed",
    })
    core.log_raise("observe_scan", entity.proposal_id, "github-proxy.github_entity_changed", entity.payload)
  end
end

return M
