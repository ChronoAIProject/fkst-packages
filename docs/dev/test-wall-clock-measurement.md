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

## Partial explanation: a fixed graph-run cost, which accounts for the SMALL packages only

One structural fact was missed above. `run_one_package` invokes the engine a **second** time, over a
freshly rebuilt filtered root, for any package that has `tests/run_graph*_test.lua`. Packages
without such tests skip it entirely — including two composed ones.

That splits the 22 units far more cleanly than composed-vs-flat:

| | median ms/test |
|---|---:|
| pays the graph run (12) | ~307 |
| does not (10, incl. 2 composed) | ~34 |

The two cheap composed packages are exactly the two that skip it: `frontend-devloop` (0.2 s total,
9-package closure) and `github-devloop-ops` (92 ms/test). **So composed root construction is not
inherently expensive — paying for a second engine invocation is.**

**The control, run before claiming anything this time.** If a fixed graph cost `F` is amortised over
a package's tests, then small graph-paying packages should total roughly `F`, and subtracting `F`
should leave a residual comparable to non-graph packages. Small graph-paying packages cluster at
1.1–3.4 s, giving `F ≳ 1.1 s`. Subtracting it:

| package | raw ms/test | residual | tests |
|---|---:|---:|---:|
| marketing-radar | 155 | **0** | 7 |
| integration-coverage-producer | 183 | 28 | 7 |
| git-branch-detector | 99 | 21 | 14 |
| archaudit | 33 | 23 | 109 |
| **github-devloop** | **409** | **408** | 1424 |
| **github-devloop-pr** | **435** | **434** | 717 |
| **github-devloop-intake** | **707** | **693** | 73 |

**Confirmed for small packages; refuted as a general explanation.** The fixed graph cost accounts for
essentially all of the apparent "expensive per test" in packages with few tests. It accounts for
almost none of it in the large devloop packages, which still cost **170–700 ms/test** after
subtraction while non-devloop packages cost **23–92 ms/test**.

Two limits, stated rather than smoothed over: `F` is treated as a constant and is not — subtracting
1.1 s from `github-devloop-worktree-gc` yields a **negative** residual, so `F` must scale with what
the root rebuild has to copy. And `github-devloop-ops` is devloop-family, skips the graph run, and is
cheap (92 ms/test), so "devloop family" is not itself the explanation either.

**The open question is narrower, not answered.** It is no longer "why does cost per test vary 32x" —
much of that was one fixed cost divided by small denominators. It is: **after removing the graph-run
cost, why does a test in the large devloop packages still cost 3–10x more than a test elsewhere?**
Answering it needs per-test duration from the engine, which is the prerequisite this document keeps
arriving at.

## The single most expensive test in the repository, and a failed attempt to fix it

Cost was traced from 22 packages down to one test function, each step measured with the real root
machinery (`load_composed_test_roots` builds the root; test files are then pruned from it — a
hand-rolled root fails at `manifest catalog is required`).

| level | result |
|---|---|
| 22 package units | `github-devloop` = 90.9% of the CI pool span |
| its 196 normal test files, in groups of 20 | two groups = 66% of the grouped total; one group of 206 tests takes 6.2 s while another of 216 takes 76.6 s |
| that group's 20 files | `context_bundle_test.lua` = 32.6 s; the other 19 are 0.1–1.7 s |
| its 26 test functions | one quarter (7 tests) = 20.8 s of 23.3 s |
| those 7 | **`test_context_bundle_file_cap_truncates_on_utf8_boundary` = 20.8 s**; the other six total 2.4 s |

**One test function is roughly 5% of `github-devloop`'s entire normal run.** It builds a fixture at
the 10 MiB `max_bundle_file_len` cap and drives the real bundle build through a probe department.

**Three plausible causes were measured and refuted before the fourth was tried:**

- the `slice4` byte-freeze characterization test, which hashes bundle bytes with a pure-Lua SHA-256 —
  it runs alone in **0.7 s**;
- pure-Lua SHA-256 in the production path — `libraries/devloop/context_bundle.lua` contains no
  `sha256` call at all;
- `contract.strings.json_string` making eight sequential `gsub` passes over the 10 MiB fixture —
  measured at **0.44 s**. (The probe also confirmed `json_string(body) == '"' .. body .. '"'` for
  this input, and that `utf8.len` on 10 MiB costs 0.01 s because it is a C function.)

