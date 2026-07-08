# The consensus engine as a universal, engine-owned philosophy core

Status: design spec, not yet implemented. Produced 2026-07-09 via multi-round adversarial consensus (independent thinking and review perspectives across models). Implementation touches the fkst-substrate consensus engine and this repo's `github-devloop-pr` risk gate; see Rollout for the mechanical test matrix.

Intent: replace proposal-shaped reviewer labels with one fixed engine-owned philosophy core: five seats, including a coupled locus dyad, while moving high-risk review out of the philosophy core into an engine-owned risk gate.

## Problem / Root Cause

Consensus is currently a source-agnostic adversarial debate pipeline. The decide department consumes a proposal, derives `angles`, spawns Phase B angle judgments, may run Phase R rebuttals, and falls through to Phase S synthesis when the first two phases do not reach a decision (`packages/consensus/departments/decide/main.lua:85-193`). The concrete flow is:

- Phase B: `core.angles(proposal)` is read at decision time (`packages/consensus/departments/decide/main.lua:88`), and each angle is spawned (`packages/consensus/departments/decide/main.lua:97-100`).
- Phase R: rebuttal runs after angle results when `rebuttal.can_run(angle_results)` allows it (`packages/consensus/departments/decide/main.lua:128-163`).
- Phase S: synthesis parses or repairs the synthesis result and returns the decision result (`packages/consensus/departments/decide/main.lua:165-192`).

The root cause is label-level configurability masquerading as philosophy-level configurability. The engine currently has default seats of `teleology`, `parsimony`, and `fidelity`, plus a `max_angles` of 4 (`packages/consensus/core.lua:8-10`). If `proposal.angles` exists, `normalized_angles` accepts those proposal-provided tokens after only bounded-string and control-character validation, then returns those names as the active angle list (`packages/consensus/core.lua:248-266`). Eligibility is satisfied when `normalized_angles(proposal) ~= nil` (`packages/consensus/core.lua:268-310`), and `M.angles(proposal)` simply returns that normalized proposal/default list (`packages/consensus/core.lua:313-315`).

That lets proposals rename or choose seats, but it does not let them install a real judging lens. Prompt rendering has a hardcoded bias table for known seats in `packages/consensus/prompts/angle.lua:28-33`. Unknown angle names fall through to the generic text `Bias: <angle>. Judge from this named perspective.` (`packages/consensus/core/prompt_rendering.lua:170-173`). The system is therefore open to cosmetic extension but closed to semantic extension: a proposal can create a label, but the engine supplies no first-class philosophy, rebuttal obligations, synthesis obligations, or safety semantics for that label.

High-risk review currently leaks through this same proposal angle channel. The devloop builder injects `proposal.angles = { "teleology", "parsimony", "fidelity", "high-risk" }` when `high_risk == true` (`libraries/devloop/payloads/builders.lua:387-390`). Consensus then special-cases `high-risk` inside prompt rendering: it is outside the BEAUTY-GATE philosopher seats (`packages/consensus/core/prompt_rendering.lua:107-113`), receives a high-risk threat-model contract (`packages/consensus/core/prompt_rendering.lua:121-132`), and has a hardcoded prompt bias in the angle prompt table (`packages/consensus/prompts/angle.lua:32`). That proves high-risk is already not a philosophy seat, even though it currently consumes an angle slot.

## Architect Rulings

1. Consensus is a universal philosophy core, owned by the engine. Upstream/downstream, source-of-truth, ownership, and containment are philosophy of the same kind as teleology, parsimony, and fidelity; they are not domain package concerns and are not proposal options.

2. The upstream/downstream axis must be a dyad of two clashing seats. It is not one folded seat. The two locus pressures must run together and must actually clash in the debate mechanics.

## The 5 Fixed Engine-Owned Seats

Proposal cannot select, rename, reshape, or omit these seats. The engine owns their identity, prompt contract, rebuttal obligations, synthesis obligations, and output parsing.

| Seat | Shape | Universal Lens | What It Attacks |
| --- | --- | --- | --- |
| `teleology` | single-pole | What end is this for; is the form forced by that purpose? | Skipped purpose, missing inevitability, purposeless structure, designs whose mechanism does not follow from their stated end. |
| `parsimony` | single-pole | What unnecessary structure, assumption, or machinery should be removed? | Magic numbers, unnecessary branches, duplicated machinery, extra concepts, assumptions that do not earn their keep. |
| `fidelity` | single-pole | Does it preserve facts, source, and constraints without proxy or narrative substitution? | Proxy-over-truth, narrative-over-verification, source drift, unsupported claims, replacing facts with summaries or vibes. |
| `natural-ownership` | locus dyad upper pole | Which locus naturally owns this invariant, duty, or constraint? Is the solution at the layer with semantic responsibility and causal control? | Symptom patches, duplicated enforcement, delegating an invariant to dependents, making consumers enforce what producers own. |
| `proportional-containment` | locus dyad lower pole | How far may this intervention rightfully bind, across scope, authority, and duration, given the evidence? | Over-hoisting, speculative abstraction, over-coupling, turning a local fact into universal law. |

