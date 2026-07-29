# GitHub Auto Twitter Marketing

`github-auto-twitter-marketing` is a hosted-facing composed package that maps
GitHub issue facts into the marketing seams already exposed by this repository.

It keeps reliable payloads pointer-only:

- strategy issues raise `strategy_imported`;
- weekly-content issues raise `weekly_content_imported`;
- schedule-publish issues raise `x-publisher.x_publish_request`;
- each handled issue raises a `github-proxy.github_issue_comment_request` status
  receipt.

The package recognizes the `auto-twitter-marketing` work label and accepts small
control fields either from a trusted `payload.controls` map or from simple
`key: value` lines in the issue body. Strategy text, weekly content, and final X
post content remain behind `source_ref`.

Live X writes are not authorized by this package. `mode: live` is only allowed
to become a live channel after the user's Environment Profile supplies an
explicit live write switch and a NyxID X service slug. The downstream
`x-publisher` package then performs the final live preflight: `NYXID_ACCESS_TOKEN`
must be present and `nyxid` must be available on `PATH`. Without those gates, the
workflow emits either a preview/shadow request or a blocked publish receipt.

## Issue formats

Strategy import:

```md
type: strategy
project: chronoai
account: main
```

Weekly content import:

````md
type: weekly-content
project: chronoai
week: 2026-W31
strategy-ref: #41

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
````

Schedule publish:

```md
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #42
mode: live
scheduled-at: 2026-07-25T09:00:00Z
```

`calendar-ref` becomes the downstream `content_ref`. For `#42`, `x-publisher` resolves it relative
to the schedule issue repo and reads the weekly content issue through the GitHub adapter.

## Live Environment Profile contract

Live mode requires user-owned profile configuration, not host-owned X
credentials:

```sh
X_PUBLISH_WRITE=1
NYXID_URL=https://nyx-api.chrono-ai.fun
NYXID_X_SERVICE_SLUG=<user-owned-x-service-slug>
X_PUBLISH_EXPECTED_USERNAME=<x-username>
NYXID_ACCESS_TOKEN=<secret-user-owned-nyxid-agent-key>
```

The profile must also install the `nyxid` CLI into a directory visible on `PATH`.
Hosted runtimes are not expected to bundle it globally.

The username preflight is a safety guard: if NyxID resolves to any account other than
`X_PUBLISH_EXPECTED_USERNAME`, the publish request is blocked and no tweet is created.
Raw X tokens must never appear in issues, manifests, package source, or logs.