**The fourth attempt failed too, and the way it failed is the point.** The probe returns the whole
10 MiB file content as a department result, and the caller uses it only for a UTF-8 validity check.
Moving that check inside the probe — same bytes, same property, same moment, no 10 MiB crossing the
process boundary — looked obviously right, and a single A/B run measured **30.8 s → 20.7 s**.

An interleaved A,B,A,B re-measurement showed the truth:

| run | before | after |
|---|---:|---:|
| 1 | 38.4 s | 22.7 s |
| 2 | 22.6 s | 23.3 s |

The first `before` was a cold-start outlier. Discarding it: **22.6 s versus 22.7 s and 23.3 s — no
improvement.** The 33% "win" from the single A/B was load noise. The change was discarded and the
tree restored.

Had it been shipped, the PR would have claimed a 33% saving, CI would have been green because
nothing was broken, and **no mechanism in this repository would have caught that the number was
fiction** — the same shape as the three crash-as-measurement incidents recorded above, where an
implausibly clean zero was the only tell.

**Standing rule this produces:** on this host a single before/after run is not evidence. Interleave
A,B,A,B, discard the first run as cold, and report the median — or do not claim a number.

**Still open:** what the 20.8 s actually is. It is not the fixture, not hashing, and not the result
marshalling. It is inside the real bundle build at 10 MiB, and isolating it further needs per-test
duration from the engine.

## A located candidate for the remaining 20.8 s — read, not measured

Everything cheap has been eliminated by measurement: the fixture (0.5 s), pure-Lua SHA-256 (absent
from the production path), `json_string` over 10 MiB (0.44 s), the 10 MiB department result crossing
the process boundary (interleaved A,B,A,B showed no effect), and `truncate_utf8` (an engine
primitive, ~0 s at 10 MiB).

What remains is inside the bundle build. Reading `libraries/devloop/context_bundle.lua:90-103`:

```lua
local function write_file(path, content, exec)
  if exec ~= nil then
    run_required("touch " .. shell_quote(path), 30, "write", exec)
  end
  local value = tostring(content or "")
  local ok = pcall(file.write, path, value)
  if ok then return end
  run_required("printf %s " .. shell_quote(value) .. " > " .. shell_quote(path), 30, "write", ...)
end
```

Two properties are visible without measuring anything:

1. When `exec` is supplied, **every file written spawns a shell `touch` first** — the bundle writes
   four to six files per build.
2. If `file.write` fails for any reason, the fallback **shell-quotes the entire content into a
   command line**. At the 10 MiB cap that means a multi-megabyte argv, and `shell_quote` is itself a
   pure-Lua pass over those bytes.

**`ASSUMED-UNVERIFIED`: whether the fallback actually triggers in this path.** A probe that appeared
to show `file.write` failing was invalid — it wrote into a directory the probe never created, which
is a defect in the probe, not evidence about production. The candidate is recorded because it is
specific and locatable, not because it is established.

**How to settle it** (for whoever continues): assert inside `write_file` which branch is taken for
the 10 MiB issue file, or time `file.write` on 10 MiB into an existing directory. If the fallback is
taken, this is a **production** defect and not a test one — a real 10 MiB issue body would take the
same path in production, and the fix belongs in `write_file`, not in the test.

That possibility is why the test was left alone. Optimising the test would have hidden a production
cost rather than removing it.

## That candidate is refuted too: `file.write` handles 10 MiB in 3 ms

The experiment named above was run. `file` is an engine-injected bare global (as `truncate_utf8` is),
not `fkst.file` — an earlier probe reached for the wrong name and its failure was a defect in the
probe, not evidence. With the right name:

| size | `file.write` | `file.read` |
|---:|---:|---:|
| 1 KiB | 0.000 s | 0.000 s |
| 1 MiB | 0.000 s | 0.000 s |
| **10 MiB** | **0.003 s** | 0.002 s |

**The shell fallback in `write_file` is never reached, and the write path is not the cost.** The
observation about that fallback stands as a latent hazard — a `file.write` failure at the cap would
put a multi-megabyte argv on a command line — but it is not what makes this test slow.

