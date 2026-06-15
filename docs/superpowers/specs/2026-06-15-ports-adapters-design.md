# Design: Ports & Adapters — a `gh`/`git` anti-corruption layer in `std`

Status: proposal v2 · Date: 2026-06-15 · Repo: fkst-packages
Builds on (read these first):
- `2026-06-14-std-shared-library-design.md` — the `std/` shelf, the Tier S/R split, the symlink vendoring, and the doctrine that earmarks **`gh`-shaped helpers as Tier R**. This spec puts the largest Tier R inhabitant on that shelf.
- `2026-06-14-saga-harness-design.md` — the `std.department{done,act}` department shape and its ①②③ idempotency oracle. §6 of this spec composes that Tier S oracle with Tier R GitHub/git fakes without making the oracle depend on GitHub types.

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

**Goal.** Introduce a **Ports & Adapters (Hexagonal / anti-corruption) boundary** for
the external `gh`/`git` world. The boundary has three explicit surfaces:

- **S1 neutral adapters** in Tier R `std.github` / `std.git`: build commands, execute
  them, parse stdout, and return neutral normalized Lua tables.
- **S2 package-owned write intents**: durable request schemas such as
  `github-proxy.v1`, carrying `source_ref`, small control fields, and `body_source`
  handles, not rendered content.
- **S3 package-owned marker/CAS guards**: trusted-bot filtering, marker grammar,
  current state, version-CAS, and expected proposal/state/version checks under the
  existing per-entity locks.

Business departments call S1 for synchronous reads, raise S2 for durable writes, and
run S3 before any guarded write execution. The core intent is unchanged: packages stop
spelling `gh`/`git` commands in business logic, and tests assert behavior at the port or
intent boundary instead of literal shell strings.

**Non-goals.**
- **Not** `codex`/fs/network now. They may use the same pattern later, but this plan
  emits no tasks for them (§7).
- **Not** a change to the **delivery topology**. Which writes are durable-event-mediated
  vs synchronous, and the `source_ref` / content-not-in-payload constitution, are
  **preserved exactly** (§5.4). This is a structural relocation of command-construction
  and parsing behind an adapter, plus a sharper write-intent/guard split.
- **Not** an engine change. Waves 0 and all vertical slices use the existing `exec_sync`
  primitive and need **zero** fkst-substrate change.
- **Not** moving the devloop **state machine** out of `github-proxy`. That
  `current_devloop_state` lives in `github-proxy` is a real layering smell, but
  relocating state-machine *ownership* is a separate concern; this spec extracts the
  `gh`/`git` **command+parse mechanics** and notes the rest as follow-up (§10 R6).

## 3. Position in the `std` stack (how the three specs compose)

```
  std-shared-library  ──  the shelf + the doctrine (peer-require forbidden, std allowed)
        │                 (Tier S / Tier R; symlink vendoring; verified)
        ├── saga-harness  ── department CONTROL-FLOW shape:  std.department{done, act}
        │                    "来了就做，做过就不做";  ①②③ oracle
        └── ports-adapters ── EXTERNAL-WORLD boundary: neutral gh/git adapters,
   (THIS spec)               package write intents, package marker/CAS guards
```

The two department-level specs are **orthogonal axes of the same rewrite**:

- `saga-harness` decides *how a department's control flow is shaped*: `done(event)`
  (idempotency predicate, read-only, re-derives truth) and `act(event)` (effects).
- `ports-adapters` decides *what vocabulary `done`/`act` speak to the outside world*:
  neutral adapter reads, durable write intents, and package-owned guards, not raw
  `gh`/`git` strings.

They reinforce each other: `done(event)` usually re-derives truth through an S1 read
operation (`read_issue`/`read_pr`), and `act(event)` either raises an S2 write intent or
executes a local `std.git` operation. A department's migration should adopt **both** axes
in one vertical slice (`done/act` + port/intent vocabulary) rather than touching
`main.lua` twice (§9).

## 4. The Three Surfaces

The old dividing question "GitHub vocabulary vs fkst vocabulary" is still useful, but it
is not enough. Guarded writes need a third home. Every line in the 148 builders / 145
parsers belongs to one of these surfaces:

