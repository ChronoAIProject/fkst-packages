# Auto Twitter Marketing Workflow

This document describes the public package workflow used by local
`fkst-hosted` for strategy import, weekly content import, X publishing,
recurring schedules, and the new marketing radar capability.

## Scope

Goal:

- Use GitHub issues as the operational input surface.
- Keep business capability in `ChronoAIProject/fkst-packages`, not in
  `fkst-hosted`.
- Let `fkst-hosted` compose packages from the public package repository.
- Publish to X only through the user's Environment Profile: the user provides
  `nyxid` CLI, a NyxID agent key, an X service slug, and the expected X account
  guard.

Non-goal:

- No raw GitHub, LLM, or X credentials in repo files, manifests, or issue
  payloads.
- No changes to `fkst-hosted` core for marketing business logic.
- No media upload or thread publishing in the MVP; current live X publishing is
  text-only.

## Runtime composition

Use the manifest:

```text
manifests/auto-twitter-marketing.json
```

It composes these packages:

```text
packages/github-proxy
packages/marketing-radar
packages/github-auto-twitter-marketing
packages/x-publisher
```

The GitHub work label is:

```text
auto-twitter-marketing
```

Every input issue must have this label.

## Required host configuration

GitHub writes are controlled by the hosted environment:

```sh
FKST_GITHUB_WRITE=1
FKST_GITHUB_BOT_LOGIN=<github-app-bot-login>
FKST_DEVLOOP_MANAGED_BOT_LOGINS=<github-app-bot-login>
FKST_GITHUB_AUTHORIZED_LOGINS=<allowed-human-or-bot-logins>
```

Live X publishing is controlled separately by the user's Environment Profile:

```sh
X_PUBLISH_WRITE=1
NYXID_URL=https://nyx-api.chrono-ai.fun
NYXID_X_SERVICE_SLUG=<user-owned-x-service-slug>
X_PUBLISH_EXPECTED_USERNAME=<x-username>
NYXID_ACCESS_TOKEN=<secret-user-owned-nyxid-agent-key>
```

The profile must also install the `nyxid` CLI into a directory visible on
`PATH`; `fkst-hosted` does not bundle it globally. `x-publisher` first checks
that `NYXID_ACCESS_TOKEN` exists and `nyxid --version` works, then preflights
the NyxID service with `/users/me`. If the resolved username is not
`X_PUBLISH_EXPECTED_USERNAME`, the package blocks the live write.

LLM configuration belongs in the host environment, not in package source:

```sh
LLM_BASE_URL=https://llm.aelf.dev/v1
LLM_MODEL=gpt-5.5
LLM_API_KEY=<secret>
```

## Issue contracts

### Strategy import

```md
type: strategy
project: chronoai
account: example_user

Positioning:
- ...
```

Expected outcome:

- `github-auto-twitter-marketing.strategy_imported`
- GitHub comment: `strategy imported`

### Weekly content import

````md
type: weekly-content
project: chronoai
week: 2026-W31
strategy-ref: #24

tweet-text:
```
FKST live publish verification for example_user via NyxID.
```
````

Expected outcome:

- `github-auto-twitter-marketing.weekly_content_imported`
- GitHub comment: `weekly content imported`

For recurring publish acceptance, `tweet-text` may include
`{{occurrence_id}}`, `{{scheduled_at}}`, `{{interval_minutes}}`, and
`{{schedule_type}}`; `x-publisher` renders them from the schedule payload before
posting so each X post can be unique.

### One-shot publish

```md
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
scheduled-at: 2026-07-28T11:10:00+08:00
```

Expected outcome:

- `github-auto-twitter-marketing` emits `x-publisher.x_publish_request`
- `x-publisher` resolves `calendar-ref` back to the weekly content issue
- `x-publisher` posts one text-only X tweet when live gates pass
- GitHub comment: `schedule publish live requested`

### Daily recurring publish

```md
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
```

Expected outcome:

- The open schedule issue is observed by periodic GitHub resync.
- After the local `11:10` occurrence is due, the package emits one publish
  request for that occurrence.
- Deduplication prevents repeated posts for the same local occurrence.
- Close the schedule issue to stop future daily runs.

### Interval recurring publish

