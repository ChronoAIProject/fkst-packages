# libraries/devloop ambient-M dissolution — endpoint and proven floor

This documents the honest end state of the `libraries/devloop` ambient-`M` (god-table)
dissolution: what was dissolved, what the two ratchets measure, and what the proven residual
floor is (and why it is not god-table coupling). It is the adversarially-built SPEC (sshx
thinking-triplet + ChatGPT Pro cross-model) referenced by the standing dissolution goal, written
as prose so the classification stays auditable and greppable.

**Scope of the claim (do not overstate).** The ambient-`M` god-table had **two** coupling shapes,
and **both are now dissolved**: the copy-onto-`M` **facade** (`M.fn = mod.fn`, measured by
`G-DEVLOOP-DECOUPLE`, driven 659 → 27) and the **`install(M)` composed-core** ambient reads
(`core.log_raise(...)` etc., measured by `G-DEVLOOP-INSTALLER`, driven **1091 → 45**). The
`install(M)` modules (`devloop.state`, `devloop.logging`, `devloop.commands`) **still exist as
normal declared libraries**, but departments now reach them through explicit
`require("devloop.<mod>").fn(...)` rather than through the ambient composed `M`. The honest
headline is "**the ambient-M god-table is dissolved (facade + install(M) composed-core); the
residual floor is measurement-artifact + dependency-injection, not ambient god-lib**", never
"installer = 0" unqualified — the ratchet floor is 45, and that 45 is proven to be non-coupling.

## Two ratchets, two coupling shapes — both dissolved

1. **Copy-onto-M facade** (`G-DEVLOOP-DECOUPLE`, "Metric B"): a package core wrote
   `M.fn = devloop_mod.fn` and departments read `core.fn(...)`. Driven **659 → 27** across PRs
   #1777–#1807. The residual 27 is 25 non-devloop name-collisions + 2 `linked_pr_surface_snapshot`
   kernel-consumers (see the git history of this file for the per-symbol breakdown).