**So the 20.8 s is still unexplained, and everything cheap has now been eliminated:** fixture
construction, SHA-256, `json_string`, the department result marshalling, `truncate_utf8`, and file
I/O. What remains is inside the bundle build between those steps, and separating it needs per-test
or per-step timing that the engine does not emit — the same prerequisite this document reaches from
four other directions.

**Seventeen hypotheses were tested here. Seventeen were wrong.** None reached a merged change. The
value of this document is that list, not a conclusion.

## Answer: 10.1 s at the exec boundary, 9.5 s in the production content filter

Eighteen attempts failed because all of them measured the function from **outside**. The method that
worked was the one this document already prescribes and I had spent hours violating: **instrument
from inside**. Temporarily stamping `os.clock()` between the named steps of
`build_context_bundle` — in the constructed test root, not the repository — answered it in one run:

| step | time |
|---|---:|
| everything before the whitelist lookup | 0.57 s |
| `content_whitelist` | 0.00 s |
| **`gh_issue_view` (the mocked exec boundary)** | **10.12 s** |
| **`content_filter.filter_gh_content_json`** | **9.45 s** |
| `truncate_if_needed` | 0.002 s |
| `write_file` | 0.003 s |
| board digest, validate | ~0 s |

So the 20.8 s is two costs of roughly equal size, and **only one of them is a test artifact**:

- **10.1 s moving 10 MiB across the exec boundary.** In the test this is `t.mock_command` returning
  the fixture on stdout. Production reads real `gh` output over a pipe, so whether production pays a
  comparable cost is **`ASSUMED-UNVERIFIED`** — the mock's transport is not necessarily the real one.
- **9.5 s in `content_filter.filter_gh_content_json`.** This is **production code on the production
  path**: a pure-Lua pass over the issue JSON that redacts comments from unauthorised authors. At the
  10 MiB cap it runs at roughly 1 MiB/s. A real 10 MiB issue body would pay this in production, on
  every context-bundle build.

**That is the answer the rest of this document was circling**, and it is not what any of the earlier
hypotheses guessed. It is not the fixture, not hashing, not JSON escaping, not the result
marshalling, not truncation, and not file I/O — all of which were measured and eliminated first.

**No optimisation is proposed here, deliberately.** `filter_gh_content_json` is a redaction boundary:
it decides which comment authors' content reaches a codex prompt. Making it faster is a change to a
security-relevant path and belongs behind the same adversarial review as any other trust-boundary
change — not a unilateral speed edit at the end of a measurement exercise. What this section
establishes is *where* the cost is and that it is **production, not test**, which is the fact a
proposal would have to start from.

## The 9.45 s is accidental, not inherent: a char-by-char JSON parser in pure Lua

The previous section declined to look further because `filter_gh_content_json` is a redaction
boundary. **That was over-applied caution.** Refusing to change *what gets redacted* without review
is right; refusing to *read why it is slow* is not, and conflating the two is the same
over-broadening this document criticises elsewhere.

Reading it: `libraries/forge/github/content_filter.lua` (784 lines) contains a hand-written JSON
parser that advances **one character at a time**, e.g.

```lua
  return self.source:sub(self.index, self.index)
```

Each call allocates a fresh single-character Lua string. Over a 10 MiB document that is on the order
of ten million `string.sub` calls and ten million allocations — which is exactly the ~1 MiB/s the
measurement shows.

**So the cost is accidental, not inherent.** Scanning with `string.find` patterns (which execute in
C) instead of per-character `sub` is a standard Lua optimisation, and — the load-bearing point —
**the redaction policy is independent of how the JSON is tokenised.** Which authors' comments are
filtered does not depend on the parser's inner loop.

**No rewrite is attempted here, for a narrower reason than before.** Rewriting a JSON parser that
decides which content reaches a codex prompt is a trust-boundary change: a parsing bug changes what
is redacted. That belongs behind the same adversarial review as any other trust-boundary change, and
attempting it at the end of a long session with an 18-for-18 record of refuted hypotheses would be
precisely the over-reach recorded elsewhere in this document.

**What a proposal should start from:** the cost is `Parser` in
`libraries/forge/github/content_filter.lua`, it is per-character string allocation, it is ~9.45 s at
the 10 MiB cap on the production path, and a semantics-preserving fix exists in principle. Any such
change touches `libraries/` and therefore goes through the integration branch, and needs a
differential test proving identical redaction output on the same inputs before and after — not just
that it is faster.

