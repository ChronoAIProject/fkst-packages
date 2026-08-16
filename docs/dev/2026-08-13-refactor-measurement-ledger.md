# Refactoring campaign, 2026-08-13/14 — measurement ledger

Landed on `integration-elonsg`: **33 commits matching `^refactor:`, +702 / −1988, net −1286 lines**
(`git log origin/integration-elonsg --no-merges --numstat --grep='^refactor:' --since=2026-08-13`).

The reusable output is not the diff. It is the table below: which units were measured, what each
yielded, and which findings were **false and why**. Re-mining an exhausted unit is cheap to start
and expensive to finish, and three of these units produce confident, entirely wrong answers.

## Units measured, and what each yielded

| unit | how measured | yield |
|---|---|---|
| duplicated functions | normalised-body clustering | exhausted; every remaining cluster refused, see below |
| whole-file duplication | basename match + line similarity | 1 large pair — **refused** |
| source files (`*.lua`, `*.sh`, `*.py`, `*.rs`) ≥ 900 lines (the soft split threshold) | `wc -l` | **0** |
| exported library functions with no consumer | whole-repo, **all file types** | 26 found → 25 de-exported (#3762) |
| file-local functions never called in their own file | occurrence count in own file | 11 flagged → **6 real** (#3765, #3768) |
| `lib_deps` declared but never required | manifest vs `require` | 1 → **0** (#3770) |
| `event_deps` declared but never mentioned | manifest vs package Lua | **0** |
| modules never required by any other file | `require` scan | 30 flagged → **all 30 false** |

## The three units that lie, and the shape of the lie

**Modules never required — 30 flagged, 0 real.** `core/restart/{transitions,marker_fields,
liveness_signal_producers}/*.lua` are loaded by a registry: `devloop_wiring.lua` calls
`load_entries("core.restart.transitions", transitions_index)`, requiring each entry by a computed
name. A scan for literal `require("...")` cannot see this. The tell was the output's *shape* — 30
results sharing one directory family means the predicate models the wrong loading mechanism.

**Dead local functions — 5 of 11 were not code.** `packages/archaudit/tests/fire_raiser_helpers.lua`
and `packages/integration-coverage-producer/tests/fire_raiser_helpers.lua` hold Lua source inside
long-bracket literals, including `[[ ... ]] .. body .. [[ ... ]]`, and generate test files at runtime
with call sites assembled from other physical files. Those five names genuinely occur once in their
helper files — as template text — while being live in the generated programs. No static count can see
this, and **no positive control catches it**: a control proves the instrument finds hits, not that what
it found was code. It was caught by running the tests.
*Before treating a text count as evidence about reachability, check the file for `[[` … `]]` or
source built by concatenation. Such a file is partly data, and code-shaped lines in it are not code.*

**Unused exports — the first scan called 62 live functions dead.** The predicate required `.name(`
and so missed `local key_set = values.key_set` import style. A positive control (a symbol known to
be used must not read as dead) catches this in one line and was not run until after the fact.

## Refusals, with the evidence, so they are not re-litigated

- **The 536- and 531-line conformance pair** (`restart_obligation_derivation_test.lua`, issue vs PR side).
  The contract was unified (#3731), leaving 57 differing lines — including **six opposing assertion pairs**:
  the two packages have different restart tables and pin different truths
  (`participating_count` 21 vs 18, `timeout_count` 1 vs 2, and one pair asserting the opposite
  expectation). Consolidating means parameterising *expected values*, which hides each package's
  expectations from its own file. Similarity is not extractability.
- **The JSON escaper family.** 20 definitions, 8 distinct behaviours, across 8 packages: they escape
  0/3/4/7/8 character classes, differ on `nil` → `"nil"` vs `""`, and on hex case. A complete correct
  escaper already exists exported. Unifying them changes observable output at 13+ sites — that is a
  **correctness change, not a refactor**, and must not ship under a refactoring banner.
- **`load_department`**, defined identically in 8 packages. It `require`s a caller-supplied module
  name, and the engine resolves `require` **per unit**, so a copy moved into a library resolves as
  that library and fails: `require.denied ... not declared/visible to unit 'testkit_internal'`.
  The duplication is load-bearing.
- **One `lib_deps`-style guard not built.** After zeroing the category, a CI ratchet was declined:
  the drift is reversible and low-harm, so doctrine prefers cheap detection plus correction over an
  up-front gate. No repository-owned detector was added; repeat the one-off measurement by comparing
  each manifest's `lib_deps` with its package's `require` targets.

## The one unit that is a CLASS, not a sweep

`refactor: delete unreachable local functions` has now landed **four times in nine days**:

| date | commit | removed |
|---|---|---|
| 2026-08-05 | #3158 | 46 files, 615 lines |
| 2026-08-12 | #3672 | 3 files, 26 lines |
| 2026-08-14 | #3765 | 4 lines |
| 2026-08-14 | #3768 | 3 files, 66 lines |

**It regrows between sweeps.** By the rule of three this is a class and belongs in a checker rather
than a fifth manual pass. (Contrast the unused `lib_deps` above: one occurrence ever, so it gets the
cheap detector, not a gate. The difference between those two decisions is the whole point of the
rule — and it is easy to invoke it on the wrong one.)

**But the checker cannot be a text scan, and this is the hard-won part.** A raw-text stripper that
treats delimiter-looking text inside ordinary quoted strings as long-bracket delimiters
*introduces the opposite error*: in

```lua
stdout = '[[{\"number\":42,\"title\":\"'
  .. title
  .. '\",\"html_url\":\"https://github.example/owner/repo/issues/42\",\"updated_at\":\"'
  .. updated_at
  .. '\",\"state\":\"open\",\"labels\":[{\"name\":\"bug\"}],\"assignees\":'
  .. assignees_json(assignees)
  .. "}]]\n",
```

the call between the two quoted template chunks is **real code**, and a raw-text stripper can
mis-pair the `[[` inside the first string with the `]]` inside the second, read the call as literal
text, and report a live function as dead
(`packages/github-devloop-intake-default/tests/run_graph_intake_replay_after_dlq_test.lua`).
So delimiter-shaped text yields false positives in **both** directions. A correct implementation
needs real Lua tokenisation, not regex stripping.

Acceptance criteria for that checker, from the cases that broke every prototype here:
- flags **0** in the current tree,
- does **not** flag `assignees_json` (live code between template chunks),
- does **not** flag `mock_idle_observe`, `mock_production_github`, or `mock_codex_findings` in
  `packages/archaudit/tests/fire_raiser_helpers.lua`,
- does **not** flag `mock_checker` or `mock_production_issue_reads` in
  `packages/integration-coverage-producer/tests/fire_raiser_helpers.lua`
  (all five are template text that is live in generated files),
- **does** flag a deliberately introduced unreferenced `local function`.

## One transferable pattern

Every measurement error in this campaign had both endpoints sound and the **mapping** between them
wrong: the idea was right and the regex wrong; the check was right and its scope wrong; the cited
rule was real and its applicability wrong. Review the correspondence, not the components — the
components were never the defect.

Practical consequence: **an instrument that can report absence must carry a positive control in the
same invocation.** "Zero" is a claim about the query until something known-present proves the query
can see.

## Structural units, measured and refused (added 2026-08-14)

Subtractive units were exhausted, so function-level structure was measured too. It yielded no work,
and the reasons are worth keeping so the next pass does not re-derive them.

| unit | measured | yield |
|---|---|---|
| function length (all functions) | `check_repo_lua.code_mask` + block-depth spans | 46 over 250 lines — **misleading, see below** |
| function length (leaf functions only) | same, excluding any function containing another | 22 over 150 lines, 58 over 100 |

**The raw count is a trap.** The longest "functions" are 700–800 lines and span nearly a whole file —
because this repo uses the dependency-injection installer shape, `function S.install(M, restart_policy)`
wrapping a module body with dozens of nested locals (`pr_review_replayer.lua:25-816` is 792 lines and
entirely correct). Reporting those as extract-method candidates would propose refactoring 46 DI
wrappers. Only **leaf** functions — those containing no nested function — are candidates.

**And the leaf candidates were refused, on two distinct grounds:**

- The largest cluster is `core/restart/transitions/*.lua` (242, 241, 222, 211 lines). These are
  **declarative transition rows**: `return function(M, h)` destructuring a handler bundle, then a
  table. Splitting one fragments a table definition and makes it less readable, not more.
- The one genuinely imperative candidate,
  `packages/github-devloop-pr/departments/review_result/main.lua:116-377` (a 262-line `with_lock`
  closure), sits on the core PR-merge CAS path.

The decisive point is not risk, it is **standard**: this repo sets a *file* limit (1000 hard, 900
soft) and **no function-length rule whatsoever**. With 22 leaf functions over 150 lines, the revealed
standard tolerates them. Refactoring core merge logic to satisfy a limit the repo has not adopted is
speculative work against an imported aesthetic — the WORTH GATE names that as a defect in itself.

**What would make this actionable:** adopting a function-length standard. That is a policy decision
for the repo, not something a refactoring pass may assume and then enforce by hand.

## Repeated string literals — measured, and the repetition is REQUIRED

352 distinct literals appear in 6 or more production files (tests excluded, 591 files scanned). The
obvious reading is "extract shared constants". Do not.

| what dominates the count | why it is not extractable |
|---|---|
| `require` paths (`devloop.base` ×153, `contract.strings` ×127) | module names, not magic strings |
| Lua type names (`"string"`, `"function"`, `"number"`) | idiomatic `type(x) ==` checks |
| queue names (`github-proxy.github_issue_label_request` ×60) | **must stay literal — see below** |
| lifecycle state names (`"blocked"` ×86, `"reviewing"` ×48) | the restart table is data; literals are how it is expressed |

**The queue-name case is the trap.** A queue name hard-coded in 60 departments looks exactly like a
missing constant. It is not: `G-SAGA-HEAD` requires each department to declare
`local spec = { consumes, produces, ... }` at file head **"so the engine static graph contract stays
greppable at the top of each department"**. Replacing those literals with shared constants defeats a
CI-enforced requirement — the repetition *is* the contract. A reasonable refactor here breaks the
build for a non-obvious reason.

Method note: a scan for string literals must mask long-bracket literals first
(`check_repo_lua.code_mask`), or fragments of template-generated code (`"):gsub("`) surface as if
they were literals in their own right.

## Running it again: `python3 scripts/refactor_survey.py`

This ledger recorded the *method* in prose while the instruments lived in a scratch directory that
does not survive the session — so the next pass would have rebuilt them and re-walked every trap
above. `scripts/refactor_survey.py` is those measurements, with each trap written beside the unit it
broke:

- unused exports — matches the bare word across **all tracked file types**, because a name can be
  referenced from a manifest or a doc, not only from Lua (the narrow `.name(` form called 62 live
  functions dead)
- unused `lib_deps` — parses the array inside the section, not the section key
- leaf functions — excludes DI installer wrappers, which are correct at 700–800 lines
- never-required modules — reported with an explicit false-positive warning; results under a
  directory family are a registry, not a corpse

It is **advisory and never fails a build**: reversible, low-harm drift gets detection and correction
rather than an up-front gate. The one unit here that is genuinely gated has its own checker,
`check_repo_dead_locals.py`, because that category regrew four times in nine days.

## The ownership axis: what a six-seat consensus found that the survey cannot (2026-08-15)

Every unit in the table above is subtractive — it asks *what can be deleted*. Running the repo's
own `sshx` six-seat panel against the same tree surfaced a different class entirely, and none of it
is visible to `scripts/refactor_survey.py`, because the code involved is **live, used and tested**:

| class | example found | why the survey is blind |
|---|---|---|
| a declared migration stopped half-way | `install(M)` scaffold whose own deletion trigger has fired (`logging.lua:235-237`; the G-DEVLOOP-INSTALLER ratchet reads zero production readers) | symbols are exported *and* referenced from tests, so they never read as unused |
| a non-owner re-declaring a format | the `state:v1` marker grammar declared 17 times in production | each declaration is used |
| a decision placed at the least-informed layer | cache consistency selected by caller booleans `opts.force_fresh` / `opts.allow_cached_validator` | no unused symbol, no size violation |

Six increments were landed from that backlog (#3786, #3788, #3789, #3791, #3793, #3798).

### The N2 precondition, measured

The largest remaining item is consolidating GitHub PR field-alias normalization — 60 alias-resolution
sites over 13 production files, with `libraries/forge/github_view.lua` as the natural owner (its
sibling `forge/github/issue.lua:307` already does exactly this for issues).

**Do not start with the migration.** Each call site accepts a *different* set of shapes; that is why
the duplication exists. Consolidating without first pinning the accepted set changes it silently and
the suite stays green. Test-feed counts show the risk is asymmetric:

| field | camelCase test files | snake_case test files |
|---|---|---|
| head ref oid | `headRefOid` **34** | `head_ref_oid` **1** |
| head ref name | `headRefName` 47 | `head_ref_name` 26 |
| draft | `isDraft` 14 | `is_draft` 6 |
| merged at | `mergedAt` 13 | `merged_at` 21 |

So the first increment of N2 is **table-driven characterization fixtures over the thinly covered
snake_case aliases**, not the extraction. `head_ref_oid` is the specific one to pin first.

### Two refusals worth not re-litigating

- **Writer vs matcher.** `state.lua` renders the marker with an unescaped literal while the matcher
  is a Lua pattern with `%-` escapes. They are two representations of one grammar and cannot share a
  string without an escaping helper — more machinery than the duplication costs.
- **`github-external-pr-intake/core.lua:464`** keeps its own copy of the grammar permanently. That
  package is absent from `libraries/devloop` `[visibility] allow`; it is not permitted to see the
  library. Widening a visibility list to remove one literal is a boundary-owner decision, not a
  refactoring one. That duplication is the correct outcome of an intentional boundary.

## N2 is unblocked: three of the four consumers were already guarded (2026-08-15)

The earlier entry said the alias-consolidation precondition was characterization fixtures for
every consumer, and implied all four needed them. Measured by mutation — removing each file's
snake_case fallbacks and running its package — that was wrong:

| consumer | fallbacks removed | tests reddened | verdict |
|---|---|---|---|
| `libraries/devloop/parsers/pr.lua` | 14 | **0** | the only gap |
| `packages/github-proxy/core.lua` | 11 | 29 | already guarded |
| `libraries/forge/github_view.lua` | 13 | 182 | already guarded |
| `packages/github-external-pr-intake/core.lua` | 10 | 5 | already guarded |

Four characterization tests were added for the devloop parser (#3802, #3803, #3805, #3807);
the same aggregate mutation there now reddens three tests instead of zero. **The precondition is
complete and the extraction may begin.** Writing fixtures for the other three would have been
three increments of pure waste, each of which would have gone green and looked necessary.

The lesson generalises past this task: `devloop/parsers/pr.lua` was an outlier, not the norm, and
one sample was mistaken for the shape of the whole area. An unstated assumption is the hardest to
catch, because it never appears in a sentence that would require evidence — it only shows up in
the order of the work.

### Mutation-harness notes, so this is repeatable

Removing ` or x.y` tokens by text needs four boundary conditions, each of which produced a
syntax error rather than a result when missing: a word boundary (else camelCase identifiers are
cut mid-word), exclusion of a following `.` (else `pr.head.ref` truncates), a substitution that
respects the same boundary used to *find* the tokens (`str.replace` does not, so a shorter token
matches inside a longer one), and exclusion of a following `(` (else a method call leaves orphan
parentheses). Bespoke structural guards caught two of the four. **`luac -p` catches all of them**,
turns a wasted three-minute test run into a one-second abort, and is what the harness uses.

Also: restore must run on a trap, not as a line after the command. A timed-out mutation left a
worktree in the mutated state once; committing from there would have shipped a mutation as a
refactor.

⟦AI:FKST⟧

## Correction: "the precondition is complete" was wrong, and the way it was wrong is the finding

The sentence above — **"The precondition is complete and the extraction may begin"** — does not
hold. It is corrected here rather than edited in place, because the shape of the error is worth
more than the conclusion was.

Two axes had been measured before that sentence was written. Both survived re-measurement:

| axis | witness |
|---|---|
| input alias acceptance (`headRefOid` / `head_ref_oid`) | was zero, now four characterization tests |
| output projection shape | already strong: deleting six `base_ref_name = ...` output lines reddens 42 tests |

The second of those was measured *after* the claim, as a check on it, and it confirmed the claim.
That is the trap: a claim that survives one additional check feels like a claim that has been
verified, when all that happened is that the checker and the claimant enumerated the same list.

A third axis exists, and it was found only by looking at a different function for an unrelated
reason. `libraries/devloop/parsers/pr.lua` and `libraries/forge/github_view.lua` both normalize a
repository name, and they disagree about **precedence**:

- `forge.repo_name_with_owner` tries `full_name`, then `nameWithOwner`, then `owner.login/name`.
- devloop's `repository_name_with_owner` tries `nameWithOwner`, then `name_with_owner`, then
  `full_name`, and additionally accepts a bare string and a separate owner argument.

Unifying them therefore requires choosing one order. Reordering devloop's to match forge's —
exactly the edit a unification would make — leaves **2157 tests passing and none red**. Precedence
has no witness at all. A unification would go green, look correct, and silently change which field
wins whenever a payload carries more than one of them.

So the extraction is not blocked by a missing test on the two axes that were measured; it is
blocked by an axis that was never enumerated. The corrected statement is narrower and does not
claim completeness:

> Two axes are measured and guarded. A third, alias precedence, is measured and **unguarded**.
> The size of the axis set is unknown.

**The general lesson is about the form of the claim, not about parsers.** Declaring a precondition
complete over a list of axes one enumerated oneself is not a measurement — it is a statement about
one's own imagination, wearing the grammar of a result. The honest form names the axes checked and
declines to bound the set. Every axis here was found by accident: the first by mutation, the second
by doubting the first, the third by reading an unrelated function. Nothing about that sequence
suggests it terminated.

⟦AI:FKST⟧

## When an `install(M)` call is removable, and when the same reasoning is destructive

`install_m_calls` fell 23 -> 17 by removing six `require("devloop.logging").install(M)` calls whose
packages read none of the four symbols it binds (#3834). The identical reasoning applied to
`require("devloop.commands").install(M)` is **unsafe**, and the difference is worth stating because
the naive analysis cannot see it.

**The discriminator is not "does this package read the symbols". It is "does any library read them
through the injected `M`".** A library function receives whichever package's table flows into it, so
one unguarded read there makes the install mandatory for *every* composing package, no matter what
that package's own files reference.

| module | libraries reading its symbols via injected `M` | verdict |
|---|---|---|
| `devloop.logging` | **0** | six installs removed |
| `devloop.commands` | **5 files**, two of them inside `libraries/devloop` itself | **not removable** |

For `commands` the readers are `libraries/devloop/liveness_scan.lua:245,253`
(`M.gh_issue_list_observe_opts`, `M.gh_pr_list_observe_opts`),
`libraries/devloop/hidden_state_conformance/poll_fakes.lua`, plus `libraries/forge/git.lua`,
`libraries/consensus/init.lua` and `libraries/testkit_internal/legacy_command_renderers.lua`. None is
nil-guarded — the value is passed straight on as an argument — so a package that drops the install
propagates `nil` down any path that reaches those functions. Proving a given package never reaches
them is a call-graph question, not a grep question, so four apparently-dead installs
(`github-devloop-decompose`, `github-devloop-intake`, `github-devloop-intake-default`,
`fkst-substrate-ref-maintainer`) stay.

**Two analyser blindnesses on the way here, both of which produced the destructive answer:**

- **Delegation is invisible to an export scan.** `devloop.commands` binds nothing directly; its
  `install` loops over six sub-installers (`support`, `validators`, `issue_reads`, `observe_lists`,
  `prs`, `git_ops`). A scan for `M.x =` reported "module exports nothing" for all eight of its call
  sites. Resolve the delegation list **from the source**, not from the sub-modules you happen to
  remember — two of the six were ones I had never looked at.
- **Same-name collisions dominate this repo.** `libraries/consensus/core.lua` defines its own
  `error_class_from_message` and `log_error_fact`; `autochrono`, `consensus` and
  `github-devloop-workflow` never compose devloop at all. Every name-matched reader analysis here
  must first ask whether the file's table can even contain the symbol.

So `install_m_calls` is not further reducible by this method. Lowering it requires giving those
library functions the capability directly rather than reading it off the ambient table — a design
change, not a sweep.

⟦AI:FKST⟧

## Where each remaining migration ledger actually stands, and what it needs

Measured on `dev` at `2d7735993`. The god-pattern reduction this campaign drove is locked in
(#3838); what follows is why the rest did not move, so the next pass does not re-derive it.

**Four ledgers were probed to exhaustion this round and none is reducible by substitution or
sweeping.** In each case the naive mechanical answer existed and was wrong:

| ledger | count | what blocks it |
|---|---:|---|
| `version-suffix.allowlist` | 3 | **floor.** All three are `libraries/contract/source_ref.lua:41-43`, below `transition_version` and unable to require it without a cycle. |
| `gh-egress.inventory` | 1 | **floor by design.** `check_repo_gh_egress.py:190` *requires* the `SANCTIONED_EGRESS` entry to be present. Terminal state is 1, not 0. |
| `library-error-class.allowlist` | 1 | **floor.** Its one site raises with a runtime `reason_code` in the class position; the message is already semantically correct and only statically unprovable. Inserting a literal class displaces the real one -- two tests catch it. |
| `lock-scope.allowlist` | 5 | 2 marked `justified:` (permanent), 3 marked `needs-redesign(#3520-class)`. |
| `dept-failure-surface.allowlist` | 3 -> 1 (#3839) | the remaining one is `integration-coverage-producer`, which has no `devloop` lib_dep; clearing it means widening the dependency graph or copying a local helper. |
| `producer-liveness.allowlist` | 2 -> 1 (#3841) | the remaining raiser's driver shells out to a Python tool and a chain of further commands; a fire_raiser test there pins a long exact argv per hop. |
| `devloop-forge-imports.inventory` | 7 | **not substitutable.** Three entries import forge for a single symbol, and the obvious redirect (`json_string` -> `contract.strings`) is a *different function*: forge escapes control characters with uppercase hex, contract with lowercase. Pinned in #3842 after measuring that changing forge's case reddened nothing. |
| `gh-handle-construction.inventory` | 19 | every entry is a DI rewiring whose blast radius is its package's call graph; no stale entries (the checker already rejects those). |
| `ambient-surface` / `devloop-godlib` | locked | reduced 168 -> 20 and 24 -> 17 this campaign; the remaining 20 exports all have real readers. |
| `service-locator`, `core-param`, `bot-login-mediation`, `monotone-gate`, `github-devloop-saga-split` | 52/489, 148/127, 86, 94, 264 | untouched; these are the large architectural programs, not sweeps. |

### The pattern worth carrying forward

Every one of the four exhausted ledgers offered a mechanical answer that measurement refuted:

- a **small count** read as "nearly done" three times, and was a required floor twice
- a **same-named function** read as a duplicate twice (`json_string` casing, `repo_name_with_owner`
  precedence), each differing in exactly one detail that nothing tested
- an **install call** read as dead because its module "exports nothing", when the module delegates

So the reusable step is not any of the fixes. It is: **before touching a ledger, read its checker for
a required floor, and measure whether the substitution you intend is actually the same behaviour.**
Both checks are minutes; both refused work that would have been green and wrong.

⟦AI:FKST⟧

## Service-locator: which department reads can be redirected, and which cannot

`G-DEVLOOP-SERVICE-LOCATOR` counts `require("core")` and `core.<member>` across every
`packages/*/departments/**` file, and its migration target is `make_department(caps)` with narrow
injected capabilities. Two smaller moves look available on the way there; only one of them works.

**Dead requires are removable.** `comment_handoff` held `local core = require("core")` and never
referenced it (#3845). Note that a member-read scan is not sufficient to find these:
`consensus_result/main.lua:382` reads no member but passes the whole table onward with
`core = core`, which only a search for the bare identifier catches.

**Redirecting a read to the owning `core/*` submodule works only if that submodule is a plain
module, not an installer.** Attempted for `github-devloop-ops/departments/doctor`, whose single read
is `core.saga_doctor_run`. That symbol is defined in `core/doctor.lua`, so
`require("core.doctor").saga_doctor_run` looks equivalent. It is not: that file defines onto the
**passed-in** `M` and ends with `return S`, and `core.lua:110` wires it as
`require("core.doctor").install(M)`. The require returns the installer, not the function, and the
department fails at runtime with `attempt to call a nil value (field 'saga_doctor_run')`.

In `github-devloop-ops`, **8 of 12** `core/*.lua` files are installers and 4 are plain modules, so
this check decides the outcome before any edit:

```sh
grep -q 'function S.install(M)' packages/<pkg>/core/<mod>.lua   # installer -> not redirectable
```

**A measurement note about the ratchet itself.** `_CORE_MEMBER` matches raw text without stripping
strings, so `require("core.doctor")` counts as a member read. Migrating a department from
`core.X` to `require("core.mod")` therefore lowers `department_core_requires` by one and leaves
`department_core_member_reads` unchanged -- the metric charges the migration path it is driving.
Progress on that axis shows only under the full `caps` migration, not the intermediate step.

⟦AI:FKST⟧
