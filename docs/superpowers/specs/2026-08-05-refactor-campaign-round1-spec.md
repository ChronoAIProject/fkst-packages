# Refactor campaign — round 1: what the ledgers actually say, and what to do first

Status: accepted. Produced by a six-seat sshx thinking panel (`teleology`, `parsimony`,
`fidelity`, `natural-ownership`, `proportional-containment`, `worth`) over raw measurements
of `integration-elonsg@3a81fb51`, converged by the meta-judge. Every seat verified the
ledgers independently against their owning checkers before ranking.

The campaign goal is a sustained, behaviour-preserving refactor: eliminate redundancy,
refine the code, work in priority order. **Refactoring is behaviour-preserving by
definition** — any change to observable behaviour is not a refactor and needs its own
argument and review.

## 1. The counting correction (the panel's main finding)

A `migration/` ledger's line count is not a debt count. All six seats opened each ledger
and its owning checker; they converged on the same classification. Ranking by raw magnitude
would have put the three largest artifacts first, and all three are **not debt**.

| artifact | lines | what an entry actually asserts | debt? |
| --- | ---: | --- | --- |
| `restart-lifecycle.inventory.json` | 50585 | self-hashed frozen OLD-behaviour parity corpus, 532 observations, zero unobserved sites | **no — evidence** |
| `github-devloop-saga-split.inventory` | 261 | one ownership classification per governed path; the paired authority allowlist is empty | **no — classification** |
| `monotone-gate.allowlist` | 96 | every row reads `classified current routing/decision read; migrate only when it is a monotone milestone gate` | **no — classification** |
| `lower-injected-m.inventory` | 85 | 30 reads / 17 unique symbols with a route+owner manifest, declared zero target | **yes** |
| `devloop-installer.inventory` | 37 | 5 current reader sites, all in `github-devloop-pr` | **no — see §2** |
| `gh-handle-construction.inventory` | 29 | 29 manual rows with **no owning checker** | **not enforceable** |
| `dept-failure-surface.allowlist` | 11 | 11 departments with neither retry nor `wrap_pipeline_failure` | real, but **not a refactor** |
| `devloop-godlib` / `ambient-surface` / `core-param` / `service-locator` | 9/4/4/4 | 2–4 *metrics* each, not per-line debts | **yes, as metrics** |
| `producer-liveness.allowlist` | 6 | 6 raisers without positive trace assertions | real, but a test gap |
| `library-error-class.allowlist` | 1 | the one runtime-correct, statically-invisible envelope | **no — deliberate** |

Ten allowlists (`code-dedup`, `content-truncation`, `gh-git-adapter`, `hidden-state`,
`integration-edge-coverage`, `live-run-dispatch`, `monotone-gate-dsl`,
`prompt-external-fetch`, `request-reply-message`, `saga-handler`, `saga-split-authority`,
`devloop-decouple-kernel`) hold zero active entries and their checkers pass.

## 2. Why the installer / godlib / decouple counters are already at their floor

Two seats proposed rewiring the five `github-devloop-pr` reader sites
(`core.gh_pr_diff_name_only`, `core.gh_pr_ready`, `core.gh_pr_comment`,
`core.log_forged_markers`, `core.payload_field`) to direct `require("devloop.commands")`
calls. The containment seat rejected it, and the repository's own
`docs/devloop-decouple-endpoint.md` settles it: those sites receive the composed core as an
**explicitly injected parameter** whose test supplies a fake
(`integration_high_risk_merge_gate_test.lua:120` passes `fake_core`), so a direct require
would bypass the fake and break the test. The same document states the endpoint outright:
*"Genuine ambient-M god-lib coupling is eliminated; the residual is measurement-artifact"* —
27 flat-package name collisions plus 18 legitimate DI points — and that *"a zero
`G-DEVLOOP-INSTALLER` count is NOT the removal condition."*

Driving these counters down is counter-gaming. Four of six seats named it in their
do-not-do lists independently.

## 3. Priority order

1. **Re-tighten the three slack ratchets** (§4). Cheapest, zero behaviour risk, and it
   restores enforcement that is currently absent.
2. **Extract the legacy command-renderer concept out of `libraries/testkit_internal/gh_argv_mock.lua`** (§5).
3. **Dissolve `lower-injected-m`**: 30 reads / 17 symbols where `libraries/workflow_internal`
   and `libraries/forge` read a composed facade passed in as a parameter. Unlike §2 this is a
   genuine dependency-direction violation — a lower library reading product behaviour through
   a late-bound table — and the manifest already names a typed route and owner per symbol.
   Deferred to round 2 because each symbol needs its own typed seam.

Not scheduled, with reasons:

- **`dept-failure-surface` (11) and `producer-liveness` (6)** are real gaps, but adding
  retry/`wrap_pipeline_failure` changes observable error facts, ACK and DLQ behaviour. That
  is a behaviour change and must not travel under a refactor label. File separately.
- **The 800–899 line band (18 files)** stays. No mixed-responsibility defect was established
  in any of them; splitting for size alone optimises the proxy and not the code.
