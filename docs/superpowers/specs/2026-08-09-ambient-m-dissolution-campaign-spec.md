# Ambient-M dissolution campaign executable specification

**Status:** design specification only. No production source, migration artifact, allowlist,
ratchet, or checker is changed by this document.

**Measurement ref:** `origin/integration-elonsg` resolved to
`1958d57b1366dec3521157f2c562d024947208ec` by M0 below. All counts in this specification are
measurements at that exported tree unless explicitly marked `INFERRED`.

**Floor-correction ref:** `bb6bf832f1fce9e9bb5b02fcd34eeab7b72b72e1`. Post-slice values in
Sections 3.1 and 5.1 were measured at this ref. Planning-ref arithmetic is retained where it
describes the original slice ledger, but `501` is not a structural floor or a completion target.

**Decision:** this is one campaign because its read sites, threaded parameters, ambient bindings,
and installer calls are different projections of the same composed-table coupling. It is not a
campaign to make four unrelated inventory totals say zero. Its executable endpoint is:

- the real devloop ambient surface is absent from every package-composed core;
- every production `libraries/devloop` function and department-local helper counted by
  `core-param` has a narrow input;
- `core-param`, `devloop-godlib`, and `ambient-surface` reach their measured campaign endpoints of
  `0`, `104`, and `0` respectively [M1, M4]; `service-locator` is reported as a lexical observation
  and has no numeric campaign floor;
- the source census, including checker-blind installers, reaches zero [M4]; and
- behavior, source-shape conformance, package exports, effects, transitions, markers, and raised
  events remain unchanged.

The planning-ref normalization contains **575 distinct obligations**, not the rounded `660` from
the prior triage and not the committed-baseline sum of `1,205` [M1, M4]. An obligation is defined
in Section 4; it is not an estimate of edited lines, commits, or engineering time.

## 1. Scope and hard boundaries

### 1.1 In scope

- Replace whole-composed-core parameters in the checker-owned production sites with existing
  typed modules, closures, or one responsibility-specific dependency record.
- Move remaining library-side reads away from the package-composed table.
- Convert the ambient forms of existing `devloop.prompts`, `devloop.restart`,
  `devloop.liveness`, `devloop.restart.pr_review_replay_facts`, `devloop.commands`,
  `devloop.logging`, `devloop.state`, and
  `devloop.restart.issue.pr_partition_contract` to typed returns from those same owners.
- Rewire package composition and department capability records atomically with each removed
  public ambient surface.
- Lower only the four named shrink-only inventories after the corresponding source facts have
  actually fallen. Never change a checker to manufacture a fall.

### 1.2 Out of scope

- No engine change. Any missing engine primitive belongs to `fkst-substrate` and blocks the
  candidate slice.
- No new `libraries/devloop` module. `libraries/devloop/fkst.toml:[exports]` is exact [M6], and
  commit `18700fa0` records the engine rejection of an unlisted private module [M6].
- No new integration `core/*.lua` path. `scripts/check_repo_saga_split.py` requires those paths to
  be inventoried, while this campaign may not expand a migration inventory.
- No compatibility surface, forwarding file, deprecated alias, or old/new mode pair.
- No behavior fix. A discovered defect goes in the implementation PR's `notes` and remains
  behaviorally unchanged here.
- No attempt to remove package-owned `core.*`, forge-installed bindings, or lexical false
  positives merely to lower `service-locator`.
- No renaming of ordinary typed module table `M` values merely to lower `devloop-godlib`.

### 1.3 Boundary rule

Every cut must have one named responsibility expressible without joining two responsibilities.
Use an existing owner first. A dependency record may cross a boundary only when all its fields
serve that one responsibility. More than six fields or positional parameters is rejection
evidence: keep the code in place, choose another existing owner, or record a no-op.

## 2. Measurement protocol

The committed inventory values are ceilings, not current-source totals. At the pinned ref the
committed values are `541`, `275`, `197`, and `192`; the owning checkers measure current totals
`540`, `275`, `193`, and `192` [M1]. Therefore baseline arithmetic is not progress arithmetic.

All measurement commands run in a read-only archive, not against a moving worktree:

```bash
MEASURE_ROOT="$(mktemp -d)"
git rev-parse origin/integration-elonsg
git archive origin/integration-elonsg | tar -x -C "$MEASURE_ROOT"
cd "$MEASURE_ROOT"
```

The measured ref and command outputs are frozen in Appendix A. Re-run M0-M5 immediately before
each implementation PR. If the ref changes, recompute the slice delta; do not copy the numbers
from this document into a changed tree.

## 3. What each artifact actually measures

### 3.1 `migration/service-locator.inventory`

Owner: `scripts/check_repo_service_locator.py` [M2]. It scans production
`packages/*/departments/**/*.lua`, excluding `tests/` and `*_test.lua`.

One `department_core_requires` unit is one raw regex occurrence of
`require("core")` or its single-quoted spelling. One `department_core_member_reads` unit is one
raw regex occurrence of `core.<identifier>`. It is not an AST read and it does not resolve the
binding source. Strings, comments, function definitions, package-submodule require strings,
package-owned members, forge members, and unbound names all count.

At the planning ref, the checker measured `51` requires plus `489` member matches, total `540`
[M1]. M3 classified `37` member occurrences by an exact list of prompt/restart/liveness provider
names and found two files with no other `core.*` match. That second result established only two
lexical require candidates: it did not inspect bare `core` uses and did not prove either require
was removable in that slice.

At the floor-correction ref, the checker's actual output is `50` requires plus `448` member
matches, total `498`; the committed ceiling remains `52 + 489 = 541`. The `37` M3 target-member
occurrences are now zero. This metric is a lexical shrink-only counter, not a semantic partition:
the current `498` includes 107 member matches in files with no `require("core")`, one match in a
comment, and nine require matches in files with no `core.<identifier>` match.

