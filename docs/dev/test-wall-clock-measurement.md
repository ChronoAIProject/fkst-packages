# Where the test suite's wall-clock actually goes, 2026-08-11

This records the first per-unit measurement of `scripts/run.sh test`, what it refutes, and the one
engine capability that four independent lines of attack all terminate at.

It leads with the refutations because nine hypotheses were tested here and **nine were wrong**. Each
looked obvious. Several would have silently weakened the repository's gate if implemented.

## What was measured, and how

Per-unit timing came from `fkst.test.unit_timing.v1` records, added by PR #3565, which every run now
writes to `$report_dir/timing/` and CI uploads as the `test-reports` artifact. The clean numbers
below are from CI run 31442678543 — a dedicated runner. Numbers taken on the dogfood host are
labelled contended and are not used for any conclusion that a clean number can carry.

Check-phase numbers came from timing each `cmd_check` unit as a separate process; per-class and
per-method numbers from `unittest` invocations with the whole-file baseline asserted green first.

## The package phase is bounded by one unit, and the pool is already optimal

CI, 22 units:

| | |
|---|---:|
| pool wall-span | **640.7 s** |
| serial sum of all units | 1166.9 s |
| mean concurrency | 1.82 |
| max observed concurrency | 4 |
| **`github-devloop`** | **582.3 s = 90.9% of the span** |
| all other 21 units combined | 584.5 s |
| time with exactly ONE unit running | **297.8 s = 46% of the span** |

The last 297.8 s of the phase is `github-devloop` running alone while at least three cores idle.
Second-to-last (`github-devloop-pr`) ends at 342.9 s.

On the contended host the same shape held: 511.2 s span, `github-devloop` 98.1%. **The dominance is
environment-independent; the exact percentage is not.**

Consequence: package-level test *selection*, pool tuning, and optimising the other 21 units cannot
reduce this phase's wall-clock. It is one unit.

## Every cost distribution here is power-law

Four granularities, four independent measurements:

| granularity | distribution |
|---|---|
| 22 package units | one = **90.9%** of the span |
| 62 `cmd_check` units | top 5 = **66%**; the tail 42 = **4%** |
| 15 classes in `check_repo_test.py` | one class = **95%** |
| 205 test files in `github-devloop` | an equal-**count** split gave **157.3 s vs 523.1 s** |

**So partitioning by count does not work.** Sharding `github-devloop`'s normal run into two
deterministic round-robin shards was implemented and measured: span 640.7 s → 573.1 s, only −10.5%
against a −54% projection, and the two shards summed to 680.4 s against 582.3 s unsharded — the
split added ~98 s of total work and distributed it 3.3:1. Four of five pre-stated discard criteria
passed; the overhead-vs-gain criterion failed and the change was discarded, tree restored.

Cost-weighted partitioning is the only shape that could work, and it needs per-test-file duration.

## Nine refuted hypotheses — do not re-adopt them

1. **"Unused `lib_deps` inflate the selection closure."** The engine's own `unused-lib-dep` warning
   reports exactly **2** occurrences repository-wide. Effectively zero value.
2. **"Sub-package execution granularity needs an engine change."** False —
   `scripts/composed_test_graph_roots.sh` `copy_package()` already builds filtered package roots by
   tar-copying a subset of tests. The mechanism exists; what is missing is the cost data to use it.
3. **"Two packages hold 65% of test lines, so they are the problem."** The line count is true and
   the inference is wrong. `github-devloop-pr` finishes before half the span; optimising it to zero
   would buy nothing. **One** package is the critical path.
4. **"Timing records can be published without touching `scripts/run.sh`."** False —
   `check_test_file_coverage` globs `$report_dir/*.json` and hard-fails on a foreign schema. Fixed
   by putting records in a `timing/` subdirectory, which the non-recursive glob cannot see.
5. **"Checker tests are fixture-only, so a Lua-only change can skip them."** False for the largest:
   `check_repo_test.py:144-151` walks the real tree with `root.rglob("*.lua")`, and `:478` asserts
   the real `packages/github-devloop-ops/departments/observability` module set.
6. **"Split `check_repo_test.py` by responsibility to lower the check pool's floor."** Pointless —
   the cost is not spread across responsibilities. One method is 95% of the file.
