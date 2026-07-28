local h = require("tests.devloop_helpers")

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
    show_file = function(ref, path, timeout)
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
    local git = recording_git({ stdout = "leanprover/lean4:v4.19.0\n", stderr = "", exit_code = 0 })

    local selected = profile.resolve(git, "refs/heads/proof-task", "Change `Proofs/Target.lean` only.")

    t.eq(selected, "lean-proof")
    t.eq(#git.calls, 1)
    t.eq(git.calls[1].ref, "refs/heads/proof-task")
    t.eq(git.calls[1].path, "lean-toolchain")
    t.eq(git.calls[1].timeout, 30)
  end,

  test_profile_stays_generic_unless_both_dispatch_facts_agree = function()
    local profile = load_profile()
    local lean_git = recording_git({ stdout = "leanprover/lean4:v4.19.0\n", stderr = "", exit_code = 0 })

    t.eq(profile.resolve(lean_git, "refs/heads/docs-task", "Update the release notes."), "generic")
    t.eq(#lean_git.calls, 0)

    local non_lean_git = recording_git({
      stdout = "",
      stderr = "fatal: path 'lean-toolchain' does not exist in 'refs/heads/proof-task'\n",
      exit_code = 128,
    })
    t.eq(profile.resolve(non_lean_git, "refs/heads/proof-task", "Change Proofs/Target.lean only."), "generic")
    t.eq(#non_lean_git.calls, 1)
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
}
