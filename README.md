# fkst-packages

`fkst-packages` is the official package repository for `fkst`. It contains Lua
packages that run on the `fkst-substrate` engine. The engine lives in the sibling
`fkst-substrate` repository; this repository owns package behavior, composition
glue, tests, scripts, and package-facing documentation.

## Packages

The runtime package view is `.fkst/packages/`, a relative symlink to `packages/`
in this development checkout. A package root uses this shape:

- `core.lua` for package-local shared code.
- `departments/<department>/main.lua` for department entry points.
- `raisers/<raiser>.lua` for cron or file-watch event sources.
- `tests/*_test.lua` and package-local test helpers.

Packages are either flat or composed:

- Flat packages are self-contained, use their own bare queue names, do not
  reference sibling package namespaces, and must pass single-root conformance.
  Current flat packages are `github-proxy` and `consensus`.
- Composed packages adapt or wire sibling packages through event queues and
  declare their test-time composition in `composed.deps`. Current composed
  packages are `autochrono`, `github-autochrono`, and `github-devloop`.

Cross-package sharing happens through event contracts, not `require`. Code that
is shared inside one package belongs in that package root. Stable capabilities
needed by multiple packages should move into the engine SDK instead of becoming
an ad hoc package dependency.

## Quick Start

Install or build `fkst-framework` from `fkst-substrate`, then configure the local
binary path:

```sh
cp .fkst/env.example .fkst/env
$EDITOR .fkst/env
```

The `BIN` value in `.fkst/env` should point to the local `fkst-framework`
binary. `scripts/run.sh` resolves the binary in this order:

1. `BIN` from the environment.
2. `BIN=` from `.fkst/env`.
3. `fkst-framework` on `PATH`.
4. A sibling `../fkst-substrate` checkout.
5. The pinned source cache from `.fkst/substrate-ref`.

Run the standard local validation from the repository root:

```sh
scripts/run.sh test
```

Run one package:

```sh
scripts/run.sh test github-proxy
```

Run only composed-package conformance:

```sh
scripts/run.sh test-composed
```

Run the read-only preflight:

```sh
scripts/run.sh doctor
```

`doctor` reports host facts and missing dependencies. It does not install
packages, write credentials, log in to services, mutate runtime state, or write
to GitHub.

## Running Departments

Run one department once and inspect raised events:

```sh
scripts/run.sh run <package> <department> '<event-json>'
```

Run a real foreground supervisor:

```sh
FKST_GITHUB_REPO=owner/repo \
FKST_RATE_POOL_ROOT=/var/lib/fkst/rate-pools \
scripts/run.sh supervise github-proxy
```

`run` uses `.fkst/runtime` unless `FKST_RUNTIME_ROOT` is already set and never
sets `FKST_GITHUB_WRITE`. `supervise` is a thin wrapper around the real
`fkst-framework supervise` loop. It does not simulate events, inject fake
commands, or infer host-specific integration branches.

## Runtime Configuration

Common host facts include:

- `BIN`: path to `fkst-framework`.
- `FKST_RUNTIME_ROOT`: runtime cache and lock root.
- `FKST_DURABLE_ROOT`: durable delivery database root for real supervisors.
- `FKST_GITHUB_REPO`: `owner/repo` target for GitHub-backed packages.
- `FKST_GITHUB_WRITE=1`: the only switch that enables real GitHub writes.
- `FKST_RATE_POOL_ROOT`: absolute shared rate-pool root for real supervisors.
- `FKST_RATE_POOL_GH`: host-owned sizing for the named GitHub rate pool.

Local machine configuration belongs in `.fkst/env`, which is ignored by git.
Do not commit credentials, runtime state, durable state, or generated worktrees.

## Testing

`scripts/run.sh test` is the CI-equivalent entry point. It runs repository static
guards, `fkst-framework --self-test`, package tests, flat-package conformance,
and final composed conformance.

The test harness uses engine-provided mocks such as `fkst.test.mock_command` and
`fkst.test.command_calls` for external commands. Tests should not create fake
`gh`, `codex`, or engine binaries on `PATH`.

## Documentation

Docs are split by audience:

- [`docs/user/`](docs/user/) is for operators installing and running `fkst`.
- [`docs/dev/`](docs/dev/) is for contributors changing `fkst`.

The authoritative engine/package contract lives in `fkst-substrate` at
`docs/package-repo-contract.md`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow, testing
expectations, and pull request guidance. Project conduct is covered by
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and vulnerability reporting is covered
by [SECURITY.md](SECURITY.md).

## License

This repository is licensed under the [MIT License](LICENSE).
