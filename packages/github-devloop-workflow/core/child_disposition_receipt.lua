local base_ids = require("devloop.base_ids")
local commands = require("devloop.commands")
local devloop_base = require("devloop.base")
local gitref = require("forge.gitref")
local marker = require("core.marker")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}

M.IDENTITY_SCHEMA = "github-devloop-workflow.child-disposition-identity.v1"
M.RECEIPT_SCHEMA = "github-devloop-workflow.child-disposition-receipt.v1"

local REF_PREFIX = "refs/fkst/github-devloop-workflow/child-disposition/"
local REMOTE = "origin"
local READ_TIMEOUT_SECONDS = 30
local PUSH_TIMEOUT_SECONDS = 60

local function fail(error_class, reason)
  error(
    "github-devloop-workflow: child-disposition-receipt-failed: error_class="
      .. tostring(error_class) .. " reason=" .. tostring(reason),
    0
  )
end

local function canonical_issue_number(value, field)
  if type(value) ~= "string" and type(value) ~= "number" then
    fail("receipt-identity-invalid", field .. " must be a positive issue number")
  end
  local text = tostring(value)
  local number = tonumber(text)
  if text:find("^[1-9]%d*$") == nil
    or number == nil
    or number ~= math.floor(number)
    or number > 2147483647 then
    fail("receipt-identity-invalid", field .. " must be a canonical positive issue number")
  end
  return text
end

local function normalize_identity(value)
  if type(value) ~= "table" then
    fail("receipt-identity-invalid", "identity must be a table")
  end
  if type(value.repo) ~= "string" or value.repo == "" or base_ids.safe_repo(value.repo) ~= value.repo then
    fail("receipt-identity-invalid", "repo must be a canonical repository identity")
  end
  if type(value.origin) ~= "string" then
    fail("receipt-identity-invalid", "origin must be a proposal identity")
  end
  local origin_repo, origin_issue = base_ids.parse_proposal_id(value.origin)
  if origin_repo ~= value.repo then
    fail("receipt-identity-invalid", "origin must belong to repo")
  end
  canonical_issue_number(origin_issue, "origin issue")
  local child_issue = canonical_issue_number(value.child_issue, "child_issue")
  if not base_ids.issue_ref_round_trips(value.repo, child_issue) then
    fail("receipt-identity-invalid", "child issue identity must round-trip")
  end
  if type(value.blueprint_digest) ~= "string" or type(value.slot) ~= "string" then
    fail("receipt-identity-invalid", "blueprint_digest and slot must be strings")
  end
  local lineage = marker.build_lineage_header(value.origin, value.blueprint_digest, value.slot)
  if lineage == nil then
    fail("receipt-identity-invalid", "workflow lineage is invalid")
  end
  return {
    repo = value.repo,
    origin = value.origin,
    blueprint_digest = value.blueprint_digest,
    slot = value.slot,
    child_issue = child_issue,
  }
end

