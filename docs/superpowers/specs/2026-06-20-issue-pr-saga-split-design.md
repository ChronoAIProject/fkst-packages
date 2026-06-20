# Split the issue saga from the PR saga into two packages (parent issue + PR child)

Status: DESIGN — awaiting operator approval before any implementation.
Date: 2026-06-20
Author: operator (out-of-band, dogfood), via `sshx` adversarial exploration + operator review.

> Revision note: the first draft proposed one package with two conformance-scanned
> transition tables. Operator review (user-as-oracle) upgraded it to **two
> packages**: the partition belongs at the package boundary (level ④
> capability-restriction, PREVENT) rather than a conformance scan (level ①,
> DETECT). See §3, §4 and §16. The delegation/return/liveness contracts (§5–§9,
> §11–§12) are unchanged — only *where the wall sits* (§3, §4, §10, §13) changed.

## 1. Problem (the root cause, verified at source)

`github-devloop` today runs **one flat state machine per issue** whose `state:v1`
marker tracks *every* phase — including the PR phases `pr-open, reviewing, fixing,
review-meta, merge-ready, merging`. Verified at source:
`packages/github-devloop/core/restart/transitions/` is **one** table holding all of
`thinking, dependency_wait, ready, implementing, pr-open, reviewing, fixing,
review-meta, merge-ready, merging, merged, impl-failed, blocked`.

