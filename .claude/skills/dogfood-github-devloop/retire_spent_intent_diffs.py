#!/usr/bin/env python3
"""Retire intent-diff manifests whose attested PR merge is in the synced head."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any


ALLOWLIST = Path("migration/intent-bounded-replay.allowlist")
MANIFEST_DIR = Path("migration/intent-diffs")
MANIFEST_RE = re.compile(r"(?P<pr>[1-9][0-9]*)\.json\Z")
GIT_SHA_RE = re.compile(r"[0-9a-f]{40,64}\Z")
REF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/\-]*\Z")
REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
RETIREMENT_COMMIT_MESSAGE = "chore(migration): retire spent intent-diff manifests"
RETIREMENT_RESULT_SCHEMA = "fkst.intent-diff-retirement.v1"


class RetirementError(RuntimeError):
    pass


def _run(argv: list[str], root: Path) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            argv,
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as error:
        raise RetirementError(f"cannot execute {argv[0]}: {error}") from error


def _run_required(
    argv: list[str], root: Path, operation: str
) -> subprocess.CompletedProcess[str]:
    result = _run(argv, root)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no error detail"
        raise RetirementError(f"{operation} failed: {detail}")
    return result


def _git_commit(root: Path, ref: str) -> str:
    result = _run_required(
        ["git", "rev-parse", "--verify", f"{ref}^{{commit}}"],
        root,
        f"cannot resolve {ref}",
    )
    commit = result.stdout.strip()
    if GIT_SHA_RE.fullmatch(commit) is None:
        raise RetirementError(f"{ref} did not resolve to a commit SHA")
    return commit


def _remote_branch_head(root: Path, branch: str) -> str:
    ref = f"refs/heads/{branch}"
    result = _run_required(
        ["git", "ls-remote", "--heads", "origin", ref],
        root,
        f"cannot read remote branch {branch}",
    )
    fields = result.stdout.split()
    if len(fields) != 2 or fields[1] != ref or GIT_SHA_RE.fullmatch(fields[0]) is None:
        raise RetirementError(f"remote branch {branch} did not resolve to one commit")
    return fields[0]


def _manifest_pr(path: Path) -> int:
    match = MANIFEST_RE.fullmatch(path.name)
    if match is None:
        raise RetirementError(f"invalid numbered intent-diff path: {path}")
    filename_pr = int(match.group("pr"))
    try:
        artifact = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RetirementError(f"cannot read {path}: {error}") from error
    if not isinstance(artifact, dict):
        raise RetirementError(f"{path} must contain a JSON object")
    if artifact.get("schema") != "fkst.intent-diff.v2":
        raise RetirementError(f"{path} must use schema fkst.intent-diff.v2")
    pr_number = artifact.get("pr_number")
    if not isinstance(pr_number, int) or isinstance(pr_number, bool) or pr_number != filename_pr:
        raise RetirementError(f"{path} pr_number must match its filename")
    return pr_number


def _merge_commit(root: Path, github_repo: str, pr_number: int) -> str | None:
    result = _run(
        [
            "gh",
            "pr",
            "view",
            str(pr_number),
            "--repo",
            github_repo,
            "--json",
            "state,mergeCommit",
        ],
        root,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "no error detail"
        raise RetirementError(f"PR#{pr_number} merge fact read failed: {detail}")
    try:
        fact: Any = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RetirementError(f"PR#{pr_number} merge fact is not valid JSON") from error
    if not isinstance(fact, dict) or not isinstance(fact.get("state"), str):
        raise RetirementError(f"PR#{pr_number} merge fact is missing state")
    if fact["state"].upper() != "MERGED":
        return None
    merge_commit = fact.get("mergeCommit")
    oid = merge_commit.get("oid") if isinstance(merge_commit, dict) else None
    if not isinstance(oid, str) or GIT_SHA_RE.fullmatch(oid) is None:
        raise RetirementError(f"PR#{pr_number} merged fact is missing mergeCommit.oid")
    return oid


def _is_ancestor(root: Path, commit: str, protected_ref: str) -> bool:
    result = _run(
        ["git", "merge-base", "--is-ancestor", commit, protected_ref],
        root,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    detail = result.stderr.strip() or "no error detail"
    raise RetirementError(
        f"cannot prove merge commit {commit} ancestry of {protected_ref}: {detail}"
    )


def _entry(raw: str) -> str:
    return raw.split("#", 1)[0].strip()


def _require_clean_policy_paths(root: Path) -> None:
    result = _run(
        [
            "git",
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--",
            MANIFEST_DIR.as_posix(),
            ALLOWLIST.as_posix(),
        ],
        root,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "no error detail"
        raise RetirementError(f"cannot inspect intent-diff policy paths: {detail}")
    if result.stdout.strip():
        raise RetirementError("intent-diff policy paths have pre-existing worktree changes")


def retirement_plan(root: Path, github_repo: str, protected_ref: str) -> list[Path]:
    manifest_dir = root / MANIFEST_DIR
    allowlist_path = root / ALLOWLIST
    if not manifest_dir.exists() and not allowlist_path.exists():
        return []
    if not manifest_dir.is_dir():
        raise RetirementError(f"missing intent-diff directory: {MANIFEST_DIR}")
    if not allowlist_path.is_file():
        raise RetirementError(f"missing intent-diff allowlist: {ALLOWLIST}")
    _require_clean_policy_paths(root)

    candidates = sorted(
        path
        for path in manifest_dir.iterdir()
        if path.is_file() and MANIFEST_RE.fullmatch(path.name) is not None
    )
    spent: list[Path] = []
    for path in candidates:
        pr_number = _manifest_pr(path)
        merge_commit = _merge_commit(root, github_repo, pr_number)
        if merge_commit is not None and _is_ancestor(root, merge_commit, protected_ref):
            spent.append(path)

    lines = allowlist_path.read_text(encoding="utf-8").splitlines()
    entries = [_entry(line) for line in lines]
    for path in spent:
        relative = path.relative_to(root).as_posix()
        if entries.count(relative) != 1:
            raise RetirementError(
                f"{relative} must have exactly one allowlist entry before retirement"
            )
    return spent


def apply_retirement(root: Path, spent: list[Path]) -> None:
    if not spent:
        return
    allowlist_path = root / ALLOWLIST
    original = allowlist_path.read_text(encoding="utf-8")
    retired = {path.relative_to(root).as_posix() for path in spent}
    retained = [line for line in original.splitlines() if _entry(line) not in retired]
    replacement = "\n".join(retained)
    if original.endswith("\n") or replacement:
        replacement += "\n"

    temporary = allowlist_path.with_name(f".{allowlist_path.name}.retirement.tmp")
    try:
        temporary.write_text(replacement, encoding="utf-8")
        for path in spent:
            path.unlink()
        os.replace(temporary, allowlist_path)
    except OSError as error:
        raise RetirementError(f"cannot apply intent-diff retirement: {error}") from error
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _commit_retirement(root: Path) -> str:
    _run_required(
        [
            "git",
            "add",
            "-A",
            "--",
            MANIFEST_DIR.as_posix(),
            ALLOWLIST.as_posix(),
        ],
        root,
        "cannot stage intent-diff retirement",
    )
    _run_required(
        ["git", "commit", "-m", RETIREMENT_COMMIT_MESSAGE],
        root,
        "cannot commit intent-diff retirement",
    )
    return _git_commit(root, "HEAD")


def promote_retirement(
    root: Path, github_repo: str, branch: str, expected_head: str
) -> tuple[list[str], str]:
    _run_required(
        ["git", "fetch", "--no-tags", "origin", f"refs/heads/{branch}"],
        root,
        f"cannot fetch integration branch {branch}",
    )
    fetched_head = _git_commit(root, "FETCH_HEAD")
    if fetched_head != expected_head:
        raise RetirementError(
            f"integration branch {branch} head changed: expected {expected_head}, got {fetched_head}"
        )

    relative_paths: list[str] = []
    published_head = expected_head
    with tempfile.TemporaryDirectory(prefix="fkst-intent-retirement-") as temporary_root:
        worktree = Path(temporary_root) / "checkout"
        _run_required(
            ["git", "worktree", "add", "--detach", str(worktree), expected_head],
            root,
            "cannot create intent-diff retirement worktree",
        )
        try:
            spent = retirement_plan(worktree, github_repo, "HEAD")
            relative_paths = [path.relative_to(worktree).as_posix() for path in spent]
            apply_retirement(worktree, spent)
            if spent:
                published_head = _commit_retirement(worktree)
                branch_ref = f"refs/heads/{branch}"
                _run_required(
                    [
                        "git",
                        "push",
                        f"--force-with-lease={branch_ref}:{expected_head}",
                        "origin",
                        f"{published_head}:{branch_ref}",
                    ],
                    root,
                    "cannot publish intent-diff retirement",
                )
                if _remote_branch_head(root, branch) != published_head:
                    raise RetirementError("published intent-diff retirement head was not observable")
        finally:
            cleanup = _run(
                ["git", "worktree", "remove", "--force", str(worktree)], root
            )
            if cleanup.returncode != 0:
                detail = cleanup.stderr.strip() or "no error detail"
                if sys.exc_info()[0] is None:
                    raise RetirementError(
                        f"cannot remove intent-diff retirement worktree: {detail}"
                    )
                print(
                    f"intent-diff-retirement: worktree cleanup failed: {detail}",
                    file=sys.stderr,
                )
    return relative_paths, published_head


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--github-repo", required=True)
    parser.add_argument("--protected-ref", required=True)
    parser.add_argument("--promote-branch")
    args = parser.parse_args(argv)
    if REPO_RE.fullmatch(args.github_repo) is None:
        parser.error("--github-repo must be owner/repo")
    if REF_RE.fullmatch(args.protected_ref) is None or ".." in args.protected_ref:
        parser.error("--protected-ref must be a safe git ref")
    if args.promote_branch is not None:
        if REF_RE.fullmatch(args.promote_branch) is None or ".." in args.promote_branch:
            parser.error("--promote-branch must be a safe git branch")
        if GIT_SHA_RE.fullmatch(args.protected_ref) is None:
            parser.error("--protected-ref must be an exact commit in promotion mode")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = args.repo_root.resolve()
    try:
        if args.promote_branch is not None:
            paths, head = promote_retirement(
                root, args.github_repo, args.promote_branch, args.protected_ref
            )
            print(
                json.dumps(
                    {
                        "schema": RETIREMENT_RESULT_SCHEMA,
                        "retired": len(paths),
                        "paths": paths,
                        "head": head,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
            return 0
        spent = retirement_plan(root, args.github_repo, args.protected_ref)
        apply_retirement(root, spent)
    except (RetirementError, OSError, UnicodeError) as error:
        print(f"intent-diff-retirement: {error}", file=sys.stderr)
        return 1
    paths = ",".join(path.relative_to(root).as_posix() for path in spent)
    print(f"intent-diff-retirement: retired={len(spent)} paths={paths or '-'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