7. **"The non-package phase is 190.2 s."** Retracted. That was `701.4 − 511.2` across two runs at
   different load; the check phase alone measures 204.6 s, impossible within one run. **Never
   subtract across runs.**
8. **"Point the 52 s repository-check test at a minimal fixture; the assertions are
   repository-independent."** Refuted 3-0 with source evidence. `check_repo.py:797-814` gives
   ordinary violations precedence over configuration failures, so `result == CONFIGURATION_EXIT`
   silently also asserts *the real repository produced no ordinary violation on that run*. And a
   fixture via `--project-root` makes `is_own_repo` false, skipping the entire library-B checker
   route including restart preflight (`check_repo_runner.py:273-286,320-330`). See below.
9. **"Shard the critical-path package by test-file count."** Measured, −10.5% against −54%
   projected, net-negative total work. Discarded.

## The 52-second floor of the check phase, and why it stays

`cmd_check` runs 62 units in a pool. Serial sum 255.7 s; isolated wall-clock 204.6 s at load ~13
(mean concurrency 1.40 — **whether that is contention or a packing defect is UNKNOWN**, and no quiet
machine was available to distinguish them).

Its longest unit is `check_repo_test.py` at 48.9 s, of which one method is essentially all:

`ViolationExitCodeTest::test_real_runner_classifies_every_unresolved_baseline_as_configuration`
= **51.8 s** in isolation; the other three methods of its class total 0.45 s; the other fourteen
classes total 1.9 s.

It patches only base-ref resolution and then calls the real `check_repo.main([])`, executing every
checker over the whole repository — so **the repository check runs twice per `scripts/run.sh test`**.
That is the source of the duplicated `OK: repository checks passed` line in a full run's output.

It is also the floor of the check pool, so no amount of skipping other units lowers that phase
below it. An adversarial panel nevertheless rejected changing it 3-0 (hypothesis 8 above). The only
legitimate removal path it identified: first add focused unresolved-branch tests beside **every**
baseline-producing checker, each asserting a typed `ConfigurationFailure` and a non-crashing
`None`-baseline path, with a mutation witness — and only then delete the broad test.

## What everything converges on

Four independent lines of attack terminate at the same missing capability:

1. lower the 90.9% critical-path unit → shard it → needs a cost-weighted partition → **per-test duration**
2. "run only the tests a change affects" at test-file granularity → **stable per-test IDs and a filter**
3. know where time goes *inside* a unit → **per-test duration**
4. the check-phase 52 s floor → refuted on other grounds; see above

`fkst-substrate`'s test report (`crates/fkst-framework/src/test_runner.rs:176-237`) carries test
identity and status and **no duration**, and its `test` subcommand accepts only
`--project-root`, `--package-root` and `--report-json` — no filter.

Per this repository's own doctrine, that capability belongs in `fkst-substrate` and must not be
emulated package-side. Until it exists, package granularity is the floor for both selection and
execution, and this repository has no remaining lever on test wall-clock that is worth its cost.

## What is not claimed

- No wall-clock improvement was delivered. PR #3565 adds instrumentation and makes the suite
  marginally slower (two clock reads per unit, ~20 ms each).
- The check phase's poor concurrency (1.40x) is **unexplained**. Contention and packing were not
  distinguished.
- The sharding numbers were produced by an implementation worker and were not independently
  reproduced.
- CI job duration was deliberately **not** subtracted from the pool span to derive a non-package
  figure; the job includes checkout and a Rust build and is not the same quantity.

⟦AI:FKST⟧

## Addendum: per-test cost varies 32x, and that is not explained

The analysis above asks *which unit is the critical path*. It never asked *why that unit is
expensive per unit of work*. Dividing the CI timings by each package's test count:

| ms/test | package | unit s | tests |
|---:|---|---:|---:|
| 729 | github-devloop-intake-default | 34.3 | 47 |
| 707 | github-devloop-intake | 51.6 | 73 |
| 435 | github-devloop-pr | 312.1 | 717 |
| **409** | **github-devloop** | **582.3** | **1423** |
| 366 | github-devloop-integration | 56.3 | 154 |
| 173 | github-devloop-workflow | 55.1 | 319 |
| 69 | github-proxy | 23.3 | 337 |
| 32 | consensus | 6.0 | 188 |
| 23 | github-external-pr-intake | 1.5 | 66 |

