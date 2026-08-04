# Refactor Campaign Spec — 2026-08-04 adversarial round

Status: ACTIVE
Scope: `fkst-packages` (Lua behaviour layer, workspace libraries, repository checkers, docs).
Out of scope: Rust engine work, which belongs to `fkst-substrate`.

## 0. How this spec was produced, and what that does and does not license

Six isolated philosopher seats (`teleology`, `parsimony`, `fidelity`, `natural-ownership`,
`proportional-containment`, `worth`) each scanned the repository read-only and returned an
independent verdict without seeing any peer's output. They produced **42 candidate items and 52
explicit rejections**. The caller converged them and then ran its own falsifying experiments in a
throwaway worktree; those experiments, not the seat prose, are the evidence cited below.

Two honesty constraints on reading this document:

- **The panel was not model-diverse.** All six seats ran on one model family (`codex-cli`). A
  cross-model challenge was dispatched separately to a ChatGPT Pro oracle; where its objections
  changed an item, that is recorded inline. Correlated blindness across the six seats is therefore
  possible and is not ruled out by their agreement.
- **Seat agreement is not evidence.** Where seats agreed, the item still carries its own measured
  evidence. Where a seat's claim was checked and failed, it was dropped — see §6.

"No omissions" is satisfied by **every candidate having a disposition**, not by every candidate being
built. §6 is therefore a load-bearing part of this spec, not an appendix.

## 1. The most instructive defect — real, bounded, and deliberately not fixed

> The repository's newest ratchet identifies debt by **physical location** and **splits its rule by
> directory**. Both properties are wrong for what it measures. Draft 1 of this spec concluded they
> therefore blocked the campaign and made fixing them Tier 0. **Measurement says the blast radius is
> 2 files and one module move, and the cheap local workaround is ~100× smaller than the fix.**
> §1.1–1.2 establish the defect; §1.3 is why it is nevertheless rejected on cost. Read the two
> together — the defect being genuine is exactly what makes the worth judgement non-obvious.

`scripts/check_repo_error_class.py` records each unclassified `error()` call as `path:line`
(`:14-25`, `:44-64`) and maintains two separate ledgers with two different regimes:

| ledger | file | entries | regime |
|---|---|---|---|
| package | `migration/error-class.allowlist` | **file does not exist** | zero tolerance |
| library | `migration/library-error-class.allowlist` | **747** across 98 files | grandfathered, shrink-only |

### 1.1 Measured consequences

Both experiments were run on `dev@a4f7362e` in a detached throwaway worktree, baseline `exit=0`.

**E1 — a byte-identical move is rejected.** `git mv libraries/devloop/queue_starvation.lua
packages/github-devloop-ops/core/queue_starvation.lua`, content unchanged (`md5
7bf075e526b0b0fdaf988bb113575e72`), no other edit:

```
exit=1
G7: packages/github-devloop-ops/core/queue_starvation.lua:147 production error(...) string
    lacks a greppable class prefix and is not in migration/error-class.allowlist
G7: packages/github-devloop-ops/core/queue_starvation.lua:25  (same)
```

**E2 — one blank line manufactures 18 debts.** A single newline prepended to
`libraries/devloop/base.lua`; `error(` count unchanged at 18 before and after:

```
exit=1
18 × G-LIB-ERROR-CLASS: libraries/devloop/base.lua:{179,227,234,237,285,322,326,330,335,
                        649,657,668,685,693,729,732,738,851}
```

### 1.2 What this refutes

