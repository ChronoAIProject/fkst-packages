# Design: Ports & Adapters — a `gh`/`git` anti-corruption layer in `std`

Status: proposal · Date: 2026-06-15 · Repo: fkst-packages
Builds on (read these first):
- `2026-06-14-std-shared-library-design.md` — the `std/` shelf, the Tier S/R split, the symlink vendoring, and the doctrine that earmarks **`gh`-shaped helpers as Tier R**. This spec puts the largest Tier R inhabitant on that shelf.
- `2026-06-14-saga-harness-design.md` — the `std.department{done,act}` department shape and its ①②③ idempotency oracle + **stateful external-truth fake**. §6 of this spec shows that fake *is* the in-memory implementation of the port defined here.

---

## 1. Problem (实证)

The system programs **directly against concrete commands**. Business logic and the
`gh`/`git` command bridge are tangled in the same files: a department that decides
"should this PR merge?" also knows the exact spelling of `gh pr merge --merge
--match-head-commit`, the JSON shape of `gh pr view`, and how to `shell_single_quote`
a branch name. CLAUDE.md already names the cure as doctrine and the code already
violates it:

> CLAUDE.md(边界模式固定): "外部系统接入优先用 Adapter，把 `gh`、`codex exec`、文件和网络
> 形态转成包内稳定结构；副作用边界集中，业务函数保持可单测。"

**Census of the violation** (scan of `packages/`, 2026-06-15):

| Surface | Count | Where it lives |
|---|---|---|
| `gh`/`git` command builders | **148 functions** | `github-devloop/core/commands.lua` (87, 777 lines) · `core/branches.lua` (26, 483) · `github-proxy/core.lua` (21, 938) · + scattered across 12 more files |
| exec call sites (`exec_sync`/`gh_exec`) | **~240** | 26 departments + core; two **separate** `gh_exec` wrappers (`github-devloop/core/base.lua:918`, `github-proxy/core/gh_rate.lua:38`) |
| parsers (`parse_*` + inline `json.decode`) | **~145** | `github-devloop/core/parsers.lua` (878 lines) · `github-proxy/core.lua` · 10+ more |
| structured domain types | **1** (`source_ref`) | everything else is raw decoded tables; no `Issue`/`PR`/`Comment`/`Worktree` type |

**Three concrete symptoms of the tangle:**

1. **`github-proxy` is a *leaky, partial* adapter.** It is a write-side saga endpoint
   (schema `github-proxy.v1`) but its command builders are embedded in its own
   `core/*`, and **reads bypass it entirely**: `github-devloop` builds its own `gh`
   read commands directly and does **not** `require("github-proxy")` at all. So the
   same operation is implemented twice — e.g. `gh_issue_assign_cmd` exists in *both*
   `github-proxy/core/claims.lua` and `github-devloop/core/claims.lua`; entity views
   are duplicated in `github-proxy/core/entity_view.lua` and
   `github-devloop/core/github_proxy_entity_view.lua`.

2. **Business logic carries GitHub's vocabulary.** `github-proxy/core.lua` holds
   `current_devloop_state` / `compare_state_marker` (the devloop **state-machine**
   version-CAS) right next to `gh_issue_list_cmd` (a raw `gh api` string). The
   "decide" and the "spell the command" responsibilities are interleaved, so neither
   can be tested or changed without the other.

3. **Tests are coupled to command *strings*, not behavior.** ~100 tests mock by exact
   literal command string (`fkst.test.mock_command("git fetch 'origin' '"..branch.."'", …)`).
   Any change to flag order, quoting, or builder spelling reddens unrelated business
   tests. This is the standing brittleness tracked as **#633** ("harness over-couples
   to exact gh-command counts"); #678's worktree fix already broke four tests this way.

The user's north star for the whole repo: **"脚本可以用最简单的代码（没有重复代码）来表达
业务逻辑，框架把公共部分做好做稳定。"** Business should read like *domain decisions*; the
"common, stable part" (the `gh`/`git` mechanics) belongs in one solid, shared place.

## 2. Goal / Non-goals

**Goal.** Introduce a **Ports & Adapters (Hexagonal / anti-corruption) layer** for the
external `gh`/`git` world. Business departments speak **domain operations** over a port
(`read_issue(source_ref) -> Issue`, `set_labels(...)`, `ensure_worktree(...)`) and never
see a command string or stdout. One Tier R adapter in `std` (`std/github`, `std/git`) is
the **single** place that knows the `gh` CLI, GraphQL fields, `git` plumbing, and their
output formats. The pattern is shaped so `codex`/filesystem/network can become
`std/<x>` adapters of the **same shape** later (this spec implements `gh`+`git` only;
scope (a)).

