local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local requests_lifecycle = require("devloop.requests.lifecycle")
local projected_transitions = require("tests.projected_transition_helpers")

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

    local selected, target = profile.resolve(git, "refs/heads/proof-task", "Change `Proofs/Target.lean` only.")

    t.eq(selected, "lean-proof")
    t.eq(target, "Proofs/Target.lean")
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

  test_lean_target_resolver_rejects_non_actionable_path_mentions = function()
    local profile = load_profile()
    local cases = {
      "Document the `.lean` extension.",
      "Change Proofs/Target.lean.bak only.",
      "Change https://example.com/Proofs/Target.lean only.",
      "Change ../Proofs/Target.lean only.",
      "Change /Proofs/Target.lean only.",
      "Change Proofs/Target.leanSuffix only.",
    }

    for _, framing in ipairs(cases) do
      local git = recording_git({ stdout = "blob\n", stderr = "", exit_code = 0 })
      local selected, target = profile.resolve(git, "refs/heads/proof-task", framing)
      t.eq(selected, "generic", framing)
      t.eq(target, nil, framing)
      t.eq(#git.calls, 0, framing)
    end
  end,

  test_lean_target_resolver_requires_framing_and_fails_loud_on_unexpected_git_error = function()
    local profile = load_profile()
    local absent = recording_git({ stdout = "blob\n", stderr = "", exit_code = 0 })
    local selected, target = profile.resolve(absent, "refs/heads/proof-task", nil)
    t.eq(selected, "generic")
    t.eq(target, nil)
    t.eq(#absent.calls, 0)

    local failed = recording_git({ stdout = "", stderr = "fatal: object database unavailable\n", exit_code = 128 })
    local ok, err = pcall(profile.resolve, failed, "refs/heads/proof-task", "Change Proofs/Target.lean only.")
    t.eq(ok, false)
    t.is_true(tostring(err):find("implement-profile-source-type-read-failed", 1, true) ~= nil)
  end,

  test_lean_proof_prompt_requires_elaborator_first_bounded_edit_check_loop = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local framing = "Change `Proofs/Target.lean` only."
    local manifest = "UNTRUSTED-NOTICE.txt\nissue.json\nboard.txt"
    local result_context = {
      implementation_version = "ready/consensus-github-devloop/issue/owner/repo/42/implementation",
      attempt = 1,
    }
    local generic = core.build_implement_prompt(proposal_id, issue(), framing, manifest, nil, result_context)
    local explicit_generic = core.build_implement_prompt(
      proposal_id, issue(), framing, manifest, "generic", result_context)
    local proof = core.build_implement_prompt(proposal_id, issue(), framing, manifest, "lean-proof", {
      target = "Proofs/Target.lean",
      phase = "construction",
      attempt = 1,
      implementation_version = result_context.implementation_version,
      timeout_seconds = 7200,
    })

    t.eq(explicit_generic, generic)
    t.is_nil(generic:find("Implementation profile: `lean-proof`", 1, true))
    t.is_true(generic:find("github-devloop.implementation-result.v1", 1, true) ~= nil)
    t.is_true(generic:find(result_context.implementation_version, 1, true) ~= nil)
    t.is_true(generic:find("`precursor-missing`", 1, true) ~= nil)
    t.is_true(generic:find("`wrong-layer`", 1, true) ~= nil)
    t.is_true(generic:find("`already-satisfied`", 1, true) ~= nil)
    t.is_nil(generic:find("`scope-mismatch`", 1, true))
    t.is_true(proof:find("Implementation profile: `lean-proof`", 1, true) ~= nil)
    t.is_true(proof:find("Inspect the target `.lean` source", 1, true) ~= nil)
    t.is_true(proof:find("actual goal or error state before editing", 1, true) ~= nil)
    t.is_true(proof:find("smallest bounded proof change", 1, true) ~= nil)
    t.is_true(proof:find("Target: `Proofs/Target.lean`", 1, true) ~= nil)
    t.is_true(proof:find("Construction phase", 1, true) ~= nil)
    t.is_true(proof:find("helper-lemma plan", 1, true) ~= nil)
    t.is_true(proof:find("one named unresolved lemma at a time", 1, true) ~= nil)
    t.is_true(proof:find("mathlib search", 1, true) ~= nil)
    t.is_true(proof:find("coherent checkpoint", 1, true) ~= nil)
    t.is_true(proof:find("`sorry` or `admit`", 1, true) ~= nil)
    t.is_true(proof:find("github-devloop.lean-proof-result.v1", 1, true) ~= nil)
    t.is_true(proof:find("7200 seconds", 1, true) ~= nil)
    t.is_true(proof:find("Rerun the same Lean checker", 1, true) ~= nil)
    t.is_true(proof:find("`scripts/run.sh test-affected`", 1, true) ~= nil)
  end,

  test_strong_repair_prompt_uses_prior_exact_obligation_and_evidence = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local proof = core.build_implement_prompt(proposal_id, issue(), "Change Proofs/Target.lean only.",
      "UNTRUSTED-NOTICE.txt\nissue.json\nboard.txt", "lean-proof", {
        target = "Proofs/Target.lean",
        phase = "strong-repair",
        attempt = 2,
        implementation_version = "ready/consensus-github-devloop/issue/owner/repo/42/reimplement/2",
        timeout_seconds = 7200,
        prior_receipt = {
          declaration = "target_theorem",
          checker_command = "lake env lean -E hasSorry Proofs/Target.lean",
          last_obligation = "target_theorem: unsolved goals\ncase h => False",
          attempted_approaches = { "simp", "exact helper_lemma" },
          search_summary = "performed: Nat.succ_eq_add_one",
          remaining_blocker = "helper_lemma still needs the monotonicity premise",
        },
      })

    t.is_true(proof:find("Strong repair phase", 1, true) ~= nil)
    t.is_true(proof:find("target_theorem: unsolved goals\ncase h => False", 1, true) ~= nil)
    t.is_true(proof:find("simp; exact helper_lemma", 1, true) ~= nil)
    t.is_true(proof:find("performed: Nat.succ_eq_add_one", 1, true) ~= nil)
    t.is_true(proof:find("helper_lemma still needs the monotonicity premise", 1, true) ~= nil)
    t.is_true(proof:find("Do not restart from the whole theorem", 1, true) ~= nil)
  end,

  test_accepted_framing_rederives_exactly_from_durable_result_fact = function()
    local profile = load_profile()
    local framing = "Prove x < y in \"Proofs/Target.lean\".\nKeep 100% of the accepted scope."
    local accepted = h.reached({ framing = framing })
    local request = projected_transitions.result_comment(core, "owner/repo", "42", accepted)
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
