# chrono-marketing

`chrono-marketing` is the **marketing department** of an fkst "company" session.
Its work label is **`fkst-marketing`**; requests reach it as OPEN issues carrying
that label alongside the umbrella **`fkst-company`** label.

It is a **thin composed package** (`kind = "package.composed"`) and is purely
**reactive** — it ships no cron raiser. It composes `github-proxy` and delegates
every GitHub read/write to that package's seams. `core.lua` is only the
conformance hook; the pure logic lives in `content_logic.lua`, which the
department requires directly.

## Flow

```text
(maintainer files an OPEN fkst-marketing content-request issue)
github-proxy.github_entity_changed
  -> departments/generate  (drafts ONE content artifact via codex)
  -> github-proxy.github_issue_comment_request   (posts the draft back as a comment)
```

The `generate` department accepts only OPEN issues carrying `fkst-marketing`,
reads the request brief from the issue body, runs codex with a content-drafter
prompt, parses a single content object
(`{title, channel, body_markdown, image_prompt}`), and posts it back as a comment
on the requesting issue. The target repo comes from the entity payload, so the
department needs no environment.

## Departments

| Department    | Consumes                              | Produces                                     | Purpose |
|---------------|---------------------------------------|----------------------------------------------|---------|
| `generate`    | `github-proxy.github_entity_changed`  | `github-proxy.github_issue_comment_request`  | Draft one content artifact for an open fkst-marketing request; reply as a comment. |
| `dead_letter` | `dead_letter`                         | —                                            | Standard dead-letter desk. |

## Scope note

The draft is posted as a **comment for human review** — this package does not
publish to external channels (social/blog/email). Channel publishing needs
per-channel credentials and an egress adapter and is deferred; the drafted
artifact names its intended channel so a human (or a future publisher package)
can act on it.

## Tests

```sh
scripts/run.sh test chrono-marketing
```

- `tests/core_test.lua` — pure request-filter / `parse_content` / `comment_request`
  / `conformance_errors` behavior.
- `tests/namespaced_dispatch_conformance_test.lua` — every consumed queue routes.
- `tests/run_graph_generate_smoke_test.lua` — an open fkst-marketing issue reaches
  `generate` and produces a bounded comment request (mocks codex).

⟦AI:FKST⟧
