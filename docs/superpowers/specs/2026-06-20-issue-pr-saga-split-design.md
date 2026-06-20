# Split the issue saga from the PR saga (parent issue + PR child workflow)

Status: DESIGN — awaiting operator approval before any implementation.
Date: 2026-06-20
Author: operator (out-of-band, dogfood), via `sshx` adversarial exploration.

## 1. Problem (the root cause, verified at source)

`github-devloop` today runs **one flat state machine per issue** whose `state:v1`
marker tracks *every* phase of the workflow — including the PR phases
`pr-open, reviewing, fixing, review-meta, merge-ready, merging`. Verified at
source: `packages/github-devloop/core/restart/transitions/` contains one table
with all of `thinking, dependency_wait, ready, implementing, pr-open, reviewing,
fixing, review-meta, merge-ready, merging, merged, impl-failed, blocked`.

Separately, the entity-local-PR work (#7) moved the PR-phase *facts* onto the **PR
entity's** comment stream, so PR phase is now written in **two** places:

- the **issue** comment stream (`state:v1 state="merge-ready" …`), and
- the **PR** comment stream (the PR-local marker).

**Two mutable authorities for one phase ⇒ desync.** The concrete production
incident: an issue sat at `pr-open` while its PR had already reached
`merge-ready`. The observability read the issue stream and reported "review never
kicked off," which is false — the PR had advanced; the issue's copy was stale.

The current mitigation is a symptom-patch: `entity.lua:97
issue_authoritative_linked_state(issue_state, linked_state)` special-cases
"issue says `pr-open` AND linked PR says `reviewing` at the same version → trust
the PR's linked state." This is a BEAUTY-GATE smell (a proxy branch that *catches*
the desync instead of making it unrepresentable), it covers exactly one
phase-pair, and it does not address the writes that produce the divergence.

A second, independent defect rides on the same confusion: a head-bound
`merge-ready` was silently invalidated by an operator head-nudge (a new head SHA),
and nothing re-derived merge eligibility — the PR stalled at `merge-ready` without
merging. That is a real merge-gate bug (tracked separately as the
merge-ready-not-merging class) but the desync made it *look* like an issue-phase
stall, costing a mis-diagnosis. The design below makes that failure legible.

### What this design fixes vs. does not

- **Fixes:** the desync *class* — the issue and PR can never again disagree about
  the PR phase, because the issue will no longer have a writable slot that can
  *name* a PR phase.
- **Does not fix (out of scope, tracked separately):** the merge-ready-not-merging
  gate bug itself. This design makes it diagnosable (issue `awaiting-pr`, PR
  `merge-ready` = "PR stuck at the merge gate," unambiguous) and supplies the
  head-bound-terminal invariant that prevents the head-nudge variant, but the
  merge-step root cause is its own fix.

## 2. Harness (prior art this is anchored to)

This is not a novel construct; it is the standard **parent workflow + child
workflow with an explicit await/join**, applied to two GitHub comment streams.

- **Temporal child workflows.** A parent records a child handle and waits for the
  child's *terminal* result; the child owns its own history, retries, and budgets.
  Our deviation: two GitHub comment streams + reliable delivery emulate the
  parent/child handles and the join edge; there is no shared transaction.
- **Saga composition (Garcia-Molina & Salem, 1987).** A child saga's terminal
  resumes the parent. Retries are *forward generations*, never undo edges back
  into an earlier lifecycle state.
- **Harel statecharts / hierarchical state machines.** The PR phases become
  substates hidden behind the parent's single `awaiting-pr` state.
- **Orthogonal regions — and the trap to avoid.** Issue and PR are separate
  regions, but only the PR region may own PR phase. *Mirrored* regions (both
  regions tracking the same phase) is the anti-pattern that produced the bug.
- **PR-merge bots (bors / homu / Mergify).** Merge/review/check state is
  PR-local; issue links are metadata, not lifecycle authority.

The cross-model oracle's framing is the operative one: **the bug was not "missing
hierarchy"; it was "duplicated authority."** So the fix is not a generic
hierarchical-saga *engine* — it is "single authority + the smallest useful join
primitive, `await_child(pr)`."