Repository mean: 307 ms/test (1167 s / 3800 tests). **Spread: 32x.** The expensive end is entirely
the devloop family; everything outside it is 23–99 ms/test.

If `github-devloop` ran at `github-proxy`'s 69 ms/test it would take 98 s instead of 582 s. **The
critical path is not expensive because it has many tests; it is expensive because each of its tests
costs 6–18x more than a test elsewhere in the same repository.** That is a test-design question,
entirely inside `packages/`, and it needs no engine capability.

**This is stated as a measured fact with no verified explanation.** Candidate causes were examined
and none was confirmed:

- Package `core.lua` size does not correlate — `github-proxy` has the largest (722 lines) and is
  among the cheapest.
- `packages/github-devloop/tests/devloop_helpers.lua` is 7 lines; it delegates to
  `libraries/testkit_internal/devloop_helpers_fixtures.lua` (461 lines). Module loading is cached
  per process, so it is not a per-test cost.
- `materialize_context_bundle` in that fixture does per-call `mkdir` plus one or two JSON file
  writes — real filesystem work per test, but not obviously hundreds of milliseconds.
- Primitive usage across the 205 test files is assertion-heavy: `t.eq` 5680, `t.is_true` 1498,
  `t.mock_command` 562, `t.run_department` 16, `fkst.codex_runs` 32. Nothing there is obviously
  hundreds of milliseconds per test.

Splitting the unit into its conformance / normal / graph phases would narrow this, and **five
attempts to obtain that split all failed**, each for a different reason. They are recorded so the
next attempt does not repeat them:

1. Timestamping the run's log — defeated by the engine block-buffering stdout when piped: the whole
   package phase flushes at process exit, so the timestamps measure when the reader saw the lines,
   not when the engine produced them. Yields an implausible 0.0 s per phase.
2. `python3 -m unittest scripts.check_repo_test.<Class>` — `scripts` is not a package; every run
   failed to import in ~0.09 s and the crash exit codes read as results.
3. Sourcing `run.sh` and invoking the phases directly — variable names were guessed rather than
   read; `load_composed_test_roots` emits `test_project_root` / `test_pkg_args`.
4. and 5. With the correct names, root construction times cleanly (0.6 s) but the subsequent engine
   invocation terminates the harness before it can report.

A sixth attempt was made along a different axis — per-FILE rather than per-phase, by hand-building
filtered roots each holding ~10 test files — and failed too: the engine refused to start with
`manifest catalog is required: missing fkst.workspace.toml`, because a hand-rolled root lacks the
workspace manifest, the libraries and the composed dependencies that `load_composed_test_roots`
supplies. It reported `0.0 s` and `tests=0`, i.e. **a startup crash read as a measurement** — the
same shape as attempt 2. In both cases the tell was an implausibly clean zero.

**Six structurally different attempts to decompose this cost from OUTSIDE the engine all failed, each
at a different boundary.** That is itself evidence for the conclusion above: per-test cost
attribution is not something a caller can assemble externally in this repository; the engine has to
emit it.

The contrast is sharp and worth stating as a rule. The one measurement in this whole exercise that
worked cleanly was the timing witness itself, which sits INSIDE `run_one_package` and records what
that function already knows. **Instrument from inside the machinery; do not try to decompose it from
outside.** Every external decomposition here hit a boundary the machinery exists to manage —
buffering, workspace manifests, composed dependency roots, library resolution.

Re-adding per-phase instrumentation was deliberately not attempted, because the information is
wanted once rather than routinely, and it would reverse a decision that was correct on the
evidence available when it was made (per-phase intervals were polluted by ~20 ms of interpreter
startup, which is fatal for a 42 ms phase and noise for a 30 s one; nothing in the design
distinguished the two).

**Open question for whoever picks this up:** why does a `github-devloop` test cost 409 ms when a
`github-proxy` test costs 69 ms? Answering it is worth more than any scheduling change measured
above, and unlike those it requires nothing from the engine.

## Correction: "ms/test" was the wrong unit, and cost tracks heavy primitives (r = 0.90)

