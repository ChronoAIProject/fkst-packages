# GitHub App Permissions

Create the GitHub App used by an FKST host with the repository permissions below. The table is a
derived inventory, not an independent contract: regenerate it from the egress adapters whenever
those adapters change.

## Why the Inventory Is Complete

GitHub CLI and Git command construction has one repository-owned egress boundary:
[`libraries/forge/github/`](../../libraries/forge/github/) for `gh`, and
[`libraries/forge/git.lua`](../../libraries/forge/git.lua) plus
[`libraries/forge/git/`](../../libraries/forge/git/) for `git`. The `G-ADAPTER` ratchet in
[`scripts/check_repo.py`](../../scripts/check_repo.py) rejects raw `gh` or `git` construction outside
those adapter paths, and [`migration/gh-git-adapter.allowlist`](../../migration/gh-git-adapter.allowlist)
is empty. That enforced zero-exception boundary makes an enumeration of the adapters complete rather
than a sample. The ports and adapters design records the wider architecture; it is not repeated here.

To regenerate this page after an adapter change:

1. Enumerate every REST path, GraphQL query, `gh` command, and remote `git` operation constructed in
   `libraries/forge/github/`, `libraries/forge/git.lua`, and `libraries/forge/git/`.
2. Group each call under the GitHub App repository or organization permission that authorizes it.
3. Run `python3 scripts/check_repo.py` and confirm that `G-ADAPTER` still passes with the migration
   allowlist empty.

## Repository Permissions

| Permission | Level | Adapter calls that require it |
|---|---|---|
| Actions | Read and write | `gh workflow run`. Optional when the deployment does not trigger workflows. |
| Administration | **Read only** | `GET repos/{r}/collaborators?permission=push`. |
| Checks | Read and write | Read `GET repos/{r}/commits/{sha}/check-runs`; write `POST repos/{r}/check-runs/{id}/rerequest`. |
| Contents | Read and write | Read with remote `git fetch`, `git clone`, and `git ls-remote`; write with `git push` and `gh pr merge --merge --match-head-commit <sha>` updating the base branch. |
| Issues | Read and write | Read open issue lists (including label filters), individual issues, issue comments, individual comments, native `sub_issues`, `gh issue view\|list`, `gh label list`, and GraphQL `repository(...){issue(...){blockedBy}}`; write with `gh issue create\|close`, issue labels and assignees, label POST/PATCH, comment POST/PATCH, and native sub-issue changes. |
| Metadata | Read | Mandatory GitHub App metadata access; GitHub grants it automatically. |
| Pull requests | Read and write | Read open PR lists (including base/head filters), closed PRs by head, individual PRs, and `gh pr view\|diff`; write with `gh pr create\|ready\|close`, PR labels and assignees, and `gh pr merge --merge --match-head-commit <sha>`. |

Administration deliberately stays at read. Merge admission depends on branch-protection required
checks and on the appliance having no administrative override. Granting Administration write would
remove the no-bypass property on which the authorization model depends.

## Organization Permission

Grant **Members: read** only when `FKST_GITHUB_AUTHORIZE_ORG_MEMBERS` is enabled. It authorizes
`GET orgs/{org}/members`; hosts that do not authorize organization members do not need it.

## Verification Boundary

The call inventory above was read from the adapters. The mapping from each endpoint or command to a
GitHub permission name follows GitHub's documented permission model, but that mapping was not
re-checked against GitHub's documentation when this file was written. The table is authoritative
only for the adapter call inventory and the repository's enforced egress boundary.

Verify a deployment by granting this set and exercising the platform. Treat a GitHub `403` as the
source for any missing permission, add the permission named by that failure, and update this page
with the adapter call and evidence that required it.

## Not Required

The adapter and platform sources were searched for GitHub API or CLI calls involving Deployments,
Discussions, Environments, Gists, Packages, Projects, Releases, Secrets, Teams, and webhook event
subscriptions. Every match was prose or a local variable, configuration, or package/path name, not
an API call. None is required by the current egress inventory. A future change from polling to
webhooks would add the corresponding event subscriptions to this scope.

⟦AI:FKST⟧
