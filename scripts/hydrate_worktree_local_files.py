#!/usr/bin/env python3
"""Copy explicitly declared host-local files into an isolated Git worktree."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ENV_NAME = "FKST_WORKTREE_LOCAL_FILES"


class HydrationError(RuntimeError):
    """A host-local file declaration cannot be hydrated safely."""


def parse_paths(raw: str) -> list[Path]:
    paths: list[Path] = []
    seen: set[str] = set()
    for line in raw.splitlines():
        if line == "":
            continue
        if line != line.strip():
            raise HydrationError("declared paths must not have leading or trailing whitespace")
        path = Path(line)
        if path.is_absolute() or line in {"", "."}:
            raise HydrationError("declared paths must be non-empty relative paths")
        if any(part in {"", ".", "..", ".git"} for part in path.parts):
            raise HydrationError("declared paths must not traverse parents or Git internals")
        if line in seen:
            raise HydrationError("declared paths must be unique")
        seen.add(line)
        paths.append(path)
    return paths


def is_within(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
    except ValueError:
        return False
    return True


def require_directory(value: str, label: str) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise HydrationError(f"{label} is not a directory")
    return path


def git_path_is_ignored(worktree: Path, relative: Path) -> bool:
    try:
        result = subprocess.run(
            ["git", "-C", str(worktree), "check-ignore", "--quiet", "--", str(relative)],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise HydrationError("Git ignore validation could not run") from error
    if result.returncode not in {0, 1}:
        raise HydrationError("Git ignore validation failed")
    return result.returncode == 0


def preflight(source_root: Path, worktree: Path, paths: list[Path]) -> list[tuple[Path, Path]]:
    copies: list[tuple[Path, Path]] = []
    for relative in paths:
        source = source_root / relative
        resolved_source = source.resolve()
        if not is_within(source_root, resolved_source):
            raise HydrationError("declared source resolves outside the host root")
        if not source.is_file():
            raise HydrationError("declared source is not a regular file")

        target = worktree / relative
        resolved_parent = target.parent.resolve()
        if not is_within(worktree, resolved_parent):
            raise HydrationError("declared target resolves outside the worktree")
        if not git_path_is_ignored(worktree, relative):
            raise HydrationError("declared target is not ignored by Git")
        if target.exists() and not target.is_file():
            raise HydrationError("declared target is not a regular file")
        copies.append((source, target))
    return copies


def copy_atomically(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{target.name}.fkst-", dir=target.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def hydrate(source_root_value: str, worktree_value: str, raw_paths: str) -> int:
    paths = parse_paths(raw_paths)
    if not paths:
        return 0
    source_root = require_directory(source_root_value, "source root")
    worktree = require_directory(worktree_value, "worktree")
    copies = preflight(source_root, worktree, paths)
    for source, target in copies:
        try:
            copy_atomically(source, target)
        except OSError as error:
            raise HydrationError("declared file could not be copied") from error
    return len(copies)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--worktree", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        count = hydrate(args.source_root, args.worktree, os.environ.get(ENV_NAME, ""))
    except HydrationError as error:
        print(f"error: worktree local-file hydration failed: {error}", file=sys.stderr)
        return 2
    if count:
        suffix = "file" if count == 1 else "files"
        print(f"hydrated {count} worktree local {suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
