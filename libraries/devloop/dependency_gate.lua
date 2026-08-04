local base_ids = require("devloop.base_ids")
local config = require("devloop.config")
local devloop_commands = require("devloop.commands")
local devloop_state = require("devloop.state")
local entity = require("devloop.entity")
local forge_validators = require("devloop.forge_validators")
local github_factory = require("devloop.github_factory")
local marker_facts = require("devloop.markers.facts")
local parsers_issue = require("devloop.parsers.issue")
local parsers_misc = require("devloop.parsers.misc")
local parsers_pr = require("devloop.parsers.pr")
local strings = require("contract.strings")

local M = {}

local max_dependency_depth = 32

M.github_graphql_queries = {
  dependency_blocked_by = '{repository(owner:"{{owner}}",name:"{{name}}"){issue(number:{{issue_number}}){number state stateReason repository{nameWithOwner} duplicateOf{number state stateReason repository{nameWithOwner}} blockedBy(first:50){totalCount pageInfo{hasNextPage} nodes{number state stateReason repository{nameWithOwner} duplicateOf{number state stateReason repository{nameWithOwner}}}}}}}',
}

local function github_result(fn)
  local ok, result_or_error = pcall(fn)
  if ok then
    return result_or_error
  end
  if type(result_or_error) == "table" and result_or_error.result ~= nil then
    return result_or_error.result
  end
  error(result_or_error)
end

function M.render_github_graphql_query(name, fields)
  local template = M.github_graphql_queries[name]
  if template == nil then
    error("github-devloop: graphql-template-unknown-query: " .. tostring(name))
  end
  return tostring(template):gsub("{{([%w_]+)}}", function(field_name)
    local value = fields and fields[field_name]
    if value == nil then
      error("github-devloop: graphql-template-missing-field: " .. tostring(field_name))
    end
    return tostring(value)
  end)
end

function M.github_graphql(name, fields, timeout, exec)
  local query = M.render_github_graphql_query(name, fields)
  local run = exec or exec_argv
  if type(run) ~= "function" then
    error("github-devloop: adapter-unavailable: GitHub GraphQL adapter requires exec_argv")
  end
  return github_result(function()
    return github_factory.new(run, exec_sync).graphql(query, nil, timeout or 30)
  end)
end

local function split_repo(repo)
  local owner, name = tostring(repo or ""):match("^([^/]+)/([^/]+)$")
  if owner == nil or owner == "" or name == nil or name == "" then
    return nil, nil
  end
  return owner, name
end

local dependency_gate_kinds = {
  satisfied = true,
  waiting = true,
  unavailable = true,
  verified_cannot_proceed = true,
}

local function verified_cannot_proceed_proof_is_valid(reason, proof, target_repo, target_issue_number)
  if type(proof) ~= "table"
    or split_repo(proof.target_repo) == nil
    or not forge_validators.is_positive_pr_number(proof.target_issue_number) then
    return false
  end
  if target_repo ~= nil and tostring(proof.target_repo) ~= tostring(target_repo) then
    return false
  end
  if target_issue_number ~= nil and tonumber(proof.target_issue_number) ~= tonumber(target_issue_number) then
    return false
  end
  if proof.kind == "dependency-cycle" then
    return reason == "dependency-cycle"
      and split_repo(proof.repo) ~= nil
      and forge_validators.is_positive_pr_number(proof.issue_number)
  end
  if proof.kind == "cross-repo-blocker" then
    return reason == "cross-repo-blocker"
      and split_repo(proof.repo) ~= nil
      and forge_validators.is_positive_pr_number(proof.issue_number)
      and split_repo(proof.blocker_repo) ~= nil
      and tostring(proof.blocker_repo) ~= tostring(proof.repo)
      and forge_validators.is_positive_pr_number(proof.blocker_number)
  end
  return false
end

local function gate(kind, reason, unmet, proof)
  if dependency_gate_kinds[kind] ~= true then
    error("github-devloop: invalid-dependency-proof-status: unknown dependency gate kind")
  end
  if type(reason) ~= "string" or reason == "" or type(unmet) ~= "table" then
    error("github-devloop: invalid-dependency-proof-status: incomplete dependency gate result")
  end
  if kind == "verified_cannot_proceed" and not verified_cannot_proceed_proof_is_valid(reason, proof) then
    error("github-devloop: invalid-dependency-proof-status: terminal dependency proof is invalid")
  end
  if kind ~= "verified_cannot_proceed" and proof ~= nil then
    error("github-devloop: invalid-dependency-proof-status: non-terminal dependency result carries proof")
  end
  local result = {
    kind = kind,
    unmet = unmet,
    reason = reason,
  }
  if kind == "waiting" then
    result.hold_kind = "waiting"
  elseif kind == "unavailable" then
    result.hold_kind = "unresolvable"
  elseif kind == "verified_cannot_proceed" then
    result.hold_kind = proof.kind == "dependency-cycle" and "cycle" or "unresolvable"
    result.proof = proof
  end
  return result
