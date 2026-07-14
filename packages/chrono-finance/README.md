# chrono-finance

`chrono-finance` is the **finance department** of an fkst "company" session.
Its work label is **`fkst-finance`**; every issue it files also carries the
umbrella **`fkst-company`** label so the shared session pod stays alive whenever
any department has open work.

It is a **thin composed package** (`kind = "package.composed"`). It owns no
`gh`/`git`/time helpers: it composes `github-proxy` and delegates every GitHub
write to that package's `github_issue_create_request` seam. `core.lua` is only
the conformance hook; the pure logic lives in `report_logic.lua`, which the
department requires directly.

## Flow

```text
finance_poll (cron raiser, default 60m)
  -> finance_tick
  -> departments/report  (runs one codex cost/usage summary for the tick window)
  -> github-proxy.github_issue_create_request   (exactly one deduped report issue)
  -> github-proxy files the issue with labels [fkst-company, fkst-finance]
```

The report department runs codex with a cost/usage-accountant prompt, parses a
single usage object (`{summary, total_units, line_items:[{area, units}]}`), and
maps it into ONE deduped report issue per 24h window (the day bucket of the
tick's slot). If `FKST_FINANCE_BUDGET_MAX_UNITS` is set and `total_units` exceeds
it, the same issue is titled as a **budget alert**.

## Departments

| Department    | Consumes       | Produces                                   | Purpose |
|---------------|----------------|--------------------------------------------|---------|
| `report`      | `finance_tick` | `github-proxy.github_issue_create_request` | One codex cost/usage summary → one deduped report/alert issue. |
| `dead_letter` | `dead_letter`  | —                                          | Standard dead-letter desk. |

## Environment

- `FKST_GITHUB_REPO` — the `owner/repo` the report targets.
- `FKST_FINANCE_BUDGET_MAX_UNITS` — optional integer budget; over it, the report
  is filed as a budget alert. Unset/blank ⇒ no alerting.

## Scope note

Effort "units" are a **relative proxy** codex estimates from git/PR history, not
real billing figures. Deep per-PR/per-feature token accounting requires an engine
usage seam (durable `fkst.observe` counters) and is deferred as a future
enhancement; this package delivers the periodic cost/usage report + budget alert.

## Tests

```sh
scripts/run.sh test chrono-finance
```

- `tests/core_test.lua` — pure `parse_usage` / `report_issue_request` /
  `over_budget` / `conformance_errors` behavior.
- `tests/namespaced_dispatch_conformance_test.lua` — every consumed queue routes.
- `tests/run_graph_finance_poll_fire_raiser_test.lua` — the real `finance_poll`
  raiser fires, routes to the report department, and files one bounded request.

⟦AI:FKST⟧
