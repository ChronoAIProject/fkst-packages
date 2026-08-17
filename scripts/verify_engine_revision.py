#!/usr/bin/env python3
"""Verify that a candidate declares its engine revision against the current base."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SEMANTIC_FAILURE = 10
CONFIGURATION_FAILURE = 11
PIN_PATH = ".fkst/substrate-ref"


class VerificationConfigurationError(RuntimeError):
    pass


def git(repo_root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit={result.returncode}"
        raise VerificationConfigurationError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout.strip()


def normalize_pin(raw: str, source: str) -> str:
    pin = raw.split("#", 1)[0].strip()
    if not pin:
        raise VerificationConfigurationError(f"empty fkst-substrate pin: {source}")
    return pin


def read_worktree_pin(repo_root: Path) -> str:
    path = repo_root / PIN_PATH
    try:
        raw = path.read_text(encoding="utf-8").splitlines()[0]
    except (OSError, IndexError) as error:
        raise VerificationConfigurationError(f"cannot read fkst-substrate pin: {path}: {error}") from error
    return normalize_pin(raw, str(path))


def read_commit_pin(repo_root: Path, commit: str) -> str:
    return normalize_pin(git(repo_root, "show", f"{commit}:{PIN_PATH}"), f"{commit}:{PIN_PATH}")


def verify(repo_root: Path, base_ref: str | None) -> int:
    head_pin = read_worktree_pin(repo_root)
    head_commit = git(repo_root, "rev-parse", "--verify", "HEAD^{commit}")
    if not base_ref:
        print(f"engine revision subject: head={head_pin} commit={head_commit} base=not-applicable")
        return 0

    base_commit = git(repo_root, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    merge_base = git(repo_root, "merge-base", head_commit, base_commit)
    merge_base_pin = read_commit_pin(repo_root, merge_base)
    base_pin = read_commit_pin(repo_root, base_commit)
    if head_pin == merge_base_pin and base_pin != merge_base_pin:
        print(
            "error: inherited stale engine pin: "
            f"head={head_pin} merge-base={merge_base_pin} base={base_pin} "
            f"base_ref={base_ref}",
            file=sys.stderr,
        )
        return SEMANTIC_FAILURE

    print(
        "engine revision subject: "
        f"head={head_pin} merge-base={merge_base_pin} base={base_pin} base_ref={base_ref}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--base-ref")
    args = parser.parse_args()
    try:
        return verify(args.repo_root.resolve(), args.base_ref)
    except VerificationConfigurationError as error:
        print(f"error: engine revision subject unavailable: {error}", file=sys.stderr)
        return CONFIGURATION_FAILURE


if __name__ == "__main__":
    raise SystemExit(main())
