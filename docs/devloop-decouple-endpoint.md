# libraries/devloop ambient-M dissolution — endpoint and documented kernel

This documents the honest end state of the `libraries/devloop` ambient-`M` (god-table)
dissolution: what was dissolved, what the `G-DEVLOOP-DECOUPLE` ratchet measures, what the
legitimate remaining kernel is, and what genuine debt is left. It is the adversarially-built
SPEC (sshx thinking-triplet + ChatGPT Pro cross-model) referenced by the standing dissolution
goal, written as prose so the classification stays auditable and greppable.

**Scope of the claim (do not overstate).** What was dissolved is the **copy-onto-`M` facade
anti-pattern** — arbitrary `M.fn = mod.fn` exposure the ratchet measures — driven 659 → 27. This
is **not** the claim that ambient composed-core `M` usage is gone: a **large sanctioned
`install(M)` composed-core kernel still exists** (~168 functions, ~925 reads: lifecycle-state,
logging, and the egress-adapter over forge). That kernel is legitimate, cohesive architecture,
adversarially validated — but it is a substantial ambient composed-core API, not its absence.
The honest headline is "**facade dissolved, documented composed-core kernel remains**", never
"ambient-M / god-lib dissolved" unqualified.

## Two distinct coupling shapes — only one is the god-table anti-pattern

`libraries/devloop` capabilities reach a package's ambient `M` two ways, and they are **not**
the same thing:

1. **Copy-onto-M facade (the anti-pattern the ratchet targets).** A package core writes
   `M.fn = devloop_mod.fn` or `M.fn = function(...) return devloop_mod.fn(M, ...) end`, then
   department code reads `core.fn(...)`. This is the loophole the earlier
   install_defs/m_writes ratchet let slip (a wrapper facade drove those to 0 without
   decoupling). `check_repo_devloop_decouple.py` counts exactly these explicit-`M.name=`
   reader calls, and only rewiring a reader to a direct `require(module).fn(...)` lowers it.

2. **`install(M)` composed-core kernel (sanctioned).** A package core calls
   `require("devloop.logging").install(M)` / `require("devloop.state").install(M)`; those
   modules define `function M.<name>` inside the installer, and departments read
   `core.log_raise(...)` / `core.current_state(...)`. This is the composed core deliberately
   providing a small, stable set of cross-cutting + lifecycle capabilities to every
   department — the "**small documented version-CAS lifecycle kernel** [that] remains
   reachable through the composed core" named in the ratchet's own docstring. It is a
   Facade / shared-capability, not the god-table anti-pattern.

The ratchet measures shape (1) by design and does not count shape (2). That is correct: shape
(2) is the sanctioned kernel, not debt. An adversarial review initially read the uncounted
shape-(2) reads as hidden debt; the sshx thinking-triplet (minimal/structural/delete,
unanimous) and ChatGPT Pro (cross-model) resolved the fork per module (below): the bulk of
shape (2) is legitimate kernel, so leaving it uncounted is honest, not a false-negative.

## Facade coupling (shape 1): 659 → 27, dissolved

Explicit-`M.name=` facade coupling was driven from **659 to 27** across PRs #1777–#1807 by
genuine decoupling (rewire readers to direct `require`, drop vestigial `M`, direct-alias for
lower-layer library callers, whole-cluster drops for the lock-key name-collision family,
global-primitive threading for `exec_sync`/`core.git`). The residual 27:

- **25 non-devloop name-collisions** — counted only because a flat package binds a
  *same-named* symbol; the binding source proves it is not a `libraries/devloop` read:
  `read_env` 9 (`env.read_env`), `invalidate_entity_after_write` 7 (github-proxy's own
  `core/entity_view.lua`), `strip_bot_login_suffix` 4 (`forge_strings`), `trim` 2
  (integration-coverage-producer's own `function M.trim`), `judgment_codex_opts` 1
  (`workflow.codex`), `error_fingerprint` 1 (`contract.error_facts`), `git` 1 (`forge.git`).
  These are a measurement artifact of name collision, not god-table coupling.
- **2 `linked_pr_surface_snapshot`** (github-devloop-pr, github-devloop) — a `devloop.entity`
  operation that consumes kernel capabilities (`gh_pr_view_observe`, `cached_entity_view`)
  through the composed `M`. It is a **kernel-consumer**, not a copy-onto-M facade: it uses the
  sanctioned composed-core kernel rather than aliasing an unrelated function onto `M`. It is the
  last explicit `M.name=` binding the ratchet still attributes to a devloop module; it could be
  rewired to `require("devloop.entity").linked_pr_surface_snapshot(core, ...)` for symmetry, but
  since it legitimately needs the composed `M` to reach the kernel, that is a cosmetic call-form
  change, not a coupling reduction.

## `install(M)` kernel (shape 2): the documented composed-core kernel

Per the converged design, the `install(M)` capabilities split by module:

- **`devloop.state` = KERNEL** (~194 reads: `cas_outcome`, `stage_rank`,
  `state_label_changes`, `state_marker`, `current_state`, `versioned_transition_status`, …).
  These are the version-CAS lifecycle state machine — exactly the "version-CAS lifecycle
  kernel" the composed core is meant to provide. Small, stable surface per capability;
  coordinating the devloop lifecycle, not arbitrary department behaviour.
- **`devloop.logging` = KERNEL** (~731 reads: `log_cas_decision`, `log_raise`, `log_entry`,
  `log_apply`, `log_line`, …). Cross-cutting structured lifecycle logging. High fan-in is
  *expected* for logging and is not evidence of god-table coupling: the surface is a handful
  of stable primitives and the dependency direction is a leaf capability, not a tangle.
  Forcing every department to re-`require` logging would be uglier, not cleaner.
- **`devloop.commands` = KERNEL (egress-adapter over forge).** The GitHub/git egress
  (`gh_pr_view_observe`, `gh_issue_view_observe`, git operations, ~89 wrappers across
  `commands/{git_ops,issue_reads,prs,observe_lists}.lua`) **already routes through forge**:
  `support.github()` / `support.git()` ARE the `forge.github` / `forge.git` argv adapters behind
  `exec_argv`, so the forge-port doctrine's actual rule (raw `gh`/`git` construction + shell
  quoting + execution live in `libraries/forge`) is satisfied. What the `commands` submodules
  add on top is the devloop-domain egress *adapter* — field selection (which PR/issue fields to
  fetch), `gh_result` error handling, and observe-vs-fix variants — which belongs in the devloop
  composed core, not in the generic domain-agnostic `forge` library (relocating it there would be
  a layering violation). An initial pass mis-classified this as forge-port debt before that
  ground-truth; a second unanimous sshx thinking-triplet plus ChatGPT Pro re-judged it KERNEL.

## Kernel guardrail — the composed core is not a new service locator

The `install(M)` composed-core kernel (`devloop.state` + `devloop.logging` +
`devloop.commands` egress-adapter) is substantial by raw count (~168 functions, ~925 reads),
so "kernel" here does **not** mean tiny — it means the **sanctioned `install(M)` composed-core
surface**, as opposed to the facade escape-hatch (arbitrary `M.fn = mod.fn` copy-onto-M) the
ratchet was built to kill and which is dissolved. The distinction that keeps this honest rather
than "the whole god-table renamed kernel" is **cohesion + the sanctioned mechanism**, bounded by:

- **`install(M)`-only, cohesive, closed.** The kernel is exactly the three cohesive
  composed-core capabilities installed via `install(M)`: lifecycle-state, structured logging, and
  the egress-adapter over forge. It is NOT a license to resume the facade pattern (copy an
  unrelated devloop function onto `M` as a wrapper) — that remains debt the ratchet counts. New
  `install(M)` growth outside those three cohesive domains must be justified here deliberately,
  never a silent widening of the ambient surface.
- **Egress construction stays in forge.** The egress-adapter is kernel only because raw
  `gh`/`git` construction/quoting/execution already lives in `libraries/forge` (via
  `support.github()`/`support.git()`); the composed core holds only devloop-domain field
  selection + variants. If any raw `gh`/`git` construction ever appears in `commands` directly,
  that part is debt to push back into forge.
- **One direction, boring.** Kernel capabilities are leaf primitives departments consume; they
  must not grow into a general dependency hub. High fan-in on a stable boring surface (logging)
  is fine; a *widening* surface is the signal it is turning back into a god-table and must split.

## Installer-coupling ratchet + pure-helper extraction (measured, capped, refined)

The facade ratchet (`G-DEVLOOP-DECOUPLE`) measures only the copy-onto-M facade and is blind to
the `install(M)` composed-core reads. A second ratchet, **`G-DEVLOOP-INSTALLER`**
(`scripts/check_repo_devloop_installer.py`), now **measures and caps** that composed-core kernel:
it resolves each package core's `require("devloop.<mod>").install(M)` surfaces and counts the
`(core|M).<installer-symbol>(` reads (baseline captured in `migration/devloop-installer.inventory`).
This makes the kernel's size **visible** and **shrink-only** — the kernel can be pared as
cleanly-separable helpers move out, and it can never silently *grow* back into a god-table.