end

local function dependency_gate_is_satisfied(result)
  return type(result) == "table" and result.kind == "satisfied"
end

local function dependency_gate_is_verified_cannot_proceed(result, target_repo, target_issue_number)
  if type(result) ~= "table" or result.kind ~= "verified_cannot_proceed" or type(result.proof) ~= "table" then
    return false
  end
  return split_repo(target_repo) ~= nil
    and forge_validators.is_positive_pr_number(target_issue_number)
    and verified_cannot_proceed_proof_is_valid(result.reason, result.proof, target_repo, target_issue_number)
end

local function add_gate_note(notes, note)
  if type(notes) == "table" and type(note) == "table" then
    table.insert(notes, note)
  end
end

local function add_unmet(unmet, seen, number)
  if not forge_validators.is_positive_pr_number(number) then
    return
  end
  local value = tonumber(number)
  if seen[value] then
    return
  end
  seen[value] = true
  table.insert(unmet, value)
end

local function marker_attr(marker, name)
  return tostring(marker or ""):match(name .. '="([^"]*)"')
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

local function parse_dependency_issue(node, include_duplicate)
  if type(node) ~= "table" or not forge_validators.is_positive_pr_number(node.number) then
    return nil
  end
  local issue_repo = node.repository and node.repository.nameWithOwner
  if type(issue_repo) ~= "string" or issue_repo == "" then
    return nil
  end
  local issue = {
    number = tonumber(node.number),
    state = tostring(node.state or ""),
    state_reason = tostring(node.stateReason or node.state_reason or ""),
    repo = issue_repo,
    duplicate_projection_complete = include_duplicate == true,
  }
  local duplicate_of = node.duplicateOf or node.duplicate_of
  if include_duplicate and type(duplicate_of) == "table" then
    issue.duplicate_of = parse_dependency_issue(duplicate_of, false)
    if issue.duplicate_of == nil then
      return nil
    end
  elseif include_duplicate and duplicate_of ~= nil and type(duplicate_of) ~= "userdata" then
    return nil
  end
  return issue
end

