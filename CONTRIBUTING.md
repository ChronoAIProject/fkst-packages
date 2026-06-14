# Contributing to fkst-packages

Thank you for contributing to `fkst-packages`. This repository contains the Lua
package layer for `fkst`; engine changes belong in `fkst-substrate`.

## Before You Start

- Read the top-level [README.md](README.md) for repository structure and commands.
- Read the relevant package code and tests before changing behavior.
- Use established distributed-systems and OSS maintenance practice before
  inventing a new workflow. Deviations should be explicit and justified.
- Keep source comments, identifiers, logs, errors, and test assertions in English.

## Development Workflow

1. Start from the repository's integration branch.
2. Create a focused branch for one logical change.
3. Keep edits scoped to the package, script, or documentation surface required by
   the issue.
4. Add or update tests when behavior changes.
5. Run the full suite before proposing the change:

```sh
scripts/run.sh test
```

If the suite cannot run because `fkst-framework` is unavailable, report that
environment failure clearly instead of treating the change as verified.

## Package Rules

- Flat packages must be self-contained and pass single-root conformance.
- Composed packages should act as facade or adapter layers for sibling packages.
- Do not share Lua modules across package roots with `require`.
- Put package-local shared code in the package root, such as `core.lua`.
- Keep runtime business state out of the source tree.
- Use `source_ref` for durable downstream events that need to re-fetch current
  source facts.
- Do not place large issue bodies, PR diffs, comments, code, or files into
  reliable delivery payloads.

## Testing Rules

- Use `fkst.test.mock_command` and `fkst.test.command_calls` for external command
  boundaries.
- Do not add fake binaries to `PATH` in tests.
- Keep fixtures production-shaped enough to catch queue namespace, byte boundary,
  source reference, and replay behavior.
- Let conformance cover graph wiring and static package declarations.

## Pull Requests

Pull requests should include:

- A short description of the problem and the chosen approach.
- The package, script, or documentation surfaces changed.
- Test evidence, including the exact command run and result.
- Any known limitations or follow-up work.

Do not include credentials, runtime state, durable state, local worktrees, or
machine-specific `.fkst/env` values in a pull request.