### 3.2 `migration/core-param.inventory`

Owner: `scripts/check_repo_core_param.py` [M2].

One `library_core_params` unit is one regex occurrence in non-test `libraries/devloop/**/*.lua`
of a table function whose first parameter is literally `M` or `core`. One
`dept_core_arg_call_sites` unit is one regex occurrence in production department Lua of
`identifier.method(core, ...)`, `identifier.method(core)`, or the corresponding literal `M`
form.

The second metric's name overstates its precision. Its regex also matches a department-local
definition such as `function M.make(core)`. The measured `127` consists of `113` call expressions
and `14` function definitions [M2]. The library side contains `148` matches, so the current and
committed total is `275` [M1]. All `275` are broad-input syntax; package-local sites are still
real narrowing work even when they are not devloop calls.

### 3.3 `migration/devloop-godlib.inventory`

Owner: `scripts/check_repo_devloop_godlib.py` [M2]. It scans every Lua file under
`libraries/devloop`, including tests, plus package-root `core.lua` files and
`libraries/devloop/fkst.toml`.

Its units are heterogeneous:

- one `install_defs` unit is one regex occurrence of a function named `install` whose parameter
  list is exactly the literal `M`; definitions with additional parameters are invisible;
- one `m_writes` unit is one textual `M.name =` or `function M.name(` occurrence, regardless of
  whether `M` is an ambient composed core or an ordinary typed module's return table;
- one `package_core_installs` unit is one exact direct
  `require("devloop.name").install(M)` occurrence in `packages/*/core.lua`; aliases, additional
  arguments, `target`, nested installers, and `core/devloop_wiring.lua` are invisible; and
- one `wildcard_exports` unit is one textual `"devloop.*"` occurrence in the devloop manifest.

Verified current metrics are `8` installer definitions, `161` `M` writes, `24` exact package
calls, and no wildcard, total `193` [M1]. The committed ceiling still records `165` writes, total
`197` [M1]. Of the `161` writes, `57` are true ambient writes and `104` are valid typed module
exports [M4]. The typed exports are a checker floor, not migration debt.

### 3.4 `migration/ambient-surface.inventory`

Owner: `scripts/check_repo_ambient_surface.py` [M2].

One `install_m_calls` unit is one exact direct
`require("devloop.name").install(M)` occurrence in a package-root `core.lua`. One
`ambient_m_exports` unit is one **unique symbol name**, not one line or source occurrence. The
checker unions names found in the directly installed modules and every quoted `devloop.*`
submodule name in those modules. It recognizes explicit `M.name` definitions or assignments plus
literal names in its loop-binding pattern. It discards the name `install`.

Verified current and committed metrics are `24` exact calls plus `168` unique names, total `192`
[M1]. The `168` names comprise `95` command names, `58` state names, `14` logging names, and one
PR-partition contract name [M4]. The checker misses the prompt, restart, liveness, review-replay,
and workflow-internal liveness surfaces described in Section 4.

## 4. Overlap map and deduplicated total

### 4.1 Normalization

To deduplicate unlike counters, normalize them into source obligations:

- a read/require/parameter/call unit is its exact source occurrence;
- an export unit is the unique ambient binding name that the call exposes;
- an installer-definition unit is its definition occurrence; and
- the same occurrence or binding name counted by two artifacts is one obligation.

This normalization deliberately does not claim one obligation equals one edited line or one PR.
Deleting one last install call can retire many export-name obligations at once.

### 4.2 Planning-ref raw overlap

The four planning-ref checker totals sum to `1,200` [M1]. Exact pairwise duplicates are [M4]:

| Same underlying obligation | First artifact | Second artifact | Count |
|---|---|---:|---:|
| Exact package-root devloop install call | `devloop-godlib` | `ambient-surface` | 24 |
| Literal-`M` installer definition | `core-param` | `devloop-godlib` | 8 |
| Explicit logging/partition binding name | `devloop-godlib` | `ambient-surface` | 15 |
| `dependency_gate.lua` typed `function M.new(core)` occurrence | `core-param` | `devloop-godlib` | 1 |

There is no triple overlap. At the planning ref, the normalized union of **all raw units**,
including units outside the direct campaign target, is `1,152 = 1,200 - 24 - 8 - 15 - 1` [M4].

### 4.3 Actionable artifact union

The original planning-ref movement ledger was [M4]:

| Artifact | Planning value | Endpoint or planning residue | Planned direct movement |
|---|---:|---:|---:|
| `service-locator` | 540 | 501 (arithmetic residue, not a floor) | 39 |
| `core-param` | 275 | 0 | 275 |
| `devloop-godlib` | 193 | 104 | 89 |
| `ambient-surface` | 192 | 0 | 192 |

The service-locator `39` is the planning-ref set attributed to the named prompt/restart work, not
proof that the complement is structurally fixed. The raw planned sum is `595`. Within that sum,
the actionable duplicates are the eight
installer definitions, fifteen binding names, and twenty-four exact install calls. The
`dependency_gate` overlap is not subtracted here because its `M` write belongs to the typed-export
floor, while its broad `core` parameter remains actionable. Thus the deduplicated actionable
union represented by the four artifacts is `548 = 595 - 8 - 15 - 24` [M4].

### 4.4 Checker-blind obligations

The source census adds `27` obligations absent from that actionable union [M4]:

- nine ambient binding names: three written by
  `devloop.restart.pr_review_replay_facts.install(ctx)` and six installed by the existing
  `workflow_internal.liveness` owners;
- one ambient-mutating installer definition:
  `devloop.restart.pr_review_replay_facts.install(ctx)`; and
- seventeen ambient install call sites: twelve package/package-wiring calls plus five nested
  calls in `devloop.commands` and `devloop.liveness`.

The other checker-blind prompt/restart/liveness definitions are already counted by `core-param`,
and their forty-two explicit ambient bindings are already counted by `devloop-godlib`; adding
them again would double-count.