`72b7ee99` (#3140), landed 2026-08-04 20:18, states in its commit message:

> "This also unblocks de-hoisting library modules into packages. That move previously failed G7
> because library code carries errors a package may not — the blocker was never the module, it was
> the missing symmetry."

**E1 refutes this.** Recording the library debt did not unblock the move: the package ledger still
does not exist, so a moved file's grandfathered errors are judged as brand-new package debt. The
claim was never verified by its author. Any plan resting on "de-hoisting is now unblocked" is
resting on a false premise.

### 1.3 What this defect does NOT justify — the reversal

The first draft of this spec claimed the keying defect was the campaign's T0 prerequisite, because it
"blocks" the two highest-consensus items. **A cross-model oracle rejected that claim, and two
measurements confirmed the oracle.** The reversal is recorded here rather than quietly edited out,
because the falsified version is the more instructive artifact.

**Measurement R1 — the blast radius is 2 files, not 23.** Of the 23 files at or above the 900-line
threshold, exactly **two** carry any ledgered site: `libraries/devloop/base.lua` and
`libraries/testkit_internal/gh_argv_mock.lua`. The other 21 are unaffected by line motion, because
they hold no ledger entries at all. "Splitting files is blocked" was true of 2/23.

**Measurement R2 — the proposed key is neither complete nor injective.** Of the 747 sites: **537**
are a pure string literal, **198 (26.5%)** are `error("prefix: " .. value)` with no complete literal,
and 12 are other shapes. Across them, **64 literals are shared by more than one site, covering 232
sites (31%)**; `devloop.restart_edges: ` alone is the prefix of **15** distinct sites. Keying debt by
message literal would fuse 31% of the ledger into ambiguous buckets.

**Measurement R3 — the cheapest sufficient alternative is two orders of magnitude smaller.** The
de-hoist candidates carry: `restart/issue_observation_conformance.lua` **0** ledgered errors,
`queue_starvation.lua` **2**, `gate.lua` 29. So the single cleanest de-hoist (T1.6) was never blocked
at all, and the next one needs **two error strings classified** — not a 180–260 line checker rewrite
plus six characterization tests.

**Verdict: the keying defect is real and the fix is NOT worth its cost.** It is moved to §6 as row 21.
What survives from the oracle's own summary: line anchoring is refactor-hostile, and a
directory-sensitive grandfathering rule did obstruct one relocation. Both are handled locally and
cheaply, per T3.1 and §6 row 6, without touching the gate's ownership scoping. Merging the two
ledgers would additionally have **removed the packages-at-zero invariant** — the oracle's strongest
objection, and correct: under a repo-wide multiset, deleting a grandfathered library call silently
finances an unrelated package regression carrying the same generic message.

## 2. Tier 0 — repair the one trust root that survives

### T0.2 — Stop the count ratchets from accepting a self-raised ceiling
*Seat: `fidelity` (sole). Revised after cross-model review.* **BEHAVIOUR CHANGE (checker).**

- **Defect**: `check_repo_service_locator.py:49-74`, `check_repo_core_param.py:55-81` and five
  siblings load only the **current tree's** inventory and fail only when `current > inventory`. The
  inventory is an ordinary file in the same commit, so a change under judgment can raise its own
  ceiling and pass. `check_repo_runner.py:235-248` trusts seven such gates.
- **Beautiful form**: one typed count-ratchet helper that reads the current inventory and the
  inventory **at the pull request's merge base**, failing when `current != current inventory` (stale)
  and when `current inventory > merge-base inventory` (self-raised ceiling).
- **Revised after cross-model review — do NOT pin to the protected default branch.** The first draft
  said "protected dev base". The oracle objected that a categorical rule breaks stacked PRs, and this
  repository is exactly that topology: work lands on `integration-<device>` and only later rolls up
  to `dev`. A PR targeting `integration-elonsg` whose parent legitimately changed an inventory
  already on that branch would fail against `dev` forever. The comparison must therefore be against
  **the actual merge base of the PR's target**, and a reviewed baseline-change path must exist for
  legitimate recalibration rather than making increases categorically impossible.
- **Open, must be settled before implementing**: the oracle also noted the seven inventories may
  encode different invariants and may already be protected by review controls (CODEOWNERS, separate
  validation). That is unverified. **Verify per inventory before applying one blanket treatment**; if
  an inventory turns out to be a deliberately reviewed exception manifest, it is out of scope.
- **Parity gate**: controls proving equal/equal/equal passes; growth plus a same-PR inventory bump
  fails against merge base; shrink with a stale inventory fails; a stacked-PR fixture where the
  target branch legitimately carries a higher inventory than the default branch **passes**. No
  production Lua is touched.
- **Worth**: a detection mechanism must not be silently degradable, and a gate a PR can widen is
  already degraded. Contained, and the only item here that is a security property. The stacked-PR
  control is what keeps the repair from breaking the repository's own topology.

## 3. Tier 1 — independent deletions and single-sourcing

Each is separately verifiable and independently revertible. Order within the tier is free.

### T1.1 — Delete the unconsumed `workflow_internal.oracle` surface
*Seats: `teleology`, `proportional-containment`.* Behaviour-preserving.
Evidence: `rg -F 'workflow_internal.oracle'` returns exactly three hits — the manifest export, the
module, and its own self-test. 61 LOC module + 18 LOC tautological test.
Gate: **present-versus-absent differential** (see §5), exact export check green, `github-proxy` test
count drops by exactly the deleted tests.

### T1.2 — Delete six zero-consumer devloop aggregate facades
*Seats: `parsimony`, `proportional-containment`; flagged ASSUMED-UNVERIFIED by `natural-ownership`
and `worth`.* **BEHAVIOUR CHANGE** — removing exact public exports changes module resolution.
Evidence: a require census with `devloop.commands` as a positive control (59 hits) returns **0** for
`devloop.{convergence,markers,parsers,payloads,requests,validators}`; 46 lines total; exported at
`libraries/devloop/fkst.toml:{40,72,81,86,101,138}`.
Gate: the positive-control census must be reproduced, **plus a present-versus-absent differential**.
Two seats explicitly refused to treat static absence as inertness; that refusal is honoured — no
deletion without the differential.

### T1.3 — Delete the never-adopted DI capability projector
*Seat: `proportional-containment`.* Behaviour-preserving after census.
Evidence: `libraries/devloop/di/{providers,select_caps,capdefs}.lua` (337 LOC) exported at
`fkst.toml:47-49`, zero production requires. `worth` rated this "not-worth *now*" purely because
static absence is not inertness — the differential settles it either way.
Gate: production require census zero, then present-versus-absent differential, then full test.

### T1.4 — Delete 82 unreachable local functions
*Seat: `parsimony`.* Behaviour-preserving.
Evidence: `local function NAME` scan with in-file word counts returned `production=18 test=64
total=82`, ≈866 spanned lines.
Gate: freeze the 82-site list; after deletion the same scan must return 0 for those names, and
`rg '\bdebug\.(getlocal|getupvalue|setlocal|setupvalue)'` must confirm no reflective access could
reach them. Full suite green.

### T1.5 — Delete the superseded host-run delegation spec
*Seat: `parsimony`.* Docs only.
Evidence: the file declares `Status: SUPERSEDED`, points at the current ADR, and a repository search
for its own name returns no other reference. 149 lines.

### T1.6 — De-hoist `issue_observation_conformance` to its sole owner
*Seats: `fidelity`, `natural-ownership`, `proportional-containment`, `worth` (independent).*
Behaviour-preserving. **No dependency — measured: this module has ZERO ledgered error sites**, so E1
never applied to it. The first draft wrongly marked it as blocked by T0.1.
Evidence: 168 lines; exactly two requires — `packages/github-devloop/core/span_conformance.lua:3`
and one test in the same package; `migration/github-devloop-saga-split.inventory:63` already declares
`owner=issue`, so the code contradicts the repository's own ownership ledger.
Gate: byte-identical file body before the require-path edits; identical conformance results; ledger
path updated in the same commit; no peer cross-package require introduced.

### T1.7 — Single-source the byte-identical intake policy prompt
*Seat: `parsimony`.* Behaviour-preserving.
Evidence: identical checksum `2019499224 3948` for
`packages/github-devloop-intake-default/prompts/intake.lua` and
`packages/github-devloop-workflow/prompts/intake.lua`, 45 lines each. This is **admission policy
duplicated across a trust boundary** — the two copies can drift silently.
Gate: hash the rendered template and full prompt before/after and require byte equality.

### T1.8 — Single-source the duplicated 559-line entity-read test fixture
*Seat: `parsimony`.* Behaviour-preserving.
Evidence: identical checksum `623788598 21834` for the `entity_read_mock_helpers.lua` in both
`github-devloop-decompose` and `github-devloop-pr`; both manifests already declare
`testkit_internal`.
Gate: byte-identical generated fixture output for every exported helper; both suites green.

## 4. Tier 2 and Tier 3

### T2.1 — One Lua lexical primitive for the checkers
*Seats: `fidelity`, `natural-ownership`, `worth`, and `parsimony` (as the exact-mechanics subset).*
Behaviour-preserving.
Evidence: 8 `lua_code_mask`, 3 `lua_string_literals`, 5 `mask_span`, 4 byte-identical `block_delta`
bodies across `scripts/check_repo*.py`; `rg '\.find\(closer'` finds 11 sites — one canonical plus 10
reimplementations.
**Explicit non-goal**: the 18 same-named `load_allowlist` functions are *not* merged. A prior round
proved they share only a name and parse different typed grammars; only the four byte-identical bodies
were foldable and #3114 already folded them. All five seats that touched this agreed.
Gate: a frozen lexical corpus (escapes, equal-level long brackets, comments containing quote-like
text, unterminated literals) plus byte-equal sorted checker output repo-wide.

### T2.2 — Centralize dev-base retrieval, leave typed parsing local
*Seat: `natural-ownership`.* Behaviour-preserving.
Evidence: eight `allowlist_at_dev_base` definitions; seven repeat the same
try/`file_at_base`/present/parse/unresolved envelope.
Gate: per-checker table-driven tests for present / absent / unresolved base / valid / parse-failure,
asserting identical status and collection type.

### T2.3 — Scope the installer ratchet to each package's actual installer relation
*Seat: `proportional-containment`.* **BEHAVIOUR CHANGE (checker).**
Evidence: `check_repo_devloop_installer.py:65-82` unions symbols across *every* package core, then
scans that union against *every* package. Measured: recorded 43, package-scoped actual **18**,
false-attributed **25** (`github-proxy`=20 among them). The gate is 58% false attribution, so its
number cannot drive work.
Gate: a planted two-package fixture where only package A installs a symbol and both define
`core.log_line` — only A may count. Live repo must report 18 with distribution
`integration=1, ops=12, pr=5`.

### T3.1 — Split the 23 files at or above the 900-line threshold
*Seats: all except `teleology`'s narrower variant — the single strongest consensus of the round.*
Behaviour-preserving. **No dependency.** Measured: only 2 of the 23 files
(`libraries/devloop/base.lua`, `libraries/testkit_internal/gh_argv_mock.lua`) carry ledgered error
sites. For those two only, the split updates the affected `path:line` ledger entries **in the same
commit** — a mechanical, reviewable edit bounded by that file's entry count. The other 21 files need
nothing.
Evidence: `check_repo.py` exits 0 but emits exactly 23 `G1` warnings, 900–994 lines,
`files_ge_1000=0`. 18 test files, 5 production/tool files.
**Executed per owner, never as one change.** `natural-ownership` explicitly rejected a
single mega-change: the 23 files span 18 packages, two libraries and three scripts and share no
causal owner, so one commit would be unreviewable and would couple unrelated blast radii.
Gate per split: freeze the registered test-name set and exported module keys; require exact set
equality after; run that package's suite immediately; final `wc -l` sweep must return empty for
`>= 900`.
**Explicit non-goal**: the 71 files in the 800–899 band are *not* touched. The repository threshold is
900, and line count below it is not evidence of mixed responsibility. Three seats rejected the
blanket variant.

### T3.2 — Retire the remaining ambient `install(M)` scaffolds
*Seats: `teleology`, `parsimony`, `proportional-containment`, `worth`.* Mixed.
Evidence: `libraries/devloop/commands.lua:26-35` names its own binding a "Migration compat scaffold";
`logging.lua:201` and `state.lua:325` retain `install(M)`. The corrected causal census is **18 real
production reads** (`integration`=1, `ops`=12, `pr`=5) — *not* the 43 the current gate reports, which
is why **T2.3 must land first** or this work will be aimed at 25 sites that do not exist.
**Explicit non-goal**: driving all 520 core member reads to zero. `worth` rejected that: the 52
require sites span 18 packages and the checker cannot prove they are devloop-owned. Scope is the 18
verified installer reads plus deletion of the now-empty scaffolds.
Gate: per call site, characterize arguments, return value, raised effects and logs before rewiring;
installer census must go 18 → 0; `rg` for the removed `.install(M)` forms returns empty.

### T3.3 — Reconcile the ambient-migration documentation
*Seat: `worth`.* Docs only. Depends on T3.2.
Evidence: `docs/devloop-decouple-endpoint.md:9-18` says the ambient god-table is already dissolved,
while a later-committed design doc says the surface remains and targets deletion, and the code
carries a self-described compat scaffold. Three sources, two incompatible present-tense claims.

### T3.4 — Correct the constitution's fanout enforcement status
*Seat: `fidelity`.* Docs only.
Evidence: `CLAUDE.md:101` says the fanout checker is DESIGNED-NOT-YET-ENFORCED while `:498` says the
narrow known-dialogue ratchet is ENFORCED; the `:498` source citation points at a line that now
configures integration coverage. The constitution is the mandatory pre-action authority, so a stale
citation inside it misroutes every future reader.

## 5. The standing gate for every deletion

Campaign lesson, falsified three times already: **"unreferenced, therefore inert" is not a proof.**
Five of ten empty `migration/*.allowlist` files turned out to be load-bearing. Every deletion item in
this spec (T1.1, T1.2, T1.3, T1.5) is gated on a **present-versus-absent differential run** —
`check_repo` and the affected suites executed with the artifact present and absent, requiring
byte-identical output — never on a code reading. Two seats independently marked their own deletion
proposals `ASSUMED-UNVERIFIED` for exactly this reason; that mark is honoured here.

## 6. Explicitly not doing — with the reason

Every one of these was proposed by at least one seat, or is an obvious adjacent move, and is
**deliberately excluded**. This section is the "no omissions" ledger.

| # | Candidate | Disposition |
|---|---|---|
| 1 | Classify all 747 library errors now | **Rejected 5:1.** 747 sites carry 579 distinct *observable* literals; rewriting them is a behaviour change requiring per-class semantic review, and bundling it into a gate change makes the diff unreviewable. T0.1 makes the ledger honest; classification is a separate campaign. |
| 2 | Merge all 18 `load_allowlist` functions | **Rejected unanimously.** Name identity carried no information: each parses a different typed grammar. #3114 already folded the only four byte-identical bodies. |
| 3 | Split the 71 files in the 800–899 band | **Rejected.** The stated threshold is 900; sub-threshold size is not evidence of mixed responsibility. |
| 4 | One mega-commit for all 23 threshold files | **Rejected.** No shared causal owner across 18 packages + 2 libraries + 3 scripts; unreviewable and couples unrelated blast radii. Split per owner instead (T3.1). |
| 5 | De-hoist `devloop.gate` | **Deferred, not scheduled.** `proportional-containment` documents it enforcing a cross-saga positive-milestone capability, contradicting the single-owner reading. Genuine seat disagreement on the facts; not resolved by this round's evidence, so not scheduled. |
| 6 | De-hoist `devloop.queue_starvation` | **Available, cheaply — revised.** E1 blocks the naked move, but the module carries exactly **2** ledgered unclassified errors. Classifying those two strings (a small, separately-argued BEHAVIOUR CHANGE) unblocks the move. Not scheduled this round only because it is behind T1.6 in value, not because it is impossible. |
| 21 | **T0.1 — re-key error debt by semantic identity** (was Tier 0 in draft 1) | **Rejected on WORTH after cross-model review + 3 measurements.** The defect is real; the fix is not worth it. R1: blast radius is 2/23 files, not campaign-wide. R2: 26.5% of sites are concatenations with no complete literal and 31% fall in colliding buckets, so message identity is neither complete nor injective. R3: the cheapest sufficient alternative — classify 2 error strings, or update a bounded set of `path:line` entries in the splitting commit — is two orders of magnitude smaller. Merging the ledgers would also delete the packages-at-zero invariant. |
| 7 | Compress `migration/restart-lifecycle.inventory.json` (50,585 lines) | **Rejected.** It is frozen parity data with 44 verified references, not source. |
| 8 | Delete the "logically empty" migration ledgers | **Rejected as unproven.** No present-versus-absent differential was run; four have 6/11/4/14 literal references. Inertness stays ASSUMED-UNVERIFIED. |
| 9 | Retire `testkit_internal.gh_argv_mock` (950 lines) | **Not scheduled this round.** `natural-ownership` makes a real ownership case, but it rewires 28 package test files against a live pipeline. Cost is not justified while T0/T1 are open; revisit after T3.1 reduces the file. |
| 10 | Prune three unused `lib_deps` grants | **Not scheduled.** `natural-ownership` marked the same measurement ASSUMED-UNVERIFIED because dynamic requires are not covered. Cheap but unproven; needs the dynamic-require census first. |
| 11 | Tune "arbitrary-looking" constants (e.g. starvation thresholds 360/30) | **Rejected.** No measured failure proves them wrong. Changing them is a behaviour change wearing a refactor's clothes. |
| 12 | Bulk-prune design docs | **Rejected.** Age and directory are not obsolescence. Only the one file that declares itself SUPERSEDED is deleted (T1.5). |
| 13 | Relocate `libraries/devloop` wholesale | **Rejected.** It is a cohesive private product kernel with 133 modules and 116 consumed across 12 packages. The known defect is shared mutable `M`, addressed by T3.2 — not file location. |
| 14 | Consolidate the seven lifecycle declaration sites | **Rejected on prior verified evidence.** They are legitimate layered projections with different loadability and ordering contracts; cross-checks already landed in #3111/#3117. |
| 15 | Delete `old_behavior*` test assets by name | **Rejected.** Filename wording is not evidence; they are live parity/golden assets with many imports. |
| 16 | Hard-enable Lua coverage | **Rejected.** Advisory status is a recorded maintainer decision (#1222). |
| 17 | Producer-liveness mutation platform | **Rejected.** The checker permits vacuity in principle, but every inspected `fire_raiser` test asserts concrete outcomes. Building a platform for an unobserved defect is speculative. |
| 18 | A universal doc-citation checker | **Rejected.** It would flag time-scoped historical records and still could not validate prose. Repair the two live contradictions directly (T3.3, T3.4). |
| 19 | Any engine/Rust primitive for the above | **Rejected and out of scope.** No accepted item needs a new SDK primitive; engine work belongs to `fkst-substrate`. |
| 20 | Reopen the falsified directions (producer multiplicity, review-loop thrash, dead lifecycle states) | **Rejected.** Source-measured and falsified in prior rounds; re-deriving them is the waste this ledger exists to prevent. |

## 7. Order and gating

```
T0.2 ── independent (verify each of the 7 inventories first; use merge base, not default branch)
T2.3 ── must precede ──> T3.2      (or T3.2 aims at 25 phantom sites)
T3.2 ── precedes ──> T3.3
T1.x ── independent of each other; each gated by §5 where it deletes
T3.1 ── independent; 2 of its 23 files also touch ledger lines in the same commit
```

There is no Tier-0 blocker. Draft 1 asserted one; §1.3 records why that was wrong. Every item below
can start immediately, which is why the ordering above is about *value*, not *unblocking*.

Every item lands as its own PR against `integration-elonsg`, except docs-only and `scripts/`-only
items which may target `dev` directly per CLAUDE.md's supervise-execution test. Nothing in this spec
authorises a merge; each PR passes the normal review gate.

## 8. What the cross-model challenge changed

The six-seat panel ran entirely on one model family, so its agreement carried correlated-prior risk
by construction. A ChatGPT Pro oracle was given the converged reasoning and asked to refute it. It
returned `reject` with three `fatal` findings, and **the two that were mechanically checkable were
both confirmed by measurement** (R1, R2 in §1.3). Its third — that merging the ledgers deletes the
packages-at-zero invariant, and that the observed failure may be the gate correctly enforcing an
intended quarantine boundary — is a design-intent argument that the measurements support.

Concretely, the cross-model seat deleted one Tier-0 item, rewrote another (T0.2's base selection,
where it caught a stacked-PR failure specific to this repository's `integration-<device>` topology),
and removed a false dependency from the two highest-value items. Four codex seats had independently
converged on the rejected design; their convergence was not evidence, and this is the round's
clearest datum for why a single model family cannot be its own adversary.

⟦AI:FKST⟧