The convergence target of the locus dyad is the natural owner layer, explicitly not the highest layer imaginable. This anti-over-reach guard is baked into the seat question: the correct answer is the layer that owns the invariant and has causal control, not the broadest possible abstraction.

## Locus Dyad Coupling + Must-Clash Mechanics

The locus dyad is structurally coupled.

- Both-or-neither execution: if either `natural-ownership` or `proportional-containment` runs, both must run. Under the fixed five-seat core, both always run.
- Phase B obligation: both poles produce independent first-pass judgments from their own opposing pressure. Natural-ownership must argue for the locus that owns the invariant. Proportional-containment must argue for the narrowest rightful binding scope supported by evidence.
- Phase R obligation: each locus pole must answer the other pole's claim. `natural-ownership` must answer the containment challenge that it is over-hoisting or over-binding. `proportional-containment` must answer the ownership challenge that it is leaving responsibility with the wrong layer, creating symptom patches, or making dependents enforce producer-owned invariants.
- Phase S obligation: synthesis must explicitly name the natural-owner layer and state why it is not merely the highest layer or merely the lowest layer. A synthesis that reaches a decision without naming that layer is structurally incomplete.

This makes the clash mechanical rather than aspirational. The engine does not merely hope two reviewers disagree; it makes the two locus poles mutually visible, requires reciprocal rebuttal, and requires synthesis to resolve the ownership-versus-containment pressure directly.

## Locus Structural Contract

The locus dyad is enforced in the existing deterministic parser layer, beside `⟦FKST:VERDICT⟧`, `⟦FKST:GAP⟧`, `⟦FKST:STANCE⟧`, and `verified-move`. It is not a new subsystem. A reached payload is structurally invalid unless the parsed locus contract is complete.

Phase B, for each locus seat:

```text
⟦FKST:LOCUS-CLAIM⟧ seat=<natural-ownership|proportional-containment> id=<bounded-id>
⟦FKST:LOCUS-PRESSURE⟧ seat=<natural-ownership|proportional-containment> text=<bounded-pressure-text>
```

The `natural-ownership` pole must also emit:

```text
⟦FKST:OWNER-CANDIDATE⟧ layer=<bounded-layer>
```

The `proportional-containment` pole must also emit:

```text
⟦FKST:CONTAINMENT-SCOPE⟧ scope=<bounded-scope>
```

Phase R, for each locus seat:

```text
⟦FKST:LOCUS-ANSWER⟧ seat=<natural-ownership|proportional-containment> answers=<opposing-pole-claim-id>
⟦FKST:LOCUS-ANSWER-TEXT⟧ seat=<natural-ownership|proportional-containment> text=<bounded-answer-text>
```

Phase S, before any valid reached decision:

```text
⟦FKST:NATURAL-OWNER-LAYER⟧ layer=<bounded-layer>
⟦FKST:NOT-HIGHEST-LAYER⟧ reason=<bounded-reason>
⟦FKST:NOT-LOWEST-LAYER⟧ reason=<bounded-reason>
```

Validator rules:

```text
valid_locus_phase_b =
  has_claim(natural-ownership)
  and has_claim(proportional-containment)
  and unique_bounded_claim_ids(natural-ownership, proportional-containment)
  and has_bounded_pressure(both)
  and has_bounded_owner_candidate(natural-ownership)
  and has_bounded_containment_scope(proportional-containment)
  and all_locus_lines_have_matching_known_locus_seat
  and no_duplicate_locus_required_lines

valid_locus_phase_r =
  has_answer(both)
  and has_bounded_answer_text(both)
  and natural_ownership_answer.answers == proportional_containment_claim.id
  and proportional_containment_answer.answers == natural_ownership_claim.id
  and both_answer_targets_exist
  and no_answer_targets_self_claim
  and no_duplicate_locus_answer_lines

valid_locus_phase_s =
  has_bounded_natural_owner_layer
  and has_bounded_not_highest_layer_reason
  and has_bounded_not_lowest_layer_reason
```

For these validators, `bounded` means length-checked, control-character-rejected, and passed through the same neutralizer required by the FKST parser lines above.

The engine fails closed: `consensus_reached` is invalid unless `valid_locus_phase_b`, `valid_locus_phase_r`, and `valid_locus_phase_s` all pass. Parsed reached payloads and provenance must carry the natural-owner fields and the locus proof data: `natural_owner_layer`, `not_highest_layer_reason`, `not_lowest_layer_reason`, locus claim ids, reciprocal answer bindings, owner candidate, containment scope, and bounded pressure/answer text. Tests must mutate or omit each required line and prove the engine refuses a merge-ready decision.