The **true deduplicated campaign total is therefore `575 = 548 + 27`** [M4]. This is the campaign's
source-obligation total under Section 4.1, not a duration or diff-size estimate.

The real ambient symbol surface is `219` unique names: `210` visible in the union of
`ambient-surface` and true-ambient `devloop-godlib` writes, plus the nine checker-blind names [M4].

## 5. Floors and honest cost

### 5.1 `service-locator`: no verified structural floor; do not target a residual count here

The original claim was that removing `37` named devloop-provider member matches and two associated
requires would leave a structural floor of `501 = 452 + 49`. That claim is false. M3 defined the
`452` only as the complement of a provider-name list, not as occurrences that cannot be narrowed.
It also called a require removable when its file had no other `core.*` match, although the file
still passed the bare `core` value. Slice 2 removed all thirty remaining target members but
only zero requires, producing `50 + 452 = 502`, not `49 + 452 = 501`.

The checker and inventory were unchanged from the planning ref through the correction ref. The
measured history is:

| Ref | Milestone | Requires | Member matches | Total |
|---|---|---:|---:|---:|
| `8ffcd070` | specification landed | 51 | 489 | 540 |
| `06086b8b` | Slice 1 landed | 50 | 482 | 532 |
| `ddc3e46f` | Slice 2 landed | 50 | 452 | 502 |
| `475e78ec` | Slice 3 landed | 50 | 452 | 502 |
| `bb6bf832` | Slice 4 landed | 50 | 448 | 498 |

Slice 4 itself did not remove the four units: its parent already measured `498`. Intervening commit
`4683ecf8` narrowed bot-login normalization and removed four raw
`core.strip_bot_login_suffix` matches from `github-external-pr-intake` and
`github-ratchet-migration-slicer`. No service-locator migration, checker change, or inventory change
caused that drop. This is direct evidence that unrelated interface narrowing changes the lexical
residual.

No positive structural floor is established. The checker's mechanical minimum is zero: it has no
exemption set and describes itself as driving the read-side debt to zero. The current occurrences
are a heterogeneous observation across nineteen packages, including package-owned reads, broad
parameters in helper files, and lexical false positives. No source invariant proves that any
fixed subset must remain, and this campaign does not need such a proof.

**Scope consequence:** Slices 5 through 9 must not add work whose sole purpose is lowering the
current `498`. They continue to narrow the named `core-param` owners and retire the named ambient
install surfaces. The service-locator value is remeasured and reported after each slice; incidental
decreases are expected and no exact final value is required. Completion is established by the
ambient-name source census and the three semantically bounded checker endpoints, not by reaching
`501` or zero in this lexical counter. Migrating unrelated package-owned reads, forge-installed
bindings, or lexical false positives belongs to a separate, broader DI decision with its own
evidence.

### 5.2 `core-param`: floor `0`; zero is the endpoint

The source census partitions all `148` library matches and all `127` department matches into the
ordered slices below [M5]. `INFERRED`: zero is behavior-preservingly reachable because every match
is a literal broad parameter or broad-argument spelling and each slice names a current owner. The
campaign must stop and report no-op for any site whose behavior or static source contract cannot
be preserved; the inference becomes verified only as slices land.

### 5.3 `devloop-godlib`: floor `104`; do not drive it to zero

The current `161` `M` writes split into `57` ambient writes and `104` typed-return exports [M4].
After all eight recognized ambient definitions and all twenty-four recognized package calls are
removed, the checker reads `0 + 104 + 0 + 0 = 104` [M4]. Renaming typed modules' local table from
`M` to another letter would change no coupling and would be ratchet gaming.

**Recommendation:** leave the `104` typed-export floor alone and reclassify the `m_writes` metric
outside this campaign. The inventory's prose target of all zero is false at the measured ref.

### 5.4 `ambient-surface`: floor `0`; zero is the endpoint

The checker derives exports only from modules with a remaining exact install call. Once its
twenty-four calls are absent, both metrics are zero by construction [M2, M4]. `INFERRED`: removing
those calls is behavior-preserving only after the exhaustive consumer census in Slice 9 is empty.

### 5.5 Work that should not be done

- Do not migrate service-locator occurrences merely because they remain in the lexical residual;
  only occurrences reached by a named slice responsibility and the ambient source census are in
  scope.
- Do not rename or rewrite the `104` typed devloop exports to satisfy a lexical metric.
- Do not convert the generic `workflow_internal.liveness` providers. Keep their existing owner and
  invoke them on a private typed liveness record rather than the package-composed core.
- Do not add an abstraction for the checker-blind census. Use the source census as a completion
  command; checker repair or reclassification is a separate accounting decision.
- Do not extract predecessor/dispatch sequences from their current department source. Static
  conformance scans same-source text [M6].

## 6. Campaign invariant: every landed prefix is safe

This invariant applies after every commit and PR, including an interrupted campaign:

1. **Behavior parity:** for the same input, the ordered effects, transitions, marker bytes, raised
   event payloads, return values, and errors are identical. A discovered bug remains unchanged and
   is recorded in `notes`.
2. **Atomic public cutover:** a removed broad interface and every production caller change in the
   same PR. No PR introduces a second public route and leaves the installer as a compatibility
   path.
3. **Monotone coupling:** none of the four current checker metrics grows. The M4 source census also
   never grows, covering the checkers' blind spots.
4. **No ambient-to-narrow adapter:** a narrow dependency record is built from typed owners, not by
   copying fields out of the ambient package core as a temporary bridge.
5. **No premature deletion:** an installer or binding is deleted only after an exhaustive
   production-source consumer census is empty and the full Lua suite passes. An empty
   `migration/devloop-installer.inventory` is insufficient because that checker does not scan
   `libraries/` [M6].
