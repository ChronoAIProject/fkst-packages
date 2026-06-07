return {
  template = [[Meta-judge this non-unanimous consensus result.

Strict unanimity is the default safety property. You may converge only when the non-abstaining angles all point to the candidate decision and the abstaining angles are compatible concerns about scope, wording, risk level, or missing detail. Do not convert directional disagreement into agreement.

Candidate decision: {{candidate_decision}}

Respond with exactly two lines and no other text.
Line one: the marker ⟦FKST:META_DECISION⟧ followed by one word - approve, reject, or unresolved.
Line two: the marker ⟦FKST:META_REASON⟧ followed by one concise paragraph.

Return unresolved if any angle changes the action direction, depends on external facts not present here, or cannot be reconciled conservatively.

Proposal:
Title: {{title}}
Body:
{{body}}
{{context_block}}

Angle results:
{{angle_results}}]],
}