## Orthogonality Rationale

The core has five seats, not four, because the locus dyad is not a replacement for parsimony, teleology, or fidelity.

Parsimony is not proportional-containment. A one-sentence rule can be perfectly parsimonious yet catastrophically uncontained: "all future cases must follow this local exception." Conversely, a contained intervention can be complex because the local fact pattern genuinely requires careful handling. Economy of machinery and scope of binding are independent axes, so parsimony remains its own seat and must not be absorbed into containment.

Natural-ownership is not teleology. Teleology asks what end the work serves and whether the form is forced by that purpose. Ownership asks which locus owns the obligation to serve that end. A warning label may serve safety, but the safety invariant may naturally belong in design constraints rather than downstream copy.

Neither dyad pole overlaps fidelity. Fidelity verifies facts, sources, constraints, and evidence. The locus dyad consumes verified facts to decide layer and scope. It does not decide whether the facts are true; it decides where the invariant belongs and how far the intervention may bind.

## Removals

Remove `angle_bias`. The round-1 injectable-philosophy idea has no legitimate use under the final architecture. Philosophy is engine-owned. Letting proposals inject philosophical bias would create judge-shopping and fragment the core.

Delete the unknown-angle fallback in prompt rendering. The current fallback at `packages/consensus/core/prompt_rendering.lua:170-173` silently creates fake empty seats. Unknown seats must fail closed because a label without an engine-owned lens is not a philosophy seat.

Remove proposal-level seat selection entirely. `proposal.angles` must no longer choose the philosophy core. The current `normalized_angles` path accepts proposal-supplied seat labels (`packages/consensus/core.lua:248-266`), and the PR review builder uses that path to add `high-risk` as a fourth angle (`libraries/devloop/payloads/builders.lua:387-390`). That is the ugliest remaining defect: if a proposal can select, rename, omit, or reshape seats, it can judge-shop by omission and can turn the required locus dyad into two reviewers that never clash.

After this change, proposals carry facts, context, and evidence forms only: `source_ref`, `content_fetch`, recurrence facts, edit sites, package and layer boundaries, risk classification, tests, and other source evidence. They never carry seat identity and never carry philosophy. Software-specific evidence forms are facts consumed by universal lenses, not lenses themselves.

`proposal.angles`, `angle_bias`, and any proposal-owned seat identity are schema-invalid before debate. The engine must reject the proposal fail-closed, not silently ignore those fields, because silent ignore hides stale callers and migration bugs.

## Fixed-Core Migration Contract

For every schema-valid proposal admitted to debate, `core.angles(proposal)` returns the fixed engine-owned table:

```lua
{ "teleology", "parsimony", "fidelity", "natural-ownership", "proportional-containment" }
```

The current `default_angles` and `max_angles` definitions at `packages/consensus/core.lua:8-10` are migration anchors only. `default_angles` becomes the fixed core table above. `max_angles` must be removed or renamed away from the philosophy core so the legacy bound cannot truncate or reject the five seats. `normalized_angles` at `packages/consensus/core.lua:248-266` must no longer select the active core from `proposal.angles`; it becomes proposal-schema validation that rejects proposal-owned seat identity before debate. No valid proposal content selects the core.

The blocking-gap list bound must also derive from the fixed philosophy seat count. The current `max_gaps = 4` and `review_gap_list` overflow behavior (`packages/consensus/core.lua:19`, `packages/consensus/core.lua:483-496`) are migration anchors only. Under the five-seat core, a valid all-reject gate-mode aggregate must carry five bounded gaps through the aggregate reject path (`packages/consensus/core.lua:551-560`), not truncate them and not return nil.

Phase R admission must derive from the fixed seat table and the required locus dyad set, not from the current hard-coded `#angle_results == 3` check at `packages/consensus/departments/decide/rebuttal.lua:68-70`. Under the five-seat core, Phase R must run whenever the fixed core results are present and the locus dyad can perform reciprocal rebuttal.

Any proposal entering the philosophy core requires the two locus Phase B claims and reciprocal Phase R answers before a valid reached payload. Existing early-exit logic must not bypass that obligation. The Phase-B aggregate path at `packages/consensus/departments/decide/main.lua:119-126` and the post-rebuttal reached path at `packages/consensus/departments/decide/main.lua:152-162` must not produce `consensus_reached` until the locus dyad's reciprocal rebuttal and the Phase-S locus resolution have parsed valid. A reached decision is ship-ready only after synthesis carries `valid_locus_phase_s`.

