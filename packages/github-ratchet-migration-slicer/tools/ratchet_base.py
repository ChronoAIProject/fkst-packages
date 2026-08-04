"""Shared base resolvers for shrink-only ratchets."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path


SAFE_REF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/\-]*\Z")


def _git(root: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )


def resolve_dev_ref(root: Path) -> str | None:
    refs: list[str] = []
    override = os.environ.get("FKST_RATCHET_DEV_REF")
    if override:
        refs.append(override)
    refs.extend(("refs/remotes/origin/dev", "origin/dev", "refs/heads/dev", "dev"))

    for ref in refs:
        result = _git(root, ["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"])
        commit = result.stdout.strip()
        if result.returncode == 0 and commit:
            return commit
    return None


def _safe_ref(ref: str) -> bool:
    return ref not in {"", "HEAD"} and ".." not in ref and SAFE_REF_RE.fullmatch(ref) is not None


def _resolve_ref(root: Path, refs: tuple[str, ...]) -> str | None:
    for ref in refs:
        if not _safe_ref(ref):
            return None
        result = _git(root, ["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"])
        commit = result.stdout.strip()
        if result.returncode == 0 and commit:
            return commit
    return None


def resolve_target_ref(root: Path) -> str | None:
    # PR checks use their target branch; push and local checks retain dev as the canonical fallback.
    override = os.environ.get("FKST_RATCHET_TARGET_REF")
    if override:
        return _resolve_ref(root, (override,))

    github_base = os.environ.get("GITHUB_BASE_REF")
    if github_base:
        if not _safe_ref(github_base):
            return None
        return _resolve_ref(
            root,
            (
                f"refs/remotes/origin/{github_base}",
                f"origin/{github_base}",
                f"refs/heads/{github_base}",
                github_base,
            ),
        )

    return resolve_dev_ref(root)


def resolve_dev_merge_base(root: Path) -> str | None:
    commit = resolve_dev_ref(root)
    if commit is None:
        return None
    result = _git(root, ["merge-base", "HEAD", commit])
    base = result.stdout.strip()
    if result.returncode != 0 or not base:
        return None
    return base


def changed_paths(root: Path, target_commit: str, pathspec: str) -> list[str] | None:
    tracked = _git(
        root,
        ["diff", "--name-only", "--no-renames", target_commit, "--", pathspec],
    )
    if tracked.returncode != 0:
        return None
    untracked = _git(root, ["ls-files", "--others", "--exclude-standard", "--", pathspec])
    if untracked.returncode != 0:
        return None
    return sorted({
        line
        for output in (tracked.stdout, untracked.stdout)
        for line in output.splitlines()
        if line
    })


def show_file_at(root: Path, commit: str, path: str) -> str | None:
    result = _git(root, ["show", f"{commit}:{path}"])
    if result.returncode != 0:
        return None
    return result.stdout


def file_at_commit(root: Path, commit: str, path: str) -> tuple[str, str | None]:
    exists = _git(root, ["cat-file", "-e", f"{commit}:{path}"])
    if exists.returncode != 0:
        return "absent", None
    shown = show_file_at(root, commit, path)
    if shown is None:
        return "unresolved", None
    return "present", shown


def file_at_base(root: Path, path: str) -> tuple[str, str | None]:
    base_commit = resolve_dev_merge_base(root)
    if base_commit is None:
        return "unresolved", None

    return file_at_commit(root, base_commit, path)
