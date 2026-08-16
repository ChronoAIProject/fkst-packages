# Control planes & host-repo composition

fkst-packages holds **two structurally separated control planes**. This doc is the
map: what each plane owns, how a **host repo** (e.g. fkst-website, or fkst-substrate running its own dogfood)
composes the platform on its own content, and how a host repo gets the same **conformance** guarantees
without rebuilding any infrastructure.

## 1. The two control planes

| Plane | Lives in | Owns | Must NOT own |
|---|---|---|---|
| **PRODUCT** | `packages/`, `libraries/` | the platform itself: agent packages (the `github-devloop` trio + the rest), exact host-facing libraries (`contract` / `workflow` / `testkit`), and private implementation libraries (`workflow_internal` / `testkit_internal` / `forge` / `devloop`), targeting the engine ABI | how a host launches; multi-host orchestration |
| **HOST-RUN contract** | `scripts/host_run.sh` (invoked via `scripts/run.sh supervise`) | ALL launch invariants for **one** host: BIN resolve + freshness rebuild, target `fkst.workspace.toml` package selection, trusted `--platform-root` provenance, runtime-scratch, `--durable-root` (mandatory, fail-closed — never defaulted), the 3-host-shape `--package-root` wiring, `FKST_GITHUB_WRITE` posture, pidfile-based `--restart` (kill -9 + verify-dead, refuses a 2nd supervise on the same durable root) | which hosts run; product logic |

## 2. How a host repo composes the platform

A **host repo** is a repo whose primary source is NOT Lua packages — fkst-website is website source,
fkst-substrate is the engine — but which RUNS the platform on its own content plus its own small package(s).
It does NOT vendor or copy the platform; it **composes** it and **pins** versions.

```
  HOST REPO (e.g. fkst-website)
  ├── <website source ...>                  # the repo's primary content
  ├── .fkst-substrate-ref                    # PIN: engine (fkst-substrate) SHA
  ├── fkst.workspace.toml                     # declares fkst-packages-platform external source
  ├── fkst.lock                               # locks the platform packages source and artifacts
  ├── .fkst/local-packages/<pkg>/            # the host's OWN package (e.g. site-board), composed into the graph
  ├── .fkst/local-libraries/<lib>/           # host-owned workspace libraries, if any
  ├── .fkst/compose/package-roots             # host composition roots, see ADR 0002
  └── .fkst/conformance/allowlists/           # host conformance allowlists, see ADR 0002
        │ composes (pkg.queue limited names; no cross-require, no vendoring)
        ▼
  PLATFORM (from the trusted fkst-packages checkout supplied as --platform-root)
    packages/{github-devloop, github-devloop-pr, github-devloop-intake, …, consensus, github-proxy, archaudit, idle-detector}
    libraries/{contract, workflow, testkit, workflow_internal, testkit_internal, forge, devloop}
        │ runs on
        ▼
  ENGINE (a pinned fkst-substrate build)
```

The host supervise resolves the requested platform package names against the target
`fkst.workspace.toml` and validates the external source IDs that own those packages against `fkst.lock`.
For external platform sources, the target manifest and lock must match the trusted `--platform-root` git
URL/path and `HEAD` before execution;
target files select package ownership but cannot redirect executable platform provenance. Target `workspace`
packages can supply platform packages only when the target root is the trusted platform root itself. Host-owned
packages still come from `.fkst/local-packages/`, all on the same engine BIN — see
`docs/user/github-devloop-dogfood-topology.md` for the dogfood directory layout.

If the target manifest is absent, does not declare a requested platform package, or declares that package in
more than one source, host supervise fails before launch with a narrow diagnostic. `--platform-root` is the
trusted provenance authority for platform execution; target `fkst.workspace.toml` and `fkst.lock` must agree
with it when the target workspace declares external platform packages.

## 3. Host-repo conformance — no per-repo rebuild

The conformance ratchets are a **common, stable part**: authored once, invoked by any repo. A host repo gets
the SAME guarantees (line limits, adapter boundary, dedup, producer-liveness, saga, …) **without copying**
the check_repo infrastructure. Three tiers by ownership:

| Tier | Home | Owns |
|---|---|---|
| **Engine built-in** | fkst-substrate | `fkst-framework conformance --project-root --package-root` — intrinsic validity: graph contract, published-seam, saga |
| **Shared source ratchets** | fkst-packages `scripts/check_repo.py --project-root <repo>` | the generic source ratchets run over ANY repo's tree (discovering packages from both `<root>/packages/*` and `<root>/.fkst/local-packages/*`); library-B-specific ratchets gate on own-repo |
| **Engine-run Lua** | `libraries/testkit`, `libraries/testkit_internal` | publishable host `run_graph` assertions and repo-private execution conformance via the engine in test mode |

A host repo's `scripts/run.sh check` invokes the **shared** `check_repo.py` from the trusted fkst-packages
checkout supplied as `--platform-root`, plus `fkst-framework conformance`, providing ONLY its config (its
package roots + its own waivers). It carries **no copied check_repo**.
(fkst-website's former 610-line copy is gone.)

## 4. Conventions a new host repo follows

- **The platform packages selector** is `fkst.workspace.toml` `[[external_sources]]` plus `fkst.lock`, with
  `fkst-packages-platform` as the source identity. Its git URL/path and locked rev must match the trusted
  `--platform-root` checkout before host supervise executes platform packages. `.fkst-substrate-ref` remains
  the engine toolchain pin when a host uses a checked-out substrate build.
- **The host's own package(s)** live under `.fkst/local-packages/<pkg>/`.
- **Host conformance libraries** are selected from the same external source with
  `libraries = ["contract", "workflow", "testkit"]`; host package manifests declare the direct subset
  they use. `workflow` exports only `workflow.saga` and `workflow.dead_letter`, while `testkit` exports
  only `testkit.graph`. The `_internal` libraries are not publishable host APIs.
- **Host composition roots** live under `.fkst/compose/package-roots`; host conformance allowlists stay under
  `.fkst/conformance/allowlists/`. See [`docs/adr/0002-host-fkst-layout.md`](../adr/0002-host-fkst-layout.md).
- **`.fkst/` is the host runtime/interface directory** (tracked + ignored mix): committed host-owned bits
  (`local-packages`, `local-libraries`, `conformance`, `compose`) plus gitignored engine scratch
  (`runtime/`, `durable/`).

### Frontend application workflow profile

Frontend application hosts use the same host-repo composition contract as any other non-Lua host repo. The
profile is composition, not a separate platform package:

- Load the platform packages that own the lifecycle: `github-proxy`, `consensus`, `github-devloop`,
  `github-devloop-pr`, and `github-devloop-intake`.
- Put host-specific UI adapters, boards, browser probes, or app metadata under
  `.fkst/local-packages/<host-package>/`.
- List those host-owned package roots in `.fkst/compose/package-roots` so the shared conformance tiers test
  them with the pinned platform graph.
- Keep frontend-specific checks as host package behavior or host CI commands. The platform `github-devloop`
  lifecycle remains the single source of truth for issue intake, implementation, PR review, fixing, and merge.

Do not add a standalone `frontend-devloop` package/profile unless it has a distinct lifecycle contract that
cannot be represented by host composition. This keeps frontend workflow support on the same DRY, single-owner
path as the existing `github-devloop` platform instead of creating a second source of truth.

## 5. The big picture

```
                 PRODUCT  (packages/ + libraries/)            ← what the platform IS
                    ▲ targets ABI            ▲ composed by
                    │                         │
   ENGINE (fkst-substrate, pinned) ───────────┤
                    ▲ launched by             │
                    │                         │
        HOST-RUN contract (host_run.sh)       │  ← how ONE host launches (all invariants)
                    ▲ used by                 │
                    │                         │
   HOST REPO (fkst-website / substrate) ──────┘  ← composes the platform via workspace external_sources + lock
                                                    + .fkst/local-packages/, gets conformance via the
                                                    shared tiers with ZERO rebuilt infrastructure
```

The separation is complete: HOST-RUN owns one host's launch invariants, while a host repo composes and
conforms to the PRODUCT platform without copying any of it.

⟦AI:FKST⟧