6. **Static observability:** before changing a source file or call shape, search all conformance
   code, tests, ratchets, and inventories for that path and symbol. A same-source predecessor and
   dispatch remain in the same scanned source in the same order. A line-keyed allowlist entry is
   not moved or rewritten by this campaign.
7. **Owner and width:** use an existing natural owner. A seam exceeding six inputs is rejected,
   never threaded through a wide helper.
8. **No hidden topology change:** no new devloop module, no new integration core path, no engine
   primitive, no public-export expansion, and no migration/checker weakening.
9. **Restartability:** every landed slice passes the full repository checks on its own. No later
   slice is required to restore runtime behavior or static enforcement.

If any clause fails, the slice verdict is `no-op`; record the rejected seam and proceed only with
another independently valid slice.

## 7. Ordered, independently landable slices

The counter deltas below are decreases from the current values in M1. Their sums are exactly the
movements in Section 4.3 [M5]. "Obligations" uses Section 4.1 and includes blind source facts.

### Slice 0: freeze behavior and source-shape evidence

**Named responsibility:** the characterization suite records the current observable contract.

**Change:** add missing cases only to existing package test ownership areas. Freeze ordered raised
events, marker bodies, transition rows, errors, prompt bytes, restart decisions, liveness
decisions, and installer-return values touched by later slices. Record M0-M6 outputs in the PR.
Do not edit a checker or inventory in this slice.

**Counter movement:** none. **Obligations retired:** none.

**Verification:** full `scripts/run.sh test`; `python3 -B scripts/check_repo.py --project-root .`;
the source-shape preflight in Section 8.

**Blast radius:** tests and evidence only. If existing tests already cover every observable, this
slice is a documented no-op.

### Slice 1: typed prompt owner

**Named responsibility:** `devloop.prompts` renders and parses configured prompts.

**Change:** make the existing module return its resolved typed prompt surface. Build that surface
at existing composition owners, including the current package `devloop_wiring.lua` files and
`github-devloop-workflow/core.lua`. Rewire the five affected department files to existing
department capability owners or a module-local narrow record. Delete `prompts.install` and all six
ambient calls in the same PR. Do not add a module.

**Measured movement [M3-M5]:** `service-locator -8` (`7` members plus one now-unused require),
`core-param -1`, `devloop-godlib -16`, `ambient-surface 0`; **31 obligations retired**.

**Verification:** exact prompt golden tests for implement, fix, review-meta, decompose, sync
conflict, and workflow intake; affected package suites; full repository suite; all four checkers;
M4 source census shows no prompt binding or call.

**Blast radius:** prompt construction and parsing in `github-devloop`, `github-devloop-pr`,
`github-devloop-decompose`, `github-devloop-integration`, `github-devloop-intake-default`, and
`github-devloop-workflow`. Prompt bytes and parser outcomes must be identical.

### Slice 2: typed restart-policy kernel

**Named responsibility:** the restart-policy kernel computes restart decisions from explicit
package wiring.

**Change:** use the existing `devloop.restart`, `devloop.liveness`,
`devloop.restart.pr_review_replay_facts`, package `core/devloop_wiring.lua` owners, and existing
department capability modules. Return one typed kernel per package composition. Invoke the two
existing `workflow_internal.liveness` installers on a private kernel table, never on package `M`.
Migrate every library and department consumer atomically; delete the ambient devloop installers,
the review-replay mutation, all direct calls, and all nested ambient-target calls. Do not extract
codex predecessor/dispatch sequences from their scanned department sources.

**Planning movement [M3-M5]:** `service-locator -31` (`30` members plus one require candidate),
`core-param -5`, `devloop-godlib -26`, `ambient-surface 0`; 82 planned obligations.

**Landed movement at `ddc3e46f`:** `service-locator -30` (thirty members and zero requires),
`core-param -5`, `devloop-godlib -26`, `ambient-surface 0`; **81 obligations retired in this
slice**. The `review_meta` require remained because bare `core` uses remained. Its removal is
contingent on the slice that removes its final real use; it cannot support a fixed floor.

**Verification:** restart table byte/value equality, replay-fact equality, liveness judgment
parity, timeout decision parity, hidden-state conformance, span conformance, restart sink inventory,
all old-behavior observation tests, affected package suites, full repository suite, all four
checkers, and the M4 blind census.

**Blast radius:** lifecycle observation, reconciliation, implementation, PR review/fix,
review-meta, timeout redrive, and package restart composition. This is the highest-consequence
slice. If the existing owners cannot express it without a wide record or a dual surface, return
`no-op`; do not create a helper module.

### Slice 3: parser and validator inputs

**Named responsibility:** parsing converts external values into typed devloop values.

**Change:** narrow functions in `devloop.parsers.issue`, `devloop.strings`,
`devloop.validators.ready`, and `devloop.validators.reviewing`; update all callers atomically.
Use direct typed requires for stable value operations.

**Measured movement [M5]:** `core-param -42`; all other campaign counters unchanged;
**42 obligations retired**.

**Verification:** parser fixtures, payload-validation tests, affected package suites, full suite,
all four checkers, and same-source preflight.

**Blast radius:** issue decoding and ready/reviewing validation across devloop, PR, intake,
integration, and ops readers. Parsed values and errors remain identical.

### Slice 4: request, payload, and context inputs

**Named responsibility:** request construction produces durable outbound intent from typed facts.

**Change:** narrow the existing context-bundle, marker-builder, operator-command, payload, and
request modules listed by M5. Keep each function in its existing owner; use one request-specific
record only when direct typed requires do not carry per-package facts.

**Planning movement [M5]:** `core-param -74`; all other campaign counters unchanged;
**74 obligations retired**. The Slice 4 commit itself left `service-locator` at its parent's
`50 + 448 = 498`; the four-unit decline from the Slice 3 milestone occurred in intervening commit
`4683ecf8`, as recorded in Section 5.1.

