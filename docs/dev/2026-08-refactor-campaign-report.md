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
