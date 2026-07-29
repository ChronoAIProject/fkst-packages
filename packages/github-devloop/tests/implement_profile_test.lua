local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local requests_lifecycle = require("devloop.requests.lifecycle")

local t = h.t
local core = h.core

local function load_profile()
  local ok, profile = pcall(require, "departments.implement.profile")
  t.eq(ok, true)
  return profile
end

local function recording_git(result)
  local calls = {}
  return {
    calls = calls,
    object_type = function(ref, path, timeout)
      table.insert(calls, {
        ref = ref,
        path = path,
        timeout = timeout,
      })
      return result
    end,
  }
end

local function issue()
  return {
    title = "Complete the bounded proof",
  }
end

return {
  test_lean_toolchain_and_explicit_lean_deliverable_select_lean_proof = function()
    local profile = load_profile()
    local git = recording_git({ stdout = "blob\n", stderr = "", exit_code = 0 })

    local selected = profile.resolve(git, "refs/heads/proof-task", "Change `Proofs/Target.lean` only.")

    t.eq(selected, "lean-proof")
    t.eq(#git.calls, 1)
    t.eq(git.calls[1].ref, "refs/heads/proof-task")
    t.eq(git.calls[1].path, "lean-toolchain")
    t.eq(git.calls[1].timeout, 30)
  end,

  test_profile_stays_generic_unless_both_dispatch_facts_agree = function()
    local profile = load_profile()
    local lean_git = recording_git({ stdout = "blob\n", stderr = "", exit_code = 0 })

    t.eq(profile.resolve(lean_git, "refs/heads/docs-task", "Update the release notes."), "generic")
    t.eq(#lean_git.calls, 0)

    local non_lean_git = recording_git({
      stdout = "",
      stderr = "fatal: path 'lean-toolchain' does not exist in 'refs/heads/proof-task'\n",
      exit_code = 128,
    })
    t.eq(profile.resolve(non_lean_git, "refs/heads/proof-task", "Change Proofs/Target.lean only."), "generic")
    t.eq(#non_lean_git.calls, 1)

    local directory_git = recording_git({
      stdout = "tree\n",
      stderr = "",
      exit_code = 0,
    })
    t.eq(profile.resolve(directory_git, "refs/heads/proof-task", "Change Proofs/Target.lean only."), "generic")
    t.eq(#directory_git.calls, 1)
  end,

  test_lean_proof_prompt_requires_elaborator_first_bounded_edit_check_loop = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local framing = "Change `Proofs/Target.lean` only."
    local manifest = "UNTRUSTED-NOTICE.txt\nissue.json\nboard.txt"
    local generic = core.build_implement_prompt(proposal_id, issue(), framing, manifest)
    local explicit_generic = core.build_implement_prompt(proposal_id, issue(), framing, manifest, "generic")
    local proof = core.build_implement_prompt(proposal_id, issue(), framing, manifest, "lean-proof")

    t.eq(explicit_generic, generic)
    t.is_nil(generic:find("Implementation profile: `lean-proof`", 1, true))
    t.is_true(proof:find("Implementation profile: `lean-proof`", 1, true) ~= nil)
    t.is_true(proof:find("Inspect the target `.lean` source", 1, true) ~= nil)
    t.is_true(proof:find("actual goal or error state before editing", 1, true) ~= nil)
    t.is_true(proof:find("smallest bounded proof change", 1, true) ~= nil)
    t.is_true(proof:find("Rerun the same Lean checker", 1, true) ~= nil)
    t.is_true(proof:find("`scripts/run.sh test-affected`", 1, true) ~= nil)
  end,

  test_accepted_framing_rederives_exactly_from_durable_result_fact = function()
    local profile = load_profile()
    local framing = "Prove x < y in \"Proofs/Target.lean\".\nKeep 100% of the accepted scope."
    local accepted = h.reached({ framing = framing })
    local request = requests_lifecycle.build_result_comment_request(core, "owner/repo", "42", accepted)
    local ready = payloads_builders.build_devloop_ready_payload(core, accepted)
    ready.framing = nil

    local resolved = profile.accepted_framing(ready, {
      {
        body = request.body,
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T01:02:03Z",
      },
    })

    t.eq(resolved, framing)
  end,
}
