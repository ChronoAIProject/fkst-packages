# Host-repo harness: one coordinate per source, atomic SHA consolidation now, a typed pack-execution contract later

Status: SPLIT after Round-2 adversarial REVIEW (3 Codex + ChatGPT Pro, all `reject` → `fix`).
- **Part A (§4) — atomic fkst-packages SHA consolidation in fkst-website: READY TO IMPLEMENT.** All four
  reviewers agree it can proceed independently provided EVERY consumer of the pin is migrated atomically.
- **Part B (§5–§7) — the structural pack-distribution + execution contract: DESIGN-INCOMPLETE.** Round-2
  review showed the earlier draft designed *where rule-pack bytes are pinned* but NOT *the public semantic
  contract by which those bytes become mandatory, correctly-scoped conformance*. Part B is now a set of
  explicit OPEN design questions, not a converged `implement`. It must NOT be implemented as-is.
Date: 2026-06-24 (revised; original 2026-06-23 draft + Round-1 in git history)
Scope: fkst-substrate (engine validator + conformance runner + resolver), fkst-packages (rule-pack data +
migration), host repos (fkst-website first; substrate-dogfood + future hosts).

## 0. Verified current state (2026-06-24 — seek truth from facts)

Round-1's premise ("fkst-website has a COPIED check_repo.py") is STALE. The copy is gone, replaced by
**fetch + a new lock**, and the defect evolved into a worse one. Verified by reading both repos:

- fkst-website has NO `check_repo*.py` copy. `scripts/run.sh check` clones fkst-packages at the SHA in
  `.fkst-packages-ref` into `.fkst/run/fkst-packages-conformance/` and runs THAT (B-private)
  `check_repo.py --project-root <website>`, then `$BIN conformance`.
- A new cross-repo dependency mechanism exists: `fkst.workspace.toml` `[[external_sources]]`
  (`id=fkst-packages-platform`, git+rev, `libraries=["contract"]`) resolved into `fkst.lock`
  (`[external_source.resolved] rev` + `tree_sha256`, `[[external_source.libraries]] contract exports_sha256`).
- **VERIFIED UGLY — two divergent pins to the same upstream (a split brain):**
  `.fkst-packages-ref` = `45ef0324…` (harness fetch) vs `fkst.lock` `external_source.resolved.rev` =
  `1734c42e…` (contract library). They are not merely different: `45ef0324` is the commit that ADDS the
  host-facing ratchet interface (`scripts/check_repo_config.py` + `check_repo.py --project-root`), and
  `1734c42e` predates it (verified by the quality reviewer via `git show <rev>:scripts/check_repo_config.py`).
  `scripts/run.sh:108` even prints "bump .fkst-packages-ref to a Track P commit with the shared host-repo
  interface". So the conformance result is the accidental product of two clocks pointing at incompatible
  commits.
- `.fkst-packages-ref` (or its checkout) has FOUR consumers (verified):
  1. `scripts/run.sh` `run_shared_source_ratchets` → fetched `check_repo.py --project-root` (run.sh:103-124).
  2. `scripts/run.sh` `build_engine_package_root_args` → resolves `.fkst/conformance/package-roots` entry
     `fkst-packages:packages/idle-detector` from the SAME checkout (run.sh:127-155, 258).
  3. `.github/workflows/ci.yml:26-35` independently reads `.fkst-packages-ref` and pre-clones the checkout
     BEFORE `scripts/run.sh` runs.
  4. `scripts/run.sh:72-82` `FKST_PACKAGES_CONFORMANCE_ROOT` — a local-only override (a second checkout
     authority).
