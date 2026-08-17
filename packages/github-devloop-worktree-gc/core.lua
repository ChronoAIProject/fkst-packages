-- github-devloop-worktree-gc core: the SAFE removable-predicate for expired
-- deterministic github-devloop worktrees.
--
-- "Expired" NEVER means age. A worktree is removable ONLY when ground-truth codex
-- liveness (fkst.codex_runs) proves no running codex owns its deterministic
-- implement/fix branch and the owning issue lifecycle is terminal. Implement runs
-- join through devloop.base.implement_branch; fix runs join through the producer-owned
-- immutable implementing:v1 branch fact.
-- The reverse (worktree path -> identity) does not round-trip and is never used.
--
-- Pure functions only (no I/O); the department wires the real primitives.

local base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local impl_failure = require("devloop.impl_failure")
local m_facts = require("devloop.markers.facts")
local parsers_misc = require("devloop.parsers.misc")
local devloop_state = require("devloop.state")

local M = {}

-- The deterministic github-devloop implement/fix branch prefix (devloop.base.implement_branch).
-- Fix worktrees push to the same implement branch, so this one prefix covers both.
local IMPLEMENT_BRANCH_PREFIX = "devloop/issue/"

-- Split into lines without dropping trailing empties inconsistently.
local function each_line(text, fn)
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    fn(line)
  end
end

