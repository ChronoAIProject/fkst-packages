# Control planes and host-repo composition

`fkst-packages` owns reusable package behavior and its repository check/test tooling. It does not
own deployment supervision. Host repositories keep their own check/test scripts, while
`fkst-deployments` and `fkst-ops` own declared machine deployments and long-running process
control.

## 1. Ownership boundaries

| Owner | Lives in | Owns | Must not own |
|---|---|---|---|
| Package platform | `fkst-packages/packages/`, `fkst-packages/libraries/` | Reusable package behavior and the engine-facing package contracts | Host application policy, engine Rust, deployment process control |
| Repository verification | Each repository's own scripts and CI | Source ratchets, engine self-test/conformance/test invocation, application-specific checks | Another repository's test orchestration |
| Deployment declarations | `fkst-deployments` | Target/platform/engine identities and revisions, deployment policy, machine control-set inputs | Package behavior or repository tests |
| Deployment operator | `fkst-ops` | Machine-root derivation, checkout hydration, launch invariants, preflight/status/restart, supervise process ownership | Product policy or application tests |

This split keeps each invariant at its natural owner. In particular, moving repository test
orchestration into the engine would turn repository policy into an engine contract, while leaving a
second supervise path in fkst-packages would duplicate the deployment operator.

## 2. How a host repo composes the platform

A host repo has primary source outside the shared package platform. `fkst-website`, for example,
owns website source and a small host package. It pins and composes fkst packages without vendoring
them:

```text
HOST REPOSITORY
  |- application source
  |- .fkst-substrate-ref                 engine source pin, when used by CI
  |- fkst.workspace.toml                 external package-source declaration
  |- fkst.lock                           resolved package-source revision
  |- .fkst/local-packages/<pkg>/         host-owned package
  |- .fkst/local-libraries/<lib>/        host-owned library, when needed
  |- .fkst/compose/package-roots         composed graph roots
  `- .fkst/conformance/allowlists/       host-owned source-ratchet waivers
             |
             | composes
             v
FKST PACKAGE PLATFORM                   pinned fkst-packages checkout
             |
             | runs on
             v
FKST ENGINE                             pinned fkst-substrate build
```

`fkst.workspace.toml` and `fkst.lock` select and freeze external package ownership. Host-owned
packages remain under `.fkst/local-packages/`. The operator hydrates the declared checkouts for a
deployment; repository scripts hydrate or receive the pinned checkout they need for checks and
tests.

There is no fkst-packages supervise entry. Deployment declarations select the target, platform,
and engine revisions, and the fkst-ops operator resolves those declarations into machine roots and
the foreground engine invocation.

## 3. Host-repo conformance

Conformance infrastructure is authored once but orchestration stays repository-owned. A host repo
uses the primitives appropriate to its source tree:

| Tier | Home | Owns |
|---|---|---|
| Engine built-in | fkst-substrate | `fkst-framework conformance --project-root --package-root`: graph, published-seam, persistence, and saga validity |
| Shared source ratchets | fkst-packages `scripts/check_repo.py --project-root <repo>` | Generic source checks over `packages/*` and `.fkst/local-packages/*`; fkst-packages-only checks gate on repository identity |
| Engine-run Lua | `libraries/testkit`, `libraries/testkit_internal` | Host package tests and composed graph assertions through `fkst-framework test` |
| Application checks | Host repository | Build, lint, smoke, browser, or other application-specific verification |

The host repository's wrapper calls these primitives directly and remains the single local/CI
entrypoint for that repository. It does not copy `check_repo.py`, delegate through a packages-owned
supervisor, or move application orchestration into fkst-substrate.

## 4. Host-repository conventions

- Declare the platform source in `fkst.workspace.toml` and freeze it in `fkst.lock`.
- Keep host packages under `.fkst/local-packages/<pkg>/` and host libraries under
  `.fkst/local-libraries/<lib>/`.
- List composed package roots in `.fkst/compose/package-roots`; keep host-specific ratchet waivers
  under `.fkst/conformance/allowlists/`.
- Keep the repository's check/test orchestration in its own scripts and CI. Invoke the shared
  source ratchet and engine primitives rather than copying their implementations.
- Declare long-running deployments in fkst-deployments and operate them through fkst-ops. Do not
  add another supervise or restart entry to a package or host repository.

See [`docs/adr/0002-host-fkst-layout.md`](../adr/0002-host-fkst-layout.md) for the committed `.fkst/`
layout.

### Frontend application profile

Frontend hosts use the same composition contract as other hosts:

- Compose the existing lifecycle packages such as `github-proxy`, `consensus`, `github-devloop`,
  `github-devloop-pr`, and `github-devloop-intake`.
- Put UI adapters, boards, browser probes, and application metadata in the host repository or its
  `.fkst/local-packages/<host-package>/` package.
- Keep frontend build and smoke orchestration in the frontend repository.
- Use the deployment declaration and operator for supervision.

Do not create a second frontend lifecycle package unless it has a lifecycle contract that cannot be
represented by host composition.

## 5. The complete flow

```text
fkst-deployments declaration
          |
          v
fkst-ops machine control set and operator ---- launches ----> pinned fkst engine
          |                                                       |
          | hydrates                                              | loads
          v                                                       v
host repository ---------------- composes ----------------> pinned fkst packages
          |
          `---- owns its check/test wrapper and application verification
```

Each arrow has one owner: declarations choose the deployment, the operator controls processes,
the host repository controls its verification, packages define behavior, and the engine enforces
generic runtime contracts.

⟦AI:FKST⟧
