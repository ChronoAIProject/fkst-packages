# browser-qa

`browser-qa` is the browser-validation owner for frontend workflows. Its published
`browser_qa_request` seam accepts one already-running URL, one viewport, and PR
lineage. The `inspect` department calls the injected browser port and, for the
walking skeleton, reports only `blank-render` findings.

The production browser adapter invokes Playwright through `exec_argv` with an argv
array. It observes the rendered DOM, records console and failed-request counts,
and writes each viewport screenshot once under its SHA-256 content address in
`.fkst/artifacts/browser-qa/`. Reliable payloads carry the screenshot's bounded
`source_ref`, never screenshot bytes.
Playwright is optional for package tests: adapter contract tests inject a command
runner, while department tests inject the in-process `browser_fake`.

A React/Vite-style host starts its own development server and publishes a request
for that already-running URL:

```lua
raise("browser-qa.browser_qa_request", {
  schema = "browser-qa.request.v1",
  repo = "owner/repo",
  pr_number = 42,
  url = "http://127.0.0.1:4173/dashboard",
  viewport = { width = 1280, height = 720 },
  dedup_key = "browser-qa/owner/repo/pr/42/dashboard/1280x720",
  source_ref = {
    kind = "external",
    ref = "owner/repo#pr/42",
  },
})
```

The host owns development-server startup and shutdown. `browser-qa` does not
manage servers, expand URL or viewport matrices, define console/network policy,
or mutate GitHub. A blank-render finding raises the existing
`github-proxy.github_pr_comment_request` intent; `github-proxy` retains dry-run
and write authority.

Run the package tests with:

```sh
scripts/run.sh test browser-qa
```

⟦AI:FKST⟧
