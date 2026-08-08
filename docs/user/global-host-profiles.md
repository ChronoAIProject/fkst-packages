# Global Host Profiles

Global host profiles are host-local shell environment files that feed the existing
`scripts/run.sh host` and `scripts/run.sh supervise` contracts. They are not a new resolver,
registry, or named profile abstraction.

The established practice is XDG-style user configuration with explicit command-line and
environment precedence. Keep machine-specific facts outside the target repository, keep
`fkst.workspace.toml` and `fkst.lock` as the project source of truth for platform package selection,
and pass normal `FKST_*` facts plus the trusted platform checkout to the shared runner.

## Location

Use one user-owned file per machine:

```sh
${XDG_CONFIG_HOME:-$HOME/.config}/fkst/host.env
```

Start from the scaffold in [`host-profile.env.example`](host-profile.env.example):

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/fkst"
cp docs/user/host-profile.env.example "${XDG_CONFIG_HOME:-$HOME/.config}/fkst/host.env"
```

Do not commit the filled file. It contains host paths, bot identity, repository identity, and
possibly write posture.

## Precedence

The precedence is deliberately boring:

1. Documentation beats scaffolds; explicit CLI/env beats documentation.
2. `fkst.workspace.toml` plus `fkst.lock` remains the source of truth for the host repository's
   platform package selection; executable provenance must still match the trusted `--platform-root`.
3. `.fkst/compose/package-roots` remains the source of truth for the composed package roots loaded
   by the host runner.
4. The global host profile supplies user- and machine-local environment facts such as `BIN`,
   `FKST_HOST_ROOT`, `FKST_PLATFORM_ROOT`, `FKST_DURABLE_ROOT`, `FKST_RATE_POOL_ROOT`,
   `FKST_GITHUB_REPO`, `FKST_GITHUB_BOT_LOGIN`, and branch topology.
5. Inline shell assignments and command-line flags may override the profile for one launch.

There is no `--profile <name>` and no `FKST_PROFILE` environment key. Add a novel named profile
surface only after proving that the existing explicit env and workspace-root mechanisms are
insufficient.

## Schema

The profile schema is the existing host-run environment surface:

| Key | Required | Meaning |
|---|---:|---|
| `BIN` | yes | Path to the `fkst-framework` binary. |
| `FKST_HOST_ROOT` | yes | Host repository root passed to `scripts/run.sh host --host-root`. |
| `FKST_PLATFORM_ROOT` | yes | `fkst-packages` checkout passed to `scripts/run.sh host --platform-root`. |
| `FKST_DURABLE_ROOT` | yes for supervise | Stable durable delivery root passed as `--durable-root`. |
| `FKST_RATE_POOL_ROOT` | yes for GitHub traffic | Host-stable external-command rate-pool root. |
| `FKST_GITHUB_REPO` | package-dependent | GitHub repository identity such as `owner/repo`. |
| `FKST_GITHUB_BOT_LOGIN` | package-dependent | This host's bot login and device identity. |
| `FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE` | optional | Claim-label naming posture: trimmed `1` selects the bare `fkst-dev:claimed` label, and only one host may use that exclusive posture because two bare-label hosts recreate a holderless lock; unset or every other value uses `fkst-dev:claimed:<normalized-owner>`. |
| `FKST_DEVLOOP_INTEGRATION_BRANCH` | `github-devloop` | Per-device integration branch. |
| `FKST_DEVLOOP_INTAKE_MILESTONE_NUMBERS` | optional | Comma-separated GitHub milestone numbers eligible for an initial issue claim. |
| `FKST_DEVLOOP_LOCAL_TEST_COMMAND` | `github-devloop` | Repository-root local verification gate run by implement/fix workers before handoff. |
| `FKST_DEVLOOP_CACHE_PREPARATION_COMMAND` | optional | Trusted-base cache preparation run for each implementation worktree before Codex starts. |

`FKST_GITHUB_WRITE=1` is intentionally commented in the scaffold. Unset means dry-run.

## Local iteration gate

A `github-devloop` deployment must provide a runnable local iteration gate. When
`FKST_DEVLOOP_LOCAL_TEST_COMMAND` is unset, the default is `scripts/run.sh test-affected` in the
deployed repository. Repositories without that executable must configure their own gate, for example
`make preflight`, `just preflight`, or `npm test`.

The configured target should be the repository's canonical local and CI gate, including any base
freshness or conflict checks required for a born-green pull request. It must be one direct executable
invocation. Put multiple steps in a repository-owned executable, Make target, or task-runner target
instead of shell control operators in the environment value.

For implementation candidate verification, `github-devloop` exports `BASE` as the candidate's frozen
base head before invoking the configured target. Base-aware gates must use that value instead of a
moving default branch. The detached raw-base attribution probe runs without this candidate-only
override because it has no candidate diff.

The gate owns the meaning of its result. On every catchable process completion it must print exactly
one v2 result line to stdout or stderr. The closed verdict and fault-class pairs are:

```text
FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE
FKST_LOCAL_ITERATION_RESULT:v2:FAIL:SEMANTIC
FKST_LOCAL_ITERATION_RESULT:v2:FAIL:CONFIGURATION
FKST_LOCAL_ITERATION_RESULT:v2:FAIL:TOOLCHAIN
FKST_LOCAL_ITERATION_RESULT:v2:FAIL:INFRASTRUCTURE
FKST_LOCAL_ITERATION_RESULT:v2:UNKNOWN:UNKNOWN
```

`PASS:NONE` is the only zero-exit declaration. `FAIL:SEMANTIC` means completed tests or checks proved
the candidate invalid. `CONFIGURATION`, `TOOLCHAIN`, and `INFRASTRUCTURE` preserve deterministic
non-candidate failures without attributing them to the implementation. `UNKNOWN:UNKNOWN` is reserved
for failures the producer cannot classify. A timeout, an untyped nonzero exit, malformed, duplicate,
or conflicting declarations, and a declaration inconsistent with the exit status are all `UNKNOWN`.
The platform never assigns domain meaning to a raw nonzero code. It retries only an unknown base
verification once, then fails closed without publishing or attributing the candidate. Repository-owned
wrappers must aggregate nested results into one top-level declaration and leave diagnostics visible.

Host activation validates the command from `FKST_HOST_ROOT` before replacing an existing supervisor.
Activation fails closed when the direct executable is missing, non-executable, or the command shape is
not safely preflightable; it does not execute the test suite during activation.

## Implementation cache preparation

`FKST_DEVLOOP_CACHE_PREPARATION_COMMAND` optionally names a repository-owned executable or task target
that hydrates build caches in an implementation worktree. `github-devloop` runs it after refreshing
`.fkst/substrate-ref` and before starting the Codex wall-clock deadline. The command runs from the
trusted supervisor project root with the candidate path in
`FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE`, never from candidate-controlled content. The command has
a 10-minute timeout; a nonzero exit fails the implementation attempt loudly.

The command must be idempotent because redelivery or a later implementation attempt can run it again
for an existing worktree. It must treat the candidate path as untrusted data and must not execute
candidate-controlled build scripts. Persistent cache ownership and reuse remain repository concerns,
so trusted base logic can use the repository's native cache mechanism without teaching
`github-devloop` about `.lake`, `node_modules`, `target`, or other toolchain-specific directories.

## Launch

For a host repository that delegates to the shared runner:

```sh
. "${XDG_CONFIG_HOME:-$HOME/.config}/fkst/host.env"

