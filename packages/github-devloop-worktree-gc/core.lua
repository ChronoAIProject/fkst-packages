-- github-devloop-worktree-gc core: the SAFE removable-predicate for expired
-- deterministic github-devloop worktrees.
--
-- "Expired" NEVER means age. A worktree is removable ONLY when ground-truth codex
-- liveness (fkst.codex_runs) proves no running codex owns its deterministic
-- implement/fix branch. Liveness is joined codex-run -> implement_branch (the exact
-- devloop.base helper, RT-independent) -> porcelain branch match; the reverse
-- (worktree path -> identity) does not round-trip and is never used.
--
-- Pure functions only (no I/O); the department wires the real primitives.

local base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local impl_failure = require("devloop.impl_failure")

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

-- Build the LIVE-BRANCH set from codex_runs().running via the codex-run -> implement_branch join.
-- Returns { set = {<branch>=true,...}, complete = bool }. `complete` is false (FAIL-OPEN) when a
-- live running row cannot be mapped to a branch (unparseable proposal_id/dedup_key or helper
-- error) — an incomplete live set must block ALL removals this pass, because a live worktree
-- could belong to the row we failed to map.
function M.live_branches(running_rows, now_ms)
  local set = {}
  local complete = true
  for _, row in ipairs(running_rows or {}) do
    if tostring(row.status) == "running" and M.lease_valid(row, now_ms) then
      local repo, issue = M.parse_proposal_repo_issue(row.proposal_id)
      local dedup = row.dedup_key
      if repo and issue and dedup ~= nil and tostring(dedup) ~= "" then
        local ok, branch = pcall(function()
          local branch_version = impl_failure.implementation_branch_version(dedup)
          return base.implement_branch(repo, issue, branch_version)
        end)
        if ok and type(branch) == "string" then
          set[branch] = true
        else
          complete = false
        end
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

-- classify(worktrees, live, opts) -> { removable = {<path>,...}, skipped = {{path,branch,reason},...} }.
-- A worktree is REMOVABLE iff ALL hold:
--   (1) the live set is complete (else fail-open: skip everything);
--   (2) it is attached to a deterministic devloop implement/fix branch (round-trips through the prefix);
--   (3) that branch is ABSENT from the live-branch set;
--   (4) a trusted terminal issue marker proves the worktree has reached a terminal lifecycle row.
-- Everything else is skipped with a positive reason and never force-removed.
function M.classify(worktrees, live, opts)
  local removable, skipped = {}, {}
  local terminal_issues = opts and opts.terminal_issues or nil
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
    else
      local issue_ref = M.issue_ref_from_branch(w.branch)
      if issue_ref ~= nil and terminal_issues ~= nil and terminal_issues[issue_ref.proposal_id] == true then
        removable[#removable + 1] = { path = w.path, branch = w.branch, issue_ref = issue_ref }
      else
        skip(w, "terminal-unverified")
      end
    end
  end
  return { removable = removable, skipped = skipped }
end

return M
