"""Shared base resolvers for shrink-only ratchets."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path


SAFE_REF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/\-]*\Z")


class ConfigurationFailure(str):
    """A producer-owned diagnostic for an unevaluable repository-check configuration."""


class GitInvocationFailure(RuntimeError):
    """A producer-typed failure to start the git observation instrument."""

    def __init__(self, fault_class: str, command: str, cause: OSError) -> None:
        if fault_class not in {"TOOLCHAIN", "INFRASTRUCTURE"}:
            raise ValueError(f"unsupported git invocation fault class: {fault_class}")
        self.fault_class = fault_class
        self.command = command
        self.cause = cause
        super().__init__(
            f"{command} could not start: {type(cause).__name__}: {cause}"
        )


def configuration_failure(message: str) -> ConfigurationFailure:
    return ConfigurationFailure(message)


def _git(root: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    command = "git " + " ".join(args)
    try:
        return subprocess.run(
            ["git", *args],
            cwd=root,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        fault_class = "TOOLCHAIN" if exc.filename == "git" else "INFRASTRUCTURE"
        raise GitInvocationFailure(fault_class, command, exc) from exc


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


def _resolve_branch_ref(root: Path, branch: str) -> str | None:
    if not _safe_ref(branch):
        return None
    return _resolve_ref(
        root,
        (
            f"refs/remotes/origin/{branch}",
            f"origin/{branch}",
            f"refs/heads/{branch}",
            branch,
        ),
    )


def _github_event_before() -> str | None:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not event_path:
        return None
    try:
        event = json.loads(Path(event_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(event, dict):
        return None
    before = event.get("before")
    return before if isinstance(before, str) and before else None


def resolve_target_ref(root: Path) -> str | None:
    # Use explicit CI and host topology facts; dev is the fallback when no target is configured.
    override = os.environ.get("FKST_RATCHET_TARGET_REF")
    if override:
        return _resolve_ref(root, (override,))

    github_base = os.environ.get("GITHUB_BASE_REF")
    if github_base:
        return _resolve_branch_ref(root, github_base)

    if os.environ.get("GITHUB_EVENT_NAME") == "push" and os.environ.get("GITHUB_REF_TYPE") == "branch":
        before = _github_event_before()
        return _resolve_ref(root, (before,)) if before else None

    integration_branch = os.environ.get("FKST_DEVLOOP_INTEGRATION_BRANCH")
    if integration_branch:
        return _resolve_branch_ref(root, integration_branch)

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
