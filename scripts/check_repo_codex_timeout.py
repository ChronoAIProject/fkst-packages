#!/usr/bin/env python3
"""Guard production codex timeout defaults behind the workflow resolver."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable, Iterable

CODEX_RUN_CALL_RE = re.compile(r"\b(?P<call>spawn_codex(?:_sync)?|workflow_codex\s*\.\s*dispatch)\s*\(")
NUMERIC_TIMEOUT_RE = re.compile(r"\btimeout\s*=\s*(?:\d+\s*(?:\*\s*\d+\s*)*)")
NUMERIC_TIMEOUT_ASSIGN_RE = re.compile(
    r"\b(?P<opts>[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*timeout\s*=\s*(?:\d+\s*(?:\*\s*\d+\s*)*)"
)
NUMERIC_CONST_ASSIGN_RE = re.compile(
    r"\b(?:local\s+)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:\d+\s*(?:\*\s*\d+\s*)*)"
)
TIMEOUT_VAR_ASSIGN_RE = re.compile(
    r"\b(?P<opts>[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*timeout\s*=\s*(?P<value>[A-Za-z_][A-Za-z0-9_]*)"
)
CODEX_TIMEOUT_CONST_RE = re.compile(
    r"\b(?:local\s+)?(?=[A-Za-z_][A-Za-z0-9_]*\s*=)(?=[A-Za-z0-9_]*codex_timeout)[A-Za-z_][A-Za-z0-9_]*\s*=\s*(?:\d+\s*(?:\*\s*\d+\s*)*)",
    re.IGNORECASE,
)


def matching_lua_paren(text: str, open_index: int) -> int | None:
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    return None


def variable_used_as_codex_opts_argument(stripped: str, name: str, start: int) -> bool:
    escaped = re.escape(name)
    lua_arg_re = re.compile(r"(?:^|,)\s*" + escaped + r"\s*(?:,|$)")
    for call in CODEX_RUN_CALL_RE.finditer(stripped, start):
        close = matching_lua_paren(stripped, call.end() - 1)
        if close is None:
            continue
        body = stripped[call.end() : close]
        call_name = re.sub(r"\s+", "", call.group("call"))
        if call_name.startswith("spawn_codex"):
            if re.fullmatch(r"\s*" + escaped + r"\s*", body):
                return True
        elif call_name == "workflow_codex.dispatch" and lua_arg_re.search(body):
            return True
    return False


def codex_timeout_literal_lines(
    text: str,
    strip_lua_comments_and_strings: Callable[[str], str],
) -> list[int]:
    stripped = strip_lua_comments_and_strings(text)
    lines: set[int] = set()
    numeric_const_lines = {
        match.group("name"): text.count("\n", 0, match.start()) + 1
        for match in NUMERIC_CONST_ASSIGN_RE.finditer(stripped)
    }
    for match in CODEX_TIMEOUT_CONST_RE.finditer(stripped):
        lines.add(text.count("\n", 0, match.start()) + 1)
    for match in NUMERIC_TIMEOUT_ASSIGN_RE.finditer(stripped):
        if variable_used_as_codex_opts_argument(stripped, match.group("opts"), match.end()):
            lines.add(text.count("\n", 0, match.start()) + 1)
    for match in TIMEOUT_VAR_ASSIGN_RE.finditer(stripped):
        const_line = numeric_const_lines.get(match.group("value"))
        if const_line is not None and variable_used_as_codex_opts_argument(stripped, match.group("opts"), match.end()):
            lines.add(const_line)
    for call in CODEX_RUN_CALL_RE.finditer(stripped):
        close = matching_lua_paren(stripped, call.end() - 1)
        if close is None:
            continue
        body = stripped[call.end() : close]
        for match in NUMERIC_TIMEOUT_RE.finditer(body):
            lines.add(text.count("\n", 0, call.end() + match.start()) + 1)
    return sorted(lines)


def repository_messages(
    root: Path,
    package_lua_files: Callable[[Path], Iterable[tuple[Path, Path]]],
    read_text: Callable[[Path], str],
    rel: Callable[[Path, Path], str],
    strip_lua_comments_and_strings: Callable[[str], str],
) -> list[str]:
    messages: list[str] = []
    for packages, path in package_lua_files(root):
        package_relative = path.relative_to(packages)
        if "tests" in package_relative.parts:
            continue
        for line in codex_timeout_literal_lines(read_text(path), strip_lua_comments_and_strings):
            messages.append(
                f"{rel(root, path)}:{line} production codex timeout defaults must come from workflow_internal.codex"
            )
    return messages