- `check_repo.py` is host-aware: `check_repo_config.is_own_repo` gates the ~8 github-devloop-hardcoded
  ratchets (skipped for an external project-root). This is a compatibility PATCH, not a public API: the
  inverted-dependency ugly (a "generic" harness hardcoding one package's name) survives under a blanket.

Verified current-state corrections to the earlier draft (do not assert these as already-solved):
- The engine `fkst-framework conformance` command EXISTS, but `host_conformance.rs` registers only an
  `EngineRulePack` + layout/schema/graph checks (runtime-layout, project-layout, locale-catalogs,
  graph-scan, department-non-empty, schema-validation). It does **not** demonstrably run testkit/devloop
  Lua saga/dispatch conformance via `--config`; `conformance --config` currently parses the TOML into an
  untyped value and otherwise **ignores** it (registry comment reserves future pack selection). Whether
  behavioral Lua conformance runs via `test`/`--self-test` mode vs the `conformance` command is TO-VERIFY,
  not an established fact.
- The resolver currently models ONLY `libraries`: `ExternalSourceDecl` / `ExternalSourceLock` carry
  `libraries` only, and `validate_source_decl` REJECTS an external source with no libraries
  (`manifest_workspace.rs`, `manifest_external.rs`). Typed `conformance_packs` / `tools` / external
  `packages` are unimplemented resolver work.
- The external `idle-detector` package is NOT a locked external artifact today; it is consumed by an
  untyped `fkst-packages:*` path in `.fkst/conformance/package-roots`.

## 1. The corrected thesis (Round-2 converged direction; the contract is still TBD — see Part B)

> A host should consume harness through its declared dependency graph: per dependency source, ONE
> authoritative coordinate; ONE public engine command executes conformance; package-owned policy travels
> with the package, not by host copies or a redundant second pin into the same upstream.

Two precise corrections the review forced:
- **"One lock" means one authoritative coordinate PER dependency source, NOT one universal lock for
  everything.** `.fkst-substrate-ref` (the engine toolchain pin) is a LEGITIMATE separate coordinate — like
  `Cargo.lock` pinning dependencies while NOT pinning the `cargo`/`rustc` binary interpreting it. The pin to
  DELETE is the *redundant second fkst-packages* pin (`.fkst-packages-ref`), not the substrate toolchain pin.
- **Rejecting a standalone `event-conformance` product with its own pin is right; but "ride the lock" only
  fixes provenance/integrity of bytes. It does NOT by itself define the execution contract** (how a pack is
  declared, activated, scoped, versioned, trusted). That contract is the real structural design (Part B), not
  a downstream implementation detail.

## 2. Harness (prior art)

- **Lockfile single-source-of-truth** (Cargo/npm): one resolver owns each upstream coordinate; the lock
  records every artifact obtained from it. A lock prevents *unintended* drift; it deliberately permits
  *indefinite staleness* — preventing stale pins needs a SEPARATE min-supported-version / expiry / update
  policy (so "a host cannot silently fall behind" is NOT a property of an ordinary lock and must not be claimed).
- **Versioned linter platform / policy-as-code** (ESLint plugins + shareable configs; OPA/Conftest): generic
  policy authored once and distributed as versioned data; BUT only meaningful with a published pack format,
  activation model, and runner protocol — not just pinned bytes.
- **Compiler vs linter ownership / capability-vs-scan**: intrinsic validity is the engine's (capability);
  static source policy is separable data owned by whoever owns the semantics; a runtime library must not
  secretly scan source (the Round-1 trap).
- **Published API vs private consumption**: consuming declared, versioned artifacts is clean; reaching into a
  repo's private `scripts/check_repo.py` by filesystem path is not.
- CLAUDE.md «守住包边界 / published seam»·«分层归属»·«Harness本质 PREVENT>DETECT»·«通用>枚举»·«迁移=inventory ratchet»·«DRY 单一真相源»·«禁 god-package».

## 3. Tiers by ownership (the stable frame; tier-2 execution contract is Part B)

| Tier | Home (code) | Owns | Must NOT own |
|---|---|---|---|
| **1. Engine built-in validator** | fkst-substrate runtime | intrinsic package invalidity: malformed metadata, duplicate runtime identifiers, impossible saga graphs, unresolved refs, published-seam legality | org/package policy, migration ratchets, allowlists |
| **2. Static rule packs** (policy-as-DATA, executed by the public runner) | authored by the OWNER of the semantics; executed by `fkst-framework conformance` | generic source rules (engine/std-owned pack) + per-package rule packs (package-owned). **The declaration/activation/scope/version/trust contract is UNDESIGNED — Part B.** | a monolithic "B god-pack"; B-private layout baked into the generic pack; arbitrary unsandboxed code |
| **3. Engine-run Lua conformance** | fkst-substrate test driver + testkit/devloop Lua, via lib_deps | properties needing EXECUTION (saga runtime, scheduling, ordering, liveness, dispatch). NOTE: whether the `conformance` command runs these today is TO-VERIFY (see §0). | static source scanning smuggled into a runtime library |

---

# PART A — atomic fkst-packages SHA consolidation in fkst-website (READY TO IMPLEMENT)

## 4. Kill the split brain: one coordinate, atomically, across all four consumers

Goal: eliminate the divergent second pin so conformance runs against ONE coherent platform commit. This is
independent of Part B and unanimously endorsed, with a hard atomicity condition.

Acceptance criteria (ALL must hold; the change is NOT done until each is true):
1. `fkst.lock`'s `external_source.resolved.rev` is bumped to a SINGLE coherent fkst-packages commit that
   satisfies EVERY consumer: it contains the host-facing ratchet interface (`scripts/check_repo_config.py` +
   `check_repo.py --project-root`), `packages/idle-detector`, and the `contract` library. The lock is
   REGENERATED (re-resolve `tree_sha256` + `contract exports_sha256`) — not hand-edited. (The current lock
   rev `1734c42e` is BEHIND the host interface, so adopting it as-is would regress; the consolidation bumps
   the lock to ≥ the `.fkst-packages-ref` rev, i.e. a Track-P commit with the host interface.)
2. `scripts/run.sh` derives its single fkst-packages checkout from the lock's resolved rev (one
   `ensure_fkst_packages_checkout` keyed on the lock, not on `.fkst-packages-ref`), and BOTH
   `run_shared_source_ratchets` and `build_engine_package_root_args` consume that same checkout; the engine
   invocation still includes `packages/idle-detector`.