## Correction: the parser cost scales with content, and real content is 1000x smaller

The section above frames the 9.45 s as an accidental production cost that is merely risky to fix.
That framing omits the decisive step, and the omission changes the conclusion.

The parser is linear in input size, and the measurement gives its rate directly: 10 MiB in 9.45 s is
**~1 MiB/s**. So:

| issue body | parser cost |
|---|---:|
| 10 MiB — the cap, built deliberately by the test | 9.45 s |
| 500 KiB — a very large real issue | ~0.5 s |
| 50 KiB — ordinary | **~0.05 s** |

**The 9.45 s is essentially unreachable in production.** It appears only in a test that deliberately
constructs a fixture at the cap — which is the point of the cap. Real issue bodies are three orders
of magnitude smaller, where the same parser costs tens of milliseconds.

So this is **not** "a production defect that is risky to fix". It is: *the test is expensive because
it must be.* The property under test — that content exceeding the cap is truncated on a UTF-8
character boundary — requires, by definition, an input exceeding the cap. The 20.8 s is the honest
price of verifying the cap end-to-end through the real bundle path.

The earlier "trust boundary, so I will not touch it" was the right decision reached through the wrong
reason, and the wrong reason mattered: it read as caution when the actual argument is **worth**.
Rewriting a JSON tokeniser on a redaction boundary to speed up a path real traffic does not take is
exactly the over-reach the WORTH GATE names — not because it is dangerous, but because it buys
nothing.

**What this closes.** The single most expensive test in the repository is expensive for a defensible
reason, and there is no cheap correct fix. Options that remain, none of them free: verify the cap
with an injectable smaller limit (changes what is exercised and needs its own argument), accept the
cost, or move the capacity check out of the default suite (changes when it runs, not whether). None
was pursued here; all three are behaviour or policy changes, not refactors.

## Two corrections an adversarial panel found in this document

Both are errors in what is written above, both verified by re-derivation, and both were overstatements
in the direction that made the conclusion sound cleaner.

### 1. "No scheduling lever remains" overstates the measurement by 58.4 s

The identical-machine makespan lower bound is `max(p_max, W/cores)`. With `p_max = 582.3 s`,
`W = 1166.9 s` and 4 cores that is `max(582.3, 291.7) = 582.3 s`. The observed span was **640.7 s**.

So the pool sits **58.4 s above its own floor — 9.1% of the span — not at it.** The correct statement
is that scheduling headroom is *bounded* at 9.1%, not that it is zero. Whether any of that 58.4 s is
recoverable is **`ASSUMED-UNVERIFIED`**: it would need a controlled ordering A/B, and the earlier
sections of this document establish that a single before/after run on the dogfood host is not
evidence.

The claim "the package pool is at ~91% of its capacity floor" is correct. The claim that therefore
"no scheduling lever remains" does not follow from it.

### 2. The parser size comparison is wrong by 4.9x, and the extrapolation is unverified

The section above says a 50 KiB issue body is "three orders of magnitude" smaller than the 10 MiB
cap. **10 MiB / 50 KiB = 204.8x**, not 1000x — the published figure is off by a factor of 4.9.

More importantly, the entire cost table below the 10 MiB row was **extrapolated from a single timing
point** on one fixture. What the source actually establishes is a per-character pass; what was
measured is 9.45 s at 10 MiB on a fixture that is one long run of `a` with no redactable content.
The following are all **`ASSUMED-UNVERIFIED`** and should not have been stated as a table of costs:

- that the whole function is linear across real JSON shapes, rather than only on that fixture;
- the ~0.05 s figure for a 50 KiB body;
- the production size distribution — production parses issue JSON **including comments**, not a bare
  body, so the relevant input is not the one that was measured.

The conclusion that the 9.45 s is unreachable in production may still be right, but **it is not
established by what was measured**, and "unreachable in production" should be read as a hypothesis,
not a finding.

### Why both errors point the same way