**Verification:** exact request bodies, labels, dedup keys, source refs, handoff markers, raised
event arrays, context fetch behavior, affected package suites, full suite, all four checkers, and
same-source preflight.

**Blast radius:** lifecycle publication, review publication, board payloads, context hydration,
and operator-command output. No request field, marker byte, or raise order changes.

### Slice 5: entity and admission inputs

**Named responsibility:** admission derives managed entity decisions from typed identity facts.

**Change:** narrow the existing autonomy-ledger, claims, decompose, entity, entity-list-cache,
execution-start, forks, and git-mechanics owners. Follow commit `18700fa0`: normalization stays in
`devloop.parsers.shared`, bot policy stays in `devloop.github_author_policy`, and source identity
stays in `devloop.base_ids`. Do not recreate `devloop.claims.identity`.

**Measured movement [M5]:** `core-param -28`; all other campaign counters unchanged;
**28 obligations retired**.

**Verification:** claim/fork/admission fixtures, execution-start effects, entity cache behavior,
autonomy ledger output, affected package suites, full suite, all four checkers, dependency-cycle
check, exact-export conformance, and same-source preflight.

**Blast radius:** issue admission, ownership policy, fork derivation, entity reads, and execution
start. Identity normalization and claim effects remain identical.

### Slice 6: convergence, replay, and queue inputs

**Named responsibility:** convergence selects the next legal lifecycle action from typed facts.

**Change:** narrow the existing convergence, dependency-gate, merge-gate-wait, merge-queue,
queue-starvation, replay-required-facts, replay-thinking-convergence, and replayer owners listed by
M5. Keep dispatch and predecessor call text in its current department source.

**Measured movement [M5]:** `core-param -58`; all other campaign counters unchanged;
**58 obligations retired**.

**Verification:** convergence round and reconcile fixtures, row replay observations, merge queue
ordering, starvation diagnosis, restart sink inventory, span conformance, affected package suites,
full suite, all four checkers, and same-source preflight.

**Blast radius:** replay routing, convergence markers, merge admission, queue ordering, and
starvation observation. Transition selection and effect order remain identical.

### Slice 7: restart-contract consumer inputs

**Named responsibility:** restart conformance validates typed restart-policy facts.

**Change:** narrow the existing hidden-state conformance, liveness-scan,
restart-actionable-epoch, restart-responsibility-contract, and saga-conformance functions listed by
M5. Consume the typed kernel landed by Slice 2. Do not relocate source-scanned calls.

**Measured movement [M5]:** `core-param -28`; all other campaign counters unchanged;
**28 obligations retired**.

**Verification:** hidden-state, responsibility, actionable-epoch, liveness-scan, saga, span, and
restart-contract suites; affected package suites; full suite; all four checkers; same-source
preflight.

**Blast radius:** conformance and scan decisions over restart rows. Error lists, ordering, and
redrive outcomes remain identical.

### Slice 8: package-local whole-core helpers

**Named responsibility:** each package-local helper owns only its existing local operation.

**Change:** narrow the `31` package-local department matches: `17` call expressions and `14`
function definitions [M2, M5]. Keep the observability helpers in their existing common/submodule
owners, the implementation helpers in their existing department files, and merge mechanics in its
existing file. Prefer closures over a new module. Reject any extraction that would require a new
integration core path.

**Measured movement [M5]:** `core-param -31`; all other campaign counters unchanged;
**31 obligations retired**.

**Verification:** package-local behavior fixtures, observability snapshots, implementation and fix
old-behavior tests, affected package suites, full suite, all four checkers, source-path scans, and
line-keyed allowlist preflight.

**Blast radius:** github-devloop implementation, github-devloop-pr fix mechanics, and
github-devloop-ops observability. No cross-package API changes.

### Slice 9: retire tracked install scaffolds

**Named responsibility:** package composition exposes typed library modules without ambient
rebinding.

**Precondition:** the generated symbol census for commands, logging, state, and the partition
contract finds no production `M.<name>` or `core.<name>` consumer in `libraries/` or `packages/`
that depends on those installers. Run the full suite before deletion; the empty installer reader
inventory alone is not proof.

**Change:** remove the eight recognized installer definitions, twenty-four exact package-root
calls, the command aggregator's nested ambient call, and dead install-only aliases/no-op helpers.
Keep every typed command, logging, state, and partition export at its existing module path. No shim.

**Measured movement [M4, M5]:** `core-param -8`, `devloop-godlib -47`,
`ambient-surface -192`, `service-locator 0`; **201 obligations retired**.

**Verification:** exhaustive consumer census before and after, module export equality excluding
only `install`, exact command/log/state behavior, all package suites that compose these libraries,
full repository suite, all four checkers, exact-export conformance, and same-source preflight.

**Blast radius:** every package root that currently installs commands or logging, every package
root that installs state, and the github-devloop partition contract. Runtime behavior must be
unchanged because all consumers already use the typed owners before this slice lands.

## 8. Verification contract for every implementation slice

### 8.1 Static source-shape preflight

Before editing each candidate file, run:

```bash
candidate='path/to/candidate.lua'
rg -n --fixed-strings "$candidate" scripts packages libraries migration docs
rg -n 'predecessor_call_before|spawn_start_messages|source_path|path:line|line_number' \
  scripts packages libraries migration
rg -n 'function_name|spawn_predecessor|spawn_function|durable_start_marker' \
  packages/*/core/restart packages/*/core/span_conformance.lua
```

Inspect every match. `packages/github-devloop/core/span_conformance.lua` scans all production
department source text and requires a predecessor call before the relevant dispatch in the same
source [M6]. Preserve that text relation. Tests and inventories also carry source-path and
line-coordinate evidence [M6]; do not shift a line-keyed migration entry.

### 8.2 Per-slice test gate

