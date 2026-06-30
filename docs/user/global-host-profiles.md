# Global host profiles

Global host profiles are the no-repo-pollution way to run one or more FKST hosts from a shared
machine. They keep machine-specific launch facts outside every checkout, then delegate to the
existing `scripts/run.sh host` and `scripts/host_run.sh` contracts.

This follows the established configuration-profile pattern used by XDG-style user configuration and
toolchain profile managers: committed repositories describe portable project structure; user-level
profiles hold local paths, credentials posture, runtime roots, and per-machine topology.

## Profile Location

By default, profiles live at:

```text
$XDG_CONFIG_HOME/fkst/host-profiles/<name>.env
```

If `XDG_CONFIG_HOME` is unset, the fallback is:

```text
$HOME/.config/fkst/host-profiles/<name>.env
```

Set `FKST_HOST_PROFILE_DIR` to use another directory. For a one-off file, pass `--file <path>`.

Concrete profile files are local-only. This repo commits only the template
`.fkst/host-profiles/example.env`; `.gitignore` keeps real `.fkst/host-profiles/*.env` files out of
version control.

## Scaffold a Profile

Create a profile template:

```sh
scripts/run.sh host-profile init dogfood
```

or choose an explicit directory:

```sh
scripts/run.sh host-profile init --profile-dir /var/lib/fkst/host-profiles dogfood
```

The command writes `<profile-dir>/dogfood.env`. Edit that file with host-local paths and posture.

## Profile Format

Profile files are dotenv-style `KEY=VALUE` data files. They are not sourced as shell code.
`scripts/run.sh host-profile` accepts only `BIN` and `FKST_*` keys and fails closed on other keys.

Required:

```sh
FKST_HOST_ROOT=/path/to/host-repo
```

Common optional keys:

```sh
FKST_PLATFORM_ROOT=/path/to/fkst-packages
FKST_LOCAL_PACKAGES=/path/to/host-repo/.fkst/local-packages
BIN=/path/to/fkst-substrate/target/debug/fkst-framework
FKST_GITHUB_REPO=owner/repo
FKST_GITHUB_WRITE=1
FKST_GITHUB_BOT_LOGIN=<bot-login>
FKST_DEVLOOP_UPSTREAM_BRANCH=dev
FKST_DEVLOOP_INTEGRATION_BRANCH=integration-<device>
FKST_DEVLOOP_ROLLUP_MERGE=auto
FKST_RUNTIME_ROOT=/path/to/global/runtime-scratch
FKST_DURABLE_ROOT=/path/to/global/durable-store
FKST_RATE_POOL_ROOT=/path/to/global/rate-pools
FKST_RATE_POOL_GH=50,50
```

`FKST_PLATFORM_ROOT` defaults to the fkst-packages checkout containing `scripts/run.sh`. That is the
right default when a host bootstrapper has already execed into the pinned platform checkout. Set it
explicitly when launching from a development checkout.

## Run a Host

Run checks:

```sh
scripts/run.sh host-profile dogfood -- check
```

Run host package tests:

```sh
scripts/run.sh host-profile dogfood -- test
```

Start a real supervisor:

```sh
scripts/run.sh host-profile dogfood -- supervise --restart
```

For `supervise`, `FKST_DURABLE_ROOT` and `FKST_RUNTIME_ROOT` from the profile are injected as
`--durable-root` and `--runtime-root` defaults. Explicit command-line roots override the profile.

The final execution still goes through the existing one-host contract:

```text
host-profile -> scripts/run.sh host -> scripts/host_run.sh -> fkst-framework supervise
```

The profile layer does not construct package roots itself, does not bypass `FKST_GITHUB_WRITE`, and
does not replace the canonical host layout in ADR 0002.

## Repository Boundary

Use profiles for host facts that should not be committed:

- local checkout paths;
- bot login and GitHub target repo;
- real-write posture;
- runtime, durable, and rate-pool roots;
- per-device integration branch topology.

Keep portable host composition in the host repository:

- `fkst.workspace.toml` and `fkst.lock`;
- `.fkst/local-packages/<pkg>/`;
- `.fkst/compose/package-roots`;
- `.fkst/conformance/allowlists/`.

For the committed host `.fkst/` layout, see
[`docs/adr/0002-host-fkst-layout.md`](../adr/0002-host-fkst-layout.md). For the control-plane split,
see [`control-planes-and-host-repo-composition.md`](control-planes-and-host-repo-composition.md).

⟦AI:FKST⟧
