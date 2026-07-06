local t = fkst.test

local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"

local function nonce()
  return tostring({}):gsub("[^%w._-]", "_")
end

local function runtime_root(name)
  return "/tmp/fkst-packages-test/consensus-judged/" .. tostring(now()) .. "/" .. nonce() .. "/" .. name
end

local function shell_single_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function opts(name)
  return {
    env = {
      FKST_RUNTIME_ROOT = runtime_root(name),
    },
  }
end

local function proposal(extra)
  local value = {
    schema = "consensus.proposal.v1",
    proposal_id = "proposal-42",
    title = "Adopt consensus package",
    body = "Create a small flat package that asks several angles to judge a proposal.",
    content_fetch = "fetch-source --ref demo/consensus/42 --full",
    angles = { "teleology", "parsimony", "fidelity" },
    dedup_key = "proposal-42-v1",
    source_ref = {
      kind = "proposal",
      ref = "demo/consensus/42",
    },
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function run_decide(event_payload, run_opts)
  return t.run_department("departments/decide/main.lua", {
    queue = "proposal",
    payload = event_payload,
  }, run_opts)
end

local function codex_calls()
  local calls = {}
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find("codex exec", 1, true) ~= nil then
      table.insert(calls, call)
    end
  end
  return calls
end

local function find_call_with_rendered(fragment)
  for _, call in ipairs(codex_calls()) do
    if tostring(call.rendered or ""):find(fragment, 1, true) ~= nil then
      return call
    end
  end
  return nil
end

local function mock_judgment_runtime()
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/consensus-judged/runtime",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_judgment_dir()
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function assert_judgment_dir_created_without_permission_control(count)
  local seen = 0
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find("mkdir -p", 1, true) ~= nil
      and call.rendered:find("/judgment-worktrees/consensus-", 1, true) ~= nil then
      seen = seen + 1
      t.is_nil(call.rendered:find("chmod", 1, true))
    end
  end
  t.eq(seen, count)
end

local function prepare_judged_fixture(root)
  os.execute("mkdir -p " .. shell_single_quote(root .. "/repo/src"))
  local file = assert(io.open(root .. "/repo/src/judged.txt", "w"))
  file:write("repo evidence line\n")
  file:close()
  return root .. "/repo"
end

local function mock_angle(_angle, reply)
  t.mock_command("codex exec", {
    stdout = verdict_label .. " approve\n" .. reply_label .. " " .. reply .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_judged_repo_checkout_allows_repo_citation_and_stamps_provenance = function()
    local run_opts = opts("citation")
    local repo_path = prepare_judged_fixture(run_opts.env.FKST_RUNTIME_ROOT)
    local head_sha = string.rep("a", 40)
    mock_judgment_runtime()
    t.mock_command("rev-parse HEAD", {
      stdout = head_sha .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_angle("teleology", "Repo evidence is present at src/judged.txt:1.")
    mock_angle("parsimony", "Parsimony approves without a repo citation.")
    mock_angle("fidelity", "Fidelity approves the cited repo evidence.")

    local result = run_decide(proposal({
      dedup_key = "proposal-42-v1/judged-repo",
      judged_repo = {
        repo = "owner/repo",
        head_sha = head_sha,
        repo_path = repo_path,
      },
    }), run_opts)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_reached")
    t.eq(result.raises[1].payload.repo_consulted, true)
    t.eq(#codex_calls(), 3)
    local judged_call = find_call_with_rendered(" -C " .. repo_path)
    t.is_true(judged_call ~= nil)
    t.is_true(judged_call.stdin:find("read-only checkout of the judged repository", 1, true) ~= nil)
    t.is_true(judged_call.stdin:find("context bundle remains the pinned snapshot of record", 1, true) ~= nil)
    t.is_true(judged_call.stdin:find("Load-bearing repo claims must cite `path:line`", 1, true) ~= nil)
    t.is_nil(judged_call.stdin:find("Read required source content only from the context manifest below.", 1, true))
    assert_judgment_dir_created_without_permission_control(0)
  end,

  test_judged_repo_without_valid_citation_does_not_stamp_provenance = function()
    local run_opts = opts("no-citation")
    local repo_path = prepare_judged_fixture(run_opts.env.FKST_RUNTIME_ROOT)
    local head_sha = string.rep("b", 40)
    mock_judgment_runtime()
    t.mock_command("rev-parse HEAD", {
      stdout = head_sha .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_angle("teleology", "The model says repo_consulted=true without evidence.")
    mock_angle("parsimony", "Missing file citation src/missing.txt:1 does not count.")
    mock_angle("fidelity", "Out-of-range citation src/judged.txt:99 does not count.")

    local result = run_decide(proposal({
      dedup_key = "proposal-42-v1/judged-repo-no-citation",
      judged_repo = {
        repo = "owner/repo",
        head_sha = head_sha,
        repo_path = repo_path,
      },
    }), run_opts)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_reached")
    t.is_nil(result.raises[1].payload.repo_consulted)
    t.eq(#codex_calls(), 3)
  end,

  test_judged_repo_head_sha_uses_detached_checkout_when_path_is_not_supplied = function()
    local run_opts = opts("detached")
    local head_sha = string.rep("c", 40)
    mock_judgment_runtime()
    t.mock_command("rev-parse HEAD", {
      stdout = "",
      stderr = "not a checkout",
      exit_code = 128,
    })
    mock_judgment_dir()
    t.mock_command("git worktree add --detach", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse HEAD", {
      stdout = head_sha .. "\n",
      stderr = "",
      exit_code = 0,
    })
    mock_angle("teleology", "Repo evidence is present at src/judged.txt:1.")
    mock_angle("parsimony", "Parsimony approves.")
    mock_angle("fidelity", "Fidelity approves.")

    local result = run_decide(proposal({
      dedup_key = "proposal-42-v1/judged-repo-detached",
      judged_repo = {
        repo = "owner/repo",
        head_sha = head_sha,
      },
    }), run_opts)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_reached")
    t.is_nil(result.raises[1].payload.repo_consulted)
    t.eq(#codex_calls(), 3)
    local first_call = codex_calls()[1]
    t.is_true(first_call.rendered:find("/worktrees/consensus-judged-owner-repo", 1, true) ~= nil)
    t.is_nil(first_call.rendered:find("/judgment-worktrees/consensus-", 1, true))
    local add_count = 0
    for _, call in ipairs(t.command_calls()) do
      if call.rendered:find("git worktree add --detach", 1, true) ~= nil then
        add_count = add_count + 1
        t.is_true(call.rendered:find(head_sha, 1, true) ~= nil)
      end
    end
    t.eq(add_count, 1)
  end,
}