```bash
git diff --check
python3 -B scripts/check_repo_service_locator.py .
python3 -B scripts/check_repo_core_param.py .
python3 -B scripts/check_repo_devloop_godlib.py .
python3 -B scripts/check_repo_ambient_surface.py .
python3 -B scripts/check_repo.py --project-root .
scripts/run.sh test
```

The four focused commands must show exactly the slice delta, never merely remain below a stale
baseline. `scripts/run.sh test` must exit zero. Compare characterization outputs before and after;
same count is insufficient when payload bytes or order differ.

### 8.3 Per-slice review evidence

Every PR records:

- measurement ref before rebase and after rebase;
- exact before/after focused metrics;
- the source-obligation census for its owner;
- full-suite exit status;
- static path/symbol search results;
- behavior equality evidence;
- explicit confirmation that no module/export/checker/allowlist/engine change was introduced; and
- `notes` containing any preserved bug or rejected seam.

## 9. Completion proof

The campaign is complete only when one fresh run proves all of the following:

- `core-param`, `devloop-godlib`, and `ambient-surface` are exactly `0`, `104`, and `0`; the fresh
  `service-locator` value is reported without an asserted floor;
- every named source obligation in the ordered slice ledger is absent; the planning-ref `575`
  normalization is accounting context, not a live completion counter [M4, M5];
- the ambient source census reports no package-composed target passed to any of the fourteen
  ambient-mutating devloop definitions, no review-replay mutation, and no nested ambient target
  [M4];
- no production library or department reads one of the `219` former ambient names from a package
  core [M4];
- the full test suite and repository check exit zero; and
- no behavior or source-shape invariant changed.

`VERIFIED` at the planning ref: checker implementations and exclusions; committed/current values;
raw overlap; `37` target service member occurrences; two lexical require candidates; `57/104`
godlib write split; `168` tracked ambient names; `219` real ambient names; `14` ambient-mutating
devloop definitions; `41` ambient-target install call sites; `548` planned actionable artifact
union; `27` blind obligations; `575` planning normalization; slice partition arithmetic; exact
exports; same-source scan. `VERIFIED` at the correction ref: service-locator `50 + 448 = 498`, zero
remaining M3 target-member occurrences, unchanged checker and inventory, and no positive structural
floor supported by the checker or source census.

`INFERRED` until implementation: behavior-preserving reachability of the `core-param` and
`ambient-surface` zero floors; adequacy of each named seam; final behavior equality. An inference
must not be used to skip a slice's no-op gate or verification.

## 10. Notes and rejected interpretations

- No runtime bug was diagnosed during this specification. Measurement-premise defects were found;
  this task does not repair them.
- At the planning ref, the committed service and godlib ceilings exceeded source by one and four
  units respectively [M1]. Progress claims must use fresh checker output.
- `501` was an arithmetic complement at the planning ref, not a structural floor. It must not be
  used to scope or complete Slices 5 through 9.
- `dept_core_arg_call_sites` includes definitions; calling all `127` units call sites is false
  [M2].
- `devloop-godlib.m_writes` conflates `57` ambient writes with `104` typed exports; targeting zero
  is false [M4].
- `ambient-surface` sees `168` names but the actual ambient name surface is `219`; using its zero
  alone as completion proof is false [M4].
- The exact-package installer reader inventory is empty at the pinned ref, yet the endpoint
  document records library-side readers. Its zero is not the scaffold deletion condition [M6].
- A wide helper seam, a new devloop module, a same-source extraction, an engine dependency, or a
  compatibility interval is a successful `no-op`, not a reason to force a cut.

## Appendix A: measurement commands and outputs

### M0 - freeze the source

```bash
git rev-parse origin/integration-elonsg
# 1958d57b1366dec3521157f2c562d024947208ec
MEASURE_ROOT="$(mktemp -d)"
git archive origin/integration-elonsg | tar -x -C "$MEASURE_ROOT"
cd "$MEASURE_ROOT"
```

### M1 - committed ceilings and current checker values

```bash
for f in service-locator core-param devloop-godlib ambient-surface; do
  sed -n '1,40p' "migration/$f.inventory"
done
python3 -B scripts/check_repo_service_locator.py .
python3 -B scripts/check_repo_core_param.py .
python3 -B scripts/check_repo_devloop_godlib.py .
python3 -B scripts/check_repo_ambient_surface.py .
```

Output totals:

```text
committed: service=52+489=541 core-param=148+127=275
committed: godlib=8+165+24+0=197 ambient=24+168=192
planning:  service=51+489=540 core-param=148+127=275
planning:  godlib=8+161+24+0=193 ambient=24+168=192
correction-ref service=50+448=498
```

### M2 - checker semantics and definition/call split

```bash
sed -n '1,240p' scripts/check_repo_service_locator.py
sed -n '1,240p' scripts/check_repo_core_param.py
sed -n '1,260p' scripts/check_repo_devloop_godlib.py
sed -n '1,240p' scripts/check_repo_ambient_surface.py
python3 -B - <<'PY'
import importlib.util, re
from pathlib import Path
root = Path('.')
spec = importlib.util.spec_from_file_location('c', root/'scripts/check_repo_core_param.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
defs = calls = 0
for path in root.glob('packages/*/departments/**/*.lua'):
    rel = path.as_posix()
    if '/tests/' in rel or rel.endswith('_test.lua'):
        continue
    text = path.read_text()
    for match in c._CALL_ARG.finditer(text):
        prefix = text[max(0, match.start()-20):match.start()]
        if re.search(r'function\s*$', prefix): defs += 1
        else: calls += 1
print({'metric_total': defs + calls, 'definitions': defs, 'call_expressions': calls})
PY
# {'metric_total': 127, 'definitions': 14, 'call_expressions': 113}
```

### M3 - planning-ref service target and lexical require candidates

