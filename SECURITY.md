# Security Policy

## Supported Versions

Security fixes are handled on the repository's active development branch and are
released through the normal project workflow.

## Reporting a Vulnerability

Do not report exploitable vulnerabilities in a public issue. Use GitHub private
vulnerability reporting when it is enabled for this repository. If it is not
enabled, contact the maintainers through the least-public channel available and
include only enough public information to establish contact.

A useful report includes:

- Affected package, script, or workflow.
- Impact and exploitability.
- Reproduction steps or a minimal proof of concept.
- Relevant logs or command output with secrets removed.
- Whether the issue affects `fkst-packages`, `fkst-substrate`, or both.

## Scope

Security-sensitive areas include GitHub write paths, merge gates, durable
delivery, state marker parsing, command execution boundaries, worktree setup,
credential handling, and prompt or issue-content trust boundaries.

Please do not exfiltrate secrets, modify GitHub state, force-push branches, or
perform destructive testing against repositories you do not own.
