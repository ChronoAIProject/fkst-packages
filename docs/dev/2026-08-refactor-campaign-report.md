# Refactoring campaign, 2026-08-05 to 2026-08-11

This records what a week-long refactoring campaign produced, what it got wrong, and which of its
numbers can be trusted. It leads with the corrections because several figures reported during the
campaign were wrong, and one self-assessment was wrong in sign.

## Corrections first

**The headline tally was contaminated for six days.** `gh pr list --author '@me'` returns the
autonomous devloop bot's PRs too, because the bot posts under the same login. Excluding
`devloop/issue/*` is insufficient — the bot also opens `fix/*` and `chore/*`. Filtering on the session
marker in the PR body gives the real figure:

| | PRs | net lines |
|---|---:|---:|
| refactoring → `integration-elonsg` | 46 | **−2153** |
| enforcement + docs → `dev` | 20 | **+2127** |
| **total** | **66** | **−26** |

Reported during the campaign: 96 PRs, +1205. Both wrong.

**A self-criticism built on that bad data was wrong in sign.** Mid-campaign I concluded "this campaign
is net line-additive and I am hiding it behind a one-way metric." The corrected numbers show
~2,150 lines of redundancy removed against ~2,130 lines of enforcement added — they nearly cancel. The
criticism read as rigorous because self-criticism always does.

**The campaign changed scope twice without saying so.** The request was 消除冗余 / 精炼代码. Days 1–3
did that. Day 4 moved to registered migration debt; day 6 moved to auditing whether the repository's
own claims are true. Both redirections were defensible on measured value, and neither was flagged as a
scope change at the time.

**The ambient-M slice campaign stopped at 7 of 10 by decision, not completion.** See cost, below.

## What is durable

Four audit documents, each with its method and coverage stated:

- `auditing-ratchet-reasons.md` — seven "do not schedule" reasons audited. **Every reason expressed as
  a number was false or unverifiable (6/6); the one expressed as a code property was true.**
- `checker-proxy-audit.md` — all 54 runner checkers opened. **1 TIGHT, 3 PROXY-SAFE, 50 PROXY-RISKY**,
  each risky one with an executed counterexample. 31 fail *open*, all defeated by indirection.
- `characterization-digest-audit.md` — 9 of 23 digests proven load-bearing; none redundant or dead.
- `2026-08-10-cas-parity-invariant-checker-design.md` — the shared harness proven **feasible and
  wrong**, with the refuted argument recorded beside the decision.

Mechanical changes: two checkers built where none existed (one had six debts drifting behind an
unenforced list); one ratchet corrected that had asserted a falsehood since 2026-06-05; two false gates
deleted; 23 characterization digests; 314 obligations retired across 7 ambient-M slices; a CI break
closed before the next substrate pin bump would have fired it.

## Cost, which was not measured until day 6

| | workers | log lines |
|---|---:|---:|
| implementation slices | 8 | **9,838,002** |
| audits and design | 6 | **360,797** |

**27× cheaper, and the audits produced every finding that changed a judgement.** No slice changed how
anything is decided. That ratio is why the slice campaign was stopped at 7 of 10 rather than run to
completion.

The audits also required no prerequisites. Reading a checker to learn what one row means, re-measuring
a "floor" for drift, and asking how many entries were individually opened could all have been done on
day 1. They were done last because they produce no diff.

## The one pattern behind almost every error

**Every misleading signal in this campaign was a summary, and every fix took under a minute.**

| signal | what it compressed away |
|---|---|
| `264 rows` | which matches were comments or unrelated bindings |
| `test: FAILURE` | which job — an artifact upload timed out; tests passed |
| `DIRTY` + no checks | CI never dispatches for a conflicted branch |
| `carrier=2` | editing vs verifying vs stuck |
| `max_workers: 20` | whether any worker was alive (`active_workers: []`) |
| `--author '@me'` | the bot shares the login |
| `552 duplicated lines` | 69 *overlapping* windows covering 272 unique lines |

The last two are mine, written during this campaign. The cost was never in the fix; it was in noticing
that a summary is a summary.

**Practical form:** anything that reduces a state to one word or one number — state what it compresses
away *before* deciding whether to trust it.

## Two rules worth keeping

**Refuting a reason does not refute its conclusion.** Three of the audited conclusions were correct
while their reasons were false. An audit that stops at the refutation turns a right answer into a wrong
one; the cas_parity case needed a second step, testing the objection that *survived*.

**Ask a worker to build the thing, not to judge whether it should be built.** Five reviewers concluded
a shared test harness was impossible because it would need nine injectable callbacks. None built it. A
worker briefed to *succeed* — and told that refuting the consensus was the most valuable available
outcome — eliminated all nine. Asking "should we?" rewards caution, and caution always answers no.

## Coverage and remaining work

Eight non-vacuity mutations came back **green** during the campaign. Each is a real coverage gap; none
was fixed, because adding an assertion is test-coverage work with its own justification and does not
belong inside a behaviour-preserving refactor.