| Surface | Owner / home | Knows | Speaks | Never |
|---|---|---|---|---|
| **S1 neutral adapter** | Tier R `std.github` / `std.git` | `gh` CLI flags, GraphQL field names, `git` plumbing, stdout/JSON shapes, shell quoting, rate-limit strings | adapter handle operations such as `github.read_issue`, `github.create_pr`, `git.ensure_worktree`; returns neutral normalized Lua tables | marker grammar, devloop states, trusted-bot policy, proposal IDs, version-CAS, consensus |
| **S2 write-intent layer** | package queues + payload schemas, primarily `github-proxy.v1` | durable delivery schema, `source_ref`, `dedup_key`, expected proposal/state/version control fields, `body_source` / `title_source` handles | intent names such as `github_issue_comment_request`, `github_issue_create_request`, `github_pr_open_request`, `github_issue_label_request` | command strings, stdout parsers, hidden rendered bodies |
| **S3 marker/CAS guard modules** | package-owned modules under package root / departments | trusted-bot filter, `current_devloop_state`, marker schemas, version-CAS order, expected proposal/state/version/head checks, dependency gate policy | guarded-write decisions made under existing `with_lock` keys before S1 execution | `gh`/`git` flag spelling, GraphQL field strings, low-level shell quoting |

S2 operation names are intentionally **distinct** from S1 execute operation names. For
example, `github-proxy.github_pr_open_request` is a durable intent; `github.create_pr`
is the neutral adapter execution. The same name must not mean both "request this durable
effect" and "run this CLI command."

Worked boundary cases:

| Case | Surface | Reason |
|---|---|---|
| `parse_issue_state` / REST comment parsing | **S1** | decode GitHub JSON into neutral tables |
| `gh_issue_view_loop_cmd`, `gh_pr_diff`, `shell_single_quote`, `url_encode`, `is_git_ref_safe` | **S1** | command spelling and shell mechanics |
| `github_issue_comment_request` payload validation | **S2** | durable request schema and bounded control fields |
| `current_devloop_state`, `compare_state_marker`, `merge_ready_fact` | **S3** | marker grammar and version-CAS are fkst policy |
| "filter comments to the trusted bot" | **S3** | the adapter only surfaces `author_login`; trust is package policy |
| "check current state before writing labels/comment/PR marker" | **S3 before S1** | guarded-write business logic belongs in the package, under the entity lock |

## 5. Architecture

### 5.1 Public surfaces and operations

There is no `interface` keyword in Lua; the surfaces are documented module contracts plus
tests. Packages use the blessed `all→std` direction (`require("std.github")` /
`require("std.git")`) for S1, package queues for S2, and package modules for S3. No peer
package require is introduced.

**S1 reads — synchronous ("re-derive truth from source"):**

| Operation | Returns | Replaces (today) |
|---|---|---|
| `github.read_issue(source_ref)` | neutral issue table with comments, labels, assignees, blocked_by | `gh issue view`/REST + `parse_issue_state` |
| `github.read_pr(source_ref)` | neutral PR table | `gh pr view` + `parse_pr_view_head_state` |
| `github.read_pr_diff(source_ref)` | `string` (full diff, no truncation — caller is in-process) | `gh pr diff` |
| `github.list_open_issues(repo)` | `{issue_summary,...}` | `gh api …/issues` + `parse_entity_list` |
| `github.list_open_prs(repo)` | `{pr_summary,...}` | `gh api …/pulls` |
| `github.find_pr_for_head(repo, branch, base?)` | PR summary or `nil` | `gh_pr_list_head_cmd` + `parse_pr_list_for_head` |
| `github.read_check_runs(repo, sha)` | check-run summary | `gh_commit_check_runs` |
| `github.read_blocked_by(source_ref)` | `{source_ref,...}` | GraphQL `blockedBy` |
| `github.list_repo_labels(repo)` | `{name,...}` | `gh label list` + `parse_repo_labels` |
| `git.show_ref(branch)` | ref table or `nil` | `git show-ref` + `parse_git_show_ref_head` |
| `git.is_ancestor(a, b)` | `bool` | `git merge-base --is-ancestor` |
| `git.remote_branch_head(branch)` | `sha` or `nil` | `git ls-remote` |
| `git.merge_tree_empty_delta(base, head)` | `bool` | `git merge-tree` |
| `git.list_worktrees()` | `{worktree,...}` | `git worktree list` |