```bash
# Provider names are extracted from the eight mutating devloop provider files with the same
# explicit-M and loop-list patterns used by the owning checkers, plus the three ctx writes in
# restart/pr_review_replay_facts.lua. Classify service-locator matches by those exact names.
python3 -B - <<'PY'
import importlib.util
from collections import Counter
from pathlib import Path
root = Path('.')
spec = importlib.util.spec_from_file_location('s', root/'scripts/check_repo_service_locator.py')
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
providers = {
 'prompts': {'actor_harness_clause','build_decompose_prompt','build_fix_prompt','build_implement_prompt','build_intake_prompt','build_review_meta_prompt','build_sync_conflict_prompt','execution_boundary_clause','judge_harness_clause','output_language','parse_intake_action','parse_review_meta_action','prompt_preamble','render_prompt_template','review_observation_boundary_clause','short_review_observation_boundary_clause'},
 'restart': {'fixing_version_matches_link','latest_complete_converge_round','restart_completeness_audit','restart_completeness_audit_for_state','restart_durable_marker_fields','restart_effect_contract_errors','restart_field_coverage_errors','restart_required_replay_payload_fields','restart_source_ref_derivations','restart_transition_table'},
 'liveness': {'restart_observe_replay_due','restart_observe_timeout_due','restart_row_liveness_deferred','restart_row_liveness_signal','restart_row_observable_on','restart_row_receiver_liveness','build_liveness_timeout_reconcile_payload','liveness_budget_minutes','liveness_state_age_minutes','liveness_timeout_attempt','liveness_timeout_decision','liveness_timeout_decision_with_facts','liveness_timeout_due','liveness_timeout_due_with_facts','maybe_timeout_redrive_from_table','next_liveness_timeout_version'},
 'pr_review_replay': {'fixing_replay_feedback_fact','review_meta_replay_fact','review_meta_replay_fact_from_state'},
}
counts, target_files = Counter(), set()
for path in s._department_files(root):
    text = path.read_text()
    for match in s._CORE_MEMBER.finditer(text):
        name = match.group(0).split('.', 1)[1]
        owner = next((key for key, names in providers.items() if name in names), None)
        if owner:
            counts[owner] += 1; target_files.add(path)
lexical_require_candidates = []
all_names = set().union(*providers.values())
for path in target_files:
    names = [m.group(0).split('.', 1)[1] for m in s._CORE_MEMBER.finditer(path.read_text())]
    if all(name in all_names for name in names): lexical_require_candidates.append(path.as_posix())
print(dict(counts), 'members=', sum(counts.values()))
print('lexical_require_candidates=', len(lexical_require_candidates), sorted(lexical_require_candidates))
PY
# {'prompts': 7, 'restart': 12, 'liveness': 17, 'pr_review_replay': 1} members=37
# lexical_require_candidates=2: implement/attempt.lua and review_meta/main.lua
```

This command proves only that those files have no `core.<identifier>` outside the provider-name
set. It does not search for bare `core` uses and therefore does not prove that both requires can be
removed with the target members. Landed Slice 2 evidence disproved that stronger interpretation.
At the correction ref, the same target-member classification prints `{} members= 0`.

### M4 - planning movements, overlaps, blind surface, and normalized total

```bash
python3 -B - <<'PY'
# Values below are first asserted by the owning regexes and source enumerations shown after this
# arithmetic block. Keeping the arithmetic executable prevents a narrative total from drifting.
planning = {'service': 540, 'core_param': 275, 'godlib': 193, 'ambient': 192}
movement = {'service': 39, 'core_param': 275, 'godlib': 89, 'ambient': 192}
residual = {key: planning[key] - movement[key] for key in planning}
overlap = {'installer_defs': 8, 'binding_names': 15, 'install_calls': 24}
artifact_union = sum(movement.values()) - sum(overlap.values())
blind = {'binding_names': 9, 'installer_defs': 1, 'install_calls': 17}
true_total = artifact_union + sum(blind.values())
print(planning, movement, 'planning_residual_not_floor', residual)
print('artifact_union', artifact_union, 'blind', blind, 'true_total', true_total)
assert movement == {'service': 39, 'core_param': 275, 'godlib': 89, 'ambient': 192}
assert residual == {'service': 501, 'core_param': 0, 'godlib': 104, 'ambient': 0}
assert artifact_union == 548 and true_total == 575
PY
```

Evidence-producing source commands:

```bash
# Exact per-file godlib matches; output sums to 161 and isolates the 57 ambient writes.
python3 -B - <<'PY'
import importlib.util
from pathlib import Path
root = Path('.')
spec = importlib.util.spec_from_file_location('g', root/'scripts/check_repo_devloop_godlib.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
for path in g._lua_files(root/g.DEVLOOP):
    text = path.read_text(errors='replace')
    count = len(g._M_ASSIGN.findall(text)) + len(g._M_FUNC.findall(text))
    if count: print(path.as_posix(), count)
print(g.measure(root))
PY
# Ambient files: logging=14, prompts=16, restart=10, liveness/signal=6,
# liveness/timeout=10, restart/issue/pr_partition_contract=1; sum=57.
# All other printed files sum to the typed-export floor 104.

# Tracked ambient calls and names.
python3 -B scripts/check_repo_ambient_surface.py .
# current: {'install_m_calls': 24, 'ambient_m_exports': 168}

# Exact tracked module distribution.
python3 -B - <<'PY'
import importlib.util
from collections import Counter
from pathlib import Path
root = Path('.')
spec = importlib.util.spec_from_file_location('a', root/'scripts/check_repo_ambient_surface.py')
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
mods = Counter()
for core in root.glob('packages/*/core.lua'):
    for match in a._INSTALL.finditer(core.read_text()): mods[match.group(1)] += 1
for mod, calls in sorted(mods.items()):
    text = a._module_path(root, mod).read_text(); names = a._export_names(text)
    for sub in a._SUBMOD.findall(text):
        path = a._module_path(root, sub)
        if path.exists(): names |= a._export_names(path.read_text())
    print(mod, calls, len(names))
PY
# commands 8/95; logging 8/14; partition 1/1; state 7/58.

# Blind writes and calls.
rg -n 'rawset\(M|function M\.|^\s*M\.[A-Za-z_].*=' \
  libraries/workflow_internal/liveness/shared.lua \
  libraries/workflow_internal/liveness/contract.lua
# Six unique workflow-internal binding names.
rg -n 'pr_review_replay_facts\.install\(M\)|prompts\.install\(M|devloop_prompts\.install\(target|require\("devloop\.(restart|liveness)"\)\.install\(M' packages
# Twelve checker-blind package/package-wiring calls.
rg -n '\.install\(M' libraries/devloop/commands.lua libraries/devloop/liveness.lua
# Five nested ambient-target calls.
```