Gate-mode reject evidence remains mechanically carried by parsed blocking gaps, not by synthesis prose. Phase S provides locus proof and framing only; the synthesis parser accepts reached decisions and bounded framing (`packages/consensus/departments/decide/synthesis.lua:133-145`) but does not parse gap lines. Therefore a gate-mode reject reached after synthesis must compose its `blocking_gaps` from the Phase-R aggregate blocking gaps (`packages/consensus/core.lua:551-560`) plus a valid parsed locus proof. If the Phase-R aggregate has no bounded blocking gaps, the reached reject is invalid even if synthesis prose describes a gap. The reached payload may then carry those existing bounded gaps through the current payload validation path (`packages/consensus/core.lua:626-632`).

Phase-R aggregate reject dominates Phase-S approval. If the Phase-R aggregate is reject because any seat rejected with bounded gaps, the final decision is reject. Phase S may frame the reject and resolve the locus proof; it may not upgrade the result to approve, even if parsed synthesis returns `reached:approve` through `packages/consensus/departments/decide/synthesis.lua:361-378`.

Consumers may vary proposal facts, evidence forms, source adapters, verdict mode, and adapter-provided non-PR risk inputs. Consumers may not vary philosophy seats, seat order, seat count, seat prompts, rebuttal obligations, synthesis obligations, or PR risk classification.

## High-Risk -> Framework-External Risk-Gate Interface

High-risk is a safety and failure-mode sentinel, not a philosophy seat. It must not consume a philosophy-seat slot, and it must not be proposal-named. Today, high-risk is injected by the domain through `proposal.angles` (`libraries/devloop/payloads/builders.lua:387-390`) while its semantics are hardcoded in consensus prompt rendering (`packages/consensus/core/prompt_rendering.lua:107-132`) and the angle prompt table (`packages/consensus/prompts/angle.lua:32`). After proposal seat selection is removed, high-risk exits the philosophy core and becomes a framework-external, engine-owned risk gate.

Concrete interface:

```lua
risk_gate.review({
  proposal = proposal,
  authoritative_risk = derive_current_pr_risk({
    source_ref = proposal.source_ref,
    content_fetch = proposal.content_fetch,
    pr_head = reviewed_head_sha,
    changed_paths = changed_paths,
    paths_digest = paths_digest,
  }),
  philosophy_decision = reached_payload_or_nil,
  philosophy_results = seat_results,
  verdict_mode = core.verdict_mode(proposal),
})
-- returns one of:
-- { decision = "pass", evidence_snapshot_digest = "...", annotations = { ... } }
-- { decision = "annotate", evidence_snapshot_digest = "...", annotations = { ... } }
-- { decision = "veto", evidence_snapshot_digest = "...", blocking_gaps = { ... }, annotations = { ... } }
-- { decision = "defer", evidence_snapshot_digest = "...", defer_reason = "...", required_evidence = { ... }, stale_evidence = { ... }, annotations = { ... } }
```

For PR review, risk is re-derived from authoritative current evidence, not trusted from proposal-carried fields. `source_ref`, `content_fetch`, the reviewed PR head SHA, changed paths, and `paths_digest` are the source of truth, matching the current re-derive-from-source behavior in `libraries/devloop/context_bundle.lua:572-583` and path classification in `libraries/devloop/github_risk.lua:72-94`. Missing, stale, unknown, or mismatched risk evidence fails closed to high risk. Proposal-carried `risk_facts` may not suppress or downgrade a PR risk gate and may not be used as merge-ready evidence.

Derived risk facts are engine-readable facts, not chosen seats. Minimal derived shape:

```lua
derived_risk_facts = {
  high_risk = true,
  known = true,
  surfaces = { "ci", "auth", "dependency", "scheduler", "workflow", "lockfile" },
  evidence = {
    source_ref = proposal.source_ref,
    content_fetch = proposal.content_fetch,
    pr_head = reviewed_head_sha,
    changed_paths = { ... },
    paths_digest = paths_digest,
    edit_sites = { ... },
    tests = { ... },
  },
}
```

The gate triggers from facts:

- `derived_risk_facts.high_risk == true`, or
- `derived_risk_facts.known ~= true`, or
- `derived_risk_facts.surfaces` contains an engine-owned high-risk surface name, such as CI, auth, dependency, scheduler, workflow, or lockfile.

`derived_risk_facts.surfaces` is intersected with an engine-owned allowlist. Unknown surfaces are schema errors and fail closed. They never create new risk semantics and never become a disguised seat-selection channel.

The gate can inspect, veto, annotate, or defer:

- Inspect: read the proposal, source evidence, content manifest, changed paths, tests, and philosophy decision.
- Veto: return `decision = "veto"` with bounded `blocking_gaps`.
- Annotate: return `decision = "annotate"` or `pass` with bounded advisory annotations.
- Defer: return `decision = "defer"` when required risk evidence is missing or stale for the current evidence snapshot.

`defer` is a bounded terminal non-merge-ready state for the current evidence snapshot. It is not an automatic retry instruction and must never cache `consensus_reached` approval while deferred. The gate may re-run only when required evidence changes or an explicit workflow event supplies the missing evidence. Required shape:

