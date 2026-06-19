#!/usr/bin/env python3
"""Merge package-root Lua coverage artifacts into the repository artifact shape."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def production_lua_files(root: Path) -> dict[str, set[int]]:
    merged: dict[str, set[int]] = {}
    for base in ("packages", "std"):
        start = root / base
        if not start.exists():
            continue
        for path in start.rglob("*.lua"):
            if path.is_symlink():
                continue
            relpath = path.relative_to(root).as_posix()
            parts = relpath.split("/")
            if "tests" in parts or relpath.endswith(("_test.lua", "_helpers.lua", "_fake.lua")):
                continue
            merged.setdefault(relpath, set())
    return merged


def merge_package_artifact(merged: dict[str, set[int]], package: str, path: Path) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"coverage artifact must be a JSON object: {path}")
    for artifact_file, file_data in data.items():
        if not isinstance(artifact_file, str) or not isinstance(file_data, dict):
            continue
        if artifact_file.startswith("packages/") or artifact_file.startswith("std/"):
            repo_file = artifact_file
        elif artifact_file.startswith("../") or artifact_file.startswith("/"):
            repo_file = artifact_file
        else:
            repo_file = f"packages/{package}/{artifact_file}"
        covered = file_data.get("covered_lines", file_data.get("covered"))
        if covered is None:
            continue
        if not isinstance(covered, list):
            raise SystemExit(f"coverage artifact covered_lines must be a list: {path}:{artifact_file}")
        lines = merged.setdefault(repo_file, set())
        for line in covered:
            if isinstance(line, bool):
                raise SystemExit(f"coverage line must be a positive integer: {path}:{artifact_file}")
            line_int = int(line)
            if line_int < 1:
                raise SystemExit(f"coverage line must be a positive integer: {path}:{artifact_file}")
            lines.add(line_int)


def parse_input(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise SystemExit(f"coverage input must be PACKAGE=PATH: {value}")
    package, raw_path = value.split("=", 1)
    if not package or not raw_path:
        raise SystemExit(f"coverage input must be PACKAGE=PATH: {value}")
    return package, Path(raw_path)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        raise SystemExit("usage: write_lua_coverage_fallback_artifact.py ROOT OUTPUT [PACKAGE=PATH ...]")
    root = Path(argv[1])
    output = Path(argv[2])
    merged = production_lua_files(root)
    for value in argv[3:]:
        package, path = parse_input(value)
        merge_package_artifact(merged, package, path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            {file: {"covered_lines": sorted(lines)} for file, lines in sorted(merged.items())},
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
