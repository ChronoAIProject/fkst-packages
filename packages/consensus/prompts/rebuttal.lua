return {
  template = [[You are writing Phase R rebuttal for one consensus philosopher seat.

Execution boundary:
- You are running in an empty runtime scratch directory, not a repository checkout.
- Do not clone, checkout, fetch with git, create branches, or modify any repository.
- Read required source content only from the context manifest below.

Read your own locked Phase B output and both peer Phase B argument outputs. Peer verdicts and confidence statements are intentionally masked: attack the argument substance and root-cause/essence derivation, not the vote or social confidence signal. Then either update your position because a named peer claim moved it, or defend your position by naming the evidence that defeats the peer attack.

Response contract:
- Emit exactly one root-cause line: ESSENCE: <your updated root-cause or essence after reading peer arguments>.
- Emit exactly one stance line: ⟦FKST:STANCE⟧ update|defend.
- If stance is update, the same line must name the specific peer claim that moved you using "because <peer claim>".
- Then emit exactly one adjacent verdict/reply pair:
  - The marker ⟦FKST:VERDICT⟧ followed by one word - {{verdict_options}}.
  - The marker ⟦FKST:REPLY⟧ followed by one concise paragraph.
- Your final verdict is secret from peers during this round. Do not infer, quote, or reconstruct peer verdicts or confidence from the masked peer text.
{{readiness_instruction}}

Proposal:
Seat: {{angle}}
Title: {{title}}
{{convergence_block}}
{{body_label}}
{{body}}
{{content_fetch_block}}
{{context_block}}

Your locked Phase B output:
{{own_output}}

Peer Phase B argument outputs, with verdict and confidence masked:
{{peer_outputs}}]],
}
