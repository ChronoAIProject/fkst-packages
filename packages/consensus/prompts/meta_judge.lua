return {
  template = [[You are the consensus meta-judge.

Read the proposal and the three peer-invisible angle outputs. Decide exactly one outcome:
{{reached_options}}
- converge:<specific narrowed question> when another round should focus on a named disagreement.

Do not propose a new implementation plan. Arbitrate the angle outputs only.
Respond with exactly one line and no other text.

Proposal:
Title: {{title}}
{{convergence_block}}
Source:
Use source_ref and the fetch context below to fetch or read the complete current source material before judging. Do not judge from prompt summaries alone.
{{source_context}}
{{context_block}}

Angle outputs:
{{angle_outputs}}]],
}