3. `.github/workflows/ci.yml` hydration step (lines 26-35) resolves the checkout from the lock rev, not from
   `.fkst-packages-ref`.
4. `FKST_PACKAGES_CONFORMANCE_ROOT` local override is removed, OR retained only with an explicit assertion
   that its `git rev-parse HEAD` equals the lock's `external_source.resolved.rev` (no second checkout authority).
5. `.fkst-packages-ref` is DELETED, along with `read_fkst_packages_pin` / `FKST_PACKAGES_PIN_FILE` and the
   README/CLAUDE references to it.
6. A concrete CI guard (a real test, not prose): assert that (a) no `.fkst-packages-ref` (or any second
   `*-ref` side pin to the fkst-packages git URL) exists, and (b) the resolved fkst-packages checkout's
   `git rev-parse HEAD` equals `fkst.lock`'s `external_source(id=fkst-packages-platform).resolved.rev`.
   `.fkst-substrate-ref` is a DISTINCT, legitimate toolchain coordinate and is explicitly out of scope of
   this guard.
7. `scripts/run.sh check && scripts/run.sh test` pass green on fkst-website after the change (the lock bump
   also moves the `contract` library that `site-board` consumes — verify nothing regresses).

Honestly-inventoried migration DEBT (Part A does not pretend to be the one-resolver end state):
- The host still MANUALLY clones the lock rev because the engine `deps` command fetches/validates locked
  external sources but does NOT expose a public source-root lookup, and a manual clone may bypass the lock's
  `tree_sha256` verification. This is acknowledged shrink-only debt, tracked toward Part B, NOT the final
  form. Part A's win is precise and real: one coordinate, no split brain, every consumer coherent — today.
- The host still fetch-runs B-private `check_repo.py`. Tolerated as shrink-only debt until Part B lands; it
  now runs at the SAME locked commit as everything else, so it is no longer a second clock.

---

# PART B — structural pack distribution + execution contract (DESIGN-INCOMPLETE — OPEN QUESTIONS)

Round-2 review (esp. ChatGPT Pro) showed the earlier "add `[[conformance_packs]]` to the lock" draft solved
only WHERE bytes are pinned, leaving the load-bearing contract undesigned. Pinning bytes without this
contract yields exactly the failures the design claims to remove: hardcode package names into the engine
(inverted dependency), execute arbitrary transitive code (god-runner), or reach into another repo by private
path (private consumption). Part B must NOT be implemented until these are answered.

## 5. The missing tier-2 execution contract (the blocking structural gap)

One concrete vertical contract is required before any pack work:
- **Pack declaration + identity**: how a package/library declares it provides (or depends on) a named static
  rule pack; stable pack id + version.
- **Activation graph edge**: the PRECISE edge that activates a pack for a host — a typed `conformance_deps` /
  `lint_deps`, or `lib_deps`, or package composition, or explicit workspace binding. Without a typed seam a
  package can be present while its static rules are silently absent — the exact failure "default-on" claims
  to prevent. ("Selected by ownership and graph reachability" is a promise with no graph edge today.)
- **Runner/pack protocol version**: which runner versions understand which pack format; compat metadata.
- **Fact model + scope**: what a source scan may inspect, and whether scope is the package's own source, the
  consumer's source, or the whole workspace.
- **Form + trust**: declarative rule IR over a versioned fact model, OR a deliberately sandboxed plugin ABI.
  A raw `checkout/path/to/script.py` lock entry is just disguised private-script consumption / arbitrary
  transitive code execution — both forbidden.
- **Failure + conflict semantics**: fail-closed for missing/unsupported reachable packs; duplicate-id and
  version-conflict rules; waiver identity + lifecycle (host-owned baselines).

## 6. Resolver work (the storage half — also required, not yet done)

- Extend the workspace/lock schema beyond `libraries` to typed external `packages` (so `idle-detector` is a
  locked artifact, not an untyped path) and typed `conformance_packs` / `tools`; relax the
  "external source must have ≥1 library" rule accordingly.
- Make `fkst-framework conformance --config` actually consume the config: a pack registry that selects packs
  per the §5 activation edge, instead of the current parse-but-ignore + static `EngineRulePack`.