```lua
{ decision = "defer", evidence_snapshot_digest = "...", defer_reason = "...", required_evidence = { ... }, stale_evidence = { ... }, annotations = { ... } }
```

`evidence_snapshot_digest`, `defer_reason`, `required_evidence`, `stale_evidence`, and `annotations` are bounded. Same inputs plus the same missing or stale evidence must return the same terminal defer result without a retry loop. New evidence may trigger a new gate run only by changing `evidence_snapshot_digest` or by an explicit workflow event supplying the missing evidence. This follows the repo liveness and saga-totality rule: bounded budget, terminal WHY, no unbounded limbo.

Before:

```lua
proposal.angles = { "teleology", "parsimony", "fidelity", "high-risk" }
```

The high-risk review appears as another angle result. In gate mode, parsing requires a reject verdict to include exactly one `FKST:GAP` line (`packages/consensus/core.lua:468-474`). Aggregation rejects the merge if any angle result rejects and preserves the collected blocking gaps (`packages/consensus/core.lua:551-560`). The reached payload validates and carries those blocking gaps (`packages/consensus/core.lua:598-630`).

After:

```lua
derived_risk_facts = {
  high_risk = true,
  known = true,
  surfaces = { "ci", "workflow" },
  evidence = {
    source_ref = proposal.source_ref,
    content_fetch = proposal.content_fetch,
    pr_head = reviewed_head_sha,
    changed_paths = changed_paths,
    paths_digest = paths_digest,
  },
}
```

The philosophy core always runs the fixed five seats. After the philosophy decision is available, `risk_gate.review(...)` runs if the authoritative derived risk facts trigger it. For merge safety, `risk_gate.review(...).decision == "veto"` maps to the same external decision semantics as the current high-risk `reject`: a bounded list of blocking gaps is attached to the reached payload and the final gate decision is reject. `pass` preserves approval, `annotate` preserves approval with advisory evidence, and `defer` prevents merge-ready approval until the risk evidence is available. The evidence semantics are unchanged: a blocking high-risk claim must still name an evidenced high-risk security gap and cite the supplied source/diff evidence, matching the current high-risk gate calibration (`packages/consensus/core/prompt_rendering.lua:126-131`) and the existing blocking-gap parse/aggregation contract (`packages/consensus/core.lua:468-474`, `packages/consensus/core.lua:551-560`).

The migration must also replace the positive high-risk approval evidence path. Today, review result requires an approved `angle="high-risk"` in `reached.angle_results` before merge readiness (`packages/github-devloop-pr/departments/review_result/main.lua:149-171`), writes a marker with `angle="high-risk"` and `verdict="approve"` (`libraries/devloop/markers/builders.lua:238-257`), parses that trusted marker (`libraries/devloop/markers/facts.lua:385-431`), and the merge gate requires the parsed fact (`packages/github-devloop-pr/core/high_risk_merge_gate.lua:5-29`). That whole angle-shaped path is removed in one contract change, with no dual path.

The same no-dual-path migration includes review carry-over and replay. The live carry-over path currently reparses the legacy angle-shaped high-risk evidence fact before allowing approved-lineage carry-over (`packages/github-devloop-pr/core/review_carry_over.lua:12-37`). That consumer must read the new `RiskGateEvidence` fact and must not retain a legacy `angle="high-risk"` parser.

Risk gate output becomes a first-class `RiskGateDecision` consumed by `review_result`:

```lua
RiskGateDecision = {
  schema = "risk_gate.decision.v1",
  producer = "risk_gate.review",
  issue_proposal = trusted_issue_proposal_id,
  issue_version = trusted_issue_version,
  pr_number = trusted_pr_number,
  reviewed_head_sha = trusted_reviewed_head_sha,
  review_proposal = trusted_review_proposal_id,
  canonical_review_dedup = canonical_review_dedup,
  paths_digest = authoritative_paths_digest,
  evidence_snapshot_digest = evidence_snapshot_digest,
  decision = "pass" | "annotate" | "veto" | "defer",
  annotations = { ... },
  blocking_gaps = { ... },
  -- present only when decision == "defer":
  defer_reason = "...",
  required_evidence = { ... },
  stale_evidence = { ... },
}
```

For PR review, `issue_proposal` and `review_proposal` are distinct lineage keys. The PR review proposal builder sets `proposal_id = review_id` (`libraries/devloop/payloads/builders.lua:431-435`), so `proposal.proposal_id` is the review proposal, not the backing issue proposal. The backing issue proposal and issue version must be derived from trusted PR origin and `review_result` state; `review_result` parses the PR review proposal id and cross-checks `source_ref` before acting (`packages/github-devloop-pr/departments/review_result/main.lua:55-63`). A decision must fail closed if these trusted lineage values cannot be derived.

`blocking_gaps` use the same string bounds as current `⟦FKST:GAP⟧` handling, with list cardinality derived from the fixed philosophy seat count. Validator rules:

- `evidence_snapshot_digest` is required and bounded for every `RiskGateDecision` value: `pass`, `annotate`, `veto`, and `defer`.
- `decision == "veto"` requires at least one bounded `blocking_gaps` entry and no defer fields.
- `decision in { "pass", "annotate" }` requires `blocking_gaps` empty, no defer fields, and emits `RiskGateEvidence`.
- `decision == "defer"` requires `blocking_gaps` empty, bounded `defer_reason`, bounded `required_evidence`, bounded `stale_evidence`, no `RiskGateEvidence` emitted, and a final non-merge-ready terminal state for this `evidence_snapshot_digest`. The gate may re-run only on a changed `evidence_snapshot_digest` or an explicit workflow event supplying the missing evidence.

`review_result` maps a veto directly:

```lua
if gate_decision.decision == "veto" then
  final.decision = "reject"
  final.blocking_gaps = gate_decision.blocking_gaps
  final.annotations = merge(philosophy_annotations, gate_decision.annotations)
end
```

For positive approval evidence, `pass` and `annotate` emit a trusted `RiskGateEvidence` fact with equivalent merge-gate standing to today's high-risk approve marker:

```lua
RiskGateEvidence = {
  schema = "github-devloop.risk_gate_evidence.v1",
  producer = "github-devloop-pr.review_result",
  issue_proposal = issue_proposal_id,
  issue_version = issue_version,
  pr_number = pr_number,
  reviewed_head_sha = reviewed_head_sha,
  review_proposal = review_proposal_id,
  canonical_review_dedup = canonical_review_dedup,
  paths_digest = paths_digest,
  evidence_snapshot_digest = evidence_snapshot_digest,
  decision = "pass" | "annotate",
  annotations = { ... },
  blocking_gaps = {},
}
```

Trusted parser rules:

- parse only trusted marker comments, using the same trust boundary as the current high-risk evidence parser;
- require exact matches for issue proposal, issue version, PR number, reviewed head SHA, review proposal, canonical review dedup, paths digest, and `evidence_snapshot_digest` against trusted current PR origin, trusted `review_result` state, the current authoritative evidence snapshot or trusted current `review_result` state bound to that snapshot, and the corresponding `RiskGateDecision`;
- require `decision` to be `pass` or `annotate` for merge-ready approval evidence;
- reject any marker with `angle`, `verdict`, `angle_digest`, unknown schema, invalid SHA, noncanonical review dedup, unbounded annotations, or any blocking gaps on a positive decision;
- return nil on any mismatch so merge readiness fails closed.

Before positive evidence marker:

```text
fkst:github-devloop:high-risk-review-evidence:v1 ... risk="high" angle="high-risk" verdict="approve" ...
```

After positive evidence marker:

```text
fkst:github-devloop:risk-gate-evidence:v1 ... decision="pass|annotate" ...
```

`review_result`, the merge gate, and review carry-over/replay consume `RiskGateEvidence`, not `angle_results` and not `angle="high-risk"` markers. Positive `RiskGateEvidence` must exact-match its `RiskGateDecision.evidence_snapshot_digest`, and merge-gate parsing must exact-match the marker digest against the current authoritative evidence snapshot or trusted current `review_result` state bound to that snapshot. Merge-gate evidence semantics are unchanged: a high-risk PR still needs a trusted positive fact bound to the issue proposal, issue version, PR number, reviewed head SHA, review proposal, canonical review dedup, paths digest, and evidence snapshot digest before merge readiness can pass.

## Proposal Schema After Change

The proposal schema becomes facts-only with respect to judgment. It may include:

- identity and source: `schema`, `proposal_id`, `dedup_key`, `source_ref`, `title`, `body`;
- context and evidence: `context`, `content_fetch`, recurrence facts, issue or PR metadata, edit sites, package and layer boundaries, changed paths, test evidence, findings records, convergence question;
- risk facts for non-PR adapters only: bounded risk evidence references that cannot suppress PR risk derivation, choose seats, or override authoritative current evidence;
- mode and control facts needed by the workflow, such as `verdict_mode`, round, and convergence fields.

It must not include:

- seat identity;
- philosophy identity;
- `angles` as a selection mechanism;
- `angle_bias`;
- proposal-owned prompt text that changes a seat's judging lens.

Unknown seat identity must fail closed at the engine boundary. A proposal that supplies `angles`, `angle_bias`, prompt overrides, or any other seat identity is schema-invalid before debate; it must not alter the philosophy core and must not be silently ignored.

## Gate: Ship-On-Lens-Completeness vs Deferred Empirical Calibration

This ships on lens completeness, not on empirical superiority. The architectural admissibility gate for the locus dyad is:

```text
universal_across_domains
&& not_reducible_to_existing_seats
&& has_distinct_failure_mode
&& has_a_legitimate_opposing_pressure
&& can_participate_in_B_R_S_without_domain_jargon
```

