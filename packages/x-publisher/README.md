# x-publisher

General X release package - **contract + shadow-first live implementation.** A reusable publish lane
for X that any host repo composes via `pkg.queue`: consume a safe publish request, validate that only
small control fields plus source pointers are present, and emit a receipt.

- **consumes** `x_publish_request` - `{ artifact_id, source_ref, content_ref?, platform?, channel?,
  dedup_key?, trace_id?, approval_id?, scheduled_at?, metadata? }`.
- **produces** `x_published` - preview receipts in shadow mode, blocked receipts when a requested
  live write is not authorized, and published receipts after NyxID returns an X tweet id.
- **payload boundary** body/content fields (`tweet`, `body`, `text`, `message`, `media_bytes`,
  provider raw responses) and sensitive fields (`token`, `bearer`, `oauth`, `secret`,
  `credential`, authorization-like names) are rejected fail-closed.
- **posture** shadow-first: live writes require all of `channel = "live"`,
  `X_PUBLISH_WRITE=1`, `NYXID_X_SERVICE_SLUG=<service-slug>`,
  `NYXID_ACCESS_TOKEN`, and a `nyxid` CLI available on `PATH`.

## Live X write contract

`x-publisher` uses NyxID as the only credential path. It never accepts or stores raw X tokens.

Required user Environment Profile for live mode:

- install the `nyxid` CLI into a directory visible on `PATH`, for example the
  profile's tool/bin directory;
- provide a user-owned NyxID agent key as the secret `NYXID_ACCESS_TOKEN`;
- provide the user's X service slug and optional expected account guard as env
  variables.

```sh
X_PUBLISH_WRITE=1
NYXID_URL=https://nyx-api.chrono-ai.fun
NYXID_X_SERVICE_SLUG=<user-owned-x-service-slug>
X_PUBLISH_EXPECTED_USERNAME=<x-username>
NYXID_ACCESS_TOKEN=<secret-user-owned-nyxid-agent-key>
```

`NYXID_ACCESS_TOKEN` is checked for presence only; the package does not read,
log, persist, or include the token in receipts. The `nyxid` CLI consumes it from
the environment when making proxy requests.

Legacy `FKST_X_PUBLISH_WRITE` / `FKST_NYXID_X_SERVICE_SLUG` /
`FKST_X_PUBLISH_EXPECTED_USERNAME` names are still accepted for older non-hosted runners. Hosted
Environment profiles reserve the `FKST_*` prefix, so hosted installs should use the non-reserved
names above.

If a live request is missing the access token or cannot execute `nyxid --version`, the package emits
an `x_published` receipt with `status = "blocked"` and does not call the X API.

When `X_PUBLISH_EXPECTED_USERNAME` is set, the package first calls:

```text
nyxid proxy request <slug> /users/me?user.fields=id,name,username -m GET
```

The returned username must match before the package can post to:

```text
nyxid proxy request <slug> /tweets -m POST -d {"text":"..."}
```

The `/tweets` path is relative to the NyxID service base URL `https://api.x.com/2`; do not use
`/2/tweets`.

## Content resolution

The publish payload stays pointer-only. For GitHub issue driven workflows, `content_ref` points to
the weekly content issue, typically `#42` relative to the schedule issue repo. The weekly content
issue must contain one explicit tweet text field, for example:

````md
type: weekly-content
project: chronoai
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
````

MVP live publishing supports one text-only X post up to 280 characters. Media upload and thread
publication are intentionally separate follow-up capabilities.

Invalid requests are skipped with a greppable log and never masquerade as successful publishes.
`core.preview_receipt(payload, "skipped")` exists as a safe shape helper for hosts/tests that need
an explicit skipped receipt, but the department does not raise it for invalid requests.

⟦AI:FKST⟧
