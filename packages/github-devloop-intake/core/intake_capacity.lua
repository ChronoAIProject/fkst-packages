local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local claims = require("devloop.claims")
local commands = require("devloop.commands")
local config = require("devloop.config")
local contract_error_facts = require("contract.error_facts")
local devloop_logging = require("devloop.logging")
local forge_validators = require("devloop.forge_validators")
local marker_facts = require("devloop.markers.facts")
local parsers_issue = require("devloop.parsers.issue")
local devloop_state = require("devloop.state")
local premise_correction = require("devloop.premise_correction")

local C = {}

local schema = "github-devloop-intake.capacity-grant.v1"

local function grant_ref(repo, owner)
  local repo_key = contract_error_facts.stable_hash(tostring(repo or ""))
  local ref = "refs/fkst/github-devloop-intake/capacity/"
    .. repo_key .. "/" .. tostring(owner or "")
  if not forge_validators.is_git_ref_safe(ref) then
    error("github-devloop-intake: capacity-grant-ref-invalid: capacity grant ref is invalid")
  end
  return ref
end

local function json_string(value)
  return '"' .. tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\r", "\\r")
    :gsub("\n", "\\n")
    .. '"'
end

local function encode_grant(record)
  local holders = {}
  for _, holder in ipairs(record.holders or {}) do
    table.insert(holders, tostring(tonumber(holder)))
  end
  return "{"
    .. '"schema":' .. json_string(schema)
    .. ',"repo":' .. json_string(record.repo)
    .. ',"owner":' .. json_string(record.owner)
    .. ',"capacity":' .. tostring(tonumber(record.capacity))
    .. ',"holders":[' .. table.concat(holders, ",") .. "]"
    .. "}"
end

local function normalize_grant(record, repo, owner, sha)
  if type(record) ~= "table"
    or record.schema ~= schema
    or record.repo ~= repo
    or record.owner ~= owner then
    error("github-devloop-intake: capacity-grant-invalid: capacity grant identity is invalid")
  end
  local capacity = tonumber(record.capacity)
  if capacity == nil or capacity ~= math.floor(capacity) or capacity < 1 or capacity > 100 then
    error("github-devloop-intake: capacity-grant-invalid: capacity grant limit is invalid")
  end
  if type(record.holders) ~= "table" or #record.holders > capacity then
    error("github-devloop-intake: capacity-grant-invalid: capacity grant holders are invalid")
  end
  local holders = {}
  local seen = {}
  for _, holder in ipairs(record.holders) do
    local number = tonumber(holder)
    if number == nil
      or number ~= math.floor(number)
      or number < 1
      or number > 2147483647
      or seen[number] then
      error("github-devloop-intake: capacity-grant-invalid: capacity grant holder is invalid")
    end
    seen[number] = true
    table.insert(holders, number)
  end
  return {
    schema = schema,
    repo = repo,
    owner = owner,
    capacity = capacity,
    holders = holders,
    sha = sha,
  }
end

local function commit_message(stdout)
  local text = tostring(stdout or ""):gsub("\r\n", "\n")
  local boundary = text:find("\n\n", 1, true)
  if boundary == nil then
    return nil
  end
  return text:sub(boundary + 2):gsub("%s+$", "")
end

local function result_required(result, error_class, operation)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("github-devloop-intake: capacity-adapter-operation-failed: error_class=" .. error_class
      .. " operation=" .. operation .. " failed: "
      .. tostring(result and result.stderr or "missing result"))
  end
  return result
end

