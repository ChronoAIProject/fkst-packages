#!/usr/bin/env python3
"""Resolve changed package and library paths to affected package targets."""

from __future__ import annotations

import sys
import tomllib
from collections import defaultdict, deque
from pathlib import Path


def manifests(root: Path, parent: str) -> list[tuple[Path, dict[str, object]]]:
    result = []
    for path in sorted((root / parent).glob("*/fkst.toml")):
        with path.open("rb") as stream:
            result.append((path, tomllib.load(stream)))
    return result


def string_list(manifest: dict[str, object], section: str, key: str) -> list[str]:
    table = manifest.get(section, {})
    if not isinstance(table, dict):
        raise ValueError(f"{section} must be a table")
    values = table.get(key, [])
    if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
        raise ValueError(f"{section}.{key} must be a string array")
    return values


def affected_packages(root: Path, changed_paths: list[str]) -> list[str]:
    reverse: dict[str, set[str]] = defaultdict(set)
    directory_nodes: dict[tuple[str, str], str] = {}
    package_targets: dict[str, str] = {}

    for path, manifest in manifests(root, "libraries"):
        if not isinstance(manifest.get("name"), str):
            raise ValueError(f"missing library name in {path}")
        node = f"library:{path.parent.name}"
        directory_nodes["libraries", path.parent.name] = node
        for dependency in string_list(manifest, "lib_deps", "libraries"):
            reverse[f"library:{dependency}"].add(node)

    for path, manifest in manifests(root, "packages"):
        if not isinstance(manifest.get("name"), str):
            raise ValueError(f"missing package name in {path}")
        node = f"package:{path.parent.name}"
        directory_nodes["packages", path.parent.name] = node
        package_targets[node] = path.parent.name
        for dependency in string_list(manifest, "lib_deps", "libraries"):
            reverse[f"library:{dependency}"].add(node)
        for dependency in string_list(manifest, "event_deps", "packages"):
            reverse[f"package:{dependency}"].add(node)

    seeds = set()
    for changed_path in changed_paths:
        parts = Path(changed_path).parts
        if len(parts) < 3 or parts[0] not in {"libraries", "packages"}:
            raise ValueError(f"unowned changed path: {changed_path}")
        node = directory_nodes.get((parts[0], parts[1]))
        if node is None:
            raise ValueError(f"unknown changed owner: {parts[0]}/{parts[1]}")
        seeds.add(node)

    reached = set(seeds)
    pending = deque(seeds)
    while pending:
        for dependent in reverse[pending.popleft()]:
            if dependent not in reached:
                reached.add(dependent)
                pending.append(dependent)

    return sorted(package_targets[node] for node in reached if node in package_targets)


def main() -> int:
    if len(sys.argv) != 3:
        return 2
    root = Path(sys.argv[1])
    changed_file = Path(sys.argv[2])
    try:
        changed_paths = [line for line in changed_file.read_text().splitlines() if line]
        for package in affected_packages(root, changed_paths):
            print(package)
    except (OSError, tomllib.TOMLDecodeError, ValueError) as error:
        print(f"test-affected: {error}; running full suite", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