The fourteen ambient-mutating devloop definition paths are:

```bash
rg -n '(function\s+[A-Za-z_][A-Za-z0-9_]*\.install\s*\(|[A-Za-z_][A-Za-z0-9_]*\.install\s*=\s*function\s*\()' libraries/devloop
```

Classify the output by mutation of the first parameter. The result is the command aggregator,
four mutating command children, logging, state, partition contract, prompts, restart, liveness,
two liveness children, and review-replay: fourteen. `devloop.gate.install(resolved)` and the two
empty command helpers do not mutate a composed target.

### M5 - slice partition

```bash
python3 -B - <<'PY'
import importlib.util
from collections import Counter
from pathlib import Path
root = Path('.')
spec = importlib.util.spec_from_file_location('c', root/'scripts/check_repo_core_param.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
groups = {
 'parse_validate': ['parsers/issue.lua','strings.lua','validators/ready.lua','validators/reviewing.lua'],
 'request_payload_context': ['context_bundle.lua','markers/builders.lua','operator_commands.lua','payloads/board.lua','payloads/builders.lua','payloads/predicates.lua','requests/bodies.lua','requests/labels.lua','requests/lifecycle.lua','requests/review.lua','requests/shared.lua'],
 'entity_admission': ['autonomy_ledger.lua','claims.lua','decompose.lua','entity.lua','entity_list_cache.lua','execution_start.lua','forks.lua','git_mechanics.lua'],
 'convergence_replay_queue': ['convergence/attempts.lua','convergence/reconcile.lua','convergence/rounds.lua','dependency_gate.lua','merge_gate_wait.lua','merge_queue.lua','queue_starvation.lua','replay_required_facts.lua','replay_thinking_convergence.lua','replayer.lua'],
 'restart_contract_consumers': ['hidden_state_conformance/poll_fakes.lua','hidden_state_conformance.lua','liveness_scan.lua','restart_actionable_epoch.lua','restart_responsibility_contract.lua','saga_conformance.lua'],
 'ambient_owners': ['commands/git_ops.lua','commands/issue_reads.lua','commands/observe_lists.lua','commands/prs.lua','commands.lua','liveness/signal.lua','liveness/timeout.lua','liveness.lua','logging.lua','prompts.lua','restart/issue/pr_partition_contract.lua','restart.lua','state.lua'],
}
library = Counter()
for name, paths in groups.items():
    for rel in paths:
        library[name] += len(c._LIB_PARAM.findall((root/'libraries/devloop'/rel).read_text()))
print(dict(library), 'sum=', sum(library.values()))
PY
# parse=21 request=44 entity=19 convergence=31 restart-consumers=19 ambient-owners=14; sum=148.
```

For the department half, print every checker match with source coordinates, resolve direct
`local alias = require("...")` bindings, follow the eight `deps.*`/multi-assignment bindings to
their source requires, and classify the fourteen `function M.name(core)` matches as definitions:

```bash
python3 -B - <<'PY'
import importlib.util
from pathlib import Path
root = Path('.')
spec = importlib.util.spec_from_file_location('c', root/'scripts/check_repo_core_param.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
for path in sorted(root.glob('packages/*/departments/**/*.lua')):
    rel = path.as_posix()
    if '/tests/' in rel or rel.endswith('_test.lua'): continue
    text = path.read_text()
    for match in c._CALL_ARG.finditer(text):
        print(f"{rel}:{text.count(chr(10), 0, match.start()) + 1}: {match.group(0)}")
PY
```

The source-resolved group totals are:

```text
parse/validate: 21 calls + 21 library definitions = 42
request/payload/context: 30 calls + 44 library definitions = 74
entity/admission: 9 calls + 19 library definitions = 28
convergence/replay/queue: 27 calls + 31 library definitions = 58
restart-contract consumers: 9 calls + 19 library definitions = 28
package-local: 17 calls + 14 department definitions = 31
ambient owners: 14 library definitions
total: 127 department units + 148 library units = 275
```

Owner-slice arithmetic, including blind obligations:

```text
prompts: checker movement 8+1+16; blind calls 6; obligations 31
restart-policy kernel: checker movement 31+5+26; blind names 9 + definition 1 + calls 10; obligations 82
tracked scaffolds: distinct checker movement 8 definitions + 168 names + 24 calls; blind nested call 1; obligations 201
```

### M6 - exports, commit evidence, and source-shape consumers

```bash
sed -n '18,155p' libraries/devloop/fkst.toml
git show --format=fuller --no-ext-diff 18700fa0
sed -n '405,555p' packages/github-devloop/core/span_conformance.lua
rg -n 'predecessor_call_before|spawn_start_messages|source_path|path:line|line_number' \
  scripts packages libraries migration
python3 -B scripts/check_repo_devloop_installer.py .
sed -n '88,180p' docs/devloop-decouple-endpoint.md
```

The commit message records `exact exports omit public module` for the rejected private
`devloop.claims.identity` attempt. The span checker implements same-source predecessor ordering.
The installer-reader command reports an empty inventory, while the endpoint documents why library
readers make that result insufficient for scaffold deletion.

⟦AI:FKST⟧