2. **`install(M)` composed-core** (`G-DEVLOOP-INSTALLER`, `scripts/check_repo_devloop_installer.py`):
   `require("devloop.<mod>").install(M)` defined `function M.<name>` inside the installer, and
   departments read `core.log_raise(...)` / `core.current_state(...)` — genuine ambient god-table
   coupling no explicit `M.name=` binding existed for, invisible to the facade ratchet. Driven
   **1091 → 45** by self-containing each module (module-level `C` functions + a loop-binding
   `install(M)` compat scaffold) and rewiring department readers to `require("devloop.<mod>").X`:

   - **logging** (PRs #1811, #1813, #1816): pure-helpers, then observable-effect
     (`log_raise`/`log_cas_decision`/`log_apply`/`log_line`), then the completion slice
     (`payload_field`, `log_forged_markers` self-contained via `require("devloop.base")` for the
     parsers_misc base-constants, `log_error_fact`, `error_class_from_message`, `log_entry`).
   - **state** (PR #1814 + the state-remainder slice): the version-CAS lifecycle surface
     (`cas_outcome`, `stage_rank`, `current_state`, …, plus `has_label`, `is_state_label`).
   - **commands** (PR #1815): the git/GitHub egress submodules
     (`git_ops`/`prs`/`issue_reads`/`observe_lists`) self-contained behind an aggregate facade;
     egress still routes through the M-free `support.git()`/`support.github()` = `forge` adapters.

## The proven floor: 45 = 27 name-collision + 18 DI-param (not god-table coupling)

`G-DEVLOOP-INSTALLER` counts `(core|M).<sym>(` where `<sym>` is any installer symbol name. At 45
the remaining reads were classified per-symbol by **binding source**; none are ambient composed-core
god-table reads:

- **27 name-collision artifacts.** Flat / non-devloop packages define their OWN same-named
  symbol, and the ratchet counts the read only because the *name* matches a devloop installer
  symbol. Proven by binding source: `github-proxy` / `github-external-pr-intake` /
  `github-ratchet-migration-slicer` each define their own `function M.log_line` (12),
  `log_error_fact` (3), `log_entry` (2), `error_class_from_message` (2), `gh_issue_comment` /
  `gh_pr_comment` (flat), `error_fingerprint` (`contract.error_facts`), `wrap_pipeline_failure`,
  etc. These are NOT `libraries/devloop` reads — rewiring them to `require("devloop.…")` is wrong
  (it adds an undeclared `devloop` dependency to a flat package). This is a measurement artifact,
  the exact analogue of the facade ratchet's documented 25 name-collisions.

- **18 dependency-injection points.** A function receives the composed core as an **injected
  parameter** (`function M.require_evidence(core, …)`) or references a sibling composed-core method
  via **M-self-reference**, and its test injects a *fake* core to stub the dependency
  (`high_risk_merge_gate`, `merge_executor`, the observability census/scoreboard/reaper/bounds).
  The reads are `gh_pr_view_observe`, `gh_issue_view_observe`, `gh_*_observe_opts`, `gh_pr_comment`,
  `gh_pr_ready`, `gh_pr_diff_name_only`, `gh_pr_close`, `gh_pr_create_body`,
  `gh_*_list_recent_*`, `payload_field`, `log_forged_markers`. This is legitimate **dependency
  injection**, not the god-table anti-pattern: the handle arrives explicitly as an argument and is
  fake-injected under test. Rewiring the call-site to `require("devloop.…")` would bypass the
  injected fake and break the test. Eliminating these would require a per-site **test-pattern
  change** (patch the module under test instead of injecting a fake core) — a separate,
  test-style scope, not further god-lib decoupling.

## Endpoint

The ambient-`M` god-table is dissolved on both axes: the copy-onto-`M` facade (659 → 27) and the
`install(M)` composed-core ambient reads (1091 → 45). The `devloop.state` / `devloop.logging` /
`devloop.commands` capabilities remain as **explicitly-required libraries** — departments call
`require("devloop.<mod>").fn(...)`, not an ambient composed `M`. The `G-DEVLOOP-INSTALLER` floor of
45 is **proven per-symbol** to be 27 flat-package name-collision artifacts (documented, the
ratchet over-counts by name) plus 18 dependency-injection points (composed core injected as a
test-fake parameter / self-reference — legitimate DI, eliminable only by a per-site test-pattern
change). **Genuine ambient-M god-lib coupling is eliminated; the residual is measurement-artifact
+ dependency-injection, not ambient god-lib.** Do not report this as "installer = 0" — report it
as the proven floor above.

⟦AI:FKST⟧

## The `install(M)` removal condition (measured 2026-08-05 — read this before deleting a scaffold)

`libraries/devloop/{commands,logging,state}.lua` each expose an `S.install(M)` migration scaffold.
Their comments used to say the scaffold is deleted "once the G-DEVLOOP-INSTALLER ratchet shows zero
reads through the ambient M". **That condition is wrong and following it breaks the library at
runtime.**

`scripts/check_repo_devloop_installer.py` scans `root/packages/<pkg>` only. It never looks at
`libraries/`. But `libraries/devloop` reads those ambient symbols itself — measured: one read each
for `gh_issue_list_observe_opts`, `gh_pr_view_freshness`, `gh_pr_view_observe`, `log_raise`,
`log_line`, `log_error_fact`. Removing `require("devloop.commands").install(M)` from a package core
whose ratchet count was already zero produced:

```
libraries/devloop/entity_list_cache.lua:302: attempt to call a nil value (field 'gh_issue_list_observe_opts')
libraries/devloop/entity.lua:143:            attempt to call a nil value (field 'gh_pr_view_freshness')
```

`check_repo` stays green through all of it; only the full Lua suite catches it.

**The real removal condition** is therefore: the ratchet is zero for **every** package **and** an
exhaustive grep of `libraries/` finds no `M.<symbol>` / `core.<symbol>` read of anything that
installer provides.

This is the third scoping defect found in that one ledger, each surfaced only by trying to *act* on
its number — #3162 removed 25 cross-package false attributions, #3178 stopped counting function
definitions as reads, and this one is the library-side blind spot. A gate's number is only validated
when someone tries to use it.

### A note on why these two comments are exactly as long as they were

`migration/library-error-class.allowlist` keys debt by `path:line`, and the gate is shrink-only
against dev. Adding even one comment line above an `error()` moves it, the old entry goes stale, and
updating the entry is then reported as *growing* the allowlist. So a comment edit in a library file
carrying ledger entries must preserve the line count — which is why the corrected comments are
one-for-one replacements and the detail lives here instead. The campaign spec rejected re-keying that
ledger on cost grounds (§1.3 of `docs/superpowers/specs/2026-08-04-refactor-campaign-spec.md`); this
is what paying that cost looks like in practice.

## What `G-DEVLOOP-SERVICE-LOCATOR`'s 494 contains (measured 2026-08-06)

The analogous binding-source measurement for `G-DEVLOOP-SERVICE-LOCATOR` was run at commit
`fc89acdd32b4b24acfe00cf501e72dcd97a87685`. The result does **not** support treating all 494
`core.<member>` matches as reads from the `libraries/devloop` ambient god-table. Only 37 actual
table-access matches bind to a symbol installed from `libraries/devloop`; 446 are package-owned
matches, including the non-read lexical matches detailed below. The requested three-way split is
not exhaustive: another 8 bind to declared `libraries/forge` installers, and 3 have no binding in
the owning package's composed core.

### Reproduction method: classify the final binding, not the name

The measurement imported `scripts/check_repo_service_locator.py` and used its
`_department_files(root)` iterator and `_CORE_MEMBER` regex directly. This reproduces the ratchet's
exact file exclusions and lexical matches; an assertion required the enumerated occurrence count to
equal `counts(root)["department_core_member_reads"] == 494`.

For each package that owned at least one occurrence, an isolated Lua process loaded that package's
`core.lua`. The process replaced only the newly-created `M` table with a proxy whose `__newindex`
and `rawset` paths recorded `(member, source file, source line)` for every assignment. The proxy
preserved `__index`, `pairs`, and assignment behavior. This captured direct `M.x = ...`,
`function M.x`, loop-based installers, package `core/` submodule installers, and
`require("devloop.X").install(M)` in execution order. Classification used the **last recorded
assignment**: a source under the owning `packages/<pkg>/core.lua` or `core/` is (a), and a source
under `libraries/devloop/` is (b). The available standalone interpreter was Lua 5.5, so the trace
performed a same-line, in-memory local-variable rewrite at the repository's four pre-5.5
generic-for mutation sites; no repository source was changed. Two complete runs produced
byte-identical per-occurrence ledgers.

The ratchet regex is lexical rather than an AST read query. Its 494 matches are 444 table-access
spellings, 33 strings inside `require("core.<submodule>")`, 16 `function core.<member>` definition
writes, and one comment (`github-devloop-worktree-gc/departments/worktree_gc/main.lua:6`). The
submodule strings are package-local module paths, so they are (a), not table reads. The 16
definition writes, and the later accesses to those definitions, are package-owned observability
installers; `packages/github-devloop-ops/departments/observability/main.lua:54-58` establishes their
installation order before the pipeline uses them.

The complete per-symbol ledger records each occurrence, final source line, and overwrite history.
The aggregate is:

| Package | (a) package-owned | (b) `libraries/devloop` install | (c) same-name ambiguous | Other: `forge` install | Unbound | Total |
|---|---:|---:|---:|---:|---:|---:|
| `archaudit` | 23 | 0 | 0 | 0 | 0 | 23 |
| `autochrono` | 23 | 0 | 0 | 0 | 0 | 23 |
| `fkst-substrate-ref-maintainer` | 1 | 0 | 0 | 0 | 0 | 1 |
| `github-autochrono` | 2 | 0 | 0 | 0 | 0 | 2 |
| `github-devloop` | 55 | 19 | 0 | 0 | 2 | 76 |
| `github-devloop-decompose` | 10 | 1 | 0 | 1 | 0 | 12 |
| `github-devloop-intake` | 7 | 0 | 0 | 0 | 0 | 7 |
| `github-devloop-integration` | 70 | 1 | 0 | 3 | 0 | 74 |
| `github-devloop-ops` | 108 | 0 | 0 | 2 | 0 | 110 |
| `github-devloop-pr` | 22 | 16 | 0 | 2 | 1 | 41 |
| `github-devloop-worktree-gc` | 1 | 0 | 0 | 0 | 0 | 1 |
| `github-external-pr-intake` | 50 | 0 | 0 | 0 | 0 | 50 |
| `github-proxy` | 39 | 0 | 0 | 0 | 0 | 39 |
| `github-ratchet-migration-slicer` | 13 | 0 | 0 | 0 | 0 | 13 |
| `idle-detector` | 5 | 0 | 0 | 0 | 0 | 5 |
| `integration-coverage-producer` | 15 | 0 | 0 | 0 | 0 | 15 |
| `marketing-radar` | 2 | 0 | 0 | 0 | 0 | 2 |
| **Total** | **446** | **37** | **0** | **8** | **3** | **494** |

### Category details

**(b), the measured target: 37 occurrences.** These final bindings come from
`devloop.prompts`, `devloop.restart`, `devloop.liveness`, and
`devloop.restart.pr_review_replay_facts`:

- `github-devloop` (19): `build_implement_prompt` (2), `fixing_version_matches_link` (2),
  `liveness_timeout_decision_with_facts` (1), `liveness_timeout_due_with_facts` (1),
  `maybe_timeout_redrive_from_table` (2), `restart_observe_replay_due` (1),
  `restart_observe_timeout_due` (1), `restart_row_liveness_signal` (1),
  `restart_row_observable_on` (2), `restart_row_receiver_liveness` (1), and
  `restart_transition_table` (5).
- `github-devloop-decompose` (1): `build_decompose_prompt`.
- `github-devloop-integration` (1): `build_sync_conflict_prompt`.
- `github-devloop-pr` (16): `build_fix_prompt`, `build_review_meta_prompt`,
  `fixing_replay_feedback_fact`, `liveness_timeout_decision_with_facts`,
  `liveness_timeout_due_with_facts`, `maybe_timeout_redrive_from_table`,
  `parse_review_meta_action`, `restart_row_liveness_signal`, and `restart_row_observable_on`
  (one each), `restart_row_receiver_liveness` (2), and `restart_transition_table` (5).

**(c), explicit ambiguous list: none.** No counted access had both an owning-package assignment and
a `libraries/devloop` assignment in its write history. Assignment order therefore resolved every
observed same-table write; there is no residual name-collision bucket to estimate.

**The 8 `forge` bindings, outside the requested trichotomy.** These are
`with_github_debug_stamp` (3), `evaluate_ci_merge_gate` (2), `run_verified_pr_merge` (1),
`merge_gate_reason_class` (1), and `merge_gate_reason_requires_pr_merge_product` (1). Their final
sources are `libraries/forge/github_debug_stamp.lua`, `libraries/forge/merge/ci_gate.lua`, and
`libraries/forge/merge/verified_merge.lua`. They are not `libraries/devloop` ambient bindings and
are not package definitions, so reporting them as either (a) or (b) would falsify the binding
source.

**The 3 unbound accesses, also outside the trichotomy.** No assignment was observed during the
owning package's core construction, and no same-package `core/` assignment exists for
`github-devloop`'s `core.terminal_linked_pr_action` reads at
`departments/observe_issue/main.lua:143,150` or `github-devloop-pr`'s `core.dependency_gate` read at
`departments/reconcile/main.lua:549`. This measurement records only that binding fact; it does not
infer runtime reachability or diagnose behavior.

### Implication for the ratchet

Do not drive the raw 494 to zero and call that ambient-`M` dissolution. Doing so would require
removing or renaming sanctioned package-local `core.lua` APIs, package `core/` submodule imports,
package-owned department installers, and declared `forge` capabilities. It would also treat 50
non-read lexical matches as service-locator reads. The binding-source target represented by this
counter is the measured (b) subset, **37 at the pinned commit**, not 494. The raw ratchet remains a
useful shrink-only inventory, but its number is not a valid measure of ambient-devloop coupling
without this composition attached.

⟦AI:FKST⟧
