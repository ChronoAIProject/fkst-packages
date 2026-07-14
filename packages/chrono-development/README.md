# chrono-development

`chrono-development` is the **development department** of an fkst "company" session.
Its work label is **`fkst-dev`**.

It is a **composed profile** package (`kind = "package.composed"`): it does **not**
reimplement the issue → PR → review → merge lifecycle. That lifecycle already exists as
the `github-devloop` package family, so this department **reuses** that family via
`[event_deps].packages` (modeled on `frontend-devloop`) instead of cloning its ~12
departments.

## What it adds

- `fkst.toml` — the composition manifest that pulls in the devloop family plus
  `github-proxy` and `consensus`, and a `[conformance]` pack + `core.profile_conformance_errors`
  hook for the profile contract.
- `core.lua` — the declarative composition + intake-scoping contract
  (`chrono-development.profile.v1`).
- `departments/dead_letter/` — the standard dead-letter desk (every package ships one).
- `conformance/pack.toml` — the package-local source-size rule pack.

It ships **no** raisers and **no** lifecycle departments of its own — the reused family
owns intake, decomposition, implementation, PR, ops, and integration.

## Reused platform packages (`[event_deps].packages`)

```text
github-proxy
consensus
github-devloop-intake
github-devloop-intake-default
github-devloop-decompose
github-devloop
github-devloop-pr
github-devloop-ops
github-devloop-integration
```

## Departments

| Department    | Consumes      | Purpose |
|---------------|---------------|---------|
| `dead_letter` | `dead_letter` | Standard dead-letter desk for failed reliable deliveries. |

There is no cron cadence: chrono-development owns no scanner/raiser. Intake cadence is
inherited from the reused `github-proxy` poll (`github_poll`, a `5m` cron) and the devloop
family it feeds.

## Work-label scoping (this is the whole reason to reuse the family)

The `fkst-dev` label namespace is **native** to the devloop family:

- `libraries/devloop/base.lua` hardwires the opt-in label `fkst-dev:enabled`; intake acts
  on an issue only when `is_opted_in(labels)` finds that exact label.
- `libraries/devloop/state.lua` drives the lifecycle through `fkst-dev:`-prefixed state
  labels (`fkst-dev:ready`, `fkst-dev:implementing`, `fkst-dev:pr-open`, …).

To fence intake at the poll boundary and **exclude** the sibling company departments'
labels (`fkst-security`, `fkst-finance`, `fkst-marketing`), configure the host's
`github-proxy` with:

```sh
FKST_GITHUB_PROXY_POLL_LABEL_PREFIX=fkst-dev:
```

`github-proxy/core.lua` reads this via `github_proxy_poll_label_prefixes`; only issues
carrying a label under the `fkst-dev:` prefix become intake candidates. Because the sibling
labels use different prefixes, this department never contends with them inside one session —
no greedy all-issues intake, no cross-department double-claim.

## Tests

```sh
scripts/run.sh test chrono-development
```

- `tests/profile_contract_test.lua` — asserts the composition list, the `fkst-dev` work
  label, and the intake-scoping contract (including sibling-label exclusion).
- `tests/namespaced_dispatch_conformance_test.lua` — asserts the `dead_letter` desk routes
  a production-shaped dead-letter payload.