Neither error is random. Each made the story tidier: one turned "9.1% headroom, recoverability
unknown" into "no lever remains", the other turned "one timing point on an unrepresentative fixture"
into a cost table with three rows. **An adversarial seat found both; the author found neither.** That
is the same ratio this document records elsewhere — 16 of 18 blocking findings in the earlier review
rounds came from review, not from the author.

## The local gate: where its 35% FULL fallback comes from, and why most of it is worth less than it looks

Everything above measures `scripts/run.sh test` — the comprehensive gate. This section measures the
*local* gate, `scripts/run.sh test-affected`, which is what an implement/fix codex pays inside its
own budget. They are different questions and the second had not been measured.

### The verdict distribution

`test_affected_requires_full_suite()` classifies each changed path, and **any** path that requires
the full suite forces `full=1` for the whole run. Replaying that function over the last 300
non-merge commits of `origin/dev`, **excluding the 59 empty-diff marker commits** the pipeline writes
(`fkst: implementation result v1 ...` and similar — they touch no path, so the classifier trivially
reports SCOPED and would otherwise inflate the denominator):

| verdict | commits |
|---|---:|
| empty diff (excluded) | 59 |
| SCOPED (graph-derived package subset) | 134 |
| **FULL (all 22 packages + composed conformance)** | **107 of 241 = 44.4%** |

FULL, by the class of the first path that forced it:

| class | commits |
|---|---:|
| `migration/` | 44 |
| `scripts/` | 27 |
| `docs/` | 13 |
| `.claude/` | 11 |
| `.fkst/` | 6 |
| `CLAUDE.md` | 2 |
| `fkst.workspace.toml` | 1 |

The function's last statement is `return 0`: FULL is the **default** for every path it does not
recognise. That is the correct fail-safe posture, and it is why the whole tail is here.

### The root cause is a missing node kind, not an overbroad prefix rule

`scripts/test_affected.py` builds nodes only for `libraries/*` and `packages/*` and edges only from
their `fkst.toml` `lib_deps` / `event_deps`. It **raises** on any seed outside those two prefixes,
and the shell falls back to `full=1`.

Meanwhile package tests read repo-root data directly:

```lua
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
...
local inventory = json.decode(file.read(INVENTORY_PATH))
```
— `packages/github-devloop-pr/tests/old_behavior_observe_pr_decompose_intent_observation_test.lua:20,373`

That read succeeds even though the filtered test root has no `migration/` directory:
`copy_package()` tars only the package directory plus every library
(`scripts/composed_test_graph_roots.sh:78-112`), and `run_one_package` invokes
`"$BIN" test --project-root "$pkg" --package-root "$pkg"` with no `cd`
(`scripts/test_parallel.sh:35,39`). So a relative `file.read` resolves against the **process CWD —
the repository root** — an ambient filesystem input that escapes the declared root entirely.

**So FULL is an honest UNKNOWN, not conservatism.** The selector has no mechanical proof of any
repo-root path's complete consumer set, because nothing confines what a test may read.

### Measuring the reader sets inverts the intuition twice

First inversion — repo-root data *is* read from Lua, so "these classes are checker-only" is false.
Second inversion — the files that are read are not the files that change.

| `migration/` file | commits (of 300) | Lua readers |
|---|---:|---:|
| `lower-injected-m.inventory` | 12 | **0** |
| `github-devloop-saga-split.inventory` | 9 | **0** |
| `service-locator.inventory` | 4 | **0** |
| `library-error-class.allowlist` | 4 | **0** |
| **`restart-lifecycle.inventory.json`** | **4** | **read by 2 packages** |
| 13 further ledgers | 15 | **0** |

The ledgers that change often are exactly the ones no Lua file reads; the one file with a large
reference count changed 4 times in 300 commits.

And scoping *that* file buys nothing. The complete repo-root read surface is **43 test files, 100% of
them in `github-devloop` (26) and `github-devloop-pr` (17)** — no library, no other package. Using
the CI unit timings above, any scope containing `github-devloop` keeps the pool's critical path
(582.3 s of a 640.7 s span), so the verdict moves the span by at most the ~9% scheduling headroom
already identified. **The largest FULL class is worth far less than its commit count suggests.**

### Two consumer families, so "relocate it under its owner" is refuted

The obvious parsimonious fix — move each repo-root fixture under the package that reads it and let
the existing manifest closure resolve it — fails on these files, because the Lua tests are not their
owner. Each is read by **two independent consumer families**:

| file(s) | Lua consumer | Python consumer |
|---|---|---|
| `migration/restart-lifecycle.inventory.json` | `github-devloop`, `github-devloop-pr` | `check_repo_restart_lifecycle.py:14`, `check_repo_restart_preflight.py:20` |
| `migration/intent_bounded_replay/corpus/*.json` (13) | one package each | `check_repo_intent_bounded_replay_trace_catalog.py:9-23` |

These are repository-wide R9 artifacts. Moving them under a package would invert the layering and
put a repo-wide ratchet under one of its consumers. Their natural owner **is** the repository root.

The frequently-changed ledgers are the clean case in the other direction: `migration/*.allowlist` and
`migration/*.inventory` are read only by their checkers (`check_repo_dedup.py:16`,
`check_repo_error_class.py:13-14`, `check_repo_gh_git_adapter.py:21`, and so on) and by nothing in
Lua.

### `docs/`, root `*.md` and `.claude/` are the only provably free classes

- **No Lua source or test reads any repo-relative `.md`.** Every `.md` path literal under `packages/`
  and `libraries/` is `/tmp/...` (github-proxy comment-body fixtures) except
  `docs/integration-note.md`, and that occurrence is inside an *embedded Python fixture string* doing
  `(root / "docs/integration-note.md").write_text(...)` into a temporary fixture root
  (`packages/github-devloop-integration/tests/integration_sync_conflict_test.lua:156-158`). It writes;
  it does not read the repository's copy.
- **`.claude/` has zero Lua references.**
- `.github/workflows/ci.yml` appears 5 times, but only as **mock stdout** in tests asserting that a
  path under `.github/` classifies as high-risk (`packages/github-devloop/tests/core_basics_test.lua:92,98`).
  The rule is under test, not the file.

That is 26 commits of 300 (8.7%).

### Why the measurement is not yet a licence to act

Everything above is a **lexical** scan of quoted path literals, and one level of indirection already
defeats the naive form of it: the corpus reads go through `file.read(CORPUS_PATH)` where
`CORPUS_PATH` is a module-local constant, so a scan for `file.read("migration/` finds **3** sites
while the real surface is 43. A computed path — `file.read("migration/" .. name)` — would be
invisible and is not currently forbidden.

The failure mode is asymmetric. A missed reference turns a correct FULL into an incorrect SCOPED, and
the gate then passes a change that breaks a test it never ran. **A wrong SCOPED is a correctness
regression; a wrong FULL is only slow.** So a lexical inventory is migration input, never verdict
evidence.

### The ordering result: the batching fix had to land first

Before `test` accepted multiple package arguments, `cmd_test_affected` invoked
`scripts/run.sh test <pkg>` once per selected package, and the `test` dispatch runs a full `cmd_check`
before `cmd_test` (`scripts/run.sh:845-855`). So a SCOPED verdict selecting N packages paid N × the
entire check phase — 204.6 s each in CI. Narrowing FULL into a multi-package SCOPED verdict was
therefore **net-negative** for much of its own addressable set: it converted one check phase into
several.

That is now fixed — the gate runs once with all affected packages — which is the precondition for any
further narrowing to have a positive sign at all. **The sequencing matters more than the selection
rule: the batching fix was worth more than the narrowing it unblocks.**

**And it was worth much more than expected, because SCOPED verdicts are not small.** Resolving each
of the 134 real SCOPED commits through `scripts/test_affected.py` against the current manifests:

| resolved packages | commits |
|---:|---:|
| 1 | 21 |
| 2 | 10 |
| 4 | 11 |
| 5 | 2 |
| 6 | 24 |
| 7 | 1 |
| 8 | 2 |
| 15 | 5 |
| **16** | **36** |
| 18 | 2 |
| **22 (every package)** | **20** |

Mean **10.4** packages. So the average SCOPED local iteration used to pay **10.4 check phases**, and
20 commits paid **22** — a SCOPED verdict that selects every package, and therefore under the old
code cost 22× the check phase that one FULL run pays once. Using the 204.6 s check phase measured
above, batching removes ≈ 9.4 × 204.6 s ≈ **32 minutes** of redundant work from an average SCOPED
iteration, and ≈ 72 minutes from the worst class.