The locus dyad passes this gate:

- It is universal across domains because every decision has some layer or locus that owns the invariant and some rightful binding scope.
- It is not reducible to teleology, parsimony, or fidelity for the orthogonality reasons above.
- It has distinct failure modes: symptom patches, delegated invariants, over-hoisting, and over-binding.
- It has a legitimate opposing pressure: ownership pushes toward the layer with semantic responsibility and causal control, while containment pushes against overreach.
- It can participate in Phase B, Phase R, and Phase S without domain jargon.

The existing ESSENCE/IDEAL advisory language does not defeat the new seats. Prompt rendering currently includes an ESSENCE and IDEAL rubric as context (`packages/consensus/core/prompt_rendering.lua:85-99`), and the converge calibration explicitly says IDEAL is context only and never an abstain ground (`packages/consensus/core/prompt_rendering.lua:81-82`). Advisory rubric mention is not a first-class adversarial lens with standing to judge, rebut, and force synthesis.

Do not claim empirical superiority yet. "This transcript would have improved" is a separate empirical-miss claim. It needs calibration-transcript evidence and is deferred to post-rollout calibration. It is not a ship blocker.

Future calibration plan:

- collect representative pre-rollout and post-rollout transcripts across issue intake, convergence, PR review, and high-risk PR gates;
- label cases where ownership, containment, or their clash was the decisive missing lens;
- measure false positives, false negatives, abstain rates, synthesis failures, and merge-gate veto quality;
- compare transcript outcomes against the fixed five-seat core and risk-gate behavior;
- accept empirical superiority only after calibrated transcript evidence shows fewer ownership/containment misses without unacceptable new overreach or abstain noise.

## SPEC-Form Rationale

Best form: a fixed engine-owned seat table, a coupled dyad, and explicit removals.

Rejected alternatives:

- Injectable philosophy primitive: rejected because it enables judge-shopping, fragments shared semantics, and recreates the fake-seat problem in a more powerful form.
- Domain package: rejected because ownership and containment are universal lenses, not software-only evidence forms.
- New subsystem for philosophy: rejected because the existing Phase B / Phase R / Phase S machinery already supplies adversarial judgment, rebuttal, and synthesis. The change is to the fixed seat contract and dyad obligations, not to the debate model.
- No change: rejected because it leaves the asymmetry, the unknown-angle fallback, high-risk-as-angle leakage, and judge-shopping-by-omission intact.

## Rollout Order + Conformance / Tests

1. Introduce the fixed engine-owned seat table with exactly five seats: `teleology`, `parsimony`, `fidelity`, `natural-ownership`, and `proportional-containment`.

2. Migrate `core.angles(proposal)` to return the fixed five seats for every schema-valid proposal admitted to debate. Tests must prove `proposal.angles` is rejected before debate, does not select the core, and that the active order is exactly the fixed table.

3. Remove or rename `max_angles` for the philosophy core. Tests must prove the legacy bound cannot truncate, reject, or otherwise collide with the five-seat core. Derive the blocking-gap list bound from the fixed philosophy seat count; tests must prove five rejecting seats produce five bounded gaps, not nil.

4. Remove proposal seat selection. `proposal.angles`, `angle_bias`, prompt overrides, and any proposal-owned seat identity are schema-invalid before debate. Tests must prove proposals cannot rename, omit, add, reorder, bias, or silently preserve stale seat fields.

5. Delete the unknown-angle fallback. Tests must prove unknown seats fail closed and never render `Bias: <angle>. Judge from this named perspective.`

6. Enforce Phase R admission from the fixed seat table and the locus dyad set, not `#angle_results == 3`. Tests must prove Phase R runs with all five seats and that each locus pole receives the other pole's Phase B claim.

7. Enforce the Phase B locus structural contract. Tests must mirror `valid_locus_phase_b`: require both locus claims; unique bounded claim ids; bounded pressure for both seats; bounded owner candidate for `natural-ownership`; bounded containment scope for `proportional-containment`; matching known locus seats on every locus line; and no duplicate required locus lines. Each omitted, duplicated, unknown-seat, mismatched-seat, control-character, overlong, or duplicate-id mutation must make the engine refuse a reached merge-ready decision.

8. Enforce reciprocal Phase R locus answers. Tests must mirror `valid_locus_phase_r`: require answers and bounded answer text for both locus seats; require `natural-ownership` to answer the `proportional-containment` claim id and `proportional-containment` to answer the `natural-ownership` claim id; require both answer targets to exist; reject self-answers; and reject duplicate answer lines. Each omitted, duplicated, swapped-id, nonexistent-target, self-target, control-character, overlong, unknown-seat, or mismatched-seat mutation must make the engine refuse a reached merge-ready decision.