- Expose a public source-root lookup from the resolver so hosts stop manually cloning (removes Part A's debt).

## 7. Bootstrap / toolchain + ownership-honesty questions

- **Bootstrap circle**: the runner cannot both be pinned-and-built by the thin runner AND be a `tools` lock
  entry that the runner itself must read. Decide explicitly: either the runner is part of the publicly
  versioned `fkst-framework` toolchain (one legitimate `.fkst-substrate-ref` coordinate + pack-compat
  metadata in `fkst.lock`), OR a small bootstrap launcher resolves a locked tool artifact then execs it.
- **Ownership honesty**: do not call a pack "engine-generic" while having fkst-packages publish it. If a rule
  is truly engine-generic it is substrate/std-owned (else the inverted dependency persists and future hosts
  couple to B); if it is org policy, name it as a public policy pack owned honestly.
- **Per-owner, not god-pack**: github-devloop's static rules become the github-devloop package's pack,
  activated only when that package is referenced; delete `is_own_repo` + the hardcoding when its pack lands.
  A B-aggregate pack may exist only as a convenience COMPOSITION of per-package packs, never the primitive.

## 8. Migration order (inventory-ratchet, not big-bang)

1. **Part A now** (§4): atomic SHA consolidation in fkst-website. Independent, unblocked today.
2. **Part B design**: answer §5 (the execution contract) FIRST; it gates everything else. Then §6 resolver
   work in fkst-substrate, then §7 decisions.
3. **Then** migrate generic ratchets into the engine/std generic pack one-by-one (inventory-ratchet; the
   `scripts/check_repo*.py` count shrinks to 0); per-package packs for package rules; fkst-packages switches
   to invoking the CLI (proving symmetry: it is just another consumer); delete `is_own_repo` + hardcoding;
   retire host execution of B-private `check_repo.py`.
4. At 0: one coordinate per source, one public command, per-owner typed packs; zero duplication, zero second
   fkst-packages pin, zero private-script consumption.

## 9. Non-goals

- Not a runtime change (conformance is build/CI-time).
- Not baking org/package policy into the engine.
- Not a big-bang rewrite.
- Not a second package manager / second fkst-packages pin / host config that duplicates the workspace graph.
- Part A is NOT the one-resolver end state (it is honest interim debt); Part B is NOT implementable until §5
  is answered.

## 10. Adversarial record

### Round-2 REVIEW (2026-06-24) — 3 Codex (architecture/quality/tests) + ChatGPT Pro, ALL `reject` → `fix`
- **quality** (reject): the two revs are functionally incompatible (`45ef0324` has the host ratchet interface,
  `1734c42e` does not); deleting the side pin while keeping the stale lock rev regresses `run.sh check`; the
  pin has multiple consumers — the first step is a proxy fix unless it is an atomic single-rev move.
- **architecture** (reject): a THIRD consumer — `.github/workflows/ci.yml` pre-hydrates from
  `.fkst-packages-ref` independently; plus `FKST_PACKAGES_CONFORMANCE_ROOT` local override is a second
  checkout authority; verified the resolver schema is libraries-only (substrate source).
- **tests** (reject): the CI guard was under-specified to be a real test; the "engine conformance already
  loads testkit/devloop Lua conformance" claim is NOT supported by `host_conformance.rs` (6 checks +
  EngineRulePack, no testkit/saga runner); "~25" unverified; `conformance --config` currently ignores config.
- **ChatGPT Pro** (reject): keystone — the spec designed WHERE bytes are pinned, not the public semantic
  CONTRACT that makes them mandatory/scoped (pack declaration → named activation graph edge → fact model →
  declarative-IR-or-sandboxed-ABI → fail-closed → trust). "One lock" overstated → bootstrap circle
  (`.fkst-substrate-ref` is a legitimate toolchain coordinate; decide externally-pinned-toolchain vs
  bootstrapped-lock-artifact). `deps fetch` discards checkout locations (no public source-root lookup) →
  Part A is honest debt, not the one-resolver form. "Host cannot silently fall behind" is false for a lock.
  External `idle-detector` is not a locked artifact. Strongest objection (blocking): without the execution
  contract, implementation collapses to inverted-dependency / god-runner / private-consumption.
  Verdict: the SHA-consolidation can proceed independently if all consumers migrate atomically; the
  structural spec must not merge in its present form.

Meta-judge exit: `fix` → this revision SPLITS the spec: Part A (atomic consolidation) is implementable now;
Part B is downgraded to explicit open design questions (no false `implement`).

### Round-2 THINKING (2026-06-24) — converged the direction (one coordinate / per-owner packs / no standalone product)
minimal/structural `revise`, delete `reject (the standalone product)`, ChatGPT Pro `refute-shape/keep-thesis`.
### Round-1 (2026-06-23) — established published-seam thesis + 3-tier ownership (superseded in shape). History in git.

⟦AI:FKST⟧