local function parse_blocked_by(stdout)
  local ok, decoded = pcall(json.decode, stdout or "")
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local issue = decoded.data
    and decoded.data.repository
    and decoded.data.repository.issue
  if issue == nil then
    return nil, nil, nil, "missing-issue"
  end
  if type(issue) ~= "table" then
    return nil
  end
  local blocked_by = issue.blockedBy
  local nodes = blocked_by and blocked_by.nodes
  if type(nodes) ~= "table" then
    return nil
  end

  local blockers = {}
  for _, node in ipairs(nodes) do
    local blocker = parse_dependency_issue(node, true)
    if blocker == nil then
      return nil
    end
    table.insert(blockers, blocker)
  end

  local issue_projection = nil
  if issue.number ~= nil then
    issue_projection = parse_dependency_issue(issue, true)
    if issue_projection == nil then
      return nil
    end
  end

  local total = blocked_by.totalCount
  local page = blocked_by.pageInfo
  local truncated = (type(total) == "number" and total > #blockers)
    or (type(page) == "table" and page.hasNextPage == true)
  return blockers, truncated, issue_projection, nil
end

local function normalized_state_reason(value)
  local text = tostring(value or ""):lower():gsub("_", "-")
  return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function managed_sibling_repo(current_repo, blocker_repo, managed_repos)
  local current_owner = split_repo(current_repo)
  local blocker_owner = split_repo(blocker_repo)
  if current_owner == nil or blocker_owner == nil or current_owner ~= blocker_owner then
    return false
  end
  return type(managed_repos) == "table" and managed_repos[tostring(blocker_repo)] == true
end

function M.new(core)
  if type(core) ~= "table" then
    error("github-devloop: dependency gate requires a core table")
  end

  local function gh_blocked_by(repo, issue_number, timeout, exec)
    local owner, name = split_repo(repo)
    if owner == nil or not forge_validators.is_positive_pr_number(issue_number) then
      error("github-devloop: invalid-dependency-target: invalid dependency query target")
    end
    local graphql = type(core.github_graphql) == "function" and core.github_graphql or M.github_graphql
    return graphql("dependency_blocked_by", {
      owner = owner,
      name = name,
      issue_number = tostring(math.floor(tonumber(issue_number))),
    }, timeout, exec)
  end

  local function fetch_blocked_by(repo, issue_number)
    local read_blocked_by = type(core.gh_blocked_by) == "function" and core.gh_blocked_by or gh_blocked_by
    local result = read_blocked_by(repo, issue_number, 30)
    if type(result) ~= "table" or result.exit_code ~= 0 then
      return nil, "gh-failed"
    end
    local blockers, truncated, issue, parse_reason = parse_blocked_by(result.stdout)
    if blockers == nil then
      return nil, parse_reason or "malformed-json"
    end
    if truncated then
      return nil, "blockedby-truncated"
    end
    return blockers, nil, issue
  end

  local function merged_blocker_cache_key(repo, blocker_number)
    if not base_ids.issue_ref_round_trips(repo, blocker_number) then
      error("github-devloop: invalid-cache-key: invalid merged blocker cache key target")
    end
    local key = "github-devloop/dependency/merged/"
      .. base_ids.safe_repo(repo)
      .. "/issue/"
      .. base_ids.safe_issue(blocker_number)
    if not strings.is_path_safe_key(key, core._max_key_len) then
      error("github-devloop: invalid-cache-key: invalid merged blocker cache key")
    end
    return key
  end

  local function cached_blocker_merged(repo, blocker_number)
    return cache_get(merged_blocker_cache_key(repo, blocker_number)) == "1"
  end

  local function cache_blocker_merged(repo, blocker_number)
    cache_set(merged_blocker_cache_key(repo, blocker_number), "1")
  end

  local function dependency_waiver_fact(comments, proposal_id, version, blocker_number)
    if type(comments) ~= "table" then
      return nil
    end
    local marker_pattern = "<!%-%- fkst:github%-devloop:dependency%-waiver:v1.-%-%->"
    for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
      for found in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
        if marker_attr(found, "proposal") == tostring(proposal_id)
          and marker_attr(found, "version") == tostring(version)
          and tonumber(marker_attr(found, "blocker") or "") == tonumber(blocker_number) then
          return {
            proposal_id = tostring(proposal_id),
            version = tostring(version),
            blocker_number = tonumber(blocker_number),
            reason = decode_dependency_attr(marker_attr(found, "reason")) or "dependency-waiver",
            comment_created_at = parsers_misc._comment_created_at(comment),
          }
        end
      end
    end
    return nil
  end

  local function has_dependency_waiver(context, blocker_number)
    if type(context) ~= "table" then
      return false
    end
    return dependency_waiver_fact(
      context.comments,
      context.proposal_id,
      context.version,
      blocker_number
    ) ~= nil
  end

  local function delegated_blocker_merged(repo, blocker_number, blocker_proposal_id, current, state)
    if type(state) ~= "table" or state.version == nil then
      return false, nil
    end
    if not devloop_state.reached(current and current.comments, blocker_proposal_id, "awaiting-pr", {
      lineage_base = state.version,
    }) then
      return false, nil
    end
    local delegation = marker_facts.pr_delegation_fact(current.comments, blocker_proposal_id, state.version)
    if delegation == nil then
      return false, nil
    end
    local pr_repo, pr_number = entity.parse_pr_proposal_id(delegation.pr_proposal_id or delegation.pr_proposal)
    if tostring(pr_repo or "") ~= tostring(repo)
      or tostring(pr_number or "") ~= tostring(delegation.pr_number or "") then
      return nil, "pr-delegation-mismatch"
    end

    local pr_result = devloop_commands.gh_pr_view_observe(repo, delegation.pr_number, 30)
    if type(pr_result) ~= "table" or pr_result.exit_code ~= 0 then
      return nil, "gh-pr-failed"
    end
    local pr_ok, pr_current = pcall(function()
      return parsers_pr.parse_pr_view_origin(pr_result.stdout)
    end)
    if not pr_ok or type(pr_current) ~= "table" then
      return nil, "malformed-pr-json"
    end
    local origin = marker_facts.pr_origin_fact(pr_current.comments)
    if origin == nil
      or tostring(origin.proposal_id or "") ~= blocker_proposal_id
      or tostring(origin.repo or "") ~= tostring(repo)
      or tostring(origin.issue_number or "") ~= tostring(blocker_number)
      or tostring(origin.impl_version or "") ~= tostring(delegation.version or "") then
      return nil, "pr-origin-mismatch"
    end
    if not devloop_state.reached(pr_current.comments, blocker_proposal_id, "merged", {
      lineage_base = delegation.version,
    }) then
      return false, nil
    end
    local merged = marker_facts.merged_fact(
      pr_current.comments,
      blocker_proposal_id,
      delegation.pr_number,
      delegation.version
    )
    return merged ~= nil, nil
  end

  local function blocker_merged(repo, blocker_number)
    local blocker_proposal_id = base_ids.proposal_id(repo, blocker_number)
    local result = devloop_commands.gh_issue_view_observe(repo, blocker_number, 30)
    if type(result) ~= "table" or result.exit_code ~= 0 then
      return nil, "gh-failed"
    end
    local ok, current = pcall(function()
      return parsers_issue.parse_issue_view_observe(core, result.stdout)
    end)
    if not ok or type(current) ~= "table" then
      return nil, "malformed-json"
    end
    if devloop_state.reached(current.comments, blocker_proposal_id, "merged") then
      return true, nil
    end

    local link = marker_facts.pr_link_fact(current.comments, blocker_proposal_id)
    if link == nil then
      local delegation = marker_facts.pr_delegation_fact(current.comments, blocker_proposal_id)
      local resolve_delegation = type(core.delegated_blocker_merged) == "function"
          and core.delegated_blocker_merged
        or delegated_blocker_merged
      return resolve_delegation(repo, blocker_number, blocker_proposal_id, current, delegation)
    end

    local pr_result = devloop_commands.gh_pr_view_observe(repo, link.pr_number, 30)
    if type(pr_result) ~= "table" or pr_result.exit_code ~= 0 then
      return nil, "gh-pr-failed"
    end
    local pr_ok, pr_current = pcall(function()
      return parsers_pr.parse_pr_view_origin(pr_result.stdout)
    end)
    if not pr_ok or type(pr_current) ~= "table" then
      return nil, "malformed-pr-json"
    end
    local origin = marker_facts.pr_origin_fact(pr_current.comments)
    if origin == nil
      or tostring(origin.proposal_id or "") ~= blocker_proposal_id
      or tostring(origin.repo or "") ~= tostring(repo)
      or tostring(origin.issue_number or "") ~= tostring(blocker_number)
      or tostring(origin.branch or "") ~= tostring(link.branch or "")
      or tostring(origin.impl_version or "") ~= tostring(link.impl_version or "")
      or tostring(origin.base_branch or "") ~= tostring(link.base_branch or "") then
      return nil, "pr-origin-mismatch"
    end

    local merged = marker_facts.merged_fact(pr_current.comments, blocker_proposal_id, link.pr_number)
    if merged == nil or not devloop_state.reached(pr_current.comments, blocker_proposal_id, "merged", {
      lineage_base = merged.version,
    }) then
      return false, nil
    end
    return true, nil
  end

  local function prove_blocker_merged(repo, blocker_number)
    if cached_blocker_merged(repo, blocker_number) then
      return true, nil
    end
    local merged, reason = blocker_merged(repo, blocker_number)
    if merged == true then
      cache_blocker_merged(repo, blocker_number)
    end
    return merged, reason
  end

  local evaluate_terminal_blocker

  local function is_duplicate_blocker(blocker)
    return blocker.state == "CLOSED"
      and normalized_state_reason(blocker.state_reason) == "duplicate"
  end

  local function resolve_duplicate(repo, blocker, context, notes, traversal)
    local stack = traversal and traversal.stack or {}
    local depth = traversal and traversal.depth or 0
    if depth > max_dependency_depth then
      return nil, "depth-cap-exceeded", blocker.number, "unresolvable"
    end

    local key = tostring(repo) .. "#" .. tostring(blocker.number)
    if stack[key] then
      return nil, "dependency-cycle", blocker.number, "cycle"
    end
    stack[key] = true

    local current = blocker
    if current.duplicate_of == nil and current.duplicate_projection_complete ~= true then
      local _, fetch_reason, projected = fetch_blocked_by(repo, current.number)
      if projected == nil then
        stack[key] = nil
        local reason = fetch_reason == "missing-issue"
          and "duplicate-target-missing"
          or "duplicate-target-unreadable"
        return nil, reason, current.number, "unresolvable"
      end
      current = projected
    end

    local target = current.duplicate_of
    if type(target) ~= "table" or not forge_validators.is_positive_pr_number(target.number) then
      stack[key] = nil
      return nil, "duplicate-target-missing", current.number, "unresolvable"
    end
    if tostring(target.repo or "") ~= tostring(repo) then
      stack[key] = nil
      return nil, "cross-repo-duplicate-target", target.number, "unresolvable"
    end

    local target_key = tostring(repo) .. "#" .. tostring(target.number)
    if stack[target_key] then
      stack[key] = nil
      return nil, "dependency-cycle", target.number, "cycle"
    end

    local satisfied, reason, unmet_number, kind = evaluate_terminal_blocker(
      repo,
      target,
      context,
      notes,
      { stack = stack, depth = depth + 1 }
    )
    stack[key] = nil
    if satisfied == nil and kind == nil then
      return nil, "duplicate-target-unreadable", unmet_number or target.number, "unresolvable"
    end
    return satisfied, reason, unmet_number or target.number, kind
  end

  evaluate_terminal_blocker = function(repo, blocker, context, notes, traversal)
    local state_reason = normalized_state_reason(blocker.state_reason)
    if is_duplicate_blocker(blocker) then
      return resolve_duplicate(repo, blocker, context, notes, traversal)
    end
    if blocker.state == "CLOSED" and state_reason == "not-planned" then
      add_gate_note(notes, {
        kind = "dependency-void",
        blocker_number = blocker.number,
        reason = "not_planned",
      })
      return true, nil
    end

    local merged, merged_reason = prove_blocker_merged(repo, blocker.number)
    if merged == nil then
      return nil, merged_reason or "unknown-blocker"
    end
    if merged then
      return true, nil
    end
    if blocker.state == "CLOSED"
      and state_reason == "completed"
      and has_dependency_waiver(context, blocker.number) then
      add_gate_note(notes, {
        kind = "dependency-waiver",
        blocker_number = blocker.number,
        reason = "completed_without_merged_marker",
      })
      return true, nil
    end
    if blocker.state == "CLOSED" and state_reason == "completed" then
      return false, "dependency-waiver-required"
    end
    return false, nil
  end

  local function evaluate_managed_sibling_blocker(repo, blocker)
    local merged, reason = prove_blocker_merged(repo, blocker.number)
    if merged == nil then
      return nil, reason or "unknown-blocker"
    end
    if merged then
      return true, nil
    end
    return false, "waiting-on-dependency"
  end

  local visit
  visit = function(
    repo,
    issue_number,
    stack,
    visited,
    unmet,
    unmet_seen,
    depth,
    context,
    notes,
    target_repo,
    target_issue_number
  )
    if depth > max_dependency_depth then
      return gate("unavailable", "depth-cap-exceeded", unmet)
    end

    local key = tostring(repo) .. "#" .. tostring(issue_number)
    if stack[key] then
      add_unmet(unmet, unmet_seen, issue_number)
      return gate("verified_cannot_proceed", "dependency-cycle", unmet, {
        kind = "dependency-cycle",
        repo = repo,
        issue_number = issue_number,
        target_repo = target_repo,
        target_issue_number = target_issue_number,
      })
    end
    if visited[key] then
      return gate("satisfied", "satisfied", unmet)
    end

    stack[key] = true
    local blockers, fetch_reason = fetch_blocked_by(repo, issue_number)
    if blockers == nil then
      stack[key] = nil
      return gate("unavailable", fetch_reason or "gh-failed", unmet)
    end

    for _, blocker in ipairs(blockers) do
      if tostring(blocker.repo or "") ~= tostring(repo) then
        if not managed_sibling_repo(repo, blocker.repo, context and context.managed_sibling_repos) then
          stack[key] = nil
          add_unmet(unmet, unmet_seen, blocker.number)
          return gate("verified_cannot_proceed", "cross-repo-blocker", unmet, {
            kind = "cross-repo-blocker",
            repo = repo,
            issue_number = issue_number,
            blocker_repo = blocker.repo,
            blocker_number = blocker.number,
            target_repo = target_repo,
            target_issue_number = target_issue_number,
          })
        end
        local satisfied, reason = evaluate_managed_sibling_blocker(blocker.repo, blocker)
        if satisfied == nil then
          stack[key] = nil
          return gate("unavailable", reason or "unknown-blocker", unmet)
        end
        if not satisfied then
          add_unmet(unmet, unmet_seen, blocker.number)
        end
      elseif is_duplicate_blocker(blocker) then
        local satisfied, satisfied_reason, canonical_number, result_kind = evaluate_terminal_blocker(
          repo,
          blocker,
          context,
          notes,
          { stack = stack, depth = depth + 1 }
        )
        if satisfied == nil then
          stack[key] = nil
          local blocked_number = canonical_number or blocker.number
          add_unmet(unmet, unmet_seen, blocked_number)
          if result_kind == "cycle" then
            return gate("verified_cannot_proceed", "dependency-cycle", unmet, {
              kind = "dependency-cycle",
              repo = repo,
              issue_number = blocked_number,
              target_repo = target_repo,
              target_issue_number = target_issue_number,
            })
          end
          return gate("unavailable", satisfied_reason or "duplicate-target-unreadable", unmet)
        end
        if not satisfied then
          add_unmet(unmet, unmet_seen, canonical_number or blocker.number)
          if satisfied_reason == "dependency-waiver-required" then
            stack[key] = nil
            return gate("waiting", "dependency-waiver-required", unmet)
          end
        end
      elseif not cached_blocker_merged(repo, blocker.number) then
        local prefer_terminal_proof = blocker.state == "CLOSED"
        local satisfied = nil
        local satisfied_reason = nil

        if prefer_terminal_proof then
          satisfied, satisfied_reason = evaluate_terminal_blocker(repo, blocker, context, notes)
        end
        if not prefer_terminal_proof
          or (satisfied == false and satisfied_reason ~= "dependency-waiver-required") then
          local nested = visit(
            repo,
            blocker.number,
            stack,
            visited,
            unmet,
            unmet_seen,
            depth + 1,
            context,
            notes,
            target_repo,
            target_issue_number
          )
          if nested.kind == "verified_cannot_proceed" or nested.kind == "unavailable" then
            stack[key] = nil
            return nested
          end
        end
        if not prefer_terminal_proof then
          satisfied, satisfied_reason = evaluate_terminal_blocker(repo, blocker, context, notes)
        end
        if satisfied == nil then
          stack[key] = nil
          return gate("unavailable", satisfied_reason or "unknown-blocker", unmet)
        end
        if not satisfied then
          add_unmet(unmet, unmet_seen, blocker.number)
          if satisfied_reason == "dependency-waiver-required" then
            stack[key] = nil
            return gate("waiting", "dependency-waiver-required", unmet)
          end
        end
      end
    end

    stack[key] = nil
    visited[key] = true
    if #unmet > 0 then
      return gate("waiting", "waiting-on-dependency", unmet)
    end
    local result = gate("satisfied", "satisfied", {})
    if type(notes) == "table" and #notes > 0 then
      result.reason = notes[1].kind
      result.notes = notes
    end
    return result
  end

  local function dependency_gate(repo, issue_number, context)
    if split_repo(repo) == nil or not forge_validators.is_positive_pr_number(issue_number) then
      return gate("unavailable", "invalid-target", {})
    end
    local gate_context = type(context) == "table" and context or {}
    gate_context.managed_sibling_repos = config.managed_sibling_repos()
    local ok, result = pcall(
      visit,
      repo,
      issue_number,
      {},
      {},
      {},
      {},
      0,
      gate_context,
      {},
      repo,
      issue_number
    )
    if not ok or type(result) ~= "table" then
      return gate("unavailable", "dependency-gate-exception", {})
    end
    return result
  end

  return {
    delegated_blocker_merged = delegated_blocker_merged,
    dependency_gate = dependency_gate,
    dependency_waiver_fact = dependency_waiver_fact,
    gh_blocked_by = gh_blocked_by,
    merged_blocker_cache_key = merged_blocker_cache_key,
  }
end

return {
  github_graphql_queries = M.github_graphql_queries,
  render_github_graphql_query = M.render_github_graphql_query,
  github_graphql = M.github_graphql,
  dependency_gate_is_satisfied = dependency_gate_is_satisfied,
  dependency_gate_is_verified_cannot_proceed = dependency_gate_is_verified_cannot_proceed,
  new = M.new,
}
