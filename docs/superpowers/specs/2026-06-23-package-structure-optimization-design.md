# package structure optimization design (audit-driven)

Status: design (2026-06-23). Driven by a 3-lens sshx package-structure audit (minimal/structural/delete), strongly converged. ⟦AI:FKST⟧ The libraries were re-decomposed separately; this targets PACKAGES.

## Scope: 3 changes, 3 separate PRs. (A 4th audit item — "add published-seam conformance" — is REFUTED: the substrate engine already enforces `produces ⊆ own + sibling published_seam` via the #145 capability gate, declared `published_seam` exists in packages, and 3-host graph-scan passes. Adding a check_repo scan would be redundant and violate "engine-PREVENT > scan". So the god-router safety prerequisite for changes ③④ is already provided by the engine.)

## Change ② (PR-A) — de-couple `github-proxy` from devloop product policy

`github-proxy` declares itself a generic stateless GitHub adapter (`packages/github-proxy/core.lua:9`) but embeds devloop product policy:
- parses `fkst:github-devloop:state:v1` markers (`core.lua:467`, `:525`)
- hardcodes the `fkst-dev:*` label→color map (`core.lua:730+`)
- poll replay filters on `^fkst%-dev:` (`departments/github_poll/main.lua:27`)
This is a lying name + leaked abstraction (the generic adapter knows one product). **Fix (behavior-preserving):** the devloop family supplies its own policy through github-proxy's published request seams / injected config — github-proxy applies whatever label name+color is requested, returns raw entity data (not devloop-parsed state), and its poll/replay label filter is configured by the host (not hardcoded `fkst-dev:`). The devloop marker parsing + state derivation moves into the devloop library/packages (which own that protocol). github-proxy's other consumers (archaudit/autochrono/github-external-pr-intake) are unaffected (they use generic I/O). RISK: github-proxy is used by every package; its entity-view contract change must keep devloop's observability behavior identical — gate with adversarial review + 3-host validation.

## Change ③ (PR-B) — extract `github-devloop-ops` from `github-devloop`

`github-devloop` (36k lines, 14 depts) fuses the issue STATE MACHINE with operational/control-plane departments that have independent change-reasons:
- `ensure_repo` (repo bootstrap / labels / dashboard topology) — `departments/ensure_repo/`, `core/ensure_repo.lua`
- `observability` (dashboards / starvation / conflict / PR reaper) — `departments/observability/` (9 files)
- `doctor` (diagnostics) — `departments/doctor/`, `core/doctor.lua`
- `dead_letter` (L2 failure triage that files issues) — `departments/dead_letter/`, `core/failure_triage.lua`
**Fix:** create composed package `github-devloop-ops` (`lib_deps=["contract","workflow","testkit","forge","devloop"]`, `event_deps=["github-proxy"]`); MOVE those 4 departments + their package-local core modules + raisers into it. Keep `observe_issue`/`consensus_result`/`implement`/`loop`/`reconcile`/`comment_handoff`/issue `liveness_scan` in `github-devloop`. Seam: ops reads GitHub/markers + emits only ops-owned queues + published github-proxy request seams; it MUST NOT produce `github-devloop`/`github-devloop-pr` internal lifecycle queues (the engine #145 gate already enforces this — ops can't god-router). Behavior-preserving: same departments, same queues/markers, same effects, just relocated; update `dogfood.config.sh DEVLOOP_PKGS` note (operator config) and the 3 dogfood hosts load the new package.

## Change ④ (PR-C) — extract substrate-ref maintenance from `github-devloop-integration`

`github-devloop-integration` fuses branch-train sync with SUBSTRATE-PIN maintenance (independent concern: its own raiser `raisers/substrate_ref_poll.lua`, department `departments/substrate_ref_scan/`, core `core/substrate_ref.lua`, hardcoded `.fkst/substrate-ref` policy).
**Fix:** create flat package `fkst-substrate-ref-maintainer`; MOVE `substrate_ref_scan` + `substrate_ref_poll` + `core/substrate_ref.lua` into it. Leave branch sync / freshness / conflict / rollup in `github-devloop-integration`. Behavior-preserving relocation; the new package is self-contained (its own poll lifecycle, no sibling internal queues).

## Constraints (all 3)
- Behavior-preserving: same departments/queues/markers/state/effects, just relocated/de-coupled; durable protocol identity unchanged.
- The engine #145 published-seam gate makes a new package (ops, substrate-ref-maintainer) producing a sibling internal queue fail-closed — so the extractions cannot create a god-router.
- 守住包边界 (independent change-reason → own package); composed=Facade; English-only; no file >1000 lines; clean break (move not copy).
- Each change is its OWN PR (PR-A/B/C); each adversarially implemented + reviewed + 3-host validated before merge.

## Sequencing + acceptance
PRs are independent; recommended order ④ (cleanest) → ③ (biggest) → ② (riskiest de-couple). After all 3 merge + the 3 dogfood hosts (packages/website/substrate) load the new structure clean, run dogfood 5h+ stable across all 3 hosts = goal met.

## DEFER (audit, with triggers — NOT in scope now)
- liveness_scan template / reconcile helper extraction → 3rd instance or repeated shared bug.
- generic dead-letter-triage library → a non-devloop package needs L2 issue-filing.
- further devloop-family boundary moves → only when a member becomes a pass-through facade.