Not done: 14 of 23 digests unclassified; slices 7–9 of ambient-M; the invariant-checker design is
decided but not implemented; the remaining intra-file duplication surface is mostly *arrangement* and
should not be extracted.

⟦AI:FKST⟧

## Addendum, 2026-08-12: the instrument, not the surface, was the limit

The section above ends by noting the remaining duplication surface is "mostly *arrangement* and should
not be extracted." That was measured further and **confirmed**: nine independent random draws
(seeds 20260811–20260819, 345 regions) classify at **~77% ARRANGEMENT, ~15% CANDIDATE, ~4% SYNTAX,
~3% MANDATED**, stable across every seed. Parallel lifecycles have parallel shapes; consolidating them
would produce a module serving two lifecycles, which this repo treats as a defect.

**But that conclusion functioned as an ending, and it was the wrong one.** It said little was left,
when what was actually left was invisible to the instrument being used.

| instrument | found | could NOT find |
|---|---|---|
| duplication sampling | 28 implementations single-sourced, −124 lines | **dead code — it is not duplicated, it is absent from everything** |
| direct mutation sampling | unwitnessed behaviour, unreachable code | behaviour that is tested but tested *wrong* |
| token-frequency scan | 46 unreachable functions, −418 lines | dead *values* — a string a validator accepts and nothing emits |

Switching from extraction to direct mutation — **for cost reasons, not insight** — surfaced a function
whose mutation killed nothing because nothing called it. Generalising that produced 17 unreachable
library exports, 3 unreachable locals, and 26 unreachable package exports. Sixteen of the last group
were pre-ports `gh` command builders orphaned when the G-ADAPTER migration moved argv construction into
`libraries/forge/` — migration residue with a history, not an artefact of the scan.

A third shape appeared only when the autonomous devloop corrected an issue filed from this work: the
intake-class outcome `"carrier"` is accepted by a validator and **emitted by nothing**, traced forward
from the single production caller which passes the literal `"folded"`. No scan run here could have
found it; it is a string, kept legal by the code that lists it.

### The two populations are nearly disjoint — measured

This is not only an argument from category. Measured between git refs, across the three deletion PRs:

```
duplicated regions before deletions: 2144
                       after:        2138
                       delta:          -6   (6 removed, 0 created)
```

**Deleting 46 unreachable functions removed 6 duplicated regions.** It should: dead code is selected by
*frequency-1 identifiers*, duplicated code by *repeated blocks*, and almost nothing satisfies both. The
6 are where a dead function happened to contain a repeated block.

So the duplication instrument was not merely slow to find the dead code — it was looking at a nearly
disjoint population. No amount of refining it would have converged on the other set.

(An earlier statement here attributed a larger drop, 2247 to 2138, to the deletions. That was wrong;
most of it came from the duplication-consolidation PRs, which remove duplicated regions by design, and
from concurrent merges by the autonomous loop. The ref-to-ref measurement above isolates the deletions.)

### What transfers

**Each instrument's shape determines the *category* of finding, not just the hit rate — and a blind
spot is invisible from inside the instrument that has it.** Eight rounds of refining the duplication
method (three gates, distinct-candidate counting, per-owner witnesses) made it measurably better and
could never have revealed what it structurally could not see. The switch came from a cost comparison,
not from noticing.

Corollary: **evidence for a method in one population is not evidence for it in another.** The dead-code
scan went 17-for-17 in `libraries/`, and `packages/` has a calling convention `libraries/` does not —
the engine invokes `M.spec`, `pipeline`, raisers and handler tables from Rust, so zero Lua references
is the *normal* state there. The 17-for-17 record carried authority into a population where its central
assumption did not hold.

⟦AI:FKST⟧

### The scan that found the dead code had its own blind spot

Stated plainly because this document earlier implied the sweep was complete: **it was not.** The
candidate scan anchored every pattern at column 0 (`^function`, `^local function`), so any callable
defined inside another block was invisible to it. An independent survey found **seven** further
definition shapes it could not see:

| shape | approx sites | scanned |
|---|---|---|
| `name = function(` | ~4674 | no |
| indented `function T.method(` | ~538 | no |
| indented `name = function(` | ~500 | no |
| `return function(` | ~70 | no |
| `local f = function(` | ~24 | no |
| colon `function T:method(` | ~15 | no |
| computed key `name[expr] = function(` | ~10 | no |

Those counts include tests, fixtures and inline anonymous callbacks, so the dead-code-relevant subset
is far smaller than the raw total — but the completeness claim was still false.

Checking three of the missed shapes yielded **3 further candidates**, which cascaded to 5 deletions
(−21 lines) once their orphaned helpers were followed. So the gap was real and nearly empty: indented
definitions are overwhelmingly live, because they sit inside `install(M)` functions that are actively
used.

**That the gap happened to be nearly empty is not a defence.** Had it held 200 dead functions, the same
reasoning that produced "four shapes, sweep complete" would have missed every one, and nothing in the
method would have signalled it. **How much a blind spot contains is independent of whether you knew it
was there** — which is this section's own thesis, arriving as evidence about the person who wrote it.