local function copy_array(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    table.insert(result, tonumber(value))
  end
  return result
end

local function contains(values, expected)
  for _, value in ipairs(values or {}) do
    if tonumber(value) == tonumber(expected) then
      return true
    end
  end
  return false
end

local function issue_occupies_capacity(repo, current)
  if type(current) ~= "table" or tostring(current.state or ""):upper() ~= "OPEN" then
    return false
  end
  local issue_number = tonumber(current.number)
  if issue_number == nil then
    return false
  end
  local proposal_id = base_ids.proposal_id(repo, issue_number)
  local decision = marker_facts.intake_decision_fact(current.comments, proposal_id)
  local pending_correction = premise_correction.matching_correction_fact(current.comments, decision)
  local has_active_state = not marker_facts.has_state_marker(current.comments, proposal_id)
    or devloop_state.has_active_issue_state(current.labels, current.comments, proposal_id)
  return (decision == nil or decision.decision == "enable" or pending_correction ~= nil)
    and has_active_state
    and not devloop_state.current_issue_observation_is_terminal(current.comments, proposal_id)
end

local function grant_matches(grant, repo, owner, max_inflight, holders)
  if type(grant) ~= "table"
    or grant.schema ~= schema
    or grant.repo ~= repo
    or grant.owner ~= owner
    or tonumber(grant.capacity) ~= tonumber(max_inflight)
    or #(grant.holders or {}) ~= #holders then
    return false
  end
  for index, holder in ipairs(holders) do
    if tonumber(grant.holders[index]) ~= tonumber(holder) then
      return false
    end
  end
  return true
end

local function build_snapshot(ports, repo, owner, grant, candidate_number, candidate_current)
  local snapshot = {}
  local numbers = {}
  local function include(number)
    local selected = tonumber(number)
    if selected ~= nil then
      numbers[selected] = true
    end
  end

  for _, number in ipairs(ports.list_open_claim_numbers(repo, owner) or {}) do
    include(number)
  end
  for _, number in ipairs(grant and grant.holders or {}) do
    include(number)
  end
  include(candidate_number)

  for number in pairs(numbers) do
    if tonumber(candidate_number) == number and type(candidate_current) == "table" then
      snapshot[number] = candidate_current
    else
      snapshot[number] = ports.read_issue(repo, number)
    end
    if type(snapshot[number]) ~= "table" then
      error("github-devloop-intake: capacity-issue-read-missing: capacity issue read returned no issue")
    end
    snapshot[number].number = number
  end
  return snapshot
end

local function desired_allocation(repo, owner, max_inflight, grant, snapshot, candidate_number)
  local holders = {}
  local selected = {}

  for _, number in ipairs(grant and grant.holders or {}) do
    local normalized = tonumber(number)
    local current = normalized and snapshot[normalized] or nil
    local ownership = current and claims.issue_claim_state(current.assignees, owner, current.labels) or "other"
    if #holders < max_inflight
      and current ~= nil
      and ownership ~= "other"
      and issue_occupies_capacity(repo, current)
      and not selected[normalized] then
      table.insert(holders, normalized)
      selected[normalized] = true
    end
  end

  local candidates = {}
  for number, current in pairs(snapshot) do
    local ownership = claims.issue_claim_state(current.assignees, owner, current.labels)
    local is_current_candidate = tonumber(candidate_number) == number
    if not selected[number]
      and issue_occupies_capacity(repo, current)
      and (ownership == "self" or (is_current_candidate and ownership == "unassigned")) then
      table.insert(candidates, {
        number = number,
      })
    end
  end
  table.sort(candidates, function(left, right) return left.number < right.number end)
  for _, candidate in ipairs(candidates) do
    if #holders >= max_inflight then
      break
    end
    table.insert(holders, candidate.number)
    selected[candidate.number] = true
  end
  return holders
end

local function converge_claims(ports, repo, owner, holders, snapshot)
  local releases = {}
  for number, current in pairs(snapshot) do
    if not contains(holders, number)
      and claims.issue_claim_state(current.assignees, owner, current.labels) == "self" then
      table.insert(releases, {
        number = number,
        active = issue_occupies_capacity(repo, current),
      })
    end
  end
  table.sort(releases, function(left, right)
    if left.active ~= right.active then
      return left.active
    end
    return left.number < right.number
  end)
  for _, release in ipairs(releases) do
    ports.release_claim_if_self(
      repo,
      release.number,
      owner,
      release.active and "excess-active-intake-claim" or "inactive-intake-claim"
    )
  end
end

local function validate_ports(ports)
  for _, name in ipairs({
    "max_inflight",
    "write_enabled",
    "owner",
    "assert_owner_binding",
    "list_open_claim_numbers",
    "read_issue",
    "read_grant",
    "compare_and_swap_grant",
    "release_claim_if_self",
  }) do
    if type(ports and ports[name]) ~= "function" then
      error("github-devloop-intake: capacity-port-missing: capacity port missing " .. name)
    end
  end
end

function C.new(ports)
  validate_ports(ports)

  local function decide(repo, candidate_number, candidate_current, proposal_id)
    local max_inflight = ports.max_inflight()
    if max_inflight == nil or not ports.write_enabled() then
      return true, max_inflight == nil and "wip-cap-disabled" or "wip-cap-dry-run"
    end
    local owner = ports.owner()
    ports.assert_owner_binding(repo)
    local grant = ports.read_grant(repo, owner)
    local snapshot = build_snapshot(ports, repo, owner, grant, candidate_number, candidate_current)
    local holders = desired_allocation(
      repo,
      owner,
      max_inflight,
      grant,
      snapshot,
      candidate_number
    )

    if not grant_matches(grant, repo, owner, max_inflight, holders) then
      local record = {
        schema = schema,
        repo = repo,
        owner = owner,
        capacity = max_inflight,
        holders = copy_array(holders),
      }
      local expected_sha = grant and grant.sha or nil
      local updated, _, push_error = ports.compare_and_swap_grant(repo, owner, expected_sha, record)
      if updated then
        grant = record
      else
        grant = ports.read_grant(repo, owner)
        local latest_sha = grant and grant.sha or nil
        if latest_sha == expected_sha then
          error("github-devloop-intake: capacity-grant-push-failed: capacity grant push failed without a new remote generation: "
            .. tostring(push_error or "unknown push failure"))
        end
        if type(grant) ~= "table" then
          error("github-devloop-intake: capacity-cas-lost: capacity grant disappeared after CAS contention")
        end
        holders = copy_array(grant.holders)
      end
    else
      holders = copy_array(grant.holders)
    end

    converge_claims(ports, repo, owner, holders, snapshot)
    if candidate_number == nil then
      return true, "wip-cap-reconciled"
    end
    local holder_granted = contains(holders, candidate_number)
    if holder_granted then
      if type(ports.log_decision) == "function" then
        ports.log_decision(proposal_id, grant, "granted", "remote capacity grant contains candidate")
      end
      return true, "wip-cap-granted"
    end
    if type(ports.log_decision) == "function" then
      ports.log_decision(proposal_id, grant, "held", "remote capacity grant is full")
    end
    return false, "wip-cap-reached"
  end

  local function relinquish(repo, issue_number, proposal_id)
    local max_inflight = ports.max_inflight()
    if max_inflight == nil or not ports.write_enabled() then
      return true
    end
    local owner = ports.owner()
    local grant = ports.read_grant(repo, owner)
    if grant == nil or not contains(grant.holders, issue_number) then
      return true
    end
    local holders = {}
    for _, holder in ipairs(grant.holders or {}) do
      if tonumber(holder) ~= tonumber(issue_number) then
        table.insert(holders, tonumber(holder))
      end
    end
    local record = {
      schema = schema,
      repo = repo,
      owner = owner,
      capacity = max_inflight,
      holders = holders,
    }
    local updated, _, push_error = ports.compare_and_swap_grant(repo, owner, grant.sha, record)
    if not updated then
      local latest = ports.read_grant(repo, owner)
      if latest ~= nil and latest.sha == grant.sha then
        error("github-devloop-intake: capacity-grant-push-failed: capacity grant relinquish failed without a new remote generation: "
          .. tostring(push_error or "unknown push failure"))
      end
      if latest ~= nil and contains(latest.holders, issue_number) then
        return false
      end
    end
    if type(ports.log_decision) == "function" then
      ports.log_decision(proposal_id, record, "relinquished", "claim acquisition did not complete")
    end
    return true
  end

  return {
    authorize = function(repo, issue_number, current, proposal_id)
      return decide(repo, tonumber(issue_number), current, proposal_id)
    end,
    reconcile = function(repo, proposal_id)
      return decide(repo, nil, nil, proposal_id)
    end,
    relinquish = relinquish,
  }
end

local function production_read_grant(adapter, repo, owner)
  local ref = grant_ref(repo, owner)
  local listed = result_required(
    adapter.commands.git_ls_remote_ref("origin", ref, 30),
    "capacity-grant-list-failed",
    "capacity grant ls-remote"
  )
  local sha, listed_ref = tostring(listed.stdout or ""):match("^(%x+)%s+([^%s]+)")
  if sha == nil then
    return nil
  end
  if listed_ref ~= ref or not forge_validators.is_git_sha(sha) then
    error("github-devloop-intake: capacity-grant-ref-invalid: capacity grant ls-remote returned an invalid ref")
  end
  result_required(adapter.commands.git_fetch_ref("origin", ref, 30), "capacity-grant-fetch-failed", "capacity grant fetch")
  local commit = result_required(adapter.commands.git_cat_file_pretty(sha, 30), "capacity-grant-read-failed", "capacity grant read")
  local message = commit_message(commit.stdout)
  local ok, decoded = pcall(adapter.json.decode, message or "")
  if not ok then
    error("github-devloop-intake: capacity-grant-decode-failed: capacity grant commit message is not valid JSON")
  end
  return normalize_grant(decoded, repo, owner, sha)
end

local function production_compare_and_swap(adapter, repo, owner, expected_sha, record)
  local normalized = normalize_grant(record, repo, owner, nil)
  local body = encode_grant(normalized)
  local tree = result_required(
    adapter.commands.git_rev_parse_ref_tree("HEAD", 30),
    "capacity-grant-tree-failed",
    "capacity grant tree read"
  )
  local tree_sha = tostring(tree.stdout or ""):match("(%x+)")
  if not forge_validators.is_git_sha(tree_sha) then
    error("github-devloop-intake: capacity-grant-tree-invalid: capacity grant tree SHA is invalid")
  end
  local identity = contract_error_facts.stable_hash(body .. "|" .. tostring(expected_sha or "new"))
  local message_file = "/tmp/fkst-github-devloop-intake-capacity-" .. identity .. ".json"
  adapter.file.write(message_file, body .. "\n")
  local commit = result_required(
    adapter.commands.git_commit_tree(tree_sha, expected_sha, message_file, 30),
    "capacity-grant-commit-failed",
    "capacity grant commit"
  )
  local commit_sha = tostring(commit.stdout or ""):match("(%x+)")
  if not forge_validators.is_git_sha(commit_sha) then
    error("github-devloop-intake: capacity-grant-commit-invalid: capacity grant commit SHA is invalid")
  end
  local pushed = adapter.commands.git_push_ref_update(
    "origin",
    commit_sha,
    grant_ref(repo, owner),
    expected_sha or false,
    60
  )
  if type(pushed) ~= "table" or pushed.exit_code ~= 0 then
    return false, nil, tostring(pushed and pushed.stderr or "missing push result")
  end
  return true, commit_sha, nil
end

function C.production_adapter(deps)
  local selected = deps or {}
  local adapter = {
    commands = selected.commands or commands,
    file = selected.file or file,
    json = selected.json or json,
  }
  return {
    read_grant = function(repo, owner)
      return production_read_grant(adapter, repo, owner)
    end,
    compare_and_swap_grant = function(repo, owner, expected_sha, record)
      return production_compare_and_swap(adapter, repo, owner, expected_sha, record)
    end,
  }
end

function C.production(_M)
  local grant_adapter = C.production_adapter()
  return C.new({
    max_inflight = config.max_inflight,
    write_enabled = function()
      return config.write_mode() == "real"
    end,
    owner = claims.claim_owner,
    assert_owner_binding = function(repo)
      if claims.claim_mode_active() == "label" then
        claims.assert_current_claim_label_binding(repo)
      end
    end,
    list_open_claim_numbers = function(repo, owner)
      local listed = result_required(
        commands.gh_issue_list_observe(repo, nil, nil, false, 30),
        "capacity-claim-list-failed",
        "capacity claim list"
      )
      local numbers = {}
      for _, current in ipairs(parsers_issue.parse_issue_list_intake(nil, listed.stdout)) do
        if claims.issue_claim_state(current.assignees, owner, current.labels) == "self" then
          table.insert(numbers, current.number)
        end
      end
      table.sort(numbers)
      return numbers
    end,
    read_issue = function(repo, issue_number)
      local viewed = result_required(
        commands.gh_issue_view_intake_judge(repo, issue_number, 30),
        "capacity-issue-view-failed",
        "capacity issue view"
      )
      local current = parsers_issue.parse_issue_view_intake_judge(nil, viewed.stdout)
      current.number = tonumber(issue_number)
      return current
    end,
    read_grant = function(repo, owner)
      return grant_adapter.read_grant(repo, owner)
    end,
    compare_and_swap_grant = function(repo, owner, expected_sha, record)
      return grant_adapter.compare_and_swap_grant(repo, owner, expected_sha, record)
    end,
    release_claim_if_self = function(repo, issue_number, _owner, reason)
      return claims.release_issue_claim_if_self(
        nil,
        "admission",
        repo,
        issue_number,
        base_ids.proposal_id(repo, issue_number),
        reason
      )
    end,
    log_decision = function(proposal_id, grant, outcome, reason)
      devloop_logging.log_cas_decision(
        "admission",
        proposal_id or "unknown",
        { state = "capacity-grant", version = grant and grant.sha or nil },
        "capacity-grant",
        "capacity-grant",
        outcome,
        reason
      )
    end,
  })
end

C.schema = schema
C.issue_occupies_capacity = issue_occupies_capacity
C.grant_ref = grant_ref

return C
