#!/usr/bin/env python3
"""Detect package Lua shell-outs to the framework binary."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable, Iterable

ALLOWLIST = "migration/shell-out-to-self.allowlist"
ENGINE_SELF_SUBCOMMANDS = {
    "observe",
    "test",
    "run",
    "supervise",
    "health",
    "conformance",
    "self-test",
    "--self-test",
}
ARGV_RE = re.compile(
    r"\b(?:exec_argv|run_argv)\s*\([^)]*\bargv\s*=\s*\{[^}]*"
    r"(?:\b(?:BIN|bin|framework_bin)\b|['\"]fkst-framework['\"])[^}]*,\s*"
    r"['\"](?P<subcommand>[A-Za-z0-9_-]+)['\"]",
    re.DOTALL,
)
SYNC_RE = re.compile(
    r"\b(?:exec_sync|run_sync)\s*\([^)]*(?:fkst-framework|\bBIN\b|\bbin\b|\bframework_bin\b)"
    r"[^)]*['\"](?P<subcommand>[A-Za-z0-9_-]+)['\"]",
    re.DOTALL,
)


def long_bracket_at(text: str, index: int) -> tuple[int, str] | None:
    if index >= len(text) or text[index] != "[":
        return None
    cursor = index + 1
    while cursor < len(text) and text[cursor] == "=":
        cursor += 1
    if cursor >= len(text) or text[cursor] != "[":
        return None
    return cursor - index + 1, "]" + ("=" * (cursor - index - 1)) + "]"


def end_of_long_bracket(text: str, body_start: int, closer: str) -> int:
    close_start = text.find(closer, body_start)
    return len(text) if close_start == -1 else close_start + len(closer)


def mask_span(chars: list[str], start: int, end: int) -> None:
    for index in range(start, end):
        if chars[index] != "\n":
            chars[index] = " "


def strip_lua_comments(text: str) -> str:
    chars = list(text)
    cursor = 0
    while cursor < len(text):
        if text.startswith("--", cursor):
            bracket = long_bracket_at(text, cursor + 2)
            if bracket is not None:
                opener_len, closer = bracket
                end = end_of_long_bracket(text, cursor + 2 + opener_len, closer)
            else:
                newline = text.find("\n", cursor)
                end = len(text) if newline == -1 else newline
            mask_span(chars, cursor, end)
            cursor = end
            continue
        cursor += 1
    return "".join(chars)


def load_allowlist(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")}


def literal_sites(relpath: str, literal) -> set[str]:
    content = literal.content
    if "fkst-framework" not in content and " observe " not in content and " test " not in content and " run " not in content:
        return set()
    tokens = content.split()
    if not any(token.endswith("fkst-framework") or token == "fkst-framework" or "$BIN" in token or "${BIN}" in token for token in tokens):
        return set()
    return {f"{relpath}:line={literal.line}:string:{token}" for token in tokens if token in ENGINE_SELF_SUBCOMMANDS}


def source_sites(relpath: str, source: str, strip_lua_comments_and_strings: Callable[[str], str], lua_string_literals: Callable[[str], Iterable]) -> set[str]:
    current: set[str] = set()
    stripped = strip_lua_comments(source)
    for match in ARGV_RE.finditer(stripped):
        subcommand = match.group("subcommand")
        if subcommand in ENGINE_SELF_SUBCOMMANDS:
            current.add(f"{relpath}:line={source.count(chr(10), 0, match.start()) + 1}:argv:{subcommand}")
    for match in SYNC_RE.finditer(stripped):
        subcommand = match.group("subcommand")
        if subcommand in ENGINE_SELF_SUBCOMMANDS:
            current.add(f"{relpath}:line={source.count(chr(10), 0, match.start()) + 1}:sync:{subcommand}")
    for literal in lua_string_literals(source):
        current.update(literal_sites(relpath, literal))
    return current


def sites(root: Path, package_roots: list[Path], read_text, rel, strip_lua_comments_and_strings, lua_string_literals) -> set[str]:
    current: set[str] = set()
    for packages in package_roots:
        for package in sorted(packages.glob("*")):
            if not package.is_dir():
                continue
            for path in sorted(package.rglob("*.lua")):
                if path.is_file():
                    current.update(source_sites(rel(root, path), read_text(path), strip_lua_comments_and_strings, lua_string_literals))
    return current


def ratchet_messages(current: set[str], allowlist: set[str]) -> list[str]:
    messages = [
        f"{site} shells out to the framework binary; use the in-process SDK primitive instead or list pre-existing debt in {ALLOWLIST}"
        for site in sorted(current - allowlist)
    ]
    messages.extend(
        f"{site} listed in {ALLOWLIST} but no longer detected; prune the stale entry"
        for site in sorted(allowlist - current)
    )
    return messages
