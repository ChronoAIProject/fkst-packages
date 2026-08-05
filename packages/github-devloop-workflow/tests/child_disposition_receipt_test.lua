local forge_git = require("forge.git")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")
local receipt = require("core.child_disposition_receipt")
local marker = require("core.marker")

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

local function receipt_json(value)
  local encoded = "{"
    .. '"schema":' .. strings.json_string(receipt.RECEIPT_SCHEMA)
    .. ',"repo":' .. strings.json_string(value.repo)
    .. ',"origin":' .. strings.json_string(value.origin)
    .. ',"blueprint_digest":' .. strings.json_string(value.blueprint_digest)
    .. ',"slot":' .. strings.json_string(value.slot)
    .. ',"child_issue":' .. strings.json_string(value.child_issue)
    .. ',"disposition":' .. strings.json_string(value.disposition)
  if value.reason_code ~= nil then
    encoded = encoded .. ',"reason_code":' .. strings.json_string(value.reason_code)
  end
  if value.successor_source_ref ~= nil then
    encoded = encoded
      .. ',"successor_source_ref":{"kind":' .. strings.json_string(value.successor_source_ref.kind)
      .. ',"ref":' .. strings.json_string(value.successor_source_ref.ref)
    if value.successor_source_ref.extra ~= nil then
      encoded = encoded .. ',"extra":' .. strings.json_string(value.successor_source_ref.extra)
    end
    encoded = encoded .. "}"
  end
  if value.unsupported_field ~= nil then
    encoded = encoded .. ',"unsupported_field":' .. strings.json_string(value.unsupported_field)
  end
  return encoded .. "}"
end

