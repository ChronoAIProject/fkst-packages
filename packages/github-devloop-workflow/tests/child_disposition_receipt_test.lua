local forge_git = require("forge.git")
local sha256 = require("contract.sha256")
local receipt = require("core.child_disposition_receipt")

local t = fkst.test

local TREE_SHA = string.rep("1", 40)
local FIRST_SHA = string.rep("a", 40)
local RACE_SHA = string.rep("b", 40)

local function fact(overrides)
  local value = {
    repo = "owner/repo",
    origin = "github-devloop/issue/owner/repo/249813",
    blueprint_digest = "d-1234567890",
    slot = "first",
    child_issue = "788438",
    disposition = "satisfied",
  }
  for key, field in pairs(overrides or {}) do
    value[key] = field
  end
  return value
end

local function result(stdout, stderr, exit_code)
  return {
    stdout = stdout or "",
    stderr = stderr or "",
    exit_code = exit_code or 0,
  }
end

local function commit_stdout(message, parent_sha)
  local headers = { "tree " .. TREE_SHA }
  if parent_sha ~= nil then
    headers[#headers + 1] = "parent " .. parent_sha
  end
  headers[#headers + 1] = "author FKST Test <test@example.com> 0 +0000"
  headers[#headers + 1] = "committer FKST Test <test@example.com> 0 +0000"
  return table.concat(headers, "\n") .. "\n\n" .. tostring(message)
end

local function new_git_process(seed)
  local model = seed or {}
  model.refs = model.refs or {}
  model.commits = model.commits or {}
  model.calls = {}
  model.next_sha = model.next_sha or FIRST_SHA
  model.fetched = {}

  local git = forge_git.new(function(opts)
    local argv = opts.argv
    model.calls[#model.calls + 1] = argv

    if argv[2] == "ls-remote" then
      local ref = argv[4]
      local remote_sha = model.refs[ref]
      return result(remote_sha and (remote_sha .. "\t" .. ref .. "\n") or "")
    end

    if argv[2] == "rev-parse" and argv[3] == "--verify" and argv[4] == "HEAD^{tree}" then
      return result(TREE_SHA .. "\n")
    end

    if argv[2] == "commit-tree" then
      t.eq(argv[3], TREE_SHA)
      t.eq(argv[4], "-F")
      t.eq(argv[6], nil)
      local message = assert(file.read(argv[5]))
      model.commits[model.next_sha] = commit_stdout(message)
      return result(model.next_sha .. "\n")
    end

    if argv[2] == "push" then
      local commit_sha, ref = tostring(argv[4]):match("^(%x+):(.+)$")
      t.is_true(commit_sha ~= nil)
      t.eq(argv[5], nil)
      if type(model.before_push_result) == "function" then
        return model.before_push_result(model, commit_sha, ref)
      end
      if model.refs[ref] ~= nil then
        return result("", "non-fast-forward", 1)
      end
      model.refs[ref] = commit_sha
      return result()
    end

    if argv[2] == "fetch" then
      local ref = argv[4]
      model.fetched[model.refs[ref]] = true
      return result()
    end

    if argv[2] == "cat-file" and argv[3] == "-p" then
      local commit_sha = argv[4]
      if not model.fetched[commit_sha] then
        return result("", "object was not fetched", 1)
      end
      local committed = model.commits[commit_sha]
      if committed == nil then
        return result("", "missing object", 1)
      end
      return result(committed)
    end

    error("unexpected git command: " .. table.concat(argv, " "))
  end)

  local commands = {
    git_ls_remote_ref = function(...) return git.ls_remote_ref(...) end,
    git_fetch_ref = function(...) return git.fetch_ref(...) end,
    git_cat_file_pretty = function(...) return git.cat_file_pretty(...) end,
    git_rev_parse_ref_tree = function(...) return git.rev_parse_ref_tree(...) end,
    git_commit_tree = function(...) return git.commit_tree(...) end,
    git_push_ref_update = function(...) return git.push_ref_update(...) end,
  }
  return model, commands
end

local function count_calls(model, command)
  local count = 0
  for _, argv in ipairs(model.calls) do
    if argv[2] == command then
      count = count + 1
    end
  end
  return count
end

local function seed_remote_commit(identity, message, parent_sha)
  local ref = receipt.receipt_ref(identity)
  local model = {
    refs = { [ref] = FIRST_SHA },
    commits = { [FIRST_SHA] = commit_stdout(message, parent_sha) },
  }
  return new_git_process(model)
end

local tests = {
  test_full_canonical_identity_uses_sha256_and_separates_verified_collision_pair = function()
    local first = fact()
    local second = fact({
      origin = "github-devloop/issue/owner/repo/982744",
      child_issue = "991610",
    })

    local first_canonical = receipt.canonical_identity(first)
    local second_canonical = receipt.canonical_identity(second)
    t.is_true(first_canonical ~= second_canonical)
    t.eq(
      receipt.receipt_ref(first),
      "refs/fkst/github-devloop-workflow/child-disposition/" .. sha256.hex(first_canonical)
    )
    t.eq(
      receipt.receipt_ref(second),
      "refs/fkst/github-devloop-workflow/child-disposition/" .. sha256.hex(second_canonical)
    )
    t.is_true(receipt.receipt_ref(first) ~= receipt.receipt_ref(second))
  end,

  test_put_once_creates_reads_back_and_replays_from_a_fresh_adapter = function()
    local model, commands = new_git_process()
    local store = receipt.new({ commands = commands })

    local created = store.put_once(fact())
    t.eq(created.schema, receipt.RECEIPT_SCHEMA)
    t.eq(created.disposition, "satisfied")
    t.eq(created.commit_sha, FIRST_SHA)
    t.eq(count_calls(model, "commit-tree"), 1)
    t.eq(count_calls(model, "push"), 1)
    t.eq(count_calls(model, "ls-remote"), 2)
    t.eq(count_calls(model, "fetch"), 1)
    t.eq(count_calls(model, "cat-file"), 1)

    local replay_model, replay_commands = new_git_process({
      refs = model.refs,
      commits = model.commits,
    })
    local replayed = receipt.new({ commands = replay_commands }).put_once(fact())

    t.eq(replayed.commit_sha, FIRST_SHA)
    t.eq(count_calls(replay_model, "commit-tree"), 0)
    t.eq(count_calls(replay_model, "push"), 0)
    t.eq(count_calls(replay_model, "ls-remote"), 1)
    t.eq(count_calls(replay_model, "fetch"), 1)
    t.eq(count_calls(replay_model, "cat-file"), 1)
  end,

  test_put_once_accepts_only_the_matching_source_visible_race_winner = function()
    local model, commands = new_git_process()
    model.before_push_result = function(current, candidate_sha, ref)
      current.commits[RACE_SHA] = current.commits[candidate_sha]
      current.refs[ref] = RACE_SHA
      return result("", "non-fast-forward", 1)
    end

    local committed = receipt.new({ commands = commands }).put_once(fact())

    t.eq(committed.commit_sha, RACE_SHA)
    t.eq(count_calls(model, "commit-tree"), 1)
    t.eq(count_calls(model, "push"), 1)
    t.eq(count_calls(model, "ls-remote"), 2)
  end,

  test_put_once_preserves_the_push_failure_when_no_valid_winner_is_visible = function()
    local model, commands = new_git_process()
    model.before_push_result = function()
      return result("", "remote rejected candidate", 1)
    end

    local ok, err = pcall(function()
      receipt.new({ commands = commands }).put_once(fact())
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("receipt-push-failed", 1, true) ~= nil)
    t.is_true(tostring(err):find("remote rejected candidate", 1, true) ~= nil)
  end,

  test_read_fails_closed_for_malformed_receipt_content = function()
    local _, commands = seed_remote_commit(fact(), "{not-json\n")

    local ok, err = pcall(function()
      receipt.new({ commands = commands }).read(fact())
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("receipt-decode-failed", 1, true) ~= nil)
  end,

  test_read_fails_closed_when_committed_identity_differs_from_requested_identity = function()
    local other = fact({ child_issue = "991610" })
    local model, commands = new_git_process()
    local other_committed = receipt.new({ commands = commands }).put_once(other)
    model.refs[receipt.receipt_ref(fact())] = other_committed.commit_sha
    local _, fresh_commands = new_git_process({ refs = model.refs, commits = model.commits })

    local ok, err = pcall(function()
      receipt.new({ commands = fresh_commands }).read(fact())
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("receipt-identity-mismatch", 1, true) ~= nil)
  end,

  test_read_fails_closed_for_a_parented_receipt_commit = function()
    local valid_model, valid_commands = new_git_process()
    local committed = receipt.new({ commands = valid_commands }).put_once(fact())
    local message = valid_model.commits[committed.commit_sha]:match("\n\n(.*)")
    local _, commands = seed_remote_commit(fact(), message, string.rep("c", 40))

    local ok, err = pcall(function()
      receipt.new({ commands = commands }).read(fact())
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("receipt-commit-not-root", 1, true) ~= nil)
  end,
}

return tests