Separately, the entity-local-PR work (#7) moved the PR-phase *facts* onto the **PR
entity's** comment stream. So PR phase is now written in **two** places — the
issue stream and the PR stream — which is **two mutable authorities for one
phase ⇒ desync**. The production incident: an issue sat at `pr-open` while its PR
had already reached `merge-ready`; the observability read the issue stream and
falsely reported "review never kicked off."

The current mitigation is a symptom-patch: `entity.lua:97
issue_authoritative_linked_state(issue_state, linked_state)` special-cases "issue
says `pr-open` AND linked PR says `reviewing` at the same version → trust the PR."
It covers exactly one phase-pair and does not stop the divergent writes.

### The desync is a symptom of an over-merged god-package

`github-devloop` has grown to **~30 departments and ~60 core modules**. They
cluster cleanly into two groups that change for different reasons:

- **issue-side**: `intake_scan/probe/judge`, `consensus_result`, `observe_issue`,
  `decompose`, `implement`, `loop`, `reconcile`, dependency gate.
- **PR-side**: `open_pr`, `observe_pr`, `review_pr/loop/meta/result`, `fix`,
  `merge`, `pr_freshness_scan`.

One package, two sources (issue entity vs PR entity), two trust domains (issue
stream vs PR stream — already separated by #7), two liveness families, fused into
one state machine. That fusion is the over-merge; the desync is what leaks out of
it. The fix is to make the two sagas two packages whose state namespaces are
disjoint by construction.

### What this design fixes vs. does not

- **Fixes**: the desync *class* — structurally, by giving each saga its own
  package, table, and single-root conformance. The issue package cannot *name* a
  PR phase because it is not in its namespace.
- **Does not fix (out of scope, tracked separately)**: the merge-ready-not-merging
  gate bug. This design makes it diagnosable (issue `awaiting-pr` + PR
  `merge-ready` = "PR stuck at the merge gate," unambiguous) and supplies the
  head-bound-merge-ready invariant that prevents the head-nudge variant, but the
  merge-step root cause is its own fix.

## 2. Harness (prior art this is anchored to)

The standard **parent workflow + child workflow with an explicit await/join**,
applied to two GitHub comment streams.

- **Temporal child workflows.** A parent records a child handle and waits for the
  child's *terminal* result; the child owns its own history, retries, budgets.
  Deviation: two comment streams + reliable delivery emulate the handles/join;
  there is no shared transaction. Temporal makes parent and child **separate
  workflows** despite their coupling — the coupling is a narrow start/await/return
  contract, which is exactly the case for separation (high cohesion, low surface).
- **Saga composition (Garcia-Molina & Salem, 1987).** A child saga's terminal
  resumes the parent. Retries are *forward generations*, never undo edges.
- **Harel statecharts / orthogonal regions.** Issue and PR are separate regions;
  only the PR region owns PR phase. A package boundary is the **strongest** form of
  region separation — disjoint namespaces, not a shared table with a fence.
- **PR-merge bots (bors / homu / Mergify).** Merge/review/check state is PR-local;
  issue links are metadata, not lifecycle authority.
- **Repo precedent.** `github-ratchet-migration-slicer` was extracted *out of*
  `github-devloop` per prefer-out-of-package; this is the same move for the PR saga.

Operative framing (the cross-model oracle): **the bug was duplicated authority,
not missing hierarchy.** So this is not a generic hierarchical-saga *engine* — it
is single authority + the smallest join primitive, `await_child(pr)`, with the two
sagas living in two packages.

## 3. Design principle

> The issue owns issue progress. The PR owns PR progress. The issue holds only a
> **pointer** ("awaiting PR child X") and resumes **only** from a **terminal** PR
> fact for X. Each saga is its **own package** with its **own** transition table
> and single-root conformance; their state namespaces are disjoint.

Four consequences drive every decision below:

1. **Single authority.** Exactly one comment stream is authoritative per phase.
   PR phase ⇒ PR stream; issue phase ⇒ issue stream. No overlap.
2. **Explicit join.** A formal `awaiting-pr → (resume on PR terminal)` edge,
   carried by a reliable cross-package queue. Without it, resume is ad hoc and the
   race re-grows.
3. **Structural partition, not a scan (PREVENT > DETECT).** Two packages make
   `ISSUE_STATES ∩ PR_PHASE_STATES = ∅` true *by construction* — the issue
   package's code cannot reference a PR-phase state because it is not in its
   namespace/table. This is level ④ capability-restriction. A conformance scan
   (`state_marker(issue,"merge-ready")` → CI-red) is level ① DETECT and is kept
   **only** as the migration backstop, shrinking to a structural guarantee as the
   extraction completes. CLAUDE.md 铁律: a contract expressible as ②③④ must not
   stay at ① scan.
4. **Decompose the god-package (SRP).** issue-lifecycle and PR-lifecycle have
   independent reasons to change; splitting corrects the over-merge and bounds blast
   radius (a PR-review change cannot touch issue lifecycle — different package).

## 4. Package topology

Two lifecycle packages plus the existing shared roots; the boundary is exactly two
reliable queues.

```
                     std/ (shared, symlinked)
   Tier S: std.saga · std.saga_conformance · version-CAS · source_ref
   Tier R: std.github · std.git · std.ports · std.testing · std.devloop_*  ← shared devloop kernel
        ▲                                          ▲
        │ require("std.*")                         │ require("std.*")
        │                                          │
┌───────┴───────────────────┐   delegation   ┌─────┴─────────────────────┐
│  github-devloop  (parent) │ ─────────────▶ │ github-devloop-pr (child) │
│  issue saga               │   devloop_pr_  │  PR saga                  │
│  intake/consensus/implement│   open (queue) │  open_pr observe_pr       │
│  observe_issue decompose   │ ◀───────────── │  review_* fix merge       │
│  loop reconcile dep-gate   │   devloop_pr_  │  pr_freshness_scan        │
│  + composes github-proxy,  │   terminal     │  + composes github-proxy, │
│    consensus, devloop-pr   │   (queue)      │    consensus              │
│  issue transition table +  │                │  PR transition table +    │
│  single-root conformance   │                │  single-root conformance  │
└────────────────────────────┘                └───────────────────────────┘
```

- **`github-devloop`** (parent / issue saga) — composed package
  (`composed.deps = github-proxy, consensus, github-devloop-pr`). Owns the issue
  transition table. On implement-success it **delegates** (creates the PR child,
  writes `pr-origin` + `pr-open`, raises `devloop_pr_open`), CASes issue
  `implementing → awaiting-pr`, then **awaits** by consuming `devloop_pr_terminal`.
- **`github-devloop-pr`** (child / PR saga) — composed package
  (`composed.deps = github-proxy, consensus`). Owns the PR transition table and all
  PR-phase departments + PR-specific core. Advances the PR from `pr-open` to a
  terminal, then raises **reliable** `devloop_pr_terminal` (`source_ref=pr`).
- **Shared kernel → `std`** (the only blessed shared root; peer cross-package
  require is forbidden by G9). The restart/saga/conformance *framework* is already
  Tier S `std.saga`; the devloop-shared *domain* kernel (entity/marker/state
  read-write, version-CAS application, `source_ref`, logging, parsers, validators,
  the comment-handoff outbox pattern, the liveness sweep) moves to a Tier R
  `std.devloop_*` module. Each package then defines its **own** table using the
  shared framework. Issue-specific and PR-specific core split to their packages.
- **Boundary = two reliable queues only.** `devloop_pr_open` (parent → child
  kickoff) and `devloop_pr_terminal` (child → parent return). Both pointer-shaped
  payloads (`source_ref` + control fields); both re-derive truth from GitHub. The
  composed conformance (`github-devloop` composing `github-devloop-pr`) covers the
  wiring as a first-class package contract — the `await_child` join is now CI-typed.

The integration-topology departments (`sync_scan`, `sync_conflict`, `rollup_scan`,
`rollup_merge`, `substrate_ref_scan`) and cross-cutting observability (`doctor`,
`observability`, `liveness_scan`, `dead_letter`, `ensure_repo`, test harness) are
neither issue- nor PR-lifecycle; they are assigned in the migration inventory
(§13). Default: keep with the parent unless an item is provably PR-only. A third
package for the integration topology is **YAGNI** until it earns its own reason to
change.

## 5. State split

### Issue package — authority = issue comment stream

```
unmanaged → thinking → dependency_wait → ready → implementing → awaiting-pr → merged ✓
                                                       │              │
                                                       ▼              ▼
                                                  impl-failed       blocked
```

Issue-saga states: `thinking, dependency_wait, ready, implementing, awaiting-pr,
impl-failed, merged, blocked`. `merged` stays the existing issue success-terminal
name (the `done` rename is a separate behavior-change, out of scope). The PR phases
do not exist in this package's namespace.

### PR package — authority = PR comment stream

```
pr-open ──→ reviewing ──→ review-meta ──→ merge-ready ──→ merging ──→ merged ✓
              │   ▲            │                              │
              ▼   │ (new head) ▼                             ▼
            fixing ┘    (fix|block decision)        closed-unmerged ✗ / blocked ✗

terminals: merged ✓ · closed-unmerged ✗ · blocked ✗
```

PR-saga states: `pr-open, reviewing, fixing, review-meta, merge-ready, merging,
merged, closed-unmerged, blocked` (`closed-unmerged` is new — the explicit
"closed without merging" terminal, today implicit). These are the existing
pr-open…merging rows relocated to the PR package with their budgets unchanged.

## 6. The delegation state `awaiting-pr`

`awaiting-pr` is the **single** issue state between implementation completion and
parent terminal/resume. It stores a **pointer to the child**, never the child's
phase.

Issue stream — immutable delegation pointer plus the state:

```
state:v1   state="awaiting-pr"  version=<issue lineage>
pr-delegation:v1 {
  parent_issue, parent_proposal_id, impl_version, generation,
  child_pr_number, pr_source_ref = "owner/repo#pr/N", branch, base, head
}
```

PR stream — the child's origin and its own state:

```
pr-origin:v1 { parent_issue, parent_proposal_id, impl_version, generation }
state:v1   state="pr-open" …
```

**Marker authority is derived from the entity** (the harness within each package):
the state-marker builder derives `saga_kind` from the entity it writes to. In the
issue package a PR-phase state is not even a defined symbol; the construction is a
compile-/load-time impossibility, not a runtime check. The existing `state:v1` wire
format is kept (behavior-preserving — no marker flag-day).

**Issue-side PR status is a projection, never state.** The issue UI may *display*
"PR #N = merge-ready @ abc123" as a non-authoritative projection derived live from
the PR stream, labelled `projection`/`derived`, with its source + sync timestamp.
**Automation must not consume it.** The only safe issue label is
`fkst-dev:awaiting-pr`; `fkst-dev:pr-open/reviewing/merge-ready` cease to exist on
issues.

## 7. Boundary A — delegation (issue → PR), idempotent ensure

Delegation is an **idempotent ensure**, recoverable from any partial write. The
deterministic correlation key is the **branch name** the system already derives
from `(issue, impl_version, generation)`; the PR is found-or-created by that branch
(the oracle's `pr_saga_id = hash(...)` is conceptually this branch token; once the
PR exists, `pr_source_ref = owner/repo#pr/N` is the durable child id).

`ensure_pr_child(issue, impl_version, generation)` (in the parent package):

1. Compute the deterministic branch/head from the implementation.
2. Find the existing PR for that branch, or create it.
3. Ensure the PR stream carries `pr-origin:v1` + initial `state pr-open`; raise
   reliable `devloop_pr_open` (`source_ref=pr`) so the child package starts
   observing.
4. Ensure the issue stream carries `pr-delegation:v1` pointing at that PR.
5. Any step already done ⇒ success (idempotent).

**CAS `implementing → awaiting-pr` fires only after** the PR start fact
(`pr-origin:v1` + `state pr-open`) is visible/verified. Until then the issue stays
`implementing` (its existing liveness covers the gap). This is the write/read-race
harness across entities: the issue does not advance to "awaiting" until the thing
it will await provably exists.

## 8. Boundary B — return (PR terminal → issue), resume only on terminal

When the PR reaches a **terminal** — `merged`, `closed-unmerged`, or PR `blocked`
— the PR package writes the PR-local terminal marker + `pr-terminal:v1` and raises
**reliable** `devloop_pr_terminal` (`source_ref = owner/repo#pr/N`).

`ensure_parent_resumed(pr_terminal)` (in the parent package, idempotent):

1. Re-fetch the PR terminal fact and the parent issue's `awaiting-pr` + delegation.
2. **Require** `issue.state == "awaiting-pr"` AND the delegation child id/version
   matches the terminal's child id (no "resume from some PR for this issue").
3. Verify the PR terminal is a trusted (bot-authored) fact and head/merge facts
   match the delegation.
4. Append a `child-completed` fact on the issue with idempotency key
   `parent_proposal_id + pr_source_ref + terminal_marker_id`.
5. CAS the issue:
   - PR `merged` → issue `merged`, then close the issue idempotently.
   - PR `closed-unmerged` → issue `ready` with a **new generation** (forward
     retry), or `blocked` if the replacement budget is exhausted.
   - PR `blocked` → issue `blocked` with WHY (or the existing decomposition flow).

**Resume only on a child terminal — never on `merge-ready`.** `merge-ready` is a
transient, head-bound capability, not a terminal; copying it back is what
re-creates the desync. Only `merged` / `closed-unmerged` are child terminals.

## 9. Head-bound merge-ready invariant (the head-nudge incident, encoded)

`merge-ready` is valid **only** for the exact PR head SHA it was computed against.
Before `merging`, the gate re-verifies `current_pr_head_sha ==
merge_ready.head_sha`; if the head moved, `merge-ready` is invalidated and the PR
returns to `fixing`/`reviewing`. This mirrors GitHub's required-checks model and
prevents a push (human or bot) from silently invalidating readiness — the failure
mode the operator head-nudge hit.

## 10. Conformance (structural first, scan as backstop)

- **Structural (the target):** `ISSUE_STATES ∩ PR_PHASE_STATES = ∅` holds because
  they are different packages with different state namespaces. Each package passes
  its **own** single-root conformance (every non-terminal state has
  budget + watchdog + guaranteed termination + WHY). The parent's composed
  conformance (composing `github-devloop-pr`) validates the two-queue boundary
  wiring.
- **Scan backstop (migration only, shrink-to-structural):** until the extraction
  completes, a ratchet forbids new issue-side PR-phase writes:
  `current_issue_state()` must not parse PR comments / linked-PR markers (deletes
  the `entity.lua:97 issue_authoritative_linked_state` promotion);
  `state_marker(issue,"<pr-phase>")` is CI-red; lifecycle-queue producers are
  authority-scoped (PR-phase queues produced only by the PR package). The allowlist
  of "issue-side modules still referencing a PR-phase state" shrinks to 0; at 0,
  the scan is redundant with the namespace boundary and the partition is purely
  structural.
- Labels are hints only: an issue label may be `awaiting-pr`; it must not mirror a
  PR phase.

## 11. Liveness

`awaiting-pr` has liveness class **`child_workflow_wait`** — distinct from
`pr-open` / `reviewing` / `merge-ready`. Its watchdog does **not** count PR review
or merge time against the parent (that is the bug class — an issue-side timer
charging PR work, the #887 one-state-one-liveness-class violation). It only
re-derives the child:

- child nonterminal & healthy under the PR row's contract → **defer**;
- child row stale → **redrive** PR observe (or let PR liveness handle it);
- child terminal visible but parent not yet resumed → **redrive** terminal-return;
- child missing/broken beyond a bounded **delegation-start** budget → issue
  `blocked` with WHY.

Its actionable epoch resets at delegation, never charging the deferred child
runtime. PR-package rows keep their existing budgets: `pr-open` 30m router,
`reviewing` heartbeat-deferred loop, `fixing` 120m, `review-meta` 90m,
`merge-ready`/`merging` CI/merge-gate budget. PR terminal is guaranteed.

## 12. Naive failure modes (and the repair)

Idempotent ensure-functions + reconciliation-from-durable-facts (not "trust events
more") close each:

| Failure mode | Result | Repair |
|---|---|---|
| Parent writes `awaiting-pr` before child exists | parent waits forever | CAS only after PR start fact visible (§7); key = deterministic branch |
| Child PR created, parent pointer write fails | orphan PR | `ensure_pr_child` idempotent; reconciler writes missing `pr-delegation` if parent valid |
| Parent resumes from "some PR for this issue" | wrong PR completes wrong attempt | resume requires delegation child id/version == terminal child id (§8.2) |
| `devloop_pr_terminal` consumed once and lost | parent never resumes | reliable delivery + `awaiting-pr` liveness redrives from the durable PR terminal fact |
| `merge-ready` copied back to the issue | original desync returns | issue package has no PR-phase symbol (§3/§6); resume only on terminal (§8) |
| `merge-ready` not bound to head SHA | a push silently invalidates readiness | head-bound invariant (§9) re-verifies head before merge |
| Issue projection consumed by automation | cache becomes authority | projection is display-only (§6); automation reads the PR stream |
| Cross-package queue mis-wired | kickoff/return silently dropped | composed conformance (§10) types the two-queue boundary; consumed-but-unrouted fails closed |

## 13. Migration — harness-first god-package extraction ratchet

The **only** intended behavior change is desync elimination. Review, fix, merge
gates, head binding, CI checks, `source_ref` fetch behavior remain equivalent. This
is a **refactor** under the behavior-preserving definition (same inputs ⇒ same
effects/terminal/delivery); the one deliberate behavior change (desync elimination)
is named and isolated, not smuggled under "refactor". Executed as an
inventory-ratchet, **never a big-bang on the live state machine**
(god-state-ratchet doctrine).

**Step 0 — inventory + harness (no behavior change).**
- Manifest every department + core module → `{issue, pr, shared, integration,
  cross-cutting}`. The manifest is the ratchet's source of truth.
- Add the failing fixtures first: the canonical desync fixture (issue `pr-open` +
  PR `merge-ready` ⇒ derived issue state `awaiting-pr`, merge continues from PR
  authority); the late-old-write fixture (legacy issue `reviewing`/`merge-ready`
  arriving after `awaiting-pr` must not become current); conformance negatives
  (issue row naming a PR phase; `state_marker(issue,"merge-ready")`).
- Scoped state parsing: current state read by `(saga_kind, entity)`, never by
  merging issue + PR comments.

**Step 1 — the delegation boundary in place (Phase-A, in current package).**
Introduce `awaiting-pr`, `pr-delegation:v1`, the `child_workflow_wait` liveness,
and the `devloop_pr_open` / `devloop_pr_terminal` queues *within* the current
package; stop issue-side PR-phase writes (scan ratchet active). This ships the
desync fix and builds the exact boundary the split needs — not throwaway work.

**Step 2 — extract `github-devloop-pr` (Phase-B, the structural split).**
Move PR-phase departments + PR-specific core to the new package; lift the shared
kernel to `std.devloop_*`; wire the two queues across the package boundary via
`composed.deps`. The scan partition becomes a namespace partition; the allowlist
hits 0. Each move is behavior-preserving and individually conformed; the live
supervise is restarted per merge (crash-only).

**Step 3 — delete the backstop.** With the allowlist at 0 and both packages passing
independent single-root conformance, remove the migration scan; the partition is
purely structural.

Old durable events normalize to PR-child authority by `source_ref=pr`; stale
issue-phase payloads re-fetch and no-op if the parent is already `awaiting-pr` for
the same (or a newer) child.

## 14. Non-goals / YAGNI

- **No generic hierarchical-saga engine.** Both packages use the existing
  `std.saga.department` shape; the child is the smallest `await_child` primitive.
- **No third package for integration-topology** until it earns its own reason to
  change (§4).
- **No `merged → done` rename** (separate behavior-change PR if ever wanted).
- **No `state:v2` marker flag-day** (entity-derived `saga_kind` keeps `state:v1`).
- **No fix to the merge-ready-not-merging gate bug here** (separate; this design
  only makes it legible + supplies the head-bound invariant).

## 15. Open decisions (to settle in writing-plans)

1. Topology detail: keep `github-devloop` as parent+composer (recommended,
   minimal — 1 new package) vs. a thin top Facade over two siblings (3 packages).
2. Exact module inventory: which `core/*` are shared-kernel (→ `std.devloop_*`),
   issue-specific, PR-specific, or integration/cross-cutting. This is Step-0 work.
3. `closed-unmerged` → issue `ready`(new generation) vs `blocked`: the
   replacement-budget threshold and where it is counted (issue generation lineage).
4. Whether PR `blocked` maps to issue `blocked` directly or routes through the
   existing decomposition (fix-drop → smaller issues) flow.
5. Home of `child_workflow_wait` in `liveness_contract.lua` and its
   `actionable_epoch` source (delegation time).
6. Whether the issue-side projection is rendered in v1 or deferred (display-only,
   non-load-bearing).

## 16. Adversarial record

Design produced by `sshx` inline consensus: 3 peer-invisible codex thinking
workers (minimal / structural / delete, read-only) + 1 cross-model ChatGPT Pro
oracle, meta-judged; then **operator review (user-as-oracle)**.

- **minimal** (`/tmp/saga-minimal.log`): "Do not build a new generic sub-saga
  layer; make the PR entity the sole authority + collapse the issue PR phase into
  one delegation state."
- **structural** (`/tmp/saga-structural.log`): "Adopt the full hierarchical
  sub-saga; the issue must never carry PR sub-phase again." → conformance partition,
  scoped parsing, child id/lineage.
- **delete** (`/tmp/saga-delete.log`): "Delete issue-level PR-phase tracking
  entirely; parent issue saga with one `awaiting-pr` + PR child saga." →
  pointer-only delegation, terminal-only return.
- **oracle / ChatGPT Pro** (cross-model): "The bug was duplicated authority, not
  missing hierarchy → single authority + smallest `await_child` primitive." Added:
  deterministic correlation IDs + idempotent `ensure` recoverable from partial
  writes; **resume only on terminal, never merge-ready**; the head-bound invariant;
  the naive failure modes; issue-side PR status as non-authoritative projection.
- **operator review (user-as-oracle)**: upgraded the partition from a conformance
  *scan* within one package to a **package boundary** (two packages). Rationale: the
  partition is expressible at level ④ capability-restriction (disjoint namespaces),
  and CLAUDE.md 铁律 forbids leaving an expressible structural contract at level ①
  scan; the move also decomposes a 30-department over-merged god-package along its
  true SRP seam. Same `美 = 真理探测器` pattern the operator has caught before — the
  AI optimized a proxy (the scan) when a structural solution (the boundary) was
  available.

**Meta-judge: `implement`.** End-state unanimous across the four sshx perspectives;
the operator review strengthens it from DETECT to PREVENT. The lone tension —
structural's "full new sub-saga layer" vs. minimal/delete/oracle's "delete the
duplication + smallest join" — resolves to: the two-package split **is** the
structural invariant achieved with least machinery (the PR entity already owns a
state machine via #7; reuse `std.saga.department`), satisfying BEAUTY GATE
(删无可删 of the scan, illegal states unrepresentable) and structural integrity at
once.

⟦AI:FKST⟧