local function assert_outcome(actual, expected)
  t.eq(actual.disposition, expected.disposition)
  t.eq(actual.reason_code, expected.reason_code)
  if expected.successor_source_ref == nil then
    t.eq(actual.successor_source_ref, nil)
  else
    t.eq(actual.successor_source_ref.kind, expected.successor_source_ref.kind)
    t.eq(actual.successor_source_ref.ref, expected.successor_source_ref.ref)
  end
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
  model.object_types = model.object_types or {}
  for sha in pairs(model.commits) do
    model.object_types[sha] = model.object_types[sha] or "commit"
  end

  local git = forge_git.new(function(opts)
    local argv = opts.argv
    model.calls[#model.calls + 1] = argv

    if argv[2] == "ls-remote" then
      local ref = argv[4]
      local remote_sha = model.refs[ref]
      return result(remote_sha and (remote_sha .. "\t" .. ref .. "\n") or "")
    end

    if argv[2] == "rev-parse" and argv[3] == "--verify" then
      if argv[4] == "HEAD^{tree}" then
        return result(TREE_SHA .. "\n")
      end
      local object_sha = tostring(argv[4]):match("^(%x+)%^%{commit%}$")
      if object_sha ~= nil then
        if model.fetched[object_sha] and model.object_types[object_sha] == "commit" then
          return result(object_sha .. "\n")
        end
        return result("", "expected commit object", 1)
      end
    end

    if argv[2] == "commit-tree" then
      t.eq(argv[3], TREE_SHA)
      t.eq(argv[4], "-F")
      t.eq(argv[6], nil)
      local message = assert(file.read(argv[5]))
      model.commits[model.next_sha] = commit_stdout(message)
      model.object_types[model.next_sha] = "commit"
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
    git_rev_parse_ref_commit = function(...) return git.rev_parse_ref_commit(...) end,
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

  test_put_once_source_reads_and_replays_every_child_disposition = function()
    local values = {
      fact(),
      fact({
        disposition = "undeliverable",
        reason_code = "missing-required-artifact",
      }),
      fact({
        disposition = "transferred",
        successor_source_ref = {
          kind = "external",
          ref = "owner/next-repo#issue/42",
        },
      }),
    }
    local expected_ref = receipt.receipt_ref(values[1])

    for _, value in ipairs(values) do
      t.eq(receipt.receipt_ref(value), expected_ref)
      local model, commands = new_git_process()
      local created = receipt.new({ commands = commands }).put_once(value)

      assert_outcome(created, value)
      t.eq(created.commit_sha, FIRST_SHA)

      local replay_model, replay_commands = new_git_process({
        refs = model.refs,
        commits = model.commits,
      })
      local fresh = receipt.new({ commands = replay_commands })
      assert_outcome(fresh.read(value), value)
      local replayed = fresh.put_once(value)

      assert_outcome(replayed, value)
      t.eq(replayed.commit_sha, FIRST_SHA)
      t.eq(count_calls(replay_model, "commit-tree"), 0)
      t.eq(count_calls(replay_model, "push"), 0)
    end
  end,

  test_put_once_rejects_invalid_outcome_values_before_git_mutation = function()
    local cases = {
      fact({ disposition = "unknown" }),
      fact({ reason_code = "forbidden" }),
      fact({
        successor_source_ref = { kind = "external", ref = "owner/repo#issue/9" },
      }),
      fact({ disposition = "undeliverable" }),
      fact({ disposition = "undeliverable", reason_code = "" }),
      fact({ disposition = "undeliverable", reason_code = "not path safe" }),
      fact({
        disposition = "undeliverable",
        reason_code = string.rep("x", marker.MAX_TERMINAL_REASON_CODE_BYTES + 1),
      }),
      fact({
        disposition = "undeliverable",
        reason_code = "blocked",
        successor_source_ref = { kind = "external", ref = "owner/repo#issue/9" },
      }),
      fact({ disposition = "transferred" }),
      fact({
        disposition = "transferred",
        successor_source_ref = { kind = "external", ref = "owner/repo#pr/9" },
      }),
      fact({
        disposition = "transferred",
        successor_source_ref = { kind = "external", ref = "owner/repo#issue/9", extra = "field" },
      }),
      fact({
        disposition = "transferred",
        reason_code = "forbidden",
        successor_source_ref = { kind = "external", ref = "owner/repo#issue/9" },
      }),
    }

    for _, value in ipairs(cases) do
      local model, commands = new_git_process()
      local ok, err = pcall(function()
        receipt.new({ commands = commands }).put_once(value)
      end)

      t.eq(ok, false)
      t.is_true(tostring(err):find("receipt-", 1, true) ~= nil)
      t.eq(count_calls(model, "commit-tree"), 0)
      t.eq(count_calls(model, "push"), 0)
    end
  end,

  test_put_once_rejects_conflicting_committed_values_without_replacing_them = function()
    local cases = {
      {
        committed = fact(),
        proposed = fact({ disposition = "undeliverable", reason_code = "not-actionable" }),
      },
      {
        committed = fact({ disposition = "undeliverable", reason_code = "not-actionable" }),
        proposed = fact({ disposition = "undeliverable", reason_code = "missing-context" }),
      },
      {
        committed = fact({
          disposition = "transferred",
          successor_source_ref = { kind = "external", ref = "owner/repo#issue/90" },
        }),
        proposed = fact({
          disposition = "transferred",
          successor_source_ref = { kind = "external", ref = "owner/repo#issue/91" },
        }),
      },
    }

    for _, case in ipairs(cases) do
      local model, commands = new_git_process()
      local store = receipt.new({ commands = commands })
      local committed = store.put_once(case.committed)
      local authoritative_sha = model.refs[receipt.receipt_ref(case.committed)]

      local ok, err = pcall(function()
        store.put_once(case.proposed)
      end)

      t.eq(ok, false)
      t.is_true(tostring(err):find("receipt-conflict", 1, true) ~= nil)
      t.eq(model.refs[receipt.receipt_ref(case.committed)], authoritative_sha)
      t.eq(authoritative_sha, committed.commit_sha)
      t.eq(count_calls(model, "commit-tree"), 1)
      t.eq(count_calls(model, "push"), 1)
      assert_outcome(store.read(case.committed), case.committed)
    end
  end,

  test_put_once_keeps_staged_bytes_bound_to_the_normalized_value = function()
    local proposed = fact({ disposition = "undeliverable", reason_code = "not-actionable" })
    local competing = fact({
      disposition = "transferred",
      successor_source_ref = { kind = "external", ref = "owner/repo#issue/91" },
    })
    local model, commands = new_git_process()
    local competing_commands = {
      git_ls_remote_ref = commands.git_ls_remote_ref,
      git_rev_parse_ref_tree = commands.git_rev_parse_ref_tree,
      git_commit_tree = function()
        return result("", "staging interleaving complete", 1)
      end,
    }
    local interleaved = false
    local file_port = {
      write = function(path, body)
        file.write(path, body)
        if interleaved then
          return
        end
        interleaved = true
        local ok, err = pcall(function()
          receipt.new({ commands = competing_commands }).put_once(competing)
        end)
        t.eq(ok, false)
        t.is_true(tostring(err):find("receipt-commit-failed", 1, true) ~= nil)
      end,
    }

    local committed = receipt.new({ commands = commands, file = file_port }).put_once(proposed)

    t.eq(interleaved, true)
    assert_outcome(committed, proposed)
    t.eq(model.refs[receipt.receipt_ref(proposed)], committed.commit_sha)
    t.eq(count_calls(model, "commit-tree"), 1)
    t.eq(count_calls(model, "push"), 1)
  end,

  test_put_once_accepts_only_the_matching_source_visible_race_winner = function()
    local model, commands = new_git_process()
    model.before_push_result = function(current, candidate_sha, ref)
      current.commits[RACE_SHA] = current.commits[candidate_sha]
      current.object_types[RACE_SHA] = "commit"
      current.refs[ref] = RACE_SHA
      return result("", "non-fast-forward", 1)
    end

    local committed = receipt.new({ commands = commands }).put_once(fact())

    t.eq(committed.commit_sha, RACE_SHA)
    t.eq(count_calls(model, "commit-tree"), 1)
    t.eq(count_calls(model, "push"), 1)
    t.eq(count_calls(model, "ls-remote"), 2)
  end,

  test_put_once_reports_a_conflicting_source_visible_race_winner = function()
    local proposed = fact({ disposition = "undeliverable", reason_code = "not-actionable" })
    local winner = fact({
      disposition = "transferred",
      successor_source_ref = { kind = "external", ref = "owner/repo#issue/91" },
    })
    local model, commands = new_git_process()
    model.before_push_result = function(current, _, ref)
      current.commits[RACE_SHA] = commit_stdout(receipt_json(winner) .. "\n")
      current.object_types[RACE_SHA] = "commit"
      current.refs[ref] = RACE_SHA
      return result("", "non-fast-forward", 1)
    end

    local ok, err = pcall(function()
      receipt.new({ commands = commands }).put_once(proposed)
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("receipt-conflict", 1, true) ~= nil)
    t.eq(model.refs[receipt.receipt_ref(proposed)], RACE_SHA)
    t.eq(count_calls(model, "commit-tree"), 1)
    t.eq(count_calls(model, "push"), 1)
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

  test_put_once_preserves_the_push_failure_when_the_visible_winner_is_invalid = function()
    local model, commands = new_git_process()
    model.before_push_result = function(current, _, ref)
      current.commits[RACE_SHA] = commit_stdout("{not-json\n")
      current.object_types[RACE_SHA] = "commit"
      current.refs[ref] = RACE_SHA
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

  test_read_fails_closed_for_invalid_outcome_content = function()
    local cases = {
      fact({ disposition = "unknown" }),
      fact({ reason_code = "forbidden" }),
      fact({ disposition = "undeliverable" }),
      fact({ disposition = "undeliverable", reason_code = "not path safe" }),
      fact({
        disposition = "undeliverable",
        reason_code = "blocked",
        successor_source_ref = { kind = "external", ref = "owner/repo#issue/9" },
      }),
      fact({ disposition = "transferred" }),
      fact({
        disposition = "transferred",
        successor_source_ref = { kind = "external", ref = "owner/repo#pr/9" },
      }),
      fact({
        disposition = "transferred",
        reason_code = "forbidden",
        successor_source_ref = { kind = "external", ref = "owner/repo#issue/9" },
      }),
      fact({
        disposition = "transferred",
        successor_source_ref = { kind = "external", ref = "owner/repo#issue/9", extra = "field" },
      }),
      fact({ unsupported_field = "field" }),
    }

    for _, value in ipairs(cases) do
      local _, commands = seed_remote_commit(fact(), receipt_json(value) .. "\n")
      local ok, err = pcall(function()
        receipt.new({ commands = commands }).read(fact())
      end)

      t.eq(ok, false)
      t.is_true(tostring(err):find("receipt-invalid", 1, true) ~= nil)
    end
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

  test_read_fails_closed_for_a_non_commit_receipt_object = function()
    local valid_model, valid_commands = new_git_process()
    local committed = receipt.new({ commands = valid_commands }).put_once(fact())
    local ref = receipt.receipt_ref(fact())
    local _, commands = new_git_process({
      refs = { [ref] = FIRST_SHA },
      commits = { [FIRST_SHA] = valid_model.commits[committed.commit_sha] },
      object_types = { [FIRST_SHA] = "blob" },
    })

    local ok, err = pcall(function()
      receipt.new({ commands = commands }).read(fact())
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("receipt-object-not-commit", 1, true) ~= nil)
  end,
}

return tests