9. Enforce Phase S locus resolution. Tests must mirror `valid_locus_phase_s`: require bounded `⟦FKST:NATURAL-OWNER-LAYER⟧`, bounded `⟦FKST:NOT-HIGHEST-LAYER⟧`, and bounded `⟦FKST:NOT-LOWEST-LAYER⟧`. Each omitted, duplicated, control-character, or overlong mutation must prove synthesis cannot reach a valid decision unless all three parse and are carried into reached payload provenance.

10. Ban early-reach bypass. Tests must prove neither the Phase-B aggregate path nor the post-rebuttal reached path can emit `consensus_reached` before valid reciprocal locus rebuttal and valid Phase-S locus resolution.

11. Move high-risk out of `proposal.angles`. Tests must prove authoritative derived high-risk facts trigger `risk_gate.review(...)` and never create a philosophy seat.

12. Enforce `derived_risk_facts.surfaces` allowlist semantics. Tests must prove known surfaces trigger the risk gate, unknown surfaces schema-error fail closed, and surfaces cannot create seat identity or risk semantics outside the allowlist.

13. Preserve high-risk veto semantics. Tests must prove a risk-gate veto maps to `final.decision = "reject"`, carries bounded blocking gaps with the same bounds as current `⟦FKST:GAP⟧`, merges risk annotations with philosophy annotations, and produces the same external reject behavior as the current high-risk angle reject path. Gate-mode reject tests must also prove reject evidence is composed from Phase-R aggregate `blocking_gaps` plus a valid parsed locus proof, that synthesis framing alone cannot supply gaps, that a reject without aggregate blocking gaps fails closed, and that a Phase-R aggregate reject cannot be overridden by a later Phase-S `reached:approve`.

14. Preserve high-risk positive evidence semantics without the high-risk angle. Tests must prove `pass` and `annotate` use the canonical `decision` field, emit a trusted `RiskGateEvidence` fact, and that merge readiness consumes that fact instead of `angle_results`, `angle="high-risk"`, `verdict="approve"`, or `angle_digest`.

15. Enforce `RiskGateDecision` and `RiskGateEvidence` trust rules. Tests must mutate each binding key: issue proposal, issue version, PR number, reviewed head SHA, review proposal, canonical review dedup, paths digest, `evidence_snapshot_digest`, `decision`, annotations, and blocking gaps. They must prove `issue_proposal` and `review_proposal` are distinct, derived from trusted PR origin and `review_result` state, and exact-match between decision and evidence. Missing digest, mismatched digest, stale old positive marker after digest change, legacy marker without digest, any mismatch, unbounded field, or legacy noncanonical decision field must fail closed with no merge-ready approval.

16. Enforce no dual high-risk path. Tests must prove legacy high-risk angle markers alone do not satisfy merge readiness; `review_result` no longer scans `reached.angle_results` for `angle == "high-risk"`; review carry-over/replay consumes `RiskGateEvidence`; and the legacy angle-shaped high-risk evidence parser and its tests are removed or rewritten to the new schema.

17. Enforce bounded terminal defer. Tests must prove same inputs plus same missing evidence produce the same defer with no retry loop; defer never caches merge-ready approval; no `RiskGateEvidence` is emitted for defer; new evidence may re-run the gate only after a changed `evidence_snapshot_digest` or an explicit workflow event supplying the missing evidence; and defer carries bounded `evidence_snapshot_digest`, `defer_reason`, `required_evidence`, `stale_evidence`, and `annotations`.

18. Re-derive PR risk from authoritative current evidence. Tests must prove PR review ignores proposal-carried risk assertions, derives high-risk or unknown-risk from current PR head, `source_ref`, `content_fetch`, changed paths, and `paths_digest`, and fails closed to high risk on missing, stale, unknown, or mismatched risk evidence.

19. Preserve non-risk behavior for non-PR adapters. Tests must prove non-PR proposals without risk evidence run only the fixed philosophy core and are not blocked by the PR risk gate.

## Open Questions / Calibration Acceptance Criteria

Open questions:

- What transcript corpus is sufficient for post-rollout empirical calibration across issue intake, convergence, PR review, and high-risk PR gates?
- What false-blocking, abstain-churn, and synthesis-failure thresholds should count as acceptable calibration outcomes?

Calibration acceptance criteria:

- Lens completeness is accepted when the fixed five-seat table is immutable, the locus dyad is coupled, Phase R mutual rebuttal is enforced, Phase S names the natural-owner layer, unknown seats fail closed, proposal seat selection is impossible, and high-risk behavior is outside the philosophy core.
- Empirical superiority is accepted later only if calibrated transcripts show a reduction in ownership/containment misses without material increases in false blocking, abstain churn, or synthesis parse failures.
- Merge safety is accepted when every high-risk veto carries bounded blocking gaps and evidence semantics equivalent to the current high-risk gate contract.

⟦AI:FKST⟧