The addendum above frames the finding as "per-test cost varies 32x". That arithmetic is right and
**the framing is wrong**, for the same reason hypothesis 3 was wrong: it assumes a test is a
comparable unit of work. It is not. `github-devloop` contains 5680 `t.eq` and 1498 `t.is_true`
calls — trivial — alongside 16 `t.run_department` invocations, which drive whole departments.

Three candidate predictors of a unit's cost were tested against the CI timings (n = 22):

| predictor | result |
|---|---|
| composed vs flat | composed median 249 ms/test vs flat 36 ms/test — but `frontend-devloop` has the **most** deps (9 packages) and is nearly the **cheapest** (0.2 s), so this is not the mechanism |
| composed closure size in KB | **r = 0.21** — no useful signal. Largest closure (7232 KB) is nearly the cheapest unit; `github-devloop-intake` is 669 KB and among the most expensive per test |
| **count of heavy test primitives** (`run_department`, `run_graph`, `fire_raiser`, `codex_runs`, `setup_worktree`, `mock_observe`) | **r = 0.90** (n = 20; two packages use none and are excluded) |

`github-devloop` makes 193 heavy calls and costs 582.3 s. `github-proxy` makes 101 and costs 23.3 s.

**So the lever for test cost is the number and price of heavy integration primitives, not the number
of tests, not file organisation, and not composition.** That is actionable inside `packages/` and
needs nothing from the engine — unlike every scheduling conclusion above.

Limits, stated: the heavy-primitive count is a **lexical** count of call sites in test sources, not a
runtime count of invocations; a loop or a helper would break it. Cost per heavy call still varies
across packages (0.07 s to 4.59 s), so the count is a strong predictor and not a complete
explanation. `r = 0.90` on n = 20 with a hand-picked primitive list is a **found** relationship, not
a validated model — it should be checked against a runtime count before anything is built on it.

**The methodological point is the durable one.** The single bias behind most of the refuted
hypotheses in this document is assuming uniformity in a system that is concentrated everywhere. That
bias reappeared here at the level of the **metric**: dividing by test count silently asserts tests
are interchangeable. A per-unit number is only as good as the unit.

## Retraction: the r = 0.90 result above is withdrawn — it loses to the null

The section above claims the count of heavy test primitives predicts unit cost at `r = 0.90` and
calls it "the first thing that actually correlates". **That claim is retracted.** The control was
never run. Running it:

| predictor | Pearson | Spearman (rank) | Pearson, dominant unit dropped |
|---|---:|---:|---:|
| plain test count | **0.97** | 0.81 | **0.87** |
| heavy primitives | 0.90 | 0.83 | **0.77** |
| test source lines | 0.99 | — | — |

`r(test count, heavy primitives) = 0.94` — they are close to the same variable. Heavy-primitive
count adds nothing over "the suite is big", and once the dominant unit is removed it is **worse**
than the trivial null.

**All of these correlations are artifacts of the power-law distribution this document itself
documents.** One unit (`github-devloop`, 1424 tests, 582 s) is an extreme point on every axis, and
Pearson's r on heavily skewed data is dominated by it. Reaching for a correlation coefficient that
assumes roughly-even spread, on data already measured as concentrated at every granularity, was the
error.

**What survives:** unit cost tracks suite size, which is trivially true and explains nothing. The
32x spread in cost-per-test (23 ms to 729 ms) is arithmetically real and **remains unexplained**.
Nothing tested — composition, closure size, heavy-primitive count, test count — accounts for it.

**The methodological point, now demonstrated three times in this document at three different
levels.** The single bias behind most of the refuted hypotheses is assuming uniformity in a
concentrated system. It appeared:

1. in a **hypothesis** — "two packages hold 65% of test lines, so they are the problem" (refuted: one
   package is the critical path);
2. in a **metric** — dividing by test count silently asserts tests are interchangeable units;
3. in a **statistical method** — Pearson's r on power-law data, where one point sets the answer.

Naming the bias did not prevent recurrence; it recurred twice after being named. What caught it each
time was **running a control that could falsify the current answer** — the null predictor, the rank
statistic, the leave-one-out. A mechanical falsification step beats vigilance, because vigilance is
what generated the number in the first place.