-- Parse `git worktree list --porcelain` -> { {path=, branch=, detached=bool}, ... }.
-- The FIRST entry is the main checkout; it is returned like any other and is filtered
-- out downstream by branch shape (its branch is never a deterministic devloop branch).
function M.parse_worktrees(porcelain)
  local out = {}
  local cur = nil
  each_line(porcelain, function(line)
    local path = line:match("^worktree (.+)$")
    if path then
      cur = { path = path, branch = nil, detached = false }
      out[#out + 1] = cur
    elseif cur then
      local branch = line:match("^branch refs/heads/(.+)$")
      if branch then
        cur.branch = branch
      elseif line == "detached" then
        cur.detached = true
      end
    end
  end)
  return out
end

-- proposal_id "github-devloop/issue/<owner>/<repo>/<issue>" -> repo="<owner>/<repo>", issue="<issue>".
function M.parse_proposal_repo_issue(proposal_id)
  local owner, repo, issue =
    tostring(proposal_id or ""):match("^github%-devloop/issue/([^/]+)/([^/]+)/([0-9]+)$")
  if owner and repo and issue then
    return owner .. "/" .. repo, issue
  end
  return nil, nil
end

-- A codex_runs row is LIVE iff status=="running" AND its lease is not expired.
-- This mirrors the devloop liveness contract exactly. Missing lease info is treated
-- as LIVE (conservative: never remove a worktree whose owner might still be running).
function M.lease_valid(row, now_ms)
  local lease = tonumber(row and row.lease_expires_at_ms)
  if lease == nil then
    return true
  end
  return lease >= tonumber(now_ms or 0)
end

-- Build the LIVE-BRANCH set from codex_runs().running via the codex-run -> owner-branch join.
-- Returns { set = {<branch>=true,...}, complete = bool }. `complete` is false (FAIL-OPEN) when a
-- live running row cannot be mapped to a branch (unparseable proposal_id/dedup_key or helper
-- error) — an incomplete live set must block ALL removals this pass, because a live worktree
-- could belong to the row we failed to map.
function M.live_branches(running_rows, now_ms, resolve_fix_branch)
  local set = {}
  local complete = true
  for _, row in ipairs(running_rows or {}) do
    if tostring(row.status) == "running" and M.lease_valid(row, now_ms) then
      local ok, branch
      if tostring(row.role or "") == "fix" then
        ok, branch = pcall(resolve_fix_branch or function() return nil end, row)
      else
        local repo, issue = M.parse_proposal_repo_issue(row.proposal_id)
        local dedup = row.dedup_key
        if repo and issue and dedup ~= nil and tostring(dedup) ~= "" then
          ok, branch = pcall(function()
            return base.implement_branch(
              repo,
              issue,
              impl_failure.implementation_branch_version(dedup)
            )
          end)
        end
      end
      if ok and type(branch) == "string" and branch ~= "" then
        set[branch] = true
      else
        complete = false
      end
    end
  end
  return { set = set, complete = complete }
end

function M.is_deterministic_devloop_branch(branch)
  return type(branch) == "string"
    and branch:sub(1, #IMPLEMENT_BRANCH_PREFIX) == IMPLEMENT_BRANCH_PREFIX
end

function M.issue_ref_from_branch(branch)
  local owner, repo_name, issue =
    tostring(branch or ""):match("^devloop/issue/([^/]+)/([^/]+)/([0-9]+)/")
  if owner == nil or repo_name == nil or issue == nil then
    return nil
  end
  local repo = owner .. "/" .. repo_name
  if base_ids.safe_repo(repo) ~= repo or base_ids.safe_issue(issue) ~= issue then
    return nil
  end
  return {
    repo = repo,
    issue = issue,
    proposal_id = base_ids.proposal_id(repo, issue),
    source_ref = base_ids.issue_source_ref(repo, issue),
  }
end

local function marker_attr(marker, name)
  return marker:match(name .. '="([^"]*)"')
end

-- A live fix row is fenced by its work-unit key, while its immutable worktree branch
-- remains the branch published by the implementation lifecycle. Multiple historical
-- facts are safe only when they agree on that exact branch.
function M.fix_owner_branch(comments, proposal_id)
  local branch = nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch("<!%-%- fkst:github%-devloop:implementing:v1.-%-%->") do
      if marker_attr(marker, "proposal") == proposal_id then
        local fact = m_facts.implementing_fact(comments, proposal_id, marker_attr(marker, "dedup"))
        if fact ~= nil then
          if branch ~= nil and branch ~= fact.branch then
            return nil
          end
          branch = fact.branch
        end
      end
    end
  end
  return branch
end

-- The deterministic branch is reused by implementation retries and PR fix attempts,
-- including after their codex rows stop running. Only the terminal issue lifecycle
-- releases the stable worktree after every possible harvest owner has finished.
function M.branch_release_fact(comments, issue_ref, branch)
  if type(issue_ref) ~= "table" or type(branch) ~= "string" then
    return nil
  end
  local proposal_id = issue_ref.proposal_id
  if devloop_state.current_issue_observation_is_terminal(comments, proposal_id) then
    return { kind = "terminal", branch = branch, proposal_id = proposal_id }
  end
  return nil
end

-- classify(worktrees, live, current_runtime_root, implementation_root, opts)
--   -> { removable = {<path>,...}, skipped = {{path,branch,reason},...} }.
-- A worktree is REMOVABLE iff ALL hold:
--   (1) the live set is complete (else fail-open: skip everything);
--   (2) it is attached to a deterministic devloop implement/fix branch (round-trips through the prefix);
--   (3) that branch is ABSENT from the live-branch set;
--   (4) it is outside both owned roots, or the trusted terminal lifecycle fact
--       releases the exact branch.
-- Everything else is skipped with a positive reason and never force-removed.
function M.classify(worktrees, live, current_runtime_root, implementation_root, opts)
  local removable, skipped = {}, {}
  local released_branches = opts and opts.released_branches or nil
  local function skip(w, reason)
    skipped[#skipped + 1] = { path = w.path, branch = w.branch, reason = reason }
  end

  if not (live and live.complete) then
    for _, w in ipairs(worktrees or {}) do
      skip(w, "fail-open-incomplete-live-set")
    end
    return { removable = removable, skipped = skipped }
  end

  for _, w in ipairs(worktrees or {}) do
    if w.detached or w.branch == nil then
      skip(w, "detached-or-non-branch")
    elseif not M.is_deterministic_devloop_branch(w.branch) then
      skip(w, "non-deterministic-branch")
    elseif live.set[w.branch] then
      skip(w, "live-branch")
    elseif base.path_under_root(current_runtime_root, w.path)
      or base.path_under_root(implementation_root, w.path) then
      local issue_ref = M.issue_ref_from_branch(w.branch)
      if issue_ref ~= nil and released_branches ~= nil and released_branches[w.branch] == true then
        removable[#removable + 1] = { path = w.path, branch = w.branch, issue_ref = issue_ref }
      elseif base.path_under_root(implementation_root, w.path) then
        skip(w, "stable-release-unverified")
      else
        skip(w, released_branches ~= nil and "current-runtime-release-unverified" or "current-runtime-root")
      end
    else
      removable[#removable + 1] = { path = w.path, branch = w.branch }
    end
  end
  return { removable = removable, skipped = skipped }
end

return M
