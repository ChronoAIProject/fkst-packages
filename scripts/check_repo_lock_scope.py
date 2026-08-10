#!/usr/bin/env python3
"""Shrink-only ratchet for external IO performed inside a with_lock critical section.

A lock's critical section may contain only the read-modify-write of the state that
lock protects. Reads-for-decision, long sequences and anything that talks to the
network belong outside it, with an in-lock currency/CAS re-check. Holding a lock
across `gh`/`git`/codex IO turns a per-entity mutex into a queue: measured holds of
minutes tempfail every other consumer of that key with exit=75, and a blocking hold
inside an already-admitted child also owns a global admission slot for its duration.

Scope of what this can see: the callback body is matched lexically, so this catches
IO invoked DIRECTLY inside the callback. IO reached through a helper call is not
visible here and stays the responsibility of review plus the site audit. Do not
describe this checker as proving a lock is IO-free.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

ALLOWLIST = "migration/lock-scope.allowlist"

# Primitives and adapter handles that perform external IO.
IO_CALLS = (
    ("exec_sync", re.compile(r"(?<![\w.])exec_sync\s*\(")),
    ("exec_argv", re.compile(r"(?<![\w.])exec_argv\s*\(")),
    ("spawn_codex", re.compile(r"(?<![\w.])spawn_codex(?:_sync)?\s*\(")),
    ("forge_handle", re.compile(r"\b(?:core\.)?(?:github|git)\s*\.\s*[a-z_]+\s*\(")),
    ("forge_factory", re.compile(r"\bgithub_factory\s*\.\s*production_handle\s*\(")),
)

OPENERS = re.compile(r"(?<![\w.])(?:function|if|for|while|do)(?![\w])")
ELSEIF = re.compile(r"(?<![\w.])elseif(?![\w])")
CLOSERS = re.compile(r"(?<![\w.])end(?![\w])")
WITH_LOCK = re.compile(r"(?<![\w.])with_lock\s*\(")


@dataclass(frozen=True, order=True)
class LockScopeSite:
    path: str
    line: int
    kind: str

    def label(self) -> str:
        return f"{self.path}:{self.line} {self.kind}"

    def key(self) -> str:
        return f"{self.path}:{self.line}:{self.kind}"


@dataclass(frozen=True, order=True)
class AllowlistEntry:
    key: str
    why: str


def strip_lua(line: str) -> str:
    """Remove comments and string bodies so keywords inside them do not count."""
    text = re.sub(r"--\[\[.*?\]\]", " ", line)
    text = re.sub(r"--.*$", "", text)
    text = re.sub(r"\[\[.*?\]\]", "''", text)
    text = re.sub(r"'(?:\\.|[^'\\])*'", "''", text)
    text = re.sub(r'"(?:\\.|[^"\\])*"', "''", text)
    return text


def callback_lines(lines: list[str], start: int) -> list[tuple[int, str]]:
    """Lines of the with_lock(...) call at `start`, matched by Lua keyword depth."""
    depth = 0
    body: list[tuple[int, str]] = []
    for index in range(start, len(lines)):
        code = strip_lua(lines[index])
        body.append((index + 1, code))
        depth += len(OPENERS.findall(code)) - len(ELSEIF.findall(code)) - len(CLOSERS.findall(code))
        if index > start and depth <= 0:
            break
        if index == start and depth <= 0:
            break
    return body


def lua_sources(root: Path) -> list[Path]:
    found: list[Path] = []
    for base in ("packages", "libraries"):
        directory = root / base
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.lua")):
            parts = path.parts
            if "tests" in parts or path.name.endswith("_test.lua"):
                continue
            found.append(path)
    return found


def sites(root: Path) -> list[LockScopeSite]:
    found: list[LockScopeSite] = []
    for path in lua_sources(root):
        rel = path.relative_to(root).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if not WITH_LOCK.search(strip_lua(line)):
                continue
            body = callback_lines(lines, index)
            seen: set[str] = set()
            for _, code in body[1:]:
                for kind, pattern in IO_CALLS:
                    if kind not in seen and pattern.search(code):
                        seen.add(kind)
            for kind in sorted(seen):
                found.append(LockScopeSite(rel, index + 1, kind))
    return sorted(found)


def read_allowlist(path: Path) -> list[AllowlistEntry]:
    if not path.is_file():
        return []
    entries: list[AllowlistEntry] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, _, why = line.partition("|")
        entries.append(AllowlistEntry(key.strip(), why.strip()))
    return entries


def repository_messages(root: Path, allowlist_dir=None, enforce_base: bool = True) -> list[str]:
    base = Path(allowlist_dir) if allowlist_dir is not None else root
    allowed = {entry.key: entry for entry in read_allowlist(base / ALLOWLIST)}
    observed = sites(root)
    messages: list[str] = []

    for site in observed:
        if site.key() not in allowed:
            messages.append(
                f"{site.label()} performs external IO inside a with_lock critical section; "
                "move the read outside the lock and keep only the currency re-check and its "
                f"protected write, or record the justified site in {ALLOWLIST}"
            )

    if enforce_base:
        observed_keys = {site.key() for site in observed}
        for key in sorted(allowed):
            if key not in observed_keys:
                messages.append(
                    f"{ALLOWLIST} entry {key} no longer matches a site; this ratchet is "
                    "shrink-only, so delete the stale entry"
                )
        for key, entry in sorted(allowed.items()):
            if not entry.why:
                messages.append(f"{ALLOWLIST} entry {key} is missing its `|why=` justification")
    return messages


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    messages = repository_messages(root)
    for message in messages:
        print(f"G-LOCK-SCOPE: {message}")
    if not messages:
        print("OK: lock-scope ratchet passed")
    return 1 if messages else 0


if __name__ == "__main__":
    raise SystemExit(main())
