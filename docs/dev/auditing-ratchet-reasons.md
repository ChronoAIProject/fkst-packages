# Auditing the reasons behind a "do not schedule" decision

This repository runs on ratchets, inventories and counts. Decisions about what *not* to work on are
therefore usually justified by a number: a floor, a structural count, an "all N are legitimate".

Seven such reasons were audited in one campaign (2026-08-05 to 2026-08-10). **Six of the seven were
false or unverifiable. The single one that held was the only one not expressed as a number.**

This note records the results and the method, because the failure mode is not obvious: in almost every
case the *conclusion* was correct while the *reason* was false, which is the hardest shape to notice.

## Results

| artifact | stated reason | verdict | conclusion |
|---|---|---|---|
| `service-locator.inventory` | "verified structural floor of 501" | **false** — an arithmetic complement; drifted to 498 under unrelated work | held, on a source-based basis |
| `*_cas_parity_test.lua` corpus | "a shared runner needs nine injectable callbacks" | **false** — a prototype eliminated all nine | held, for a *different* reason: it would become a second specification of the production protocol |
| `github-devloop-saga-split.inventory` | "264 is one row per governed path; the floor is 264" | **false** — add an eligible file → 265, remove one → 263 | held, restated as *dynamic exhaustive classification* |
| `monotone-gate.allowlist` | "all 96 entries are legitimate" | **unverifiable** — 21 were sampled; 75 were never opened | unsupported at the claimed scale |
| `gh-handle-construction.inventory` | "16 rows are canonical and can never be removed" | **false** — the artifact is debt-only; zero *is* a valid target | held, on a source-based basis |
| `devloop-godlib.inventory` | "typed exports give it a floor of 104" | **false** — unsupported as a numerical statement | held: `m_writes` is not a valid zero-target proxy |
| `dept-failure-surface.allowlist` | "3 of 11 are behaviour changes, not formalisations" | **TRUE** | held — and 8 departments were formalised and landed on this distinction |

## The pattern

**Reasons expressed as numbers failed 6 for 6. The reason expressed as a code property held.**

`dept-failure-surface`'s reason survived because it was checkable in source: all three departments opt
out with `retry = false`, while the proposed `retry = {}` enables host-resolved retries, and each
pipeline has concrete failure paths with externally observable work. That is a claim about behaviour,
not about a count.

Every "floor" dissolved on measurement — an arithmetic complement, a file-set-determined count that
moves when you add a file, a lexical regex that counts comments and unrelated local bindings, an
aggregate impression from a purposive sample.

## Why this is worth checking

**A correct conclusion resting on a false reason is more dangerous than a wrong conclusion.** It
survives review — the conclusion checks out — while the false reason keeps being inherited by later
decisions. The cas_parity reason had already propagated into two merged PR bodies as settled fact
before anyone tested it, and the `501` floor was used to put ~500 units out of a campaign's scope.

**Refuting a reason does not refute its conclusion.** Three conclusions here were correct while their
reasons were false. An audit that stops at the refutation will flip a right answer into a wrong one;
the cas_parity case required a second step — testing the *surviving* objection — to reach
right-answer-right-reason.

## Method

Audit reasons **separately** from conclusions, and allow three outcomes rather than two:

- `reason_true` — a perfectly good finding; record what was verified and how
- `reason_false` — then state explicitly whether the conclusion still holds **on some other basis you
  can name**, or is now unsupported
- `reason_unverifiable` — say what evidence would be needed

Practical checks that did the work here:

1. **Drift test.** Re-measure after unrelated work lands, or add and remove an eligible file in a
   scratch root. A "structural floor" that moves is a snapshot of a lexical count.
2. **Open the producer.** Read the checker and state what *one row* represents before valuing the
   total. One-row-per-governed-path has a floor above zero; one-row-per-violation has a floor of zero.
3. **Ask how many were individually checked.** "All N are legitimate" is usually an aggregate
   impression. Record "21 of 96 sampled" rather than "96 legitimate".
4. **Try to build the thing that was called impossible.** Brief the attempt to *succeed*, and say that
   refuting the existing consensus is the most valuable available outcome. Asking "should we?" rewards
   caution and caution always answers no; five reviewers agreed on the cas_parity corpus and none of
   them built it.

When recording a refusal, record **what was actually verified alongside it** — how many entries were
opened, by which command. A refusal is cheap to produce and expensive to check, which is exactly why
its reason tends never to be tested.

⟦AI:FKST⟧