**This also reframes the FULL fallback.** FULL is not the expensive verdict it appeared to be
relative to SCOPED — before batching, the median SCOPED verdict was *more* expensive than FULL in
check-phase terms. The narrowing work this section set out to justify was chasing the smaller of the
two costs, and the larger one was one `for` loop away.

*Method note: package sets are resolved with the current `test_affected.py` and current manifests
against historical paths, so a commit touching a since-deleted package resolves imprecisely. The
distribution's shape — concentrated at 16 and 22 — does not depend on those edges.*

*Second method note, and it cuts against the number above: multiplying 204.6 s by the repeat count
assumes every repeated check phase costs what the first one costs. It will not — repeated invocations
in one session hit the OS page cache and `__pycache__` is disabled (`python3 -B`) but the interpreter
and imported module bytecode still warm. So `9.4 × 204.6 s` is an **upper bound** on the removed
work, not a measurement of it. What **is** measured without that assumption is the repeat count
itself: mean 10.4 invocations where one suffices, and 22 in the worst class. The direction and the
shape are solid; treat the minutes as the ceiling.*

### What a proposal must start from

- The residual opportunity is bounded by the 26 provably-free commits plus the checker-only
  `migration/` ledgers, not by the headline 104.
- Any narrowing needs an enforcement boundary that makes an undeclared repo-root read impossible or
  fail closed, with every unknown or dynamic path retaining FULL. Without one, FULL is the correct
  verdict and keeping it costs only time.
- One such boundary needs no engine change: run each package test with its filtered root as the
  process CWD and stage the declared repo-root inputs into it, so an undeclared read fails because
  the file is absent. That is `scripts/`-side and measurable — and it is **`ASSUMED-UNVERIFIED`**
  whether the 43 reader files are the only relative-path behaviour that a CWD change would disturb.

## The enforcement boundary is feasible: measured, with the cost that decides against it

The section above leaves one thing `ASSUMED-UNVERIFIED` — whether confining the test process's CWD to
its constructed root would work as an enforcement boundary, and what else it would disturb. That was
settled by experiment rather than by reading, and the answer is: **it works, and the reason not to
build it is cost, not feasibility.**

### The experiment

A probe test was added to a real constructed root (`scripts/composed_test_graph_roots.sh normal
github-devloop-ops`, which produces a `$work` tree holding `packages/`, `libraries/` and
`fkst.workspace.toml` and **no** `migration/`). The probe reads a repo-root file and raises on either
outcome, so the result appears in the output rather than being collapsed into pass/fail:

```lua
local ok, content = pcall(file.read, "migration/restart-lifecycle.inventory.json")
if not ok then error("PROBE_RESULT=READ_FAILED detail=" .. tostring(content)) end
error("PROBE_RESULT=READ_OK bytes=" .. tostring(#content))
```

The identical engine invocation was then run twice, differing only in the process CWD:

| | CWD = repository root (production) | CWD = the constructed root |
|---|---|---|
| probe | `PROBE_RESULT=READ_OK bytes=2065810` | `PROBE_RESULT=READ_FAILED: No such file or directory (os error 2)` |
| everything else | 179 passed, 2 failed | 179 passed, 2 failed |
| failing **set** | `fire_raiser_ops_test::…route_real_ticks`, probe | **identical** |

Three results, none of them previously established:

1. **A relative `file.read` resolves against the process CWD.** Measured, not inferred — the same
   invocation reads 2 MB from one CWD and `ENOENT` from another.
2. **Confinement fails closed**, which is exactly the enforcement property a sound narrowing needs.
3. **Zero collateral damage** on a package that does not make such reads — the failing *sets* are
   identical, not merely the counts.

### The cost that decides it

Confinement is only complete if it covers every package, and the two package kinds are not
symmetric. `run_one_package` gives a **composed** package a constructed root
(`test_project_root` = `$work/packages/<name>`, with `libraries/` and the repo layout mirrored
alongside), but a **flat** package is run directly against its own directory — there is no mirrored
root to confine it to.

Classifying every package that makes a real repo-root `file.read` (a literal, or a module CONST
holding one):

