local contract_error_facts = require("contract.error_facts")
local sha256 = require("contract.sha256")
local commands = require("devloop.commands")
local forge_validators = require("devloop.forge_validators")
local marker = require("core.marker")

local M = {}

local function fail(code, message)
  error(
    "github-devloop-workflow: child-disposition-receipt-failed: error_class="
      .. tostring(code) .. " reason=" .. tostring(message),
    0
  )
end

local function normalized_expected(fields)
  local expected = type(fields) == "table" and fields or {}
  local repo = tostring(expected.repo or "")
  local child_issue = tostring(expected.child_issue or expected.child_issue_number or "")
  local dedup_key, err = marker.child_disposition_dedup_key(
    expected.origin,
    expected.blueprint_digest,
    expected.slot,
    child_issue
  )
  if repo == "" or dedup_key == nil then
    fail(
      "receipt-identity-invalid",
      tostring(err and err.path or "repo") .. ":" .. tostring(err and err.code or "empty")
    )
  end
  return {
    repo = repo,
    origin = tostring(expected.origin),
    blueprint_digest = tostring(expected.blueprint_digest),
    slot = tostring(expected.slot),
    child_issue = child_issue,
    dedup_key = dedup_key,
  }
end

local function receipt_ref(expected)
  local repo_key = contract_error_facts.stable_hash(expected.repo)
  local receipt_key = sha256.hex(expected.dedup_key)
  local ref = "refs/fkst/github-devloop-workflow/child-disposition/"
    .. repo_key .. "/" .. receipt_key
  if not forge_validators.is_git_ref_safe(ref) then
    fail("receipt-ref-invalid", "derived receipt ref is invalid")
  end
  return ref
end

local function result_required(result, error_class, operation)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    fail(error_class, operation .. " failed: " .. tostring(result and result.stderr or "missing result"))
  end
  return result
end

function M.production_adapter(deps)
  local selected = deps or {}
  local adapter = {
    commands = selected.commands or commands,
    file = selected.file or file,
  }

  return {
    read = function(fields)
      local expected = normalized_expected(fields)
      local ref = receipt_ref(expected)
      local listed = result_required(
        adapter.commands.git_ls_remote_ref("origin", ref, 30),
        "receipt-list-failed",
        "receipt ls-remote"
      )
      local sha, listed_ref = tostring(listed.stdout or ""):match("^(%x+)%s+([^%s]+)")
      if sha == nil then
        return nil
      end
      if listed_ref ~= ref or not forge_validators.is_git_sha(sha) then
        fail("receipt-ref-invalid", "receipt ls-remote returned an invalid ref")
      end
      result_required(
        adapter.commands.git_fetch_ref("origin", ref, 30),
        "receipt-fetch-failed",
        "receipt fetch"
      )
      local commit = result_required(
        adapter.commands.git_cat_file_pretty(sha, 30),
        "receipt-read-failed",
        "receipt read"
      )
      local fact = marker.parse_child_disposition_marker(
        adapter.commands.git_commit_object_message(commit.stdout),
        expected.origin,
        expected.blueprint_digest,
        expected.slot,
        expected.child_issue
      )
      if fact == nil or fact.dedup_key ~= expected.dedup_key then
        fail("receipt-content-invalid", "committed receipt does not match the slot identity")
      end
      fact.commit_sha = sha
      return fact
    end,

    compare_and_swap = function(fields, body)
      local expected = normalized_expected(fields)
      local fact = marker.parse_child_disposition_marker(
        body,
        expected.origin,
        expected.blueprint_digest,
        expected.slot,
        expected.child_issue
      )
      if fact == nil or fact.dedup_key ~= expected.dedup_key then
        fail("receipt-content-invalid", "candidate receipt does not match the slot identity")
      end
      local tree = result_required(
        adapter.commands.git_rev_parse_ref_tree("HEAD", 30),
        "receipt-tree-failed",
        "receipt tree read"
      )
      local tree_sha = tostring(tree.stdout or ""):match("(%x+)")
      if not forge_validators.is_git_sha(tree_sha) then
        fail("receipt-tree-invalid", "receipt tree SHA is invalid")
      end
      local identity = contract_error_facts.stable_hash(body)
      local message_file = "/tmp/fkst-github-devloop-workflow-child-disposition-"
        .. identity .. ".md"
      adapter.file.write(message_file, body .. "\n")
      local commit = result_required(
        adapter.commands.git_commit_tree(tree_sha, nil, message_file, 30),
        "receipt-commit-failed",
        "receipt commit"
      )
      local commit_sha = tostring(commit.stdout or ""):match("(%x+)")
      if not forge_validators.is_git_sha(commit_sha) then
        fail("receipt-commit-invalid", "receipt commit SHA is invalid")
      end
      local pushed = adapter.commands.git_push_ref_update(
        "origin",
        commit_sha,
        receipt_ref(expected),
        false,
        60
      )
      if type(pushed) ~= "table" or pushed.exit_code ~= 0 then
        return false, nil, tostring(pushed and pushed.stderr or "missing push result")
      end
      return true, commit_sha, nil
    end,
  }
end

function M.receipt_ref(fields)
  return receipt_ref(normalized_expected(fields))
end

return M
