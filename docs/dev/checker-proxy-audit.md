# Checker proxy audit

Audit date: 2026-08-10. Population: the 54 checker invocations in
`scripts/check_repo_runner.py`; all 54 implementations were opened. Result: **1 TIGHT, 3
PROXY-SAFE, 50 PROXY-RISKY**.

`TIGHT` means the measured property is the claim. `PROXY-SAFE` means the checker is explicitly a
warning or advisory signal here. `PROXY-RISKY` means an isolated counterexample made the checker
accept a violation or reject a non-violation. Except for `intent-bounded-replay`, every risky row is
load-bearing because its message is appended to the runner's blocking `violations` list or its count
is a shrink-only target. `intent-bounded-replay` is conditional: with `FKST_R9_TRACE_ROOT` absent,
the runner performs no NEW-trace comparison. GraphQL and REST are warnings; coverage is advisory and
`migration/coverage-uncovered.required` is absent.

## Classification

The quoted text is an exact representative message fragment (or, for a silent false negative, the
checker-level claim that the missing message is intended to enforce).

| # | checker | what it measures -> what it claims | class / load |
|---:|---|---|---|
| 1 | line-limit | `splitlines()` count in selected source trees -> `has {count} lines; limit is 1000` | TIGHT / gate |
| 2 | test-shape | filename and regex-recognized `test_*` assignments -> `helper but defines test entries` | PROXY-RISKY / gate |
| 3 | helper-reachability | graph of literal `require("tests.*")` calls -> `is not reachable from any *_test.lua` | PROXY-RISKY / gate |
| 4 | graphql-connection-guards | GraphQL-looking string literals and selected fields -> `lacks a truncation guard; possible fail-open` | PROXY-SAFE / warning |
| 5 | rest-pagination-guards | a local text window around `per_page=100` -> `lacks gh api --paginate; possible fail-open truncation` | PROXY-SAFE / warning |
| 6 | hidden-text-encoded-literals | helper-name and encoded-looking-literal regexes -> `hidden text uses an encoded literal decode helper` | PROXY-RISKY / gate |
| 7 | gh-rate-pool-sizing | `burst`/`refill_per_*` tokens between a `gh_rate_pool` header and first `end` -> `gh rate pool sizing belongs to ... host posture` | PROXY-RISKY / gate |
| 8 | error-class-prefixes | any call token named `error` with an unprefixed literal -> `production error(...) string lacks a greppable class prefix` | PROXY-RISKY / gate |
| 9 | library-error-class | the same lexical detector under `libraries/` -> `production library error(...) string lacks a greppable class prefix` | PROXY-RISKY / gate |
| 10 | persistence-classes | raw occurrence of saga-recovery tokens in non-saga package text -> `uses saga recovery token ... but ... is reliable` | PROXY-RISKY / gate |
| 11 | cross-package-require | literal require names -> `peer cross-package require ... is forbidden` | PROXY-RISKY / gate |
| 12 | library-layering | literal require names in libraries -> `library requires package-only module` | PROXY-RISKY / gate |
| 13 | dependency-cycle | SCCs over literal library require edges -> `is a library require cycle` | PROXY-RISKY / gate |
| 14 | scoped-file-watch-ingress | raw regex tables for consumes/produces/glob -> `must target a package-consumed queue` | PROXY-RISKY / gate |
| 15 | no-permission-control | raw source lines containing chmod/mode tokens -> `may not be used for permission-based control` | PROXY-RISKY / gate |
| 16 | gh-git-adapter | statically reconstructed string command heads -> `constructs a new gh/git command head` | PROXY-RISKY / gate |
| 17 | shell-out-to-self | selected aliases/data flow into known exec calls -> `shells out to the framework binary` | PROXY-RISKY / gate |
| 18 | code-dedup | hashes function bodies after stripping blank lines and surrounding whitespace -> `cross-file byte-identical production function body` | PROXY-RISKY / gate |
| 19 | content-truncation | named caps plus nearby truncation and sink regexes -> `truncates large content into a reliable payload or codex prompt` | PROXY-RISKY / gate |
| 20 | dept-failure-surface | raw `retry = {` or `wrap_pipeline_failure` regex -> `uses neither an enabled retry table nor wrap_pipeline_failure` | PROXY-RISKY / count gate |
| 21 | version-suffix | selected suffix literals/patterns -> `constructs/parses a transition-version suffix` | PROXY-RISKY / gate |
| 22 | lock-scope | direct IO call tokens in lexical `with_lock` callbacks -> `performs external IO inside a with_lock critical section` | PROXY-RISKY / gate |
| 23 | coverage | engine coverage JSON plus heuristic candidate source lines -> `is an uncovered production Lua line`; checker also says `reference signal, not a hard CI gate` | PROXY-SAFE / advisory |
| 24 | integration-coverage | source occurrence of `graph.assert_covers("edge")` -> `add a run_graph test covering it` | PROXY-RISKY / gate |
| 25 | producer-liveness | `fire_raiser` and any assertion containing a trace field -> `lacks a trace-asserting fire_raiser test` | PROXY-RISKY / gate |
| 26 | namespaced-queue | first `local spec.consumes` table plus direct queue compare -> `compares event.queue to bare own queue` | PROXY-RISKY / gate |
| 27 | dead-letter | raw regex-extracted consumes/ephemeral strings -> `has no department consuming dead_letter` | PROXY-RISKY / gate |
| 28 | live-run-dispatch | inline or simply assigned identity fields at raw spawn -> `raw identity-carrying ... is forbidden` | PROXY-RISKY / gate |
| 29 | codex-timeout | selected numeric timeout syntax/data flow -> `production codex timeout defaults must come from workflow_internal.codex` | PROXY-RISKY / gate |
| 30 | monotone-gate | recognized cursor calls/state equalities, counted by lexical bucket -> `unclassified transient lifecycle cursor read` | PROXY-RISKY / count gate |
| 31 | restart-lifecycle | inventory schema/hash and source substring provenance -> `symbol not found in ...` | PROXY-RISKY / gate |
| 32 | saga-handler | literal workflow.saga require plus `.department` syntax -> `free-form department` / `still defines free-form top-level pipeline` | PROXY-RISKY / gate |
| 33 | saga-head | unbound `saga.department` syntax plus raw workflow.saga text -> `spec ... must be declared ... at file head` | PROXY-RISKY / gate |
| 34 | bot-login-mediation | recognized names, assignments, equality and membership syntax -> `bypasses bot-login mediation` | PROXY-RISKY / gate |
| 35 | fanout-only | known queue strings anywhere in department source -> `is a new known-dialogue surface` | PROXY-RISKY / gate |
| 36 | restart-preflight | git diffs plus regex-recognized authority/exposure tokens -> `adds a restart authority call` | PROXY-RISKY / gate |
| 37 | intent-bounded-replay | artifact fields/hashes; NEW traces only when a trace root is supplied -> `R9 intent-bounded-replay enforcement` / `trace canonical hash mismatch` | PROXY-RISKY / conditional |
| 38 | github-content-ingress | recognized raw command/policy/helper syntax -> `raw gh ... bypasses the GitHub capability seam` | PROXY-RISKY / gate |
| 39 | ownership-gate-claim-owner | direct `trusted_bot_login(` inside a regex function block -> `must use claim_owner(), not ... trusted_bot_login()` | PROXY-RISKY / gate |
| 40 | std-dependency-model | TOML equality plus literal devloop-to-forge imports -> `imports ... but is not listed` | PROXY-RISKY / gate |
| 41 | dogfood-boundary | regexes over naively delimited shell functions -> `launch path must delegate through scripts/run.sh supervise` | PROXY-RISKY / gate |
| 42 | saga-split | exhaustive path inventory plus literal PR-phase state arguments -> `writes or parses PR-phase authority from a non-PR owner` | PROXY-RISKY / gate |
| 43 | hidden-state | required/forbidden token presence and shrink-only allowlist -> `must install behavioral hidden_state_conformance` | PROXY-RISKY / gate |
| 44 | gh-egress | inline `{argv=...}` calls to known callback parameters -> `additional GitHub raw argv egress sink` | PROXY-RISKY / gate |
| 45 | gh-handle-construction | recognized literal imports/factory calls -> `new consumer-side GitHub handle locator` | PROXY-RISKY / count gate |
| 46 | intake-default-surface | dot-form export/definition regexes -> `package-private GitHub capability export is forbidden` | PROXY-RISKY / gate |
| 47 | intake-routing | literal spec queues, marker calls/strings and `issue_list` token -> `must not build or write state:v1 markers` | PROXY-RISKY / gate |
| 48 | devloop-godlib | raw regex counts for install/M writes/core installs/wildcards -> `god-PATTERN coupling grew` | PROXY-RISKY / count gate |
| 49 | lower-injected-m | direct `M.*` tokens inside functions with parameter named `M` -> `injected-M coupling grew` | PROXY-RISKY / count gate |
| 50 | devloop-decouple | `(core|M).known_symbol(` regex counts -> `production reader-calls through the ambient M` | PROXY-RISKY / count gate |
| 51 | devloop-installer | literal installer discovery plus `(core|M).symbol(` readers -> `reader-calls through the ambient M` | PROXY-RISKY / count gate |
| 52 | service-locator | raw `require("core")` and `core.member` regex counts -> `Departments must not add ambient ... reads` | PROXY-RISKY / count gate |
| 53 | ambient-surface | literal install calls and recognized `M` exports -> `install(M) ambient-surface exports ... GREW` | PROXY-RISKY / count gate |
| 54 | core-param | only parameters/arguments literally named `M` or `core` -> `Do not thread the composed core/M as a parameter` | PROXY-RISKY / count gate |