**Non-goals.**
- **Not** `codex`/fs/network now — those are the generalization hook (§7), out of scope.
- **Not** a change to the **delivery topology**. Which writes are durable-event-mediated
  vs synchronous, and the `source_ref` / content-not-in-payload constitution, are
  **preserved exactly** (§5.4). This is a structural relocation of command-construction
  and parsing behind a port, not a redesign of reliable delivery.
- **Not** an engine change to *start*. Waves 0–3 use the existing `exec_sync` primitive
  and need **zero** fkst-substrate change. Only the optional Wave 4 fidelity gate
  consumes the substrate record-replay primitive (substrate #88) — and the refactor
  delivers its core value without it (§6).
- **Not** moving the devloop **state machine** out of `github-proxy`. That `current_devloop_state`
  lives in `github-proxy` is a real layering smell, but relocating state-machine
  *ownership* is a separate concern; this spec only extracts the `gh`/`git`
  **command+parse** surface and notes the rest as follow-up (§8).

## 3. Position in the `std` stack (how the three specs compose)

```
  std-shared-library  ──  the shelf + the doctrine (peer-require forbidden, std allowed)
        │                 (Tier S / Tier R; symlink vendoring; verified)
        ├── saga-harness  ── department CONTROL-FLOW shape:  std.department{done, act}
        │                    "来了就做，做过就不做";  ①②③ oracle;  stateful-truth fake
        └── ports-adapters ── department EXTERNAL-WORLD boundary:  domain ops over a port
   (THIS spec)               std/github + std/git;  Issue/PR/Comment types;  no command strings
```

The two department-level specs are **orthogonal axes of the same rewrite**:

- `saga-harness` decides *how a department's control flow is shaped*: `done(event)`
  (idempotency predicate, read-only, re-derives truth) and `act(event)` (effects).
- `ports-adapters` decides *what vocabulary `done`/`act` speak to the outside world*:
  domain operations, not `gh`/`git` strings.

They reinforce each other: `done(event)` **is** a read port call ("re-derive truth from
source" = `read_issue`/`read_pr`), and `act(event)` writes **are** write port calls. The
saga harness's "stateful external-truth fake" (an in-memory model of gh/marker state for
the ②-restart test) is, precisely, the **in-memory implementation of the port** this spec
defines (§6). So a department's migration ideally adopts **both** axes in one PR
(`done/act` + the port) rather than touching `main.lua` twice (§5.5 sequencing).

## 4. The dividing line: GitHub's vocabulary vs fkst's vocabulary

Every line of the 148 builders / 145 parsers belongs on exactly one side of a single
question — *whose vocabulary is this?*

| | **Adapter** (`std/github`, `std/git`, Tier R) | **Business** (departments + package `core`) |
|---|---|---|
| Knows | `gh` CLI flags, GraphQL field names, `git` plumbing, stdout/JSON shapes, shell quoting, rate-limit strings | the devloop state machine, marker schema `fkst:github-devloop:state:v1`, version-CAS order, dependency gates, consensus |
| Speaks | builds commands, runs `exec_sync`, parses output into **neutral** domain structs | calls port ops, receives domain structs, decides |
| Returns | `Issue`/`PullRequest`/`Comment`/`Worktree`/`Ref`/`CheckRuns`/`MergeResult` | events, markers, state transitions |
| Never | mentions `fkst:…` markers, devloop states, consensus | mentions `gh `, `git `, `--json`, `shell_single_quote`, `json.decode` |

Worked boundary cases (the rule resolves each unambiguously):

- `parse_issue_state` (decode `gh` JSON → labels/assignees/comments) → **adapter** (GitHub vocabulary).
- `current_devloop_state` (regex-pull `fkst:…:state:v1` markers + version-CAS) → **business**
  (fkst vocabulary). The adapter hands back `Comment{author_login, body, …}`; the package's
  marker parser reads the bodies. The adapter never learns the marker grammar.
- "filter comments to the trusted bot" → **business** owns the *policy* (which login is
  trusted is fkst config); the adapter merely surfaces `author_login`.
- `shell_single_quote`, `is_git_ref_safe`, `url_encode` → **adapter** private toolkit
  (mechanics of spelling a safe command).

## 5. Architecture

### 5.1 The port (domain operations)

There is no `interface` keyword in Lua; the **port is the documented public surface** of
`std.github` / `std.git` plus the domain type shapes (§5.2). Business `require("std.github")`
/ `require("std.git")` (the blessed `all→std` direction; no peer require, no G9 violation)
and depends only on this surface.

**Reads — synchronous ("re-derive truth from source"):**

| Operation | Returns | Replaces (today) |
|---|---|---|
| `github.read_issue(source_ref)` | `Issue` (with comments, labels, assignees, blocked_by) | `gh issue view`/REST + `parse_issue_state` |
| `github.read_pr(source_ref)` | `PullRequest` | `gh pr view` + `parse_pr_view_head_state` |
| `github.read_pr_diff(source_ref)` | `string` (full diff, no truncation — caller is in-process) | `gh pr diff` |
| `github.list_open_issues(repo)` | `{Issue,…}` (summary) | `gh api …/issues` + `parse_entity_list` |
| `github.list_open_prs(repo)` | `{PullRequest,…}` | `gh api …/pulls` |
| `github.find_pr_for_head(repo, branch, base?)` | `PullRequest \| nil` | `gh_pr_list_head_cmd` + `parse_pr_list_for_head` |
| `github.read_check_runs(repo, sha)` | `CheckRuns` | `gh_commit_check_runs` |
| `github.read_blocked_by(source_ref)` | `{source_ref,…}` | GraphQL `blockedBy` |
| `github.list_repo_labels(repo)` | `{name,…}` | `gh label list` + `parse_repo_labels` |
| `git.show_ref(branch)` | `Ref \| nil` | `git show-ref` + `parse_git_show_ref_head` |
| `git.is_ancestor(a, b)` | `bool` | `git merge-base --is-ancestor` |
| `git.remote_branch_head(branch)` | `sha \| nil` | `git ls-remote` |
| `git.merge_tree_empty_delta(base, head)` | `bool` | `git merge-tree` |
| `git.list_worktrees()` | `{Worktree,…}` | `git worktree list` |

**Writes — GitHub mutations, delivery topology unchanged (§5.4):** business emits a
durable **write-intent** event (schema `github-proxy.v1`, carrying `source_ref` + control
fields, **never content**); the `github-proxy` department consumes it and calls the
adapter **execute** op. Same op names name both the intent and the execution:

| Operation | Returns |
|---|---|
| `github.create_issue(intent)` | `Issue` |
| `github.post_comment(target_ref, body_source)` | `Comment` (body via `--body-file`, from source, not payload) |
| `github.set_labels(target_ref, add, remove)` | `bool` (level-reconcile; ensures repo labels exist) |
| `github.set_blocked_by(blocked_ref, blocker_ref)` | `bool` (GraphQL `addBlockedBy`; #660's `issueId` fix preserved) |
| `github.assign/unassign(issue_ref, login)` | `bool` |
| `github.create_pr(intent)` | `PullRequest` |
| `github.merge_pr(pr_ref, opts)` | `MergeResult` (`gh pr merge --merge --match-head-commit`) |
| `github.close_issue(issue_ref)` | `bool` |

**Local `git` writes — synchronous within a department worktree (idempotent; not saga-mediated; topology unchanged):**

| Operation | Note |
|---|---|
| `git.ensure_worktree(branch, path)` → `Worktree` | **idempotent**; the #678 force-clean (`worktree remove --force; rm -rf; prune`) lives *inside* this op, not at call sites |
| `git.fetch(branch)` / `fetch_pr_head(pr)` / `fetch_pr_merge(pr)` | |
| `git.commit(worktree, message)` → `sha` · `git.push(branch, opts)` | `opts`: normal / force-with-lease / update |
| `git.merge_no_ff(...)` / `fast_forward(...)` / `force_clean_worktree(path)` | |

### 5.2 Domain types (neutral GitHub structs — `std/github/types.lua`)

Constructors + validators; **no fkst vocabulary**. Shapes derived from the current
inline parsers so the move is behavior-preserving:

```
Issue        = { number, title, body, state,            -- state: "OPEN"|"CLOSED"
                 author, assignees={login,…}, labels={name,…},
                 comments={Comment,…}, blocked_by={source_ref,…}, url, updated_at }
PullRequest  = { number, title, body, state,
                 head_ref_name, head_ref_oid, base_ref_name,
                 head_repository, is_cross_repository,    -- "owner/repo" | nil
                 mergeable, merge_state_status,
                 labels={…}, comments={…}, url, updated_at }
Comment      = { id, author_login, body, created_at, updated_at }
Worktree     = { path, branch, head_sha }
Ref          = { branch, head_sha }
CheckRuns    = { status, conclusion }
MergeResult  = { merged, sha }
```

`source_ref` stays **Tier S** (`std/source_ref.lua`, per the std-shared-library drain §8)
and is reused unchanged as the read/write addressing token. The adapter is the boundary
that turns a `source_ref` into a fetched struct and back.

### 5.3 The adapter internals (file layout respects the 1000-line cap)

The targets are large (777/483/878/938 lines); a flat `std/github.lua` would blow the
hard cap immediately. The adapter is therefore **multi-file, split by stable
responsibility** (SRP), with thin entry aggregators:

```
std/
  github.lua            -- entry: aggregates submodules, exposes the port surface
  github/
    shell.lua           -- shell_single_quote, url_encode, is_git_ref_safe, validators (private toolkit)
    exec.lua            -- the ONE canonical gh_exec wrapper (rate-limit detection, error_class facts)
    types.lua           -- §5.2 constructors + validators
    issue.lua           -- read_issue / list_open_issues / create_issue / close_issue / assign  (+ builders+parsers)
    pr.lua              -- read_pr / read_pr_diff / list_open_prs / find_pr_for_head / create_pr / merge_pr
    comment.lua         -- post_comment / comment reads
    label.lua           -- set_labels / list_repo_labels / ensure_repo_label
    graphql.lua         -- blocked_by / node-id / named GraphQL constants (from core/github_graphql.lua)
    check.lua           -- read_check_runs / dispatch_ci
  git.lua               -- entry
  git/
    exec.lua            -- git exec wrapper
    worktree.lua        -- ensure_worktree / list_worktrees / force_clean (#678)
    branch.lua          -- fetch / push / show_ref / is_ancestor / remote_branch_head
    diff.lua            -- diff_check / merge_tree_empty_delta / unmerged_paths / conflict_markers
    merge.lua           -- merge_no_ff / fast_forward
```

The 148 builders and 145 parsers become these submodules' **private** functions; only the
domain ops are public. The two `gh_exec` wrappers (`base.lua` + `gh_rate.lua`) collapse
into one `github/exec.lua`. **Nested-require risk (R1):** the std spec only verified
*flat* `require("std.saga")`. `require("std.github.issue")` resolves under the **same**
`?.lua` package.path substitution (`std.github.issue` → `std/github/issue.lua`), one
directory deeper. Wave 0 includes a spike to confirm this; if the engine loader rejects
nested dirs, fall back to flat naming (`std/github_issue.lua`, `require("std.github_issue")`)
— same modules, flatter paths, verified-to-resolve.

### 5.4 Read/write delivery topology — preserved exactly

The refactor is **behavior-preserving**: it changes *how a command is built and parsed*,
never *which path carries the effect*. Concretely:

- **Reads** were already synchronous in-process; they stay synchronous — the port op
  wraps build+exec+parse. This realizes "回源 derive 真相" cleanly (the adapter fetches,
  business decides) with no payload-staleness.
- **GitHub mutations** that go through the `github-proxy.v1` durable saga today still do
  — the only change is the saga's executor calls `std.github.<write_op>` instead of an
  inline command. The constitution holds: **content stays out of the payload** (the port
  takes a `source_ref` + a body *source*, not body text), reliable delivery + idempotent
  markers are untouched.
- **Local `git` writes** done synchronously in a worktree (implement/fix/merge) stay
  synchronous; they move behind `std.git` ops with the idempotency (e.g. #678) folded
  into the op.

### 5.5 `github-proxy` transformation + the exec/error consolidation

- **`github-proxy` becomes a thin write-side saga endpoint over `std.github`.** Its
  command builders + GitHub-JSON parsers move into `std/github`; its departments, on
  consuming a write-intent, call `std.github.<write_op>`. The duplicated builders
  (`claims`, `entity_view`) collapse to one shared copy. `github-devloop`'s reads call
  `std.github` directly. End state: **one adapter, zero duplication**, `github-proxy` =
  pure saga wiring.
- **One `gh_exec`.** `github-devloop/core/base.lua:918` and `github-proxy/core/gh_rate.lua:38`
  unify into `std/github/exec.lua` (rate-limit detection + `error_class`/`fingerprint`
  facts). `error_facts.lua`'s GitHub error taxonomy (`gh-rate-limited`/`gh-command-failed`)
  moves with it (Tier R; the *generic* L1/L2 error-fact shape stays Tier S).

**Sequencing with saga-harness.** Both refactors rewrite the same ~20 department
`main.lua` files. To avoid double-touching, a department's migration PR adopts **both**:
`std.department{done, act}` **and** port ops inside `done`/`act`. The port lands *with or
just before* the `done/act` rewrite, because `done` = a read port call and `act` = write
port calls — the port is the natural vocabulary for those bodies.

## 6. Test boundary (the payoff: behavior, not strings)

Today ~100 business tests mock exact command strings (#633 brittleness). After the
refactor the boundary is a **port**, so:

1. **Business unit tests mock at the port.** They inject an **in-memory port
   implementation** and assert on **domain operations** — `assert post_comment called once
   with target=issue#42`, `read_pr returns PullRequest{state="OPEN", head_ref_oid=…}`.
   Counting "`post_comment` invoked once" is **stable across any command-spelling change**.
   This is the structural resolution of **#633**: a worktree-fix like #678 can never again
   redden an unrelated review test.

2. **The in-memory port is the saga-harness "stateful external-truth fake."** The
   saga-harness ①②③ oracle needs an in-memory gh/marker model that records delivery-1's
   writes and serves them as delivery-2's reads. That fake **is** the in-memory
   implementation of this port. This spec gives it a **typed domain-op surface** instead
   of a command-string model, so the oracle's "write-class command multiset compared
   between delivery 1 and 2" upgrades to "**write-intent multiset at the port**" — cleaner,
   decoupled from spelling, and shared by every department test.

3. **The real adapter is tested once, in isolation, for API-contract fidelity.** Only
   `std/github`'s own tests verify "this domain op builds *this* command and parses *that*
   stdout shape." This is the **single** place command-string coupling is allowed to
   exist — shrinking it from ~100 business tests to ~one adapter suite. When the substrate
   **record-replay** primitive (substrate #88) lands, those become golden cassette tests
   (record real `gh`/`git` I/O once, replay deterministically). **Until #88**, the adapter
   keeps a thin set of command-string contract tests — but the brittleness is now
   *concentrated*, not spread. The refactor's core value does not block on #88.

This directly serves "让问题都在测试解决": business tests become readable domain assertions,
and the one brittle seam is isolated where it can be hardened independently.

## 7. Generalization hook (out of scope, same shape later)

`codex`, filesystem, and network are the same anti-corruption pattern. Projects 2+ add
`std/codex` (`run_consensus_angle(prompt, opts) -> AngleResult` over `spawn_codex_sync`),
`std/fs`, `std/net` — each a Tier R adapter exposing domain ops, each with an in-memory
port double for tests, each forbidding raw command/IO construction outside itself. This
spec deliberately ships **only** `gh`+`git` (scope (a)) and proves the shape; nothing here
hard-codes "GitHub" into the *pattern*, only into the `std/github` instance.

## 8. Conformance teeth (the "严格约束" — make the boundary permanent)

A new `scripts/check_repo.py` G-gate (ratchet, same mechanism as saga-harness's
allowlist):

- **No command construction outside the adapter.** A string literal matching `^gh%s` or
  `^git%s` (command head) may appear **only** under `std/github/` and `std/git/`. Anywhere
  else is red. During migration this is an allowlist that **only shrinks** (per file/dept),
  monotonically driving the 148 builders into the adapter.
- **No direct exec of gh/git outside the adapter.** `exec_sync`/`gh_exec` of a gh/git
  command outside `std/github|git` is red (codex/other exec unaffected).
- **Port-only dependency.** Packages reach the gh/git world only via `require("std.github")`
  / `require("std.git")`; peer cross-package require stays banned (existing G9).

These are the physical enforcement of CLAUDE.md's Adapter doctrine — "副作用边界集中" stops
being aspirational.

## 9. Migration — strangler in waves (coordinated, behavior-preserving)

Each wave is independently mergeable and CI-gated; the big mechanical waves preserve
command strings so existing string-mocks stay green until a dept is deliberately flipped.

- **Wave 0 — Foundations (one PR, behavior-neutral).** Create `std/github` + `std/git`
  skeleton + entry aggregators; spike-verify nested `require("std.github.issue")` (R1
  fallback decided here); define `types.lua`; consolidate the **one** `gh_exec`/`git_exec`
  wrapper. No call sites change yet.
- **Wave 1 — Relocate builders+parsers UNCHANGED (CI is the oracle).** Move the 148
  builders + 145 parsers from `commands.lua`/`branches.lua`/`parsers.lua`/`github-proxy`
  into the adapter submodules verbatim (identical command strings); dedup the duplicated
  builders; old call sites call `std.github.<builder>` (still low-level, transitional).
  Existing string-mocks stay green. This is the bulk move.
- **Wave 2 — Lift to domain ops + migrate READS dept-by-dept.** Add the high-level read
  ops; flip read-side depts (intake_scan, observe_issue, observe_pr, reconcile, queue) one
  at a time to call domain ops; rewrite *those* depts' tests to mock at the port.
  Coordinate with saga-harness Phase 2 (adopt `done/act` in the same PR). Reads first —
  idempotent, lowest risk.
- **Wave 3 — Migrate WRITES through the port.** `github-proxy` depts + `github-devloop`
  sync `git` writes call port write ops; rewrite write-dept tests to assert write-intents;
  `github-proxy` becomes thin saga wiring; turn the §8 ratchet on for migrated files.
- **Wave 4 — Adapter fidelity gate (depends on substrate #88; optional/deferred).** Add
  golden record-replay cassettes at `std/github`; flip the §8 gate to fully closed (zero
  gh/git construction outside the adapter). Until #88, Wave 3's concentrated command-string
  adapter tests carry fidelity.

Each wave decomposes into per-dept issues sized for the autonomous devloop. Waves 0–1 are
foundational (out-of-band or single PRs); Waves 2–3 are ideal dogfood (one small dept PR
each).

## 10. Risks / open questions

- **R1 — nested `std/` require unverified.** Mitigation: Wave 0 spike; flat-naming
  fallback (§5.3). Cheap, decided before any bulk move.
- **R2 — collision with the concurrent saga-harness dept rewrite.** Both touch every
  `main.lua`. Mitigation: §5.5 sequencing — one PR per dept adopts both axes; the port is
  the vocabulary `done`/`act` already need.
- **R3 — behavior drift during the bulk relocation (Wave 1).** 148 builders moved by hand
  could silently change a command string. Mitigation: Wave 1 is a *pure* move (strings
  byte-identical), and the existing ~100 string-mocks are the regression oracle — they
  *must* stay green through Wave 1 precisely because they pin the strings. They are rewritten
  to port-level only in Waves 2–3, after relocation is proven.
- **R4 — 1000-line cap during the move.** The adapter is pre-split by responsibility
  (§5.3) so no submodule approaches the cap; `parsers.lua` (878) and `commands.lua` (777)
  *shrink* as their contents distribute across `issue/pr/comment/label/graphql`.
- **R5 — `read_pr_diff` and large content.** Reads return full content **in-process** to
  the caller (no payload, no truncation) — consistent with the content-not-in-payload
  constitution, which constrains *delivery payloads*, not in-process port returns. The port
  must not be (mis)used to stuff diff text into a durable event; §5.4 keeps writes
  `source_ref`-addressed.
- **R6 — state-machine vocabulary still in `github-proxy`.** `current_devloop_state` /
  version-CAS remain business logic mislocated in `github-proxy`. Out of scope here (§2);
  noted as a follow-up once the gh/git surface is clean (the parsers it depends on will by
  then live in `std/github`, making the later move smaller).

## 11. Substrate dependencies (what is package-side vs fkst-substrate)

| Item | Home | Blocking? |
|---|---|---|
| `std/github` + `std/git` adapter, port, domain types, dept migration, port-level tests | **fkst-packages** (this repo) | core deliverable; Waves 0–3 |
| `exec_sync` primitive (already exists) | fkst-substrate | already available; no change |
| Record-replay test mode (cassette record/replay) | fkst-substrate **#88** | **non-blocking** — only Wave 4's gold fidelity gate; Waves 0–3 ship without it |

The package-side refactor (Waves 0–3) is self-contained and needs **no** engine change —
the strongest de-risking property of this design.

⟦AI:FKST⟧