Within each kernel module, the methods split into a **cohesive cross-cutting core** and
**cleanly-separable pure helpers**, decided per method by ground-truth (library-caller count +
conformance/test instrumentation), not by name:

- **Cohesive cross-cutting core stays on `M`.** For `devloop.logging` the observable-effect
  methods `log_raise` / `log_cas_decision` / `log_apply` / `log_line` are called from ~54
  `libraries/devloop/*.lua` sites through the injected `M` and are the **single
  state-machine-advancement instrumentation seam** that `hidden_state_conformance.lua`'s
  `with_effect_capture` patches (plus 9 test monkey-patches). For `devloop.state` the version-CAS
  lifecycle methods `cas_outcome` / `stage_rank` / `state_marker` / `current_state` /
  `versioned_transition_status` / `version_fix_round` are likewise called from ~60 library sites
  and are used by the conformance fixtures. Relocating these to a required module would **not
  remove the essential coupling** — it would relocate the same pervasive instrumentation
  dependency from `core.X` to `module.X`; `core.X` is arguably the better seam because the
  conformance verifies composed-core state-machine advancement, not a module in isolation. This
  is the recognized injected-logger / cross-cutting-concern pattern, adversarially re-adjudicated
  cross-model (ChatGPT Pro: `migrate-pure-helpers-only`, `observable_effect_is_kernel = yes`), and
  it is the honest, ground-truth-validated reason these methods are kernel rather than debt.
- **Cleanly-separable pure helpers move to a self-contained module.** `devloop.logging`'s 8 pure
  helpers (`log_entry` / `log_outbound` / `log_codex_*` / `log_error_fact` / `wrap_pipeline_failure`
  / `error_fingerprint` / `error_class_from_message`) were rewired from `core.X`/`M.X` to
  `require("devloop.logging").X` (logging is now a self-contained module whose `S.install(M)` only
  binds a compat scaffold). These are cleanly separable because they do not call the kept-on-core
  observable-effect methods internally in an instrumentation-sensitive way.
- **Where the "helpers" are internally entangled with the kernel, they are kernel too.** Ground-truth
  on `devloop.state` shows its non-lifecycle readers (`cyclic_transition_status`,
  `next_review_loop_version`, `reached`, `fix_version_from_review_version`, …) are **not** leaf:
  they call the version-CAS kernel methods internally (`stage_rank`, `version_fix_round`,
  `is_at_or_after`, `next_fix_version`, …). Migrating them to a module would relocate the same
  internal-dispatch seam that the kernel methods are instrumented on (`stage_rank` alone is
  monkey-patched by 12 tests), for no separation gain — the readers *depend on* the lifecycle
  kernel. So `devloop.state` is an even more cohesive version-CAS kernel than logging: only a
  handful of genuinely leaf formatters are separable, and extracting them is not worth relocating
  the seam. `devloop.state` stays the composed-core version-CAS lifecycle kernel.

## Endpoint

The god-table facade anti-pattern is dissolved (659 → 27 explicit facade reads, of which 25
are non-devloop name collisions and 2 are `linked_pr_surface_snapshot`). The `install(M)`
composed-core surface — `devloop.state` (version-CAS lifecycle), `devloop.logging`
(cross-cutting structured logging), and `devloop.commands` (the egress-adapter over forge) — is
the sanctioned kernel, each confirmed by an unanimous sshx thinking-triplet plus ChatGPT Pro
(commands re-judged from an initial forge-port mis-classification once the already-through-forge
ground-truth was established). There is therefore **no forge-port debt**: raw `gh`/`git`
construction already lives in `libraries/forge`. The only residual under the ratchet's
facade measure is 25 non-devloop name collisions (documented above, not devloop coupling) plus
`linked_pr_surface_snapshot` (2 reads) — an entity operation that consumes the kernel
capabilities (`gh_pr_view_observe`, `cached_entity_view`) through the composed `M`, i.e. a
kernel-consumer, not a copy-onto-M facade. The god-lib facade is dissolved; the composed core
carries a cohesive, sanctioned, `install(M)`-only lifecycle + logging + egress-adapter kernel.

⟦AI:FKST⟧
