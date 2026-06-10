#!/usr/bin/env python3
"""Bootstrap fkst-framework from the fkst-substrate source pin."""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from resolve_substrate_ref import DEFAULT_REPOSITORY, parse_pin, read_pin


def fail(code: str, detail: str | None = None) -> int:
    suffix = f": {detail}" if detail else ""
    print(f"error: {code}{suffix}", file=sys.stderr)
    return 1


def require_command(name: str, code: str) -> bool:
    if shutil.which(name):
        return True
    print(f"error: {code}: required command not found: {name}", file=sys.stderr)
    return False


def cache_checkout() -> Path:
    cache_base = os.environ.get("XDG_CACHE_HOME") or (
        str(Path(os.environ["HOME"]) / ".cache") if os.environ.get("HOME") else ""
    )
    if not cache_base:
        raise ValueError("fkst-substrate-cache-root-missing: set XDG_CACHE_HOME or HOME")
    return Path(cache_base) / "fkst" / "fkst-substrate"


def run_checked(command: list[str], code: str, detail: str) -> None:
    try:
        subprocess.run(command, check=True, stdout=sys.stderr)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"{code}: {detail}") from exc


def git_ref_exists(checkout: Path, ref: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(checkout), "rev-parse", "--verify", "--quiet", ref],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def checkout_ref(checkout: Path, ref: str) -> str:
    remote_ref = f"refs/remotes/origin/{ref}"
    tag_ref = f"refs/tags/{ref}"
    if git_ref_exists(checkout, f"{remote_ref}^{{commit}}"):
        return remote_ref
    if git_ref_exists(checkout, f"{tag_ref}^{{commit}}"):
        return tag_ref
    return ref


def sync_checkout(repository: str, ref: str, checkout: Path) -> None:
    remote_url = f"https://github.com/{repository}.git"
    checkout.parent.mkdir(parents=True, exist_ok=True)

    if (checkout / ".git").is_dir():
        print(f"fetching fkst-substrate source pin: {repository}@{ref}", file=sys.stderr)
        run_checked(
            ["git", "-C", str(checkout), "remote", "set-url", "origin", remote_url],
            "fkst-substrate-remote-update-failed",
            repository,
        )
        run_checked(
            ["git", "-C", str(checkout), "fetch", "--tags", "--prune", "origin"],
            "fkst-substrate-fetch-failed",
            f"{repository}@{ref}",
        )
    elif checkout.exists():
        raise RuntimeError(f"fkst-substrate-cache-not-git: {checkout}")
    else:
        print(f"cloning fkst-substrate source pin: {repository}@{ref}", file=sys.stderr)
        run_checked(
            ["git", "clone", remote_url, str(checkout)],
            "fkst-substrate-clone-failed",
            f"{repository}@{ref}",
        )

    run_checked(
        ["git", "-C", str(checkout), "remote", "set-url", "origin", remote_url],
        "fkst-substrate-remote-update-failed",
        repository,
    )
    run_checked(
        ["git", "-C", str(checkout), "checkout", "--detach", checkout_ref(checkout, ref)],
        "fkst-substrate-checkout-failed",
        f"{repository}@{ref}",
    )


def build_framework(repository: str, ref: str, checkout: Path) -> Path:
    print(f"building fkst-framework from source pin: {repository}@{ref}", file=sys.stderr)
    run_checked(
        ["cargo", "build", "--manifest-path", str(checkout / "Cargo.toml"), "-p", "fkst-framework"],
        "fkst-substrate-build-failed",
        f"{repository}@{ref}",
    )
    return checkout / "target" / "debug" / "fkst-framework"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin-file", required=True, help="path to .fkst-substrate-ref")
    args = parser.parse_args()

    if os.environ.get("FKST_NO_AUTOBUILD"):
        print(
            "error: fkst-bin-unresolved-autobuild-disabled: "
            "fkst-framework binary not found and FKST_NO_AUTOBUILD is set",
            file=sys.stderr,
        )
        print("  configure BIN, repo .env, PATH, or sibling ../fkst-substrate.", file=sys.stderr)
        return 1

    try:
        repository, ref = parse_pin(read_pin(Path(args.pin_file)))
        if repository != DEFAULT_REPOSITORY:
            raise ValueError("fkst-substrate-bootstrap-repository-not-allowed")
        checkout = cache_checkout()
    except ValueError as exc:
        return fail("fkst-substrate-pin-invalid", str(exc))

    if not require_command("git", "fkst-substrate-bootstrap-git-missing"):
        return 1
    if not require_command("cargo", "fkst-substrate-bootstrap-cargo-missing"):
        return 1

    try:
        sync_checkout(repository, ref, checkout)
        bin_path = build_framework(repository, ref, checkout)
    except RuntimeError as exc:
        return fail(str(exc))

    print(f"BIN={shlex.quote(str(bin_path))}")
    print("FKST_BOOTSTRAPPED_BIN=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
