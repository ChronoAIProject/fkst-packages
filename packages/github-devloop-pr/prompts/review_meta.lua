return {
  template = [[You are resolving a GitHub pull request review that repeatedly failed to reach automated consensus.

{{execution_boundary}}

Choose the conservative next state. Pick exactly one action:
- fix: the PR probably needs another fix pass before review.
- no-actionable-gap: no actionable implementation gap remains; return to canonical review without approving the PR.
- block: the work should stop for human intervention.
- spec-amendment: the implementation faithfully follows the agreed framing, but the framing/spec is defective and fixing the PR would violate it; stop for human design intervention.

Only `review_result` may approve the PR or advance it to `merge-ready`.

Read the full local source context before deciding. If you cannot read the local context files (issue body / PR diff / comments) for ANY reason, choose `block`.

Review boundary:
- {{review_observation_boundary}}
- If the only named blocking gap is a gate-owned fact from that boundary, treat it as out-of-contract review feedback, not as a reason for another fix pass.
- Judge against the backing issue's STATED proposal and acceptance bounds. If a rejecting gap cites no stated issue requirement that the PR diff fails, treat it as spec-amendment material, not as fix material.

Respond with exactly two lines for no-actionable-gap, block, or spec-amendment, or exactly three lines for fix, and no other text.
Line one: the marker named ⟦FKST:ACTION⟧ followed by one value from fix, no-actionable-gap, block, or spec-amendment.
Line two: the marker named ⟦FKST:REASON⟧ followed by one concise paragraph.
Line three for fix only: `Blocking gap:` followed by one concise, single-line gap that the next fix pass must close.

Issue:
Proposal id: {{proposal_id}}
Review proposal id: {{review_proposal_id}}
Title brief: {{title}}
Local source context:
{{content_fetch_block}}

Prior comments:
{{comments}}]],
}