| package | reader files | kind |
|---|---:|---|
| `github-devloop` | 30 | composed |
| `github-devloop-pr` | 19 | composed |
| `github-devloop-ops` | 1 | composed |
| `archaudit` | 1 | composed |
| **`github-proxy`** | **1** | **flat** — reads `libraries/contract/strings.lua` |

So 51 of 52 reader files are in composed packages, which already pay for a constructed root and could
be confined for free. The single flat reader is what breaks the symmetry, and closing it costs one of:

- **build a mirrored root for flat packages too** — a full `libraries/` tar copy per flat package.
  The document's own fixed-graph-cost section measures that copy at `F ≳ 1.1 s`, and notes `F` scales
  with what is copied. Across ~10 flat packages that is ~10 s **added** to every suite run;
- **or a second, different mechanism for flat packages** — a conformance check forbidding repo-root
  reads there, with a shrink-only allowlist that starts at exactly 1 entry.

The second is cheap and would work. But the benefit it unlocks is the narrowing this document already
priced: the `docs/` + `.claude/` classes at 26 of 241 commits, plus the checker-only `migration/`
ledgers — against a `migration/` class whose only Lua-read file resolves to the critical-path package
and therefore saves nothing. **Adding a second enforcement mechanism, in a second place, with its own
ledger to maintain, to unlock that** is the same trade the panel already declined, now with the cost
side measured rather than estimated.

**What this closes:** feasibility is no longer the open question, so nobody needs to re-run this
experiment. What remains open is worth, and the measured cost moved it further from the line, not
closer. The recipe is recorded above if a future change to the reader distribution — in particular
`github-devloop` or `github-devloop-pr` losing their repo-root reads — makes it cheap enough to
revisit.

**Still `ASSUMED-UNVERIFIED`:** whether any of the 118 computed-path `file.read`/`file.write` calls
resolve to repo-root locations. The experiment above probes one known path, not the computed set, and
a confinement rollout would surface them as ENOENT failures rather than proving their absence first.

⟦AI:FKST⟧

## Retraction: the check pool's "1.4–2.9x unexplained gap" was an artifact of my own model

The section above ends by claiming the check phase's real cost is a 1.4–2.9x gap that list ordering
does not explain, and names it the open question. **That claim is withdrawn.** It compared a model
built from *serially* measured unit durations against *parallel* reality, and the gap is the
difference between those two things, not a defect.

Instrumenting `run_units_parallel` to stamp each unit's start and end — the method this document
already prescribes and I had just spent a section violating — answers it in one run:

| | measured |
|---|---:|
| span | **57.6 s** |
| serial sum **under parallelism** | **381.9 s** |
| serial sum measured **one unit at a time** | 260.3 s |
| mean concurrency | **6.63** (median 8, max 8, on 8 slots) |
| span with ≤1 unit running | 3.0 s = **5%** |
| longest unit | 55.4 s, starts at **0.0 s** |
| **span ÷ makespan floor** | **1.04x** |

Three corrections follow.

1. **The pool saturates.** Median concurrency is 8 of 8 slots. The earlier "mean concurrency 1.40 —
   contention or packing defect UNKNOWN" reading, and my own 3.0 estimate derived by dividing a
   serial sum by a wall-clock, are both artifacts of the same mistake: dividing *serial* work by
   *parallel* time understates concurrency whenever units inflate under load.
2. **Units inflate 47% under 8-way parallelism** — 260.3 s of serial work becomes 381.9 s. Any model
   fed serially-measured durations will predict a makespan that reality cannot achieve, and will
   then read the difference as an unexplained defect. It is not a defect; it is the model's input
   being the wrong quantity.
3. **The check pool is already near-optimal at 1.04x its floor**, and that floor is one unit's
   duration. There is no scheduling lever here at all — not the ordering one already refuted, and not
   the packing one I invented to replace it. The only way down is to make the longest unit cheaper,
   which is the whole-repository check that an adversarial panel declined to remove, on grounds
   recorded earlier in this document.

**The methodological point, now demonstrated for the fourth time in this document and the second time
against me in the same session.** Modelling from outside produced a phantom defect and an open
question that did not exist. One `date +%s.%N` per unit inside the scheduler settled it. *Instrument
from inside the machinery; do not decompose it from outside* — the rule was already written here, in
this file, by the same author who then ignored it.

⟦AI:FKST⟧
