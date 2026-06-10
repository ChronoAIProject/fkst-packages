#!/usr/bin/env python3
"""Resolve the fkst-substrate source pin used by local scripts and CI."""

from __future__ import annotations

import argparse
import re
import shlex
import sys
from pathlib import Path


DEFAULT_REPOSITORY = "ChronoAIProject/fkst-substrate"
DEFAULT_REF = "dev"
REPOSITORY_RE = re.compile(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")


def parse_pin(raw: str | None) -> tuple[str, str]:
    pin = "".join((raw or "").split())
    if not pin:
        return DEFAULT_REPOSITORY, DEFAULT_REF
    if "@" not in pin:
        return DEFAULT_REPOSITORY, pin

    repository, ref = pin.split("@", 1)
    if not repository or not ref:
        raise ValueError("invalid-substrate-pin-empty-part")
    if "@" in ref:
        raise ValueError("invalid-substrate-pin-too-many-at")
    if not REPOSITORY_RE.fullmatch(repository):
        raise ValueError("invalid-substrate-pin-repository")
    return repository, ref


def read_pin(path: Path) -> str:
    if not path.exists():
        return ""
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped:
                return stripped
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin", default=None, help="explicit pin text")
    parser.add_argument("--file", default=None, help="pin file path")
    parser.add_argument(
        "--format",
        choices=("shell", "github-output"),
        default="shell",
        help="output format",
    )
    args = parser.parse_args()

    try:
        raw = args.pin if args.pin is not None else read_pin(Path(args.file)) if args.file else ""
        repository, ref = parse_pin(raw)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.format == "github-output":
        print(f"repository={repository}")
        print(f"ref={ref}")
    else:
        print(f"FKST_SUBSTRATE_REPOSITORY={shlex.quote(repository)}")
        print(f"FKST_SUBSTRATE_REF={shlex.quote(ref)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