## Demonstrated counterexamples

These probes ran against checker functions in isolated temporary roots. `[]`, `{}`, `0`, and
`None` are the actual accepting responses. A nonempty response in an FP row is the actual false
positive. The full response objects are retained in the audit result JSON.

| checker | counterexample code/shape | actual checker response |
|---|---|---|
| test-shape | `metrics.test_latency = 5` in a helper | FP: `helper but defines test entries: test_latency` |
| helper-reachability | `local n="tests.x_helpers"; require(n)` | FP: helper `is not reachable` |
| hidden-text-encoded-literals | identity helper `h("48656c6c6f21")` | FP: line `[2]` |
| gh-rate-pool-sizing | unrelated `{ burst = true }` inside `gh_rate_pool` | FP: line `[2]` |
| error-class-prefixes | local non-throwing `error(message)` | FP: `[[2,"plain diagnostic"]]` |
| library-error-class | same local function under `libraries/` | FP: `[[2,"plain diagnostic"]]` |
| persistence-classes | comment containing `current_entity_state` | FP: `uses saga recovery token 'current_entity_state'` |
| cross-package-require | `local n="sibling.mod"; require(n)` | FN: `[]` |
| library-layering | `local n="core.state"; require(n)` in a library | FN: `[]` |
| dependency-cycle | `a` and `b` require variable-held names in a cycle | FN: `[]` cycles |
| scoped-file-watch-ingress | only `-- consumes={"q"}` claims consumption | FN: `None` |
| no-permission-control | `# chmod 444 state-file` comment | FP: `permission command may not be used` |
| gh-git-adapter | `string.char(103,104) .. " issue view 1"` | FN: `[]` |
| shell-out-to-self | string.char-built framework path passed to `exec_argv` | FN: `[]` |
| code-dedup | bodies differ in blank lines/indentation only | FP: `is a cross-file byte-identical ... body` |
| content-truncation | `body:sub(1, limit)` then `spawn_codex({prompt=cut})` | FN: `[]` |
| dept-failure-surface | multiline comment contains `retry = {}` | FN: `has_failure_surface=True` |
| version-suffix | `base .. "/lo" .. "op/" .. n` | FN: `[]` |
| lock-scope | callback calls helper; helper calls `github.get()` | FN: `[]` |
| integration-coverage | `if false then graph.assert_covers("p.q -> other.consumer") end` | FP coverage: `['p.q -> other.consumer']` |
| producer-liveness | `t.eq(trace.raised, trace.raised)` | FP coverage: `['clock']` |
| namespaced-queue | unused `local spec` consumes `q`; returned spec does not | FP: `compares event.queue to bare own queue 'q'` |
| dead-letter | only dead-letter consumer is in a comment | FN: `[]` |
| live-run-dispatch | `spawn_codex(build_opts())`, helper returns all identity fields | FN: `[]` |
| codex-timeout | `local budget=60; spawn_codex({timeout=budget})` | FN: `[]` |
| monotone-gate | `state["current_" .. "state"](issue)` | FN: `[]` |
| restart-lifecycle | inventory symbol appears only in a source comment | FN: `[]` provenance errors |
| saga-handler | workflow.saga loaded through a variable-held module name | FP: `free-form department` |
| saga-head | workflow.saga only in comment; `saga` is a fake builder | FP: `saga.department must pass a named spec` |
| bot-login-mediation | `rawequal(a.author_login,b.trusted_bot_login)` | FN: `[]` |
| fanout-only | `log("consensus.proposal")` | FP: `request-producer|...|consensus.proposal` |
| restart-preflight | `local transition=decide_transition; transition(...)` | FN: `{}` new matches |
| intent-bounded-replay | `trace_root=None`; no NEW traces supplied | FN: repository response `[]` |
| github-content-ingress | string.char-built `gh` head executes authored API read | FN: `[]` |
| ownership-gate-claim-owner | alias then call `trusted_bot_login` | FN: `[]` lines |
| std-dependency-model | variable-held `forge.git` module passed to `require` | FN: `[]` imports |
| dogfood-boundary | each launch function runs `"$runner" supervise` with `runner=scripts/run.sh` | FP: `launch path must delegate through scripts/run.sh supervise` |
| saga-split | `local target="reviewing"; state_marker(issue,target)` | FN: `[]` leaks |
| hidden-state | every required harness token appears only in comments | FN: `[]` |
| gh-egress | `local opts={argv=...}; exec_argv(opts)` | FN: `[]` sinks |
| gh-handle-construction | variable-held module name then `factory.production_handle()` | FN: `[]` candidates |
| intake-default-surface | `M["github_capability_raw"] = function...` | FN: `[]` |
| intake-routing | aliases assemble both `state_marker` and `state:v1` | FN: `[]` |
| devloop-godlib | comment `-- M.fake = typed_export` with baseline zero | FP: `m_writes 1 > baseline 0` |
| lower-injected-m | ordinary map parameter `function transform(M) return M.value end` | FP count: `{'value':1}` |
| devloop-decouple | `local ctx=core; ctx.work()` | FN count: `0` |
| devloop-installer | installed method called through `ctx` alias | FN inventory: `{}` |
| service-locator | comment `-- core.fake is documentation only` | FP: `department_core_member_reads = 1` |
| ambient-surface | variable-held module then `m.install(M)` | FN: `install_m_calls=0`, `ambient_m_exports=0` |
| core-param | core passed under local/parameter name `ctx` | FN: both counts `0` |

## Coverage and epistemic status

**VERIFIED:** runner enumeration 54/54; implementations opened 54/54; executable
counterexamples 50/50 PROXY-RISKY classifications; coverage required flag absent. The counterexample
responses above came from the checker functions, not reimplementations.

**INFERRED:** the semantic half of each counterexample (for example, that a variable-held Lua
`require` still loads the sibling module) follows the language/runtime semantics; the checker
response itself is verified. No classification was extrapolated from an unopened checker. This
audit establishes what these source gates recognize; it does not measure whether another engine,
runtime, review, or test gate independently catches the same code shape.
