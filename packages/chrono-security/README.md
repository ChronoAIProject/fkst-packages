# chrono-security

`chrono-security` is the **security department** of an fkst "company" session.
Its work label is **`fkst-security`**; every issue it files also carries the
umbrella **`fkst-company`** label so the shared session pod stays alive whenever
any department has open work.

It is a **thin composed package** (`kind = "package.composed"`). It owns no
`gh`/`git`/time helpers: it composes `github-proxy` and delegates every GitHub
write to that package's `github_issue_create_request` seam. `core.lua` is pure
functions only (prompt, finding parse, request mapping).

## Flow

```text
security_poll (cron raiser)
  -> security_tick
  -> departments/scan  (runs one codex security scan of the local checkout)
  -> github-proxy.github_issue_create_request   (one per validated finding)
  -> github-proxy files the issue with labels [fkst-company, fkst-security]
```

The scan department runs codex with a security-scoped prompt, parses a strict
JSON array of findings (`{file, line, severity, title, remediation}`), and maps
each into a `github-proxy.issue-create.v1` request. github-proxy owns the actual
`gh` call, dedup, and label creation.

## Departments

| Department    | Consumes        | Produces                                   | Purpose |
|---------------|-----------------|--------------------------------------------|---------|
| `scan`        | `security_tick` | `github-proxy.github_issue_create_request` | Run one codex security scan; file each finding. |
| `dead_letter` | `dead_letter`   | —                                          | Standard dead-letter desk. |

## Cadence

`raisers/security_poll.lua` is a `cron` raiser (`interval = core.poll_interval()`,
default `30m`) producing `security_tick`. The company scheduler (fkst-hosted) may
additionally open `fkst-security`-labeled work issues on a longer cadence; those
flow through `github-proxy` intake independently of this self-poll.

## Environment

- `FKST_GITHUB_REPO` — the `owner/repo` the scan targets (read through the
  sandboxed `env_port`; it is the only env name the department allowlists).

## Tests

```sh
scripts/run.sh test chrono-security
```

- `tests/core_test.lua` — pure `parse_findings` / `issue_create_request` /
  `conformance_errors` behavior (no graph, no runtime PATH).
- `tests/namespaced_dispatch_conformance_test.lua` — every consumed queue routes.
- `tests/run_graph_scan_smoke_test.lua` — `security_tick` drives the scan
  department to a `github_issue_create_request` (mocks codex + `FKST_GITHUB_REPO`).
- `tests/fire_raiser_security_test.lua` — the real `security_poll` raiser fires
  and its tick reaches the scan department.

⟦AI:FKST⟧
