#!/usr/bin/env python3
"""Shrink-only inventory for the existing consensus request-reply dialogue.

This intentionally detects only the known consensus queue and origin-filter
shapes. It is not a general requester-provenance detector.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import ratchet_base


ALLOWLIST = "migration/request-reply-message.allowlist"
REQUEST_QUEUE = "consensus.proposal"
REPLY_QUEUES = (
    "consensus.consensus_reached",
    "consensus.consensus_converge",
)
LOCAL_REQUEST_QUEUE = "proposal"
LOCAL_REPLY_QUEUES = ("consensus_reached", "consensus_converge")
KINDS = {
    "event-dep",
    "origin-filter",
    "reply-consumer",
    "reply-producer",
    "request-handler",
    "request-producer",
}
MIGRATION_LINK_RE = re.compile(r"migration=[^|\s]+\.md#[A-Za-z0-9_.-]+$")
ORIGIN_PARSE_RE = re.compile(r"\b(?:[A-Za-z_][A-Za-z0-9_]*\s*\.\s*)?parse_[A-Za-z0-9_]*proposal_id\s*\(")
ORIGIN_MATCH_RE = re.compile(r"\bproposal_id\s*:\s*match\s*\(")


@dataclass(frozen=True, order=True)
class KnownDialogueEntry:
    kind: str
    path: str
    surface: str

    @classmethod
    def parse(cls, line: str) -> "KnownDialogueEntry":
        parts = line.split("|")
        if len(parts) != 5:
            raise ValueError(f"invalid {ALLOWLIST} line: {line}")
        kind, path, surface, migration, why = parts
        if kind not in KINDS:
            raise ValueError(f"invalid {ALLOWLIST} kind: {line}")
        if not path.startswith("packages/") or not (path.endswith(".lua") or path.endswith("fkst.toml")):
            raise ValueError(f"invalid {ALLOWLIST} path: {line}")
        if not surface:
            raise ValueError(f"invalid {ALLOWLIST} surface: {line}")
        if MIGRATION_LINK_RE.fullmatch(migration) is None:
            raise ValueError(f"invalid {ALLOWLIST} migration link: {line}")
        if not why.startswith("why=") or why == "why=":
            raise ValueError(f"invalid {ALLOWLIST} WHY: {line}")
        return cls(kind=kind, path=path, surface=surface)

    def key(self) -> tuple[str, str, str]:
        return self.kind, self.path, self.surface

    def label(self) -> str:
        return "|".join(self.key())


def _long_bracket(source: str, index: int) -> tuple[int, str] | None:
    if index >= len(source) or source[index] != "[":
        return None
    cursor = index + 1
    while cursor < len(source) and source[cursor] == "=":
        cursor += 1
    if cursor >= len(source) or source[cursor] != "[":
        return None
    return cursor - index + 1, "]" + ("=" * (cursor - index - 1)) + "]"


def _quoted_end(source: str, start: int) -> int:
    quote = source[start]
    cursor = start + 1
    while cursor < len(source):
        if source[cursor] == "\\":
            cursor += 2
            continue
        if source[cursor] == quote:
            return cursor + 1
        cursor += 1
    return len(source)


def lua_strings_and_code(source: str) -> tuple[set[str], str]:
    strings: set[str] = set()
    code = list(source)
    cursor = 0
    while cursor < len(source):
        if source.startswith("--", cursor):
            bracket = _long_bracket(source, cursor + 2)
            if bracket is None:
                newline = source.find("\n", cursor)
                end = len(source) if newline == -1 else newline
            else:
                opener_len, closer = bracket
                close = source.find(closer, cursor + 2 + opener_len)
                end = len(source) if close == -1 else close + len(closer)
            for index in range(cursor, end):
                if code[index] != "\n":
                    code[index] = " "
            cursor = end
            continue
        if source[cursor] in {"'", '"'}:
            end = _quoted_end(source, cursor)
            content_end = end - 1 if end <= len(source) and source[end - 1] == source[cursor] else end
            strings.add(source[cursor + 1 : content_end])
            cursor = end
            continue
        bracket = _long_bracket(source, cursor)
        if bracket is not None:
            opener_len, closer = bracket
            body_start = cursor + opener_len
            close = source.find(closer, body_start)
            body_end = len(source) if close == -1 else close
            strings.add(source[body_start:body_end])
            cursor = len(source) if close == -1 else close + len(closer)
            continue
        cursor += 1
    return strings, "".join(code)


def has_origin_filter(strings: set[str], code: str) -> bool:
    return (
        "skip-foreign(proposal_id)" in strings
        or ORIGIN_MATCH_RE.search(code) is not None
        or ORIGIN_PARSE_RE.search(code) is not None
    )


def source_surfaces(path: str, source: str) -> set[KnownDialogueEntry]:
    if "/departments/" not in path or not path.endswith("/main.lua"):
        return set()
    strings, code = lua_strings_and_code(source)
    surfaces: set[KnownDialogueEntry] = set()
    if path.startswith("packages/consensus/"):
        if LOCAL_REQUEST_QUEUE in strings:
            surfaces.add(KnownDialogueEntry("request-handler", path, LOCAL_REQUEST_QUEUE))
        for queue in LOCAL_REPLY_QUEUES:
            if queue in strings:
                surfaces.add(KnownDialogueEntry("reply-producer", path, queue))
        return surfaces

    if REQUEST_QUEUE in strings:
        surfaces.add(KnownDialogueEntry("request-producer", path, REQUEST_QUEUE))
    for queue in REPLY_QUEUES:
        if queue not in strings:
            continue
        surfaces.add(KnownDialogueEntry("reply-consumer", path, queue))
        if has_origin_filter(strings, code):
            surfaces.add(KnownDialogueEntry("origin-filter", path, f"{queue}:proposal_id"))
    return surfaces


def manifest_surfaces(path: str, source: str) -> set[KnownDialogueEntry]:
    match = re.search(r"(?ms)^\[event_deps\]\s*$\n(?P<body>.*?)(?=^\[|\Z)", source)
    if match is None or re.search(r"[\"']consensus[\"']", match.group("body")) is None:
        return set()
    return {KnownDialogueEntry("event-dep", path, "consensus")}


def repository_surfaces(root: Path) -> set[KnownDialogueEntry]:
    packages = root / "packages"
    if not packages.exists():
        return set()
    surfaces: set[KnownDialogueEntry] = set()
    for path in sorted(packages.glob("*/departments/*/main.lua")):
        relpath = path.relative_to(root).as_posix()
        surfaces.update(source_surfaces(relpath, path.read_text(encoding="utf-8")))
    for path in sorted(packages.glob("*/fkst.toml")):
        relpath = path.relative_to(root).as_posix()
        surfaces.update(manifest_surfaces(relpath, path.read_text(encoding="utf-8")))
    return surfaces


def load_allowlist(path: Path) -> set[KnownDialogueEntry]:
    if not path.exists():
        return set()
    entries: set[KnownDialogueEntry] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            entries.add(KnownDialogueEntry.parse(line))
    return entries


def ratchet_messages(
    current: set[KnownDialogueEntry],
    allowlist: set[KnownDialogueEntry],
    base_allowlist: set[KnownDialogueEntry] | None = None,
) -> list[str]:
    messages: list[str] = []
    for entry in sorted(current - allowlist):
        messages.append(f"{entry.label()} is a new known-dialogue surface; request-reply messages may not grow")
    for entry in sorted(allowlist - current):
        messages.append(f"{entry.label()} no longer exists; prune the stale entry")
    if base_allowlist is not None:
        for entry in sorted(allowlist - base_allowlist):
            messages.append(f"{entry.label()} grows the known-dialogue allowlist relative to the protected base")
    return messages


def allowlist_at_protected_base(root: Path) -> tuple[str, set[KnownDialogueEntry] | None]:
    status, source = ratchet_base.file_at_base(root, ALLOWLIST)
    if status != "present":
        return status, None
    assert source is not None
    return "present", {
        KnownDialogueEntry.parse(line.strip())
        for line in source.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def repository_messages(root: Path, enforce_base: bool = True) -> list[str]:
    current = repository_surfaces(root)
    allowlist = load_allowlist(root / ALLOWLIST)
    base_status, base_allowlist = allowlist_at_protected_base(root) if enforce_base else ("absent", None)
    messages: list[str] = []
    if base_status == "unresolved":
        messages.append("cannot resolve the protected base allowlist; set FKST_RATCHET_DEV_REF to the protected base ref")
    messages.extend(ratchet_messages(current, allowlist, base_allowlist))
    return messages
