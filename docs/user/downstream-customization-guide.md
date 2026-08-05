# Downstream Customization Guide

This is the first document to read when you want a specialized downstream `fkst` setup. It is an
orientation guide, not a second contract: detailed mechanics remain owned by the linked scaffold,
host-composition, profile, ADR, and substrate contract documents.

## 1. Orientation Decision

| Special requirement | Build this shape | Trade-off |
|---|---|---|
| "I need one new self-contained `fkst` behavior package." | A flat package in a package repo. | Smallest surface: it uses only its own bare queues and must pass single-root conformance. |
| "I need to adapt or combine existing sibling packages." | A composed package in a package repo. | It may connect sibling packages, but only through declared `[event_deps]` and published seams. |
| "I need `fkst` to run on my non-Lua product repo." | A host repo composing the platform. | The host owns product code and small host packages; the platform trio stays pinned external source. |

Use a flat package until you need cross-package event wiring. Use a composed package when the work is
only package-to-package adaptation. Use host composition when the primary repository is a website,
service, engine, or other product that runs `fkst` over its own source tree.

## 2. Customization Surface

Specialize these surfaces:

- Your own package source: `packages/<pkg>/` in a Lua-primary package repo, or
  `.fkst/local-packages/<pkg>/` for tracked host-owned packages in a host repo.
- Your own departments, raisers, package-local `core.lua`, tests, and `fkst.toml`.
- Package composition in `fkst.toml`, especially `kind = "package.composed"` and
  `[event_deps] packages = [...]` for composed packages.
- Host composition facts: `fkst.workspace.toml` `[[external_sources]]`, `fkst.lock`,
  `.fkst-*-ref` source pins when the host uses them, `.fkst/compose/package-roots`, and host-local
  profile values such as `FKST_HOST_ROOT`, `FKST_PLATFORM_ROOT`, and `FKST_DURABLE_ROOT`.

Do not specialize these surfaces:

- Platform package internals such as `github-proxy`, `consensus`, `github-devloop`, and their
  sibling lifecycle packages.
- The engine contract or engine Rust behavior from this package repo.
- Package boundaries by peer cross-package `require`.
- Raw `gh` or `git` command construction in business code.
- Reliable-delivery payloads that copy large issue bodies, PR diffs, comments, code, or files.

## 3. The Clear Standard

The single downstream conformance standard is: the runner-backed local gate for your shape is green.
For Lua-primary package repos, this is literal:

> A downstream customization is correct iff `scripts/run.sh test` is green.

```sh
scripts/run.sh test
```

For host repos, use the same platform runner through the host contract:

```sh
scripts/run.sh host --host-root <HOST> --platform-root <PKGSRC> -- test
```

These commands are the mechanical bar. Nothing outside the enforced invariants is required; nothing
inside them is optional.

| Invariant | Checkable rule | Why | Owning detail |
|---|---|---|---|
| Flat package | Use `kind = "package"`, keep queue names bare, avoid external package-namespace references, and pass single-root conformance. | A flat package is self-contained, so its graph must be valid without sibling package roots. | [`new-package-repo-bootstrap.md`](new-package-repo-bootstrap.md), [`fkst-substrate/docs/package-repo-contract.md`](https://github.com/ChronoAIProject/fkst-substrate/blob/dev/docs/package-repo-contract.md) |
| Composed package | Use `kind = "package.composed"`, declare sibling packages in `[event_deps]`, and satisfy `raise ⊆ produces ⊆ (own queues ∪ sibling published_seam)`. | Composition is a facade or adapter layer; engine graph scan permits only own queues or a sibling's published seam. | [`new-package-repo-bootstrap.md`](new-package-repo-bootstrap.md), [`fkst-substrate/docs/package-repo-contract.md`](https://github.com/ChronoAIProject/fkst-substrate/blob/dev/docs/package-repo-contract.md) |
| Package boundary | Do not peer cross-package `require`; share code only through declared workspace `lib_deps`. | Package boundaries keep ownership and dependency direction mechanical. | [`../../README.md`](../../README.md), [`fkst-substrate/docs/package-repo-contract.md`](https://github.com/ChronoAIProject/fkst-substrate/blob/dev/docs/package-repo-contract.md) |
| Payload discipline | Reliable-delivery payloads carry `source_ref`, `schema`, `dedup_key`, and small control fields; large content is fetched from `source_ref`. | Durable events are pointers to truth, not content snapshots. | [`new-package-repo-bootstrap.md`](new-package-repo-bootstrap.md), [`../../README.md`](../../README.md) |
| Egress | Route all `gh` and `git` access through `forge` argv adapters; business code does not construct raw `gh` or `git`. | `G-ADAPTER` keeps quoting, execution, rate, mock, and audit behavior behind one egress boundary. | [`../../README.md`](../../README.md), [`fkst-substrate/docs/package-repo-contract.md`](https://github.com/ChronoAIProject/fkst-substrate/blob/dev/docs/package-repo-contract.md) |
| Host repo composition | Declare platform packages through `fkst.workspace.toml` `[[external_sources]]` plus `fkst.lock`; pin sources with `.fkst-*-ref` files where the host contract uses them; keep host-owned packages under `.fkst/local-packages/<pkg>/`; use a sibling platform checkout as `--platform-root` instead of vendoring it. | Host repos compose the platform while preserving host ownership and platform provenance. | [`control-planes-and-host-repo-composition.md`](control-planes-and-host-repo-composition.md), [`../adr/0002-host-fkst-layout.md`](../adr/0002-host-fkst-layout.md) |

Owning references:

- Flat and composed package mechanics: [`new-package-repo-bootstrap.md`](new-package-repo-bootstrap.md).
- Host composition and host conformance tiers:
  [`control-planes-and-host-repo-composition.md`](control-planes-and-host-repo-composition.md).
- Host layout authority: [`../adr/0002-host-fkst-layout.md`](../adr/0002-host-fkst-layout.md).
- Repository guards and package conventions: [`../../README.md`](../../README.md).
- Authoritative engine-package contract:
  [`fkst-substrate/docs/package-repo-contract.md`](https://github.com/ChronoAIProject/fkst-substrate/blob/dev/docs/package-repo-contract.md).

## 4. Next Steps

- Bootstrap a new package repo with
  [`new-package-repo-bootstrap.md`](new-package-repo-bootstrap.md).
- Compose a host repo with
  [`control-planes-and-host-repo-composition.md`](control-planes-and-host-repo-composition.md).
- Configure host-local profile values with
  [`global-host-profiles.md`](global-host-profiles.md).
- Check the accepted host `.fkst/` layout in
  [`../adr/0002-host-fkst-layout.md`](../adr/0002-host-fkst-layout.md).
- Defer engine-package contract details to
  [`fkst-substrate/docs/package-repo-contract.md`](https://github.com/ChronoAIProject/fkst-substrate/blob/dev/docs/package-repo-contract.md).

⟦AI:FKST⟧