Use this contract for short-window local acceptance where waiting a full day is
not practical:

```md
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
recurrence: every-minutes
interval-minutes: 10
scheduled-at: 2026-07-29T11:20:00+08:00
```

Expected outcome:

- `scheduled-at` is the first occurrence anchor.
- `interval-minutes` is a positive integer from 1 to 1440.
- Each due occurrence has its own occurrence id and publish dedup key.
- Keep the issue open until the required number of occurrences has been
  observed, then close it to stop future interval runs.

### Radar config

```md
type: radar-config
project: chronoai
account: example_user
cadence: daily
timezone: Asia/Shanghai
topics: FKST, hosted automation, AI workflow
competitors: example-a, example-b
```

Expected outcome:

- `marketing-radar.radar_config_imported`
- GitHub comment: `radar config imported`

### Radar signal

```md
type: radar-signal
project: chronoai
week: 2026-W31
topic: FKST hosted automation
source-url: https://github.com/OWNER/CONTENT_REPO/issues/24
insight: GitHub issue inputs can drive strategy, weekly content, and scheduled X publishing.
priority: high
```

Expected outcome:

- `marketing-radar.radar_signal_imported`
- GitHub comment: `radar signal imported`

### Radar run to weekly content

````md
type: radar-run
project: chronoai
week: 2026-W31
strategy-ref: #24
topic: FKST hosted automation
source-url: https://github.com/OWNER/CONTENT_REPO/issues/24
insight: Local hosted can import issues and schedule X posts.
assignee: github-username

tweet-text:
```
Radar generated test post for FKST auto-twitter.
```
````

Expected outcome:

- `marketing-radar.radar_brief_created`
- `marketing-radar` emits `github-proxy.github_issue_create_request`
- `github-proxy` creates a new `weekly-content` issue with label
  `auto-twitter-marketing`
- The generated weekly issue is then imported by
  `github-auto-twitter-marketing`

### Radar run to schedule issue when `calendar-ref` is already known

```md
type: radar-run
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
assignee: github-username
```

Expected outcome:

- `marketing-radar.radar_brief_created`
- `github-proxy` creates a `schedule-publish` issue that points to `#25`

## Current boundary

`github-proxy` can create issues and writes idempotent markers, but it does not
publish the newly created issue number back as a package event. Therefore the
MVP supports this reliable two-step path:

1. `radar-run` creates a `weekly-content` issue.
2. Use the actual generated issue number as `calendar-ref` in a
   `schedule-publish` issue.

If a future fully automatic chain is required, add a new public seam such as
`github-proxy.github_issue_created` and let `marketing-radar` consume it.

## Acceptance cases

Run these against local `fkst-hosted` with UI at `http://127.0.0.1:5280` and
API at `http://127.0.0.1:18082`.

1. Create a `strategy` issue and verify the import receipt.
2. Create a `weekly-content` issue and verify the import receipt.
3. Create a one-shot `schedule-publish` issue with a due `scheduled-at` and
   verify one live X tweet from `example_user`.
4. Create a daily `schedule-publish` issue with a near-future local `time` and
   verify exactly one tweet for that occurrence; close the issue after the test.
5. Create an `every-minutes` `schedule-publish` issue and verify at least two
   live X tweets across two distinct occurrence ids.
6. Create a daily recurring `schedule-publish` issue, keep it open overnight,
   and verify live X tweets across two dates before closing it.
7. Create a `radar-config` issue and verify the radar config receipt.
8. Create a `radar-signal` issue and verify the radar signal receipt.
9. Create a `radar-run` issue without `calendar-ref` and verify that a new
   `weekly-content` issue is created and imported.
10. Create a `radar-run` issue with `calendar-ref` and verify that a new
   `schedule-publish` issue is created.
11. Publish from the generated content and verify the X tweet id through NyxID.

## Operational notes

- Without a public webhook URL, local hosted relies on periodic GitHub polling.
  Tests can be accelerated by manual resync or by shortening the host poll
  interval when the local host exposes that config.
- `mode: shadow` is safe and creates preview receipts only.
- `mode: live` requires both GitHub write and X write gates.
- Re-running the same issue is safe; `dedup_key` and GitHub markers prevent
  duplicate external effects for the same logical request.
