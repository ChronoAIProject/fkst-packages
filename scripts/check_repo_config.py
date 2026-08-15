#!/usr/bin/env python3
"""Configuration for the published repository conformance seam."""

from __future__ import annotations

import argparse
from collections.abc import Callable
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from typing import TypeVar

import ratchet_base


ParsedAllowlist = TypeVar("ParsedAllowlist")
ConfigurationFailure = ratchet_base.ConfigurationFailure
configuration_failure = ratchet_base.configuration_failure


OWN_REPO_ROOT = Path(__file__).resolve().parents[1]
GENERIC_RATCHETS = (
    "line/file limits",
    "test shape/helper reachability",
    "fkst package layout",
    "gh/git adapter boundary",
    "dedup",
    "producer-liveness",
    "ingress",
    "monotone-gate",
    "content-truncation",
    "version-suffix",
    "coverage",
    "saga-head/free-form-saga",
    "namespaced-queue",
    "permission-control",
)
LIBRARY_B_SPECIFIC_RATCHETS = (
    "std_dependency_model",
    "devloop product knowledge",
    "github-devloop saga-split guards",
    "github-devloop-intake-default surface guard",
)


@dataclass(frozen=True)
class CheckRepoConfig:
    project_root: Path
    allowlist_dir: Path | None
    platform_root: Path | None = None
    own_repo_root: Path = OWN_REPO_ROOT

    @property
    def is_own_repo(self) -> bool:
        return same_path(self.project_root, self.own_repo_root)


def same_path(left: Path, right: Path) -> bool:
    return left.resolve() == right.resolve()


def resolve_dir(path: str | Path) -> Path:
    return Path(path).expanduser().resolve()


def default_project_root() -> Path:
    return OWN_REPO_ROOT


def parse_args(argv: list[str] | None = None) -> CheckRepoConfig:
    parser = argparse.ArgumentParser(description="Run fkst package repository conformance ratchets.")
    parser.add_argument(
        "--project-root",
        type=resolve_dir,
        default=default_project_root(),
        help="repository tree to check; defaults to this fkst-packages checkout",
    )
    parser.add_argument(
        "--allowlist-dir",
        type=resolve_dir,
        help="directory containing *.allowlist waiver files; defaults to <project-root>/migration",
    )
    parser.add_argument(
        "--platform-root",
        type=resolve_dir,
        help="fkst-packages checkout to include for host-owned integration coverage edges",
    )
    args = parser.parse_args(argv)
    return CheckRepoConfig(project_root=args.project_root, allowlist_dir=args.allowlist_dir, platform_root=args.platform_root)


def package_roots(project_root: Path) -> list[Path]:
    packages = project_root / "packages"
    if same_path(project_root, OWN_REPO_ROOT):
        return [packages]
    local_packages = project_root / ".fkst" / "local-packages"
    roots = [packages, local_packages]
    existing = [root for root in roots if root.exists()]
    return existing if existing else [packages]


def package_root(project_root: Path) -> Path:
    return package_roots(project_root)[0]


def allowlist_path(root: Path, allowlist_dir: Path | None, relpath: str) -> Path:
    if allowlist_dir is None:
        return root / relpath
    return allowlist_dir / Path(relpath).name


def load_allowlist(path: Path, *, parse_allowlist_lines: Callable[[list[str]], set[str]]) -> set[str]:
    if not path.exists():
        return set()
    return parse_allowlist_lines(path.read_text(encoding="utf-8").splitlines())


def allowlist_at_dev_base(
    root: Path,
    *,
    allowlist: str,
    parse_allowlist_lines: Callable[[list[str]], ParsedAllowlist],
    catch_errors: bool = True,
) -> tuple[str, ParsedAllowlist | None]:
    try:
        status, shown = ratchet_base.file_at_base(root, allowlist)
        if status != "present":
            return status, None
        assert shown is not None
        return "present", parse_allowlist_lines(shown.splitlines())
    except Exception:
        if not catch_errors:
            raise
        return "unresolved", None


def bind_allowlist_helpers(
    allowlist: str,
    parse_allowlist_lines: Callable[[list[str]], set[str]],
) -> tuple[Callable[[Path], set[str]], Callable[[Path], tuple[str, set[str] | None]]]:
    return (
        partial(load_allowlist, parse_allowlist_lines=parse_allowlist_lines),
        partial(
            allowlist_at_dev_base,
            allowlist=allowlist,
            parse_allowlist_lines=parse_allowlist_lines,
        ),
    )