## 3. Design principle

> The issue owns issue progress. The PR owns PR progress. The issue may hold only
> a **pointer** that says "awaiting PR child X," and the issue resumes **only** from
> a **terminal** PR fact for child X.

Three consequences drive every decision below:

1. **Single authority.** Exactly one comment stream is authoritative for each
   phase. PR phase ⇒ PR stream. Issue phase ⇒ issue stream. No overlap.
2. **Explicit join.** The parent has a formal `awaiting-pr → (resume on PR
   terminal)` edge. Without it, return/resume is ad hoc and the race re-grows.
3. **Least new machinery (BEAUTY GATE: 删无可删).** The PR entity *already* has a
   state machine (#7). We do not add a generic sub-saga framework; we (a) **delete**
   the issue-side PR-phase authority, (b) add **one** issue delegation state, (c)
   add **one** reliable terminal-return edge, (d) lock it with a conformance
   partition. Both sagas use the existing `std.saga.department` shape.

## 4. State split

### Issue saga — authority = issue comment stream

```
unmanaged → thinking → dependency_wait → ready → implementing → awaiting-pr → merged (done, terminal)
                                                       │              │
                                                       ▼              ▼
                                                  impl-failed       blocked
                                                  (terminal)       (terminal-hold)
```

Issue-saga states: `thinking, dependency_wait, ready, implementing, awaiting-pr,
impl-failed, merged, blocked`.

- `merged` stays the existing issue success-terminal name (the codex `done`
  proposal is a *rename* — a separate behavior-change, explicitly out of scope to
  keep this migration behavior-preserving).
- **Removed from issue authority:** `pr-open, reviewing, fixing, review-meta,
  merge-ready, merging`. These become *illegal* on the issue stream (conformance,
  §8).

### PR sub-saga — authority = PR comment stream

```
pr-open ──→ reviewing ──→ review-meta ──→ merge-ready ──→ merging ──→ merged ✓
              │   ▲            │                              │
              ▼   │ (new head) ▼                             ▼
            fixing ┘    (fix|block decision)        closed-unmerged ✗ / blocked ✗

terminals: merged ✓ (PR merged) · closed-unmerged ✗ · blocked ✗
```

PR-saga states: `pr-open, reviewing, fixing, review-meta, merge-ready, merging,
merged, closed-unmerged, blocked`. (`closed-unmerged` is new — the explicit
PR-terminal for "PR closed without merging," today implicit.)

The PR rows are the *existing* pr-open…merging rows, relocated to a PR-scoped
table with their existing budgets and watchdogs unchanged.

## 5. The delegation state `awaiting-pr`

`awaiting-pr` is the **single** issue state between implementation completion and
the parent's terminal/resume. It stores a **pointer to the child**, never the
child's phase.

### Marker shapes

Issue stream — the delegation is an immutable pointer marker plus the state:

```
state:v1   state="awaiting-pr"  version=<issue lineage>
pr-delegation:v1 {
  parent_issue, parent_proposal_id, impl_version, generation,
  child_pr_number, pr_source_ref = "owner/repo#pr/N",
  branch, base, head
}
```

PR stream — the child's origin and its own state:

```
pr-origin:v1 { parent_issue, parent_proposal_id, impl_version, generation }
state:v1   state="pr-open" … (then the PR saga advances this)
```

### Marker authority is derived from the entity (the harness)

The state-marker builder derives `saga_kind` from the entity it is writing to:
issue entity ⇒ issue saga, PR entity ⇒ PR saga. Constructing a PR-phase state for
an issue entity (`state_marker(issue, "merge-ready")`) is a **construction error**,
fail-closed. This keeps the existing `state:v1` wire format (behavior-preserving —
no marker flag-day); the alternative `state:v2 saga_kind=…` explicit tag is a
heavier option we reject for least-machinery. Either way the *invariant* is the
same and is enforced mechanically in §8.

### Issue-side PR status is a projection, never state

The issue UI may *display* "PR #N = merge-ready @ abc123" as a **non-authoritative
projection** (derived live from the PR stream, labelled `projection`/`derived`,
never persisted as `state`). **Automation must not consume the projection.** The
only safe issue *label* is `fkst-dev:awaiting-pr`; `fkst-dev:pr-open`,
`fkst-dev:reviewing`, `fkst-dev:merge-ready` cease to exist on issues (they remain
PR labels). A stale projection can still mislead a human, so the projection must
show its source + sync timestamp and point at the PR as the authority.

## 6. Boundary A — delegation (issue → PR), idempotent ensure

Delegation is an **idempotent ensure**, recoverable from any partial write — not a
fire-once transition. The deterministic correlation key is the **branch name**,
which the system already derives deterministically from `(issue, impl_version,
generation)`; the PR is found-or-created by that branch, so no separate hash id is
needed (the oracle's `pr_saga_id = hash(...)` is conceptually this branch token;
once the PR exists, `pr_source_ref = owner/repo#pr/N` is the durable child id).

`ensure_pr_child(issue, impl_version, generation)`:

1. Compute the deterministic branch/head from the implementation.
2. Find the existing PR for that branch, or create it.
3. Ensure the PR stream carries `pr-origin:v1` + initial `state pr-open`.
4. Ensure the issue stream carries `pr-delegation:v1` pointing at that PR.
5. Any step already done ⇒ treat as success (idempotent).

**The CAS `implementing → awaiting-pr` fires only after** the PR-local start fact
(`pr-origin:v1` + `state pr-open`) is visible/verified. Until then the issue stays
`implementing` (its existing liveness covers the gap). This ordering is the
write/read-race harness applied across entities: the issue does not advance to
"awaiting" until the thing it will await provably exists.

Reliable payloads across the boundary are **pointer-shaped only**: parent
proposal id, issue number, PR number, impl version, source refs, lineage keys. The
receiver always re-fetches issue/PR by `source_ref` (no content in payload).

## 7. Boundary B — return (PR terminal → issue), resume only on terminal

When the PR reaches a **terminal** — `merged`, `closed-unmerged`, or PR `blocked`
— the PR writer records the PR-local terminal marker plus `pr-terminal:v1` and
raises a **reliable** `devloop_pr_terminal` event with `source_ref = owner/repo#pr/N`.

`ensure_parent_resumed(pr_terminal)` (idempotent):

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
   - PR `blocked` → issue `blocked` with WHY (or the existing decomposition flow
     if that remains the chosen PR-failure policy).

**Resume only on a child terminal — never on `merge-ready`.** `merge-ready` is a
*transient, head-bound capability*, not a terminal; copying it back to the issue is
exactly what re-creates the desync. Only `merged` / `closed-unmerged` are child
terminals.

### Head-bound merge-ready invariant (the head-nudge incident, encoded)

`merge-ready` is valid **only** for the exact PR head SHA it was computed against.
Before `merging`, the gate must re-verify `current_pr_head_sha ==
merge_ready.head_sha`; if the head moved, `merge-ready` is invalidated and the PR
returns to `fixing`/`reviewing`. This mirrors GitHub's own required-checks model
(checks must pass against the latest commit) and prevents a push (human or bot)
from silently invalidating readiness — the failure mode the operator head-nudge hit.

## 8. Conformance (the mechanical harness)

The partition is enforced by a conformance invariant, CI-red on violation — the
duplication is made *unrepresentable*, not merely discouraged:

- `ISSUE_STATES ∩ PR_PHASE_STATES = ∅`. The issue restart table may contain only
  `{thinking, dependency_wait, ready, implementing, awaiting-pr, impl-failed,
  merged, blocked}`; the PR restart table only the PR-saga states.
- An issue row may **not** declare a PR-phase successor, a PR-phase
  `output_postcondition`, or a PR-phase label projection.
- A PR row must declare `authority_surface = "pr-comment-stream"` and a child id.
- `current_issue_state()` must **not** parse PR comments or linked-PR state
  markers. (Deletes the `issue_authoritative_linked_state` promotion at
  `entity.lua:97` — the symptom-patch is removed, not generalized.)
- The state-marker builder requires/derives `saga_kind`; `state_marker(issue,
  "<pr-phase>")` is a construction error.
- Lifecycle-queue producers are authority-scoped: PR-phase queues are produced
  only by PR-saga departments; the parent produces only delegation/terminal-return
  queues.
- Labels are hints only: an issue label may be `awaiting-pr`; it must not mirror a
  PR phase.

## 9. Liveness

`awaiting-pr` has liveness class **`child_workflow_wait`** — a *new* class,
distinct from `pr-open` / `reviewing` / `merge-ready`. Its watchdog does **not**
count PR review or merge time against the parent (that is the bug class — an
issue-side timer charging PR work). It only re-derives the child:

- child nonterminal & healthy under the PR row's contract → **defer**;
- child row stale → **redrive** PR observe (or let PR liveness handle it);
- child terminal visible but parent not yet resumed → **redrive** the
  terminal-return;
- child missing/broken beyond a bounded **delegation-start** budget → issue
  `blocked` with WHY.

This is the one-state-one-liveness-class doctrine (#887) applied: `awaiting-pr`
carries exactly one liveness semantics (waiting on a child), with its actionable
epoch reset at delegation, never charging the deferred child runtime.

PR-saga rows keep their existing budgets, now PR-local: `pr-open` 30m router,
`reviewing` heartbeat-deferred review loop, `fixing` 120m bounded repair,
`review-meta` 90m bounded decision, `merge-ready`/`merging` CI/merge-gate budget.
Lineage keys include child id, parent delegation version, PR number, head SHA, and
generation. PR terminal is guaranteed: `merged` or `closed-unmerged` (or `blocked`
with WHY).

## 10. Naive failure modes (and the repair)

A naive child-workflow still fails on these; the design's idempotent
ensure-functions + reconciliation-from-durable-facts (not "trust events more")
close each:

| Failure mode | Result | Repair |
|---|---|---|
| Parent writes `awaiting-pr` before child exists, no recovery token | parent waits forever | CAS to `awaiting-pr` only after PR start fact visible (§6); delegation key is the deterministic branch |
| Child PR created but parent pointer write fails | orphan PR | `ensure_pr_child` is idempotent; reconciler writes the missing `pr-delegation` if parent still valid |
| Parent resumes from "some PR for this issue" not the exact child | wrong PR completes wrong attempt | resume requires delegation child id/version == terminal child id (§7.2) |
| PR terminal event consumed once and lost | parent never resumes | reliable delivery + `awaiting-pr` liveness redrives terminal-return from the durable PR terminal fact |
| `merge-ready` copied back to the issue | original desync returns | issue has no writable PR-phase slot (§8); resume only on terminal (§7) |
| `merge-ready` not bound to head SHA | a push silently invalidates readiness | head-bound invariant (§7) re-verifies head before merge |
| Issue projection consumed by automation | cache becomes authority | projection is display-only, labelled non-authoritative (§5); automation reads PR stream |
| Legacy issue `state=pr-open` still readable as authoritative | humans/bots keep making the old mistake | migration rewrites/ignores legacy issue PR-phase markers (§11) |

## 11. Migration — harness-first, behavior-preserving

The **only** intended behavior change is desync elimination. Review, fix, merge
gates, head binding, CI checks, and `source_ref` fetch behavior remain equivalent.

**Harness first (failing fixtures before code):**

- Canonical desync fixture: issue marker `pr-open` + linked PR marker
  `merge-ready` ⇒ derived issue state must become `awaiting-pr`, and merge must
  continue from PR authority.
- Late-old-write fixture: a legacy issue `reviewing`/`merge-ready` marker arriving
  *after* `awaiting-pr` must **not** become the current issue state.
- Conformance negative samples: an issue row naming a PR phase, and
  `state_marker(issue, "merge-ready")`, must fail CI.

**Cutover:**

- Scoped state parsing: current state is read by `(saga_kind, entity)`, never by
  merging issue + PR comments.
- Live migration on observe: if an issue has a legacy PR-phase state and a
  `pr-link`/delegation, fetch the PR. If the PR has a child state, write only issue
  `awaiting-pr`. If the PR lacks a child state, seed the PR child once from the
  legacy facts.
- Old durable events: PR-phase queues normalize to PR-child authority by
  `source_ref = pr`; stale issue-phase payloads re-fetch and no-op if the parent is
  already `awaiting-pr` for the same (or a newer) child.

This is a **refactor** under the behavior-preserving definition (CLAUDE.md): same
inputs ⇒ same effects/terminal/delivery, only the structure (authority partition)
changes. The one deliberate behavior change (desync elimination) is named and
isolated; it is not smuggled in under "refactor."

## 12. Non-goals / YAGNI

- **No generic hierarchical-saga engine.** Both sagas use the existing
  `std.saga.department` shape; the "child workflow" is the smallest `await_child`
  primitive, not a framework.
- **No `merged → done` rename** (separate behavior-change PR if ever wanted).
- **No `state:v2` marker flag-day** unless the entity-derived `saga_kind` path
  proves insufficient.
- **No fix to the merge-ready-not-merging gate bug here** (separate; this design
  only makes it legible + supplies the head-bound invariant).
- **No new state for PR-failure policy** beyond mapping PR terminal → existing
  issue `ready`(new generation)/`blocked`/decomposition.

## 13. Open decisions (to settle in writing-plans)

1. `closed-unmerged` → issue `ready`(new generation) vs. `blocked`: the
   replacement-budget threshold and where it is counted (issue generation lineage).
2. Whether PR `blocked` maps to issue `blocked` directly or routes through the
   existing decomposition (fix-drop → smaller issues) flow.
3. Exact home of the `child_workflow_wait` liveness class in
   `liveness_contract.lua` and its `actionable_epoch` source (delegation time).
4. Department topology: does `awaiting-pr` get its own observe department, or does
   `observe_issue` handle the delegation/return edges? (Prefer the latter for least
   machinery, if the conformance partition stays clean.)
5. Whether the issue-side projection is rendered at all in v1, or deferred (it is
   display-only and non-load-bearing).

## 14. Adversarial record (sshx, 4 perspectives)

Design produced by `sshx` inline consensus: 3 peer-invisible codex thinking
workers (minimal / structural / delete biases, read-only) + 1 cross-model ChatGPT
Pro oracle, then meta-judged.

- **minimal** (`/tmp/saga-minimal.log`): "Do not build a new generic sub-saga
  layer; make the PR entity the sole authority + collapse the issue PR phase into
  one delegation state." → the state split + `awaiting-pr` + terminal return.
- **structural** (`/tmp/saga-structural.log`): "Adopt the full hierarchical
  sub-saga; the issue must never carry PR sub-phase again." → the conformance
  partition + scoped parsing + child id/lineage.
- **delete** (`/tmp/saga-delete.log`): "Delete issue-level PR-phase tracking
  entirely; parent issue saga with one `awaiting-pr` + PR child saga." → pointer-only
  delegation, terminal-only return, the only behavior change is desync elimination.
- **oracle / ChatGPT Pro** (cross-model): "The bug was duplicated authority, not
  missing hierarchy → single authority + smallest `await_child` primitive." Added:
  deterministic correlation IDs + idempotent `ensure` recoverable from partial
  writes; **resume only on terminal, never merge-ready**; the head-bound merge-ready
  invariant; the 8 naive failure modes (§10); issue-side PR status as
  non-authoritative projection only.

**Meta-judge: `implement`.** The end-state is unanimous (state split + single
delegation state + terminal-return join + `child_workflow_wait` liveness +
conformance partition). The one tension — structural's "full new sub-saga layer"
vs. minimal/delete/oracle's "delete the duplication + smallest join" — `resolves-to`
the minimal framing: the PR entity already owns a state machine (#7), so the
structural *invariant* (issue never names a PR phase) is achieved with the least
new machinery, satisfying BEAUTY GATE (删无可删, make illegal states
unrepresentable) and structural integrity (the partition is a hard conformance
invariant) at once.

⟦AI:FKST⟧