- **`gh-handle-construction` (29) and `gh-authorpolicy-fixture`** have no owning checker.
  Give them one first, or their counts are not evidence of anything.
- **`markers/shared.lua:81`**, the single `library-error-class` row: its runtime class is
  already correct. The panel independently reached the ruling already recorded in the
  allowlist header.

## 4. Item 1 — the ratchets are slack

Measured with each checker's own `counts()` against its own `baseline()`:

| ratchet | recorded baseline | current | slack |
| --- | --- | --- | ---: |
| `service-locator.inventory` `department_core_member_reads` | 520 | 500 | 20 |
| `core-param.inventory` `library_core_params` | 149 | 148 | 1 |
| `core-param.inventory` `dept_core_arg_call_sites` | 132 | 127 | 5 |
| `devloop-godlib.inventory` `m_writes` | 167 | 165 | 2 |

`ambient-surface.inventory` is in sync at 24 / 169.

Every drift is in the improved direction, which is exactly why it is dangerous: a
shrink-only ratchet whose baseline sits above the current measurement **is not ratcheting**.
Twenty new `core` member reads could land today with CI green.

The fix is to record the current measurement as the new baseline. It changes no code.

**Non-vacuity is part of the deliverable.** Recording a baseline that happens to match today
proves nothing; the change must be shown to restore enforcement. For each refreshed
counter, introduce one additional occurrence in a scratch copy and demonstrate the checker
goes red at the new baseline where it stayed green at the old one.

## 5. Item 2 — `gh_argv_mock.lua`, split along the seam a retirement would cut

`libraries/testkit_internal/gh_argv_mock.lua` is 950 lines, the only file over the 900-line
soft threshold, with 32 consumers.

The panel clashed here, and the clash is the locus dyad in its pure form. `teleology` and
`parsimony` want the legacy renderer concept **retired** — splitting it, they argue,
preserves the duplicate compatibility grammar that produced the size. `proportional-containment`
and `worth` refuse the retirement: 32 consumers establish shared ownership, a 14-root
migration of 342 references is not the cheapest sufficient repair, and it cannot be done
without behaviour risk.

**Resolution: the split is not an alternative to the retirement, it is its precondition — if
and only if it is cut along the seam the retirement would later cut.** Extract the legacy
command-renderer concept (the legacy command builders, `install_legacy_command_renderers`,
and the entity command renderers) into its own `testkit_internal` module, behind the
**unchanged** seven-key public facade `{argv_rendered, call_rendered, call_contains,
argv_contains, argv_value_after, count_calls, install}`. Ownership gets the duplicate
grammar isolated into one deletable unit; containment gets a library-local, behaviour-
preserving change with no consumer touched. A later retirement becomes a deletion rather
than a dissection.

The justification is the mixed responsibility, not the line count. Splitting this file to
get under 900 would be the same proxy optimisation the panel rejected for the 800–899 band.

**Behaviour preservation proof, before any edit**: a characterization capture that
serializes, in stable order, the exact public key set, the output of every public matcher
over a frozen table of quoted and unquoted `gh` and `git` calls, and every pattern
registered by `install`. The capture must be byte-identical before and after.

## 6. Meta-judge convergence

```
                     GoalArtifact: week-long behaviour-preserving refactor
                                          |
        +---------------------------------+---------------------------------+
        |                                 |                                 |
  [raw counters]                    [gh_argv_mock 950]                [ambient M/core]
        |                                 |                                 |
  fidelity --------- agree ------- proportional-containment          parsimony
        | verified: 3 of the                 |  "internal split is             | "delete the
        | largest are evidence,              |   cheapest sufficient"          |  concept"
        | not debt                           |                                 |
        |                              conflict                          conflict
        |                                    |                                 |
  teleology "counters are not the     teleology + parsimony            natural-ownership
   purpose" ------ agree              "retire the duplicate             "typed owner, not
        |                              grammar"                          ambient core"
        |                                    |                                 |
        +--> resolved-by: §1 table    resolved-by: §5 split along      resolved-by: §2 —
             (rank by verified         the retirement seam; split       repo's own endpoint
             semantics, never          is precondition, not             doc refutes the
             magnitude)                alternative                      premise; NOT debt
                                              |                                 |
   worth --- agree: §4 first (cheapest, restores enforcement),   worth --- agree: not worth
             §5 second (bounded, library-local),                          counter-gaming a
             §3.3 deferred (needs a typed seam per symbol)                proven floor
                                              |
                                     converges-to: §3 order
```

Every conflict edge is resolved by evidence, not by splitting the difference: the
ownership/containment clash on `gh_argv_mock` resolves into a single plan that satisfies
both poles, and the ambient-core clash resolves against the two seats that raised it
because the repository already ruled on it and the test at
`integration_high_risk_merge_gate_test.lua:120` demonstrates it.

The `worth` seat's judgment is satisfied without rebuttal: item 1 is near-zero cost and
restores lost enforcement; item 2 is bounded, library-local, and characterization-gated;
the expensive candidates are deferred or rejected above.

⟦AI:FKST⟧
