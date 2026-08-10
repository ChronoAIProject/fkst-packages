# cas_parity corpus: adopt a post-capture invariant checker

Status: decided, not yet implemented.
Scope: the 18 files matching `packages/*/tests/*_cas_parity_test.lua` (18 files, 12,675 lines at time
of writing). 14 require `devloop.restart_cas_catalog`; the other 4 require neither it nor
`restart_owner_pending_projection` and are a different species.

## Decision

Adopt a **post-capture invariant checker**. Do not consolidate the corpus behind a shared execution
harness, and do not leave the repeated invariant distributed across 14 files.

Each test continues to arrange and run the real department path exactly as it does today. It then
hands a **normalised observation record** to a small shared verifier. The verifier checks only facts
that are universal across the corpus — OLD/current admission equality for the same CAS edge, evidence
shape, CAS identity consistency, and separation of admission from effect observation. It **must not**
execute departments, install mocks, synthesise events, or decide expected policy outcomes.

Centralise the invariant. Do not centralise the choreography.

## How this decision was reached, including the part that was wrong

This matters more than the conclusion, because the first answer was confidently held and false.

**What was believed.** Four independent reviewers, then a cross-model reviewer, concluded the corpus
must not be consolidated: a shared runner would need injectable callbacks for nine behaviours
(department execution, source construction, mock installation order, probe mapping, boundary capture,
OLD/current classification, pre-CAS policy, effect observation, trace construction), so *"the interface
is as complex as the implementation."*

**None of the five built it.** The judgement stood for two days and shaped campaign scope.

**What refuted it.** The cross-model reviewer named the falsifier the others had not: can the catalog
files be represented by one fixed execution choreography with data-only variation and no
order-sensitive callbacks? A prototype worker, briefed to *try hard to succeed* rather than to
evaluate, built exactly that: three materially different departments — `observe_pr` (12 cases),
`review_loop` (10), `merge` (20) — 42 literal cases, **all nine injection points eliminated**, 42
passed / 0 failed, originals byte-identical.

The complexity argument is dead. It should not be cited again.

**What survived, and was then confirmed.** The cross-model reviewer's *other* objection had never been
tested: a shared harness risks becoming **a second specification of the production protocol**. Examined
against the actual prototype, it holds, with citations:

- `:40-80` centralises module names, consumed queues, event kinds, mock profiles, policy IDs, corpus
  paths, schemas, families and edge IDs
- `:528-556` synthesises three production event wire shapes, including schemas, identity fields, dedup
  keys and source refs
- `:570-705` encodes department-specific mock choreography; `:616-641` is an exact ordered model of
  merge gates, reads and writes
- `:708-749` decides which runtime boundaries count as decisions and effects by monkey-patching the
  production decider, the global `raise`, and the PR comment command

It does not reimplement the CAS comparison algorithm. It does create a centralised, independently
maintained model of how three production protocols are constructed, driven, intercepted and
interpreted — a duplicated source of truth, which this repo forbids.

So: the harness is **feasible and wrong**. Those are separate findings and both were needed.

## The demonstration

A minimal checker was built for the same three departments: **112 shared lines**, 338 lines of
demonstration, three independently executed production paths, and **four negative tests** proving the
checker rejects violations rather than merely accepting conformant input —
`test_checker_rejects_admission_mismatch`, `test_checker_rejects_cas_identity_mismatch`,
`test_checker_rejects_effects_mixed_into_admission`, `test_checker_rejects_invalid_evidence_shape`.
7 passed, 0 failed.

## What this does not buy

**It does not materially reduce the 12,675-line corpus.** Each file still needs a local record adapter.
Anyone adopting this should not expect a line-count win; the win is that a genuinely universal
invariant gets one owner instead of fourteen independent restatements.

Only 3 of the 14 catalog files were built against either design. The remaining 11 were measured as
containing the same bidirectional parity assertion pattern, but were not fitted. **No all-14 claim is
made by either design.**

## Implementation notes for whoever picks this up

- The verifier's contract is the whole design. If it ever needs to know a department's event shape,
  mock order, or expected policy, it has drifted into being an execution harness and the
  second-specification objection reapplies.
- Adopt per department, not corpus-wide. Each adoption is one file gaining a record adapter and losing
  its local restatement of the parity assertion.
- The corpus is not a size problem. Files crossing the 900-line threshold should be split by scenario
  into named sibling files, which is what the campaign already did for `observe_pr_cas_parity_test.lua`
  and `observe_issue_entry_cas_parity_test.lua`.

⟦AI:FKST⟧