**S1 execute operations — mechanics only, called after S3 where guards are needed:**

| Operation | Returns | Notes |
|---|---|---|
| `github.create_issue(request)` | issue table | takes title/body sources resolved by the executor, not a durable payload body |
| `github.create_comment(target_ref, body_source)` | comment table | writes via `--body-file`; adapter resolves body source to a temp file |
| `github.edit_comment(comment_ref, body_source)` | comment table | command mechanics only; stale-target classification belongs to adapter, retry policy to package |
| `github.reconcile_labels(target_ref, add, remove)` | `bool` | ensures repo labels exist; S3 decides whether the label write is still allowed |
| `github.add_blocked_by(blocked_ref, blocker_ref)` | `bool` | GraphQL `addBlockedBy`; #660's `issueId` fix stays in the adapter mechanics |
| `github.assign_issue(issue_ref, login)` / `github.unassign_issue(issue_ref, login)` | `bool` | assignee claim policy remains package-owned |
| `github.create_pr(request)` | PR table | adapter push/create mechanics only; S3 validates state/head/claim first |
| `github.merge_pr(pr_ref, opts)` | merge result table | `gh pr merge --merge --match-head-commit`; merge authorization remains S3 |
| `github.close_issue(issue_ref)` | `bool` | command execution only |

**S2 durable write intents — package-owned request schemas:**

| Intent / queue | Carries |
|---|---|
| `github_issue_comment_request` / `github_pr_comment_request` | target `source_ref`, `dedup_key`, replace/hand-off control fields, `body_source` |
| `github_issue_create_request` | parent/lineage control fields, `dedup_key`, labels/assignees, `title_source`, `body_source` |
| `github_pr_open_request` | issue `source_ref`, branch/head/base control, expected proposal/state/version/head, `title_source`, PR `body_source`, issue-comment `body_source` |
| `github_issue_label_request` / `github_pr_label_request` | target `source_ref`, expected proposal/state/version, add/remove labels |
| `github_issue_blocked_by_request` | blocked/blocking `source_ref`, `dedup_key`, marker body source |

**S3 guarded-write modules — package-owned policy:**

Each guarded write slice introduces or reuses a small package module that runs under the
current per-entity lock before S1 execution. Examples: `comment_guard`, `label_guard`,
`pr_open_guard`, `merge_guard`, `blocked_by_guard`. These modules read current neutral
comments/issues/PRs through S1, apply trusted-bot filtering and marker/CAS policy, and
return a narrow decision (`apply`, `already_done`, `stale`, `blocked`) plus the exact S1
execute request. They do not build command strings.

**Local `git` writes — synchronous within a department worktree (idempotent; not saga-mediated; topology unchanged):**

| Operation | Note |
|---|---|
| `git.ensure_worktree(branch, path)` → worktree table | **idempotent**; the #678 force-clean (`worktree remove --force; rm -rf; prune`) lives *inside* this op, not at call sites |
| `git.fetch(branch)` / `fetch_pr_head(pr)` / `fetch_pr_merge(pr)` | command mechanics behind the adapter |
| `git.commit(worktree, message)` → `sha` · `git.push(branch, opts)` | `opts`: normal / force-with-lease / update |
| `git.merge_no_ff(...)` / `fast_forward(...)` / `force_clean_worktree(path)` | |

### 5.2 Neutral normalized return shapes, grown per operation

Do **not** front-load a full `Issue`/`PullRequest`/`Comment`/`Worktree` constructor and
validator universe. v1 uses **per-operation documented plain Lua tables**, grown only as
vertical slices need them. A shared type module emerges by Rule-of-Three: when three or
more public operations share the same shape and tests would otherwise duplicate shape
normalization, extract that shape into `std/github/types.lua` or `std/git/types.lua`.

Initial slice examples:

```
read_issue(source_ref) -> {
  number, title, body, state, url, updated_at,
  author_login,
  assignees = { login, ... },
  labels = { name, ... },
  comments = { { id, author_login, body, created_at, updated_at }, ... },
  blocked_by = { source_ref, ... },
}

read_pr(source_ref) -> {
  number, title, body, state, url, updated_at,
  head_ref_name, head_ref_oid, base_ref_name,
  head_repository, is_cross_repository,
  mergeable, merge_state_status,
  labels = { name, ... },
  comments = { { id, author_login, body, created_at, updated_at }, ... },
}

git.list_worktrees() -> {
  { path, branch, head_sha }, ...
}
```

`source_ref` stays **Tier S** (`std/source_ref.lua`, per the std-shared-library drain
§8) and is reused unchanged as the read/write addressing token. S1 is the boundary that
turns a `source_ref` into a fetched neutral table; S3 interprets that table using package
marker/CAS policy.

### 5.3 Adapter internals (file layout respects the 1000-line cap)

The targets are large (777/483/878/938 lines); a flat `std/github.lua` would blow the
hard cap immediately. The adapter is therefore **multi-file, split by stable
responsibility** (SRP), with thin entry aggregators:

```
std/
  github.lua            -- entry: exposes new(exec), no module-global mutable handle
  github/
    shell.lua           -- shell_single_quote, url_encode, is_git_ref_safe, validators (private toolkit)
    exec.lua            -- the ONE canonical gh_exec wrapper (rate-limit detection, error_class facts)
    issue.lua           -- read_issue / list_open_issues / create_issue / close_issue / assign
    pr.lua              -- read_pr / read_pr_diff / list_open_prs / find_pr_for_head / create_pr / merge_pr
    comment.lua         -- create_comment / edit_comment / comment reads
    label.lua           -- reconcile_labels / list_repo_labels / ensure_repo_label
    graphql.lua         -- blocked_by / node-id / named GraphQL constants (from core/github_graphql.lua)
    check.lua           -- read_check_runs / dispatch_ci
    types.lua           -- created later only when Rule-of-Three justifies shared shapes
  git.lua               -- entry: exposes new(exec)
  git/
    exec.lua            -- git exec wrapper
    worktree.lua        -- ensure_worktree / list_worktrees / force_clean (#678)
    branch.lua          -- fetch / push / show_ref / is_ancestor / remote_branch_head
    diff.lua            -- diff_check / merge_tree_empty_delta / unmerged_paths / conflict_markers
    merge.lua           -- merge_no_ff / fast_forward
```

Builders and parsers move only when their **own vertical slice** moves. Inside the
adapter they are **private** helpers for one public domain operation; no public
low-level builder API is exposed and no transitional shim is left behind. The two
`gh_exec` wrappers (`base.lua` + `gh_rate.lua`) collapse into one `github/exec.lua`.

**Nested-require risk (R1):** the std spec only verified *flat*
`require("std.saga")`. `require("std.github.issue")` resolves under the **same** `?.lua`
package.path substitution (`std.github.issue` → `std/github/issue.lua`), one directory
deeper. Wave 0 includes a spike to confirm this; if the engine loader rejects nested
dirs, fall back to flat naming (`std/github_issue.lua`, `require("std.github_issue")`)
— same modules, flatter paths, verified-to-resolve.

### 5.4 Read/write delivery topology and `body_source`

The refactor is **behavior-preserving** only if it changes *how a command is built and
parsed*, never *which path carries the effect*. Concretely:

- **Reads** were already synchronous in-process; they stay synchronous. The S1 operation
  wraps build+exec+parse. This realizes "回源 derive 真相" cleanly (the adapter fetches,
  business decides) with no payload-staleness.
- **GitHub mutations** that go through `github-proxy.v1` durable requests today still do
  — the executor calls S1 after S3 accepts the write. Reliable delivery, idempotent
  markers, and per-entity locks are untouched.