"$FKST_PLATFORM_ROOT/scripts/run.sh" host \
  --host-root "$FKST_HOST_ROOT" \
  --platform-root "$FKST_PLATFORM_ROOT" \
  -- supervise \
  --durable-root "$FKST_DURABLE_ROOT" \
  --restart
```

For direct host-run contract use:

```sh
. "${XDG_CONFIG_HOME:-$HOME/.config}/fkst/host.env"

scripts/run.sh host --host-root "$FKST_HOST_ROOT" --platform-root "$FKST_PLATFORM_ROOT" -- check
scripts/run.sh host --host-root "$FKST_HOST_ROOT" --platform-root "$FKST_PLATFORM_ROOT" -- test
scripts/run.sh host --host-root "$FKST_HOST_ROOT" --platform-root "$FKST_PLATFORM_ROOT" -- supervise --durable-root "$FKST_DURABLE_ROOT" --restart
```

`FKST_RUNTIME_ROOT` is intentionally absent from the scaffold. `scripts/run.sh host ... supervise`
uses fresh runtime scratch by default while `FKST_DURABLE_ROOT` stays host-stable and reused across
restarts.

## Boundaries

Global profiles must not replace repository facts:

- Do not put platform package selectors in the profile; keep them in `fkst.workspace.toml` and `fkst.lock`.
- Do not put package-root lists in the profile; keep them in `.fkst/compose/package-roots`.
- Do not use file permissions as a control mechanism.
- Do not source issue text, comments, or other untrusted remote content as shell.
