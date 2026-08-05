local ci_wait = require("core.merge_ci_wait")
local devloop_logging = require("devloop.logging")

local t = fkst.test
local BASE_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local HEAD_SHA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

local function field_value(fields, key)
  local prefix = key .. "="
  for _, field in ipairs(fields or {}) do
    if tostring(field):sub(1, #prefix) == prefix then
      return tostring(field):sub(#prefix + 1)
    end
  end
  return nil
end

local function run_probe(ancestor_exit_code, merge_tree_result)
  local calls = {}
  local logs = {}
  local core = {
    git = {
      fetch_branch = function(remote, branch, timeout)
        table.insert(calls, { op = "fetch_branch", remote = remote, branch = branch, timeout = timeout })
        return { stdout = "", stderr = "", exit_code = 0 }
      end,
      remote_branch_head = function(remote, branch, timeout)
        table.insert(calls, { op = "remote_branch_head", remote = remote, branch = branch, timeout = timeout })
        return { stdout = BASE_SHA .. "\n", stderr = "", exit_code = 0 }
      end,
      is_ancestor = function(base_sha, head_sha, timeout)
        table.insert(calls, { op = "is_ancestor", base_sha = base_sha, head_sha = head_sha, timeout = timeout })
        return { stdout = "", stderr = "", exit_code = ancestor_exit_code }
      end,
      merge_tree = function(base_sha, head_sha, timeout)
        table.insert(calls, { op = "merge_tree", base_sha = base_sha, head_sha = head_sha, timeout = timeout })
        return merge_tree_result
      end,
    },
  }
  local original_log_line = devloop_logging.log_line
  devloop_logging.log_line = function(level, dept, proposal_id, tag, fields)
    table.insert(logs, {
      level = level,
      dept = dept,
      proposal_id = proposal_id,
      tag = tag,
      fields = fields,
    })
  end
  local result = {
    pcall(ci_wait.should_wait_for_stale_mergeability, core, {
      number = 7,
      head_sha = HEAD_SHA,
    }, {
      integration = "dev",
    }, "mergeable-conflicting", "github-devloop/issue/owner/repo/42"),
  }
  devloop_logging.log_line = original_log_line
  return result, calls, logs
end

return {
  test_non_ancestor_clean_merge_rescues_stale_verdict_with_structured_fact = function()
    local result, calls, logs = run_probe(1, {
      stdout = "cccccccccccccccccccccccccccccccccccccccc\n",
      stderr = "",
      exit_code = 0,
    })

    t.eq(result[1], true)
    t.eq(result[2], true)
    t.eq(result[3], "stale-mergeability-local-merge-clean")
    t.eq(calls[#calls].op, "merge_tree")
    t.eq(calls[#calls].base_sha, BASE_SHA)
    t.eq(calls[#calls].head_sha, HEAD_SHA)
    t.eq(calls[#calls].timeout, 30)
    t.eq(logs[#logs].tag, "MERGEABILITY_PROBE")
    t.eq(field_value(logs[#logs].fields, "outcome"), "stale-verdict-rescued")
    t.eq(field_value(logs[#logs].fields, "probe"), "merge-tree-write-tree")
  end,

  test_non_ancestor_merge_conflict_remains_authoritative = function()
    local result, calls, logs = run_probe(1, {
      stdout = "",
      stderr = "CONFLICT (content): merge conflict",
      exit_code = 1,
    })

    t.eq(result[1], true)
    t.eq(result[2], false)
    t.eq(result[3], "genuine-merge-conflict")
    t.eq(calls[#calls].op, "merge_tree")
    t.eq(field_value(logs[#logs].fields, "outcome"), "genuine-conflict-confirmed")
  end,

  test_merge_probe_error_fails_closed_without_conflict_classification = function()
    local result, _, logs = run_probe(1, {
      stdout = "",
      stderr = "fatal: bad object",
      exit_code = 128,
    })

    t.eq(result[1], false)
    t.is_true(tostring(result[2]):find("mergeability-probe-failed", 1, true) ~= nil)
    t.eq(field_value(logs[#logs].fields, "outcome"), "probe-failed")
    t.eq(field_value(logs[#logs].fields, "exit_code"), "128")
  end,
}