local function append_field(parts, name, value)
  parts[#parts + 1] = name
  parts[#parts + 1] = tostring(#value)
  parts[#parts + 1] = value
end

function M.canonical_identity(value)
  local identity = normalize_identity(value)
  local parts = {}
  append_field(parts, "schema", M.IDENTITY_SCHEMA)
  append_field(parts, "repo", identity.repo)
  append_field(parts, "origin", identity.origin)
  append_field(parts, "blueprint_digest", identity.blueprint_digest)
  append_field(parts, "slot", identity.slot)
  append_field(parts, "child_issue", identity.child_issue)
  return table.concat(parts, "\n")
end

function M.receipt_ref(value)
  return REF_PREFIX .. sha256.hex(M.canonical_identity(value))
end

local function operation_result(result, error_class, operation)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    fail(error_class, operation .. " failed: " .. tostring(result and result.stderr or "missing result"))
  end
  return result
end

local function remote_ref_sha(stdout, expected_ref)
  local sha = nil
  for line in (tostring(stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local candidate, listed_ref = line:match("^(%x+)%s+([^%s]+)$")
      if candidate == nil or listed_ref ~= expected_ref or not gitref.is_git_sha(candidate) or sha ~= nil then
        fail("receipt-ref-invalid", "ls-remote returned an invalid receipt ref")
      end
      sha = candidate
    end
  end
  return sha
end

local function commit_message(stdout)
  local text = tostring(stdout or ""):gsub("\r\n", "\n")
  local boundary = text:find("\n\n", 1, true)
  if boundary == nil then
    fail("receipt-commit-invalid", "receipt commit has no message boundary")
  end
  local headers = text:sub(1, boundary - 1)
  local tree_count = 0
  for line in (headers .. "\n"):gmatch("([^\n]*)\n") do
    local tree_sha = line:match("^tree (%x+)$")
    if tree_sha ~= nil then
      if not gitref.is_git_sha(tree_sha) then
        fail("receipt-commit-invalid", "receipt commit tree is invalid")
      end
      tree_count = tree_count + 1
    elseif line:find("^parent ") ~= nil then
      fail("receipt-commit-not-root", "receipt commit must be parentless")
    end
  end
  if tree_count ~= 1 then
    fail("receipt-commit-invalid", "receipt commit must contain one tree header")
  end
  local message = text:sub(boundary + 2)
  if strings.trim(message) == "" then
    fail("receipt-commit-invalid", "receipt commit message is empty")
  end
  return message
end

local receipt_fields = {
  schema = true,
  repo = true,
  origin = true,
  blueprint_digest = true,
  slot = true,
  child_issue = true,
  disposition = true,
  reason_code = true,
  successor_source_ref = true,
}

local function normalize_successor_source_ref(value)
  if type(value) ~= "table" then
    fail("receipt-outcome-invalid", "successor_source_ref must be an external issue source ref")
  end
  for key in pairs(value) do
    if key ~= "kind" and key ~= "ref" then
      fail("receipt-outcome-invalid", "successor_source_ref contains an unsupported field")
    end
  end
  if type(value.kind) ~= "string" or type(value.ref) ~= "string" then
    fail("receipt-outcome-invalid", "successor_source_ref kind and ref must be strings")
  end
  local repo, issue_number = devloop_base.parse_issue_source_ref(value)
  local canonical_ref = repo and (repo .. "#issue/" .. issue_number) or nil
  if value.kind ~= "external" or canonical_ref == nil or value.ref ~= canonical_ref then
    fail("receipt-outcome-invalid", "successor_source_ref must be a canonical external issue source ref")
  end
  return {
    kind = "external",
    ref = canonical_ref,
  }
end

local function normalize_receipt(value)
  if type(value) ~= "table" then
    fail("receipt-invalid", "receipt value must be a table")
  end
  for key in pairs(value) do
    if receipt_fields[key] ~= true then
      fail("receipt-invalid", "receipt contains an unsupported field")
    end
  end
  if value.schema ~= nil and value.schema ~= M.RECEIPT_SCHEMA then
    fail("receipt-invalid", "receipt schema is invalid")
  end

  local identity = normalize_identity(value)
  local normalized = {
    schema = M.RECEIPT_SCHEMA,
    repo = identity.repo,
    origin = identity.origin,
    blueprint_digest = identity.blueprint_digest,
    slot = identity.slot,
    child_issue = identity.child_issue,
    disposition = value.disposition,
  }
  if value.disposition == "satisfied" then
    if value.reason_code ~= nil or value.successor_source_ref ~= nil then
      fail("receipt-outcome-invalid", "satisfied forbids outcome-specific fields")
    end
  elseif value.disposition == "undeliverable" then
    if not strings.is_path_safe_key(value.reason_code, marker.MAX_TERMINAL_REASON_CODE_BYTES) then
      fail("receipt-outcome-invalid", "undeliverable requires a bounded path-safe reason_code")
    end
    if value.successor_source_ref ~= nil then
      fail("receipt-outcome-invalid", "undeliverable forbids successor_source_ref")
    end
    normalized.reason_code = value.reason_code
  elseif value.disposition == "transferred" then
    if value.reason_code ~= nil then
      fail("receipt-outcome-invalid", "transferred forbids reason_code")
    end
    normalized.successor_source_ref = normalize_successor_source_ref(value.successor_source_ref)
  else
    fail("receipt-disposition-invalid", "disposition must be satisfied, undeliverable, or transferred")
  end
  return normalized
end

local function encode_receipt(value)
  local encoded = "{"
    .. '"schema":' .. strings.json_string(value.schema)
    .. ',"repo":' .. strings.json_string(value.repo)
    .. ',"origin":' .. strings.json_string(value.origin)
    .. ',"blueprint_digest":' .. strings.json_string(value.blueprint_digest)
    .. ',"slot":' .. strings.json_string(value.slot)
    .. ',"child_issue":' .. strings.json_string(value.child_issue)
    .. ',"disposition":' .. strings.json_string(value.disposition)
  if value.reason_code ~= nil then
    encoded = encoded .. ',"reason_code":' .. strings.json_string(value.reason_code)
  elseif value.successor_source_ref ~= nil then
    encoded = encoded
      .. ',"successor_source_ref":{"kind":' .. strings.json_string(value.successor_source_ref.kind)
      .. ',"ref":' .. strings.json_string(value.successor_source_ref.ref)
      .. "}"
  end
  return encoded .. "}"
end

local function matching_receipt(expected, committed)
  if encode_receipt(expected) ~= encode_receipt(committed) then
    fail("receipt-conflict", "a different child disposition receipt is already committed")
  end
  return committed
end

local function decode_receipt(decoder, message, expected, commit_sha)
  local ok, decoded = pcall(decoder.decode, message)
  if not ok or type(decoded) ~= "table" then
    fail("receipt-decode-failed", "receipt commit message is not valid JSON")
  end
  if decoded.schema ~= M.RECEIPT_SCHEMA then
    fail("receipt-invalid", "receipt schema is invalid")
  end
  local normalized_ok, embedded = pcall(normalize_receipt, decoded)
  if not normalized_ok then
    fail("receipt-invalid", "receipt value is invalid: " .. tostring(embedded))
  end
  for _, field in ipairs({ "repo", "origin", "blueprint_digest", "slot", "child_issue" }) do
    if embedded[field] ~= expected[field] then
      fail("receipt-identity-mismatch", "receipt identity differs at " .. field)
    end
  end
  embedded.commit_sha = commit_sha
  return embedded
end

local function body_file(identity)
  return "/tmp/fkst-github-devloop-workflow-child-disposition-"
    .. sha256.hex(M.canonical_identity(identity)) .. ".json"
end

function M.new(deps)
  local selected = deps or {}
  local adapter = selected.commands or commands
  local file_port = selected.file or file
  local decoder = selected.json or json

  local function read(value)
    local identity = normalize_identity(value)
    local ref = M.receipt_ref(identity)
    local listed = operation_result(
      adapter.git_ls_remote_ref(REMOTE, ref, READ_TIMEOUT_SECONDS),
      "receipt-list-failed",
      "receipt ls-remote"
    )
    local commit_sha = remote_ref_sha(listed.stdout, ref)
    if commit_sha == nil then
      return nil
    end
    operation_result(
      adapter.git_fetch_ref(REMOTE, ref, READ_TIMEOUT_SECONDS),
      "receipt-fetch-failed",
      "receipt fetch"
    )
    local resolved = operation_result(
      adapter.git_rev_parse_ref_commit(commit_sha, READ_TIMEOUT_SECONDS),
      "receipt-object-not-commit",
      "receipt commit verification"
    )
    if strings.trim(resolved.stdout) ~= commit_sha then
      fail("receipt-object-not-commit", "receipt ref does not name the resolved commit directly")
    end
    local committed = operation_result(
      adapter.git_cat_file_pretty(commit_sha, READ_TIMEOUT_SECONDS),
      "receipt-read-failed",
      "receipt cat-file"
    )
    return decode_receipt(decoder, commit_message(committed.stdout), identity, commit_sha)
  end

  local function put_once(value)
    local normalized = normalize_receipt(value)
    local existing = read(normalized)
    if existing ~= nil then
      return matching_receipt(normalized, existing)
    end

    local tree = operation_result(
      adapter.git_rev_parse_ref_tree("HEAD", READ_TIMEOUT_SECONDS),
      "receipt-tree-failed",
      "receipt tree read"
    )
    local tree_sha = strings.trim(tree.stdout)
    if not gitref.is_git_sha(tree_sha) then
      fail("receipt-tree-invalid", "receipt tree SHA is invalid")
    end
    local path = body_file(normalized)
    file_port.write(path, encode_receipt(normalized) .. "\n")
    local committed = operation_result(
      adapter.git_commit_tree(tree_sha, nil, path, READ_TIMEOUT_SECONDS),
      "receipt-commit-failed",
      "receipt commit-tree"
    )
    local candidate_sha = strings.trim(committed.stdout)
    if not gitref.is_git_sha(candidate_sha) then
      fail("receipt-commit-invalid", "receipt commit SHA is invalid")
    end

    local pushed = adapter.git_push_ref_update(
      REMOTE,
      candidate_sha,
      M.receipt_ref(normalized),
      false,
      PUSH_TIMEOUT_SECONDS
    )
    if type(pushed) ~= "table" or tonumber(pushed.exit_code) ~= 0 then
      local visible_ok, winner = pcall(read, normalized)
      if visible_ok and winner ~= nil then
        return matching_receipt(normalized, winner)
      end
      fail("receipt-push-failed", "receipt ref creation failed: "
        .. tostring(pushed and pushed.stderr or "missing result"))
    end

    local visible = read(normalized)
    if visible == nil then
      fail("receipt-readback-missing", "receipt ref is not source-visible after push")
    end
    return matching_receipt(normalized, visible)
  end

  return {
    read = read,
    put_once = put_once,
  }
end

function M.install(target)
  target.child_disposition_receipt = M
end

return M
