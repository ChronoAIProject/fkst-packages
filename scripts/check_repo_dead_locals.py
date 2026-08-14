#!/usr/bin/env python3
"""Reject Lua local functions with no other identifier occurrence in their file."""

from __future__ import annotations

import re
from collections import Counter
from pathlib import Path

import check_repo_lua


LOCAL_FUNCTION_RE = re.compile(
    r"\blocal\s+function\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\("
)
POSITIVE_CONTROL_NAME = "fkst_dead_local_positive_control"
POSITIVE_CONTROL_SOURCE = f"local function {POSITIVE_CONTROL_NAME}() end\n"


def dead_local_functions(source: str) -> list[tuple[int, str]]:
    code = check_repo_lua.code_mask(source)
    occurrences = Counter(check_repo_lua.LUA_WORD_RE.findall(code))
    return [
        (source.count("\n", 0, match.start()) + 1, match.group("name"))
        for match in LOCAL_FUNCTION_RE.finditer(code)
        if occurrences[match.group("name")] == 1
    ]


def lua_files(root: Path) -> list[Path]:
    return [
        path
        for source_root in (root / "libraries", root / "packages")
        if source_root.exists()
        for path in sorted(source_root.rglob("*.lua"))
        if path.is_file()
    ]


def verify_positive_control() -> None:
    expected = [(1, POSITIVE_CONTROL_NAME)]
    actual = dead_local_functions(POSITIVE_CONTROL_SOURCE)
    if actual != expected:
        raise RuntimeError(
            f"dead-local positive control failed: expected {expected!r}, got {actual!r}"
        )


def repository_messages(root: Path) -> list[str]:
    verify_positive_control()
    messages: list[str] = []
    for path in lua_files(root):
        source = path.read_text(encoding="utf-8")
        for line, name in dead_local_functions(source):
            messages.append(
                f"{path.relative_to(root).as_posix()}:{line} "
                f"local function {name!r} is unreachable within its file"
            )
    return messages