- **Local `git` writes** done synchronously in a worktree (implement/fix/merge) stay
  synchronous; they move behind `std.git` operations with idempotency (e.g. #678) folded
  into the operation.

The content-not-in-payload constitution needs one explicit contract for authored bot
text. A bot-authored body (comment body, issue body, PR body) is content, and often it is
**not** re-derivable from the target `source_ref`. Current intents already carry raw
`body`/`title` fields (`github-proxy` comment, issue-create, and pr-open requests). A
write slice is not behavior-preserving until those are converted.

S2 payloads may carry only `source_ref`, bounded control fields, and text **handles**:

```
body_source = {
  kind = "template",
  template = "github-devloop.reviewing-comment.v1",
  source_ref = { kind = "external", ref = "owner/repo#issue/42" },
  params = { proposal_id = "...", version = "...", pr_number = 7 }
}

body_source = {
  kind = "artifact",
  artifact_ref = "github-devloop/comment-body/<dedup-key>",
  sha256 = "...",
  media_type = "text/markdown"
}
```

The preferred form is deterministic re-derivation at execute time: a template id plus
source-derived inputs and small bounded params are rendered on every delivery. Nothing
is stored in the payload, and retry/idempotency sees the same rendered text. The same
contract applies to `title_source` for issue/PR titles.

For genuinely non-re-derivable authored text, the full text must live in a durable
artifact addressed by `artifact_ref`; the payload carries only that handle plus an
integrity digest. It must not live in `<RT>` scratch, must not be truncated, and must not
be hidden in hex/base64/byte escapes. If a chosen write slice has neither a deterministic
template nor a durable artifact handle for its current `body`/`title`, that slice cannot
land: moving the command would otherwise silently change reliable-delivery semantics.

### 5.5 `github-proxy` transformation + exec/error consolidation

- **`github-proxy` stops owning gh/git command+parse mechanics.** Its GitHub command
  builders and GitHub-JSON parsers move slice-by-slice into `std.github`; its
  departments consume S2 intents, run S3 guards under the existing locks, then call S1
  execute operations. `github-devloop` read paths call S1 directly. Duplicated builders
  (`claims`, `entity_view`) collapse when the relevant slice lands.
- **`github-proxy` does not become "pure saga wiring" in this spec.** State-machine
  ownership remains where it is for now. Marker/CAS guard logic is explicitly package
  business logic (S3), not adapter logic. Moving that state-machine vocabulary out of
  `github-proxy` is R6 future work after the gh/git mechanics are clean.
- **One `gh_exec`.** `github-devloop/core/base.lua:918` and
  `github-proxy/core/gh_rate.lua:38` unify into `std/github/exec.lua` (rate-limit
  detection + `error_class`/`fingerprint` facts). `error_facts.lua`'s GitHub error
  taxonomy (`gh-rate-limited`/`gh-command-failed`) moves with it (Tier R; the *generic*
  L1/L2 error-fact shape stays Tier S).

**Sequencing with saga-harness.** Both refactors rewrite the same ~20 department
`main.lua` files. To avoid double-touching, a department's vertical slice adopts **both**:
`std.department{done, act}` **and** port/intent/guard vocabulary inside `done`/`act`.
The port lands *with or just before* the `done/act` rewrite, because `done` = an S1 read
and `act` = an S2 intent or S1/S3 write.

### 5.6 Injection seam (the #633 load-bearing mechanism)

The adapter is obtained through an explicit constructor, not by monkey-patching a cached
Lua module:

```
local github_mod = require("std.github")
local git_mod = require("std.git")

local ports = {
  github = github_mod.new(exec_sync),
  git = git_mod.new(exec_sync),
}
```

`std.github.new(exec)` and `std.git.new(exec)` return handles whose operations are bound
to the injected `exec` primitive. If `exec` is missing, the constructor fails loudly.
The handle has no hidden mutable singleton and no module-level fake switch.

Departments create the handle at the pipeline boundary and pass it into helpers:

```
local function done(event, ports)
  local issue = ports.github.read_issue(event.payload.source_ref)
  ...
end
```

Tests use the same seam in two ways:

- adapter contract tests call `std.github.new(fake_exec)` / `std.git.new(fake_exec)` and
  assert command construction + parse behavior in one isolated suite;
- business tests inject Tier R fakes such as `std.github.fake.new(model)` and assert
  domain reads, S2 intents, and S3 guard decisions without ever matching command strings.

This mirrors existing package-side injection precedent (`read_env(name, exec)`,
`gh_exec(..., exec)`) and makes the #633 payoff real: command spelling is swappable at
the adapter boundary, not through global monkey-patching.

## 6. Test boundary (the payoff: behavior, not strings)

Today ~100 business tests mock exact command strings (#633 brittleness). After the
refactor the test boundary is split by the same three surfaces:

1. **Business tests inject ports through §5.6.** They use Tier R fakes and assert on
   neutral reads, durable S2 write intents, and S3 guard outcomes: `read_pr` returns a
   PR table with `head_ref_oid=…`, a comment intent was raised once for `issue#42`, or a
   guard returned `already_done` because a trusted marker is visible. Counting
   "`post_comment` command string invoked once" disappears from business tests.

2. **The saga-harness oracle stays Tier S and GitHub-agnostic.** It defines an abstract
   effect/truth interface: record write-class effects, replay reads from external truth,
   and compare delivery-1 vs delivery-2 behavior under the ①②③ restart contract. It must
   never depend on GitHub-specific shapes, marker names, or `std.github` APIs.

3. **`std.github.fake` / `std.git.fake` are Tier R implementations of that abstract
   interface.** They are the in-memory GitHub/git models used by business tests through
   the constructor seam. The oracle observes write **intents/effects** through the
   abstract interface; the upgrade from "command multiset" to "intent/effect multiset"
   survives, but the Tier S harness is not identical to the GitHub fake.

4. **The real adapter is tested once, in isolation, for API-contract fidelity.** Only
   `std.github` / `std.git` tests verify that a public operation builds the expected
   command and parses the expected stdout shape. This is the single place command-string
   coupling is allowed to exist. It is concentrated adapter-local brittleness, not
   business-test brittleness.

This directly serves "让问题都在测试解决": business tests become readable behavioral
assertions, the restart oracle remains generic, and command spelling is pinned only
where command spelling is the product.

## 7. Generalization hook (future, not in this plan)

`codex`, filesystem, network, and record-replay hardening can adopt the same adapter
shape later; this plan emits no tasks for them.

## 8. Conformance teeth (the "严格约束" — make the boundary permanent)

A new `scripts/check_repo.py` G-gate uses the same ratchet mechanism as the
saga-harness allowlist, but it must be **context-aware**:

- **No gh/git command construction outside migrated adapter files.** Flag a string that
  is built as a `gh`/`git` command and passed to `exec_sync`, `gh_exec`, `git_exec`, or an
  equivalent wrapper outside `std/github` or `std/git`. Do **not** flag ordinary textual
  mentions in prompts, tests, docs, comments, fixture bodies, marker text, or issue
  templates.
- **No direct gh/git execution outside the adapter.** A direct `exec_sync` / `gh_exec` /
  `git_exec` call whose command head is `gh` or `git` is red once that file's slice has
  migrated. `codex` and other non-gh/git exec uses are unaffected.
- **Per-migrated-file ratchet.** During migration the allowlist is file-scoped and only
  shrinks. A vertical slice closes the gate on the files it touches; untouched files keep
  their temporary allowance until their slice lands.
- **Port-only dependency.** Packages reach the gh/git world through
  `require("std.github")` / `require("std.git")`; peer cross-package require stays
  banned (existing G9).

The gate enforces the Adapter doctrine without banning harmless prose. It catches the
decay mode that matters: newly constructed or directly executed gh/git commands leaking
back into business code.

## 9. Migration — vertical-slice strangler

Each slice is independently mergeable and CI-gated. There is no bulk public-builder
relocation wave, no public low-level builder API, and no compatibility shim.

- **Wave 0 — Foundations (one PR, behavior-neutral).**
  - Consolidate the two `gh_exec` implementations into the S1 adapter exec module shape.
  - Create empty `std.github` / `std.git` skeletons with `new(exec)` constructors.
  - Create the Tier S abstract oracle interface that the saga-harness will observe.
  - Spike-verify nested `require("std.github.issue")` and decide the R1 fallback.
  - Move no builders/parsers and change no business behavior.

- **Per-slice loop — repeat one high-level operation at a time.**
  - Pick one public port operation, reads first: `read_issue`, then `read_pr`,
    `read_pr_diff`, `read_check_runs`, and so on.
  - Move only the builders/parsers that operation needs into the adapter as private
    internals.
  - Expose exactly one neutral domain operation returning the per-op shape from §5.2.
  - Migrate that operation's call sites.
  - Rewrite those tests to use the §5.6 port fake / S2 intent assertions instead of
    command-string mocks.
  - Delete the old builder/parser copy in the same slice.
  - Close the §8 ratchet on the touched files.
  - If the department is also adopting saga-harness `done/act`, do the `done`/`act`
    rewrite in the same slice.

- **Reads first.** Read operations are synchronous and idempotent, so they are the
  lowest-risk way to prove the boundary and fake seam.

- **Guarded writes second.** Each write slice introduces the needed S2 intent schema
  cleanup (`body_source` / `title_source`) and the S3 guard module before moving the S1
  execution mechanics. The order is: intent contract, guard decision under lock, adapter
  execute op, tests, delete old command code, close ratchet.

- **Coordinate with saga-harness.** A department's `done`/`act` rewrite adopts the port
  vocabulary in the same slice. The oracle observes S2 intents / abstract effects; the
  business test injects Tier R fakes through §5.6.

Waves and slices need no engine change. Adapter-local command-string contract tests
cover command fidelity now.

## 10. Risks / open questions

- **R1 — nested `std/` require unverified.** Mitigation: Wave 0 spike; flat-naming
  fallback (§5.3). Cheap, decided before any operation slice.
- **R2 — collision with the concurrent saga-harness dept rewrite.** Both touch every
  `main.lua`. Mitigation: §9 sequencing — one PR per dept adopts both axes; the port is
  the vocabulary `done`/`act` already need.
- **R3 — behavior drift during per-slice extraction.** Moving builders/parsers by hand
  could silently change command semantics. Mitigation: each slice has adapter-local
  command+parse contract tests before business tests are rewritten, and the old
  builder/parser copy is deleted in the same slice.
- **R4 — 1000-line cap during the move.** The adapter is pre-split by responsibility
  (§5.3) so no submodule approaches the cap; `parsers.lua` (878) and `commands.lua` (777)
  *shrink* as their contents distribute across `issue/pr/comment/label/graphql`.
- **R5 — `read_pr_diff` and large content.** Reads return full content **in-process** to
  the caller (no payload, no truncation) — consistent with the content-not-in-payload
  constitution, which constrains *delivery payloads*, not in-process port returns. The
  port must not be used to stuff diff text into a durable event; §5.4 keeps writes
  source/address-handle based.
- **R6 — state-machine vocabulary still in `github-proxy`.** `current_devloop_state` /
  version-CAS remain business logic mislocated in `github-proxy`. Out of scope here (§2);
  noted as a follow-up once the gh/git mechanics are clean (the neutral comments it
  depends on will by then come from `std.github`, making the later move smaller).
- **R7 — injection seam bypass.** Developers may accidentally call `exec_sync` directly
  in migrated files. Mitigation: §8 context-aware gate plus tests that construct ports
  through `std.github.new(exec)` / `std.git.new(exec)`.
- **R8 — non-re-derivable authored text.** Some current `body`/`title` payloads may not
  have a deterministic template yet. Mitigation: §5.4 blocks write-slice migration until
  the slice has either deterministic `body_source` / `title_source` rendering or a real
  durable artifact handle.

## 11. Substrate dependencies (what is package-side vs fkst-substrate)

| Item | Home | Blocking? |
|---|---|---|
| `std.github` + `std.git` adapters, constructor seam, per-op slices, S2 intent cleanup, S3 guards, port-level tests | **fkst-packages** (this repo) | core deliverable |
| `exec_sync` primitive (already exists) | fkst-substrate | already available; no change |
| Record-replay test mode / substrate #88 | future optional hardening | **non-blocking**; not in this plan |

The package-side refactor is self-contained and needs **no** engine change — the
strongest de-risking property of this design.

⟦AI:FKST⟧
