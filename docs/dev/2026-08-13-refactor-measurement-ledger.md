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

⟦AI:FKST⟧
