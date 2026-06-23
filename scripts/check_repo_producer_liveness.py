#!/usr/bin/env python3
"""Producer-liveness fire_raiser trace assertion ratchet."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import ratchet_base


ALLOWLIST = "migration/producer-liveness.allowlist"
TRACE_FIELDS = ("consumer_result", "source_payload", "raised")
RAISER_NAME_RE = re.compile(r"\b(?:name|raiser)\s*=\s*(?P<quote>[\"'])(?P<name>[A-Za-z0-9_.-]+)(?P=quote)")
PRODUCES_STRING_RE = re.compile(r"\bproduces\s*=\s*(?P<quote>[\"'])(?P<queue>[A-Za-z0-9_.-]+)(?P=quote)")
PRODUCES_TABLE_RE = re.compile(r"\bproduces\s*=\s*\{(?P<body>.*?)\}", re.DOTALL)
STRING_RE = re.compile(r"(?P<quote>[\"'])(?P<value>[A-Za-z0-9_.-]+)(?P=quote)")
TEST_START_RE = re.compile(
    r"^\s*(?:test_[A-Za-z0-9_]+|\[\s*[\"']test_[A-Za-z0-9_]+[\"']\s*\])\s*=\s*function\b"
    r"|^\s*function\s+(?:[A-Za-z_][A-Za-z0-9_]*[.:])?test_[A-Za-z0-9_]+\s*\("
)
FIRE_RAISER_RE = re.compile(
    r"(?:(?:local\s+)?(?P<var>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*)?"
    r"\bt\s*\.\s*fire_raiser\s*\(\s*"
    r"(?P<quote>[\"'])(?P<raiser>[A-Za-z0-9_.-]+)(?P=quote)\s*\)"
)
LUA_WORD_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")


@dataclass(frozen=True, order=True)
class ProducerRaiser:
    package: str
    name: str
    path: str
    produces: tuple[str, ...]

    def key(self) -> str:
        return f"{self.package}.{self.name}"

    def label(self) -> str:
        queues = ",".join(self.produces) if self.produces else "<unknown>"
        return f"{self.key()} ({self.path} -> {queues})"


def mask_span(chars: list[str], start: int, end: int) -> None:
    for index in range(start, min(end, len(chars))):
        if chars[index] != "\n":
            chars[index] = " "


def long_bracket_at(text: str, index: int) -> tuple[int, str] | None:
    if index >= len(text) or text[index] != "[":
        return None
    cursor = index + 1
    while cursor < len(text) and text[cursor] == "=":
        cursor += 1
    if cursor >= len(text) or text[cursor] != "[":
        return None
    level = cursor - index - 1
    return cursor - index + 1, "]" + ("=" * level) + "]"


def end_of_long_bracket(text: str, body_start: int, closer: str) -> int:
    close_start = text.find(closer, body_start)
    return len(text) if close_start == -1 else close_start + len(closer)


def end_of_quoted_string(text: str, start: int) -> int:
    quote = text[start]
    cursor = start + 1
    while cursor < len(text):
        if text[cursor] == "\\":
            cursor += 2
            continue
        if text[cursor] == quote:
            return cursor + 1
        cursor += 1
    return len(text)


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
        char = text[cursor]
        if char in ("'", '"'):
            cursor = end_of_quoted_string(text, cursor)
            continue
        if char == "[":
            bracket = long_bracket_at(text, cursor)
            if bracket is not None:
                opener_len, closer = bracket
                cursor = end_of_long_bracket(text, cursor + opener_len, closer)
                continue
        cursor += 1
    return "".join(chars)


def mask_lua_comments_and_strings(text: str) -> str:
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
        char = text[cursor]
        if char in ("'", '"'):
            end = end_of_quoted_string(text, cursor)
            mask_span(chars, cursor, end)
            cursor = end
            continue
        if char == "[":
            bracket = long_bracket_at(text, cursor)
            if bracket is not None:
                opener_len, closer = bracket
                end = end_of_long_bracket(text, cursor + opener_len, closer)
                mask_span(chars, cursor, end)
                cursor = end
                continue
        cursor += 1
    return "".join(chars)


def block_delta(line: str) -> int:
    tokens = LUA_WORD_RE.findall(line)
    delta = 0
    for index, token in enumerate(tokens):
        if token in {"function", "do", "repeat"}:
            delta += 1
        elif token == "then" and (index == 0 or tokens[index - 1] != "elseif"):
            delta += 1
        elif token in {"end", "until"}:
            delta -= 1
    return delta


def test_blocks(source: str) -> list[str]:
    masked_lines = mask_lua_comments_and_strings(source).splitlines()
    original_lines = source.splitlines()
    blocks: list[str] = []
    index = 0
    while index < len(masked_lines):
        if TEST_START_RE.search(masked_lines[index]) is None:
            index += 1
            continue
        depth = block_delta(masked_lines[index])
        end = index
        while depth > 0 and end + 1 < len(masked_lines):
            end += 1
            depth += block_delta(masked_lines[end])
        blocks.append("\n".join(original_lines[index : end + 1]))
        index = end + 1
    return blocks


def trace_field_re(var: str) -> re.Pattern[str]:
    fields = "|".join(re.escape(field) for field in TRACE_FIELDS)
    return re.compile(
        r"\b" + re.escape(var) + r"\s*(?:\.\s*(?:" + fields + r")|\[\s*(?P<quote>[\"'])(?:"
        + fields + r")(?P=quote)\s*\])"
    )


def call_asserts_trace(block: str, match: re.Match[str]) -> bool:
    var = match.group("var")
    if var is not None and trace_field_re(var).search(block) is not None:
        return True
    tail = block[match.end() : match.end() + 240]
    return re.search(r"^\s*\.\s*(?:" + "|".join(TRACE_FIELDS) + r")\b", tail) is not None


def covered_raisers_in_source(source: str) -> set[str]:
    covered: set[str] = set()
    for block in test_blocks(source):
        searchable = strip_lua_comments(block)
        for match in FIRE_RAISER_RE.finditer(searchable):
            if call_asserts_trace(searchable, match):
                covered.add(match.group("raiser"))
    return covered


def package_test_coverage(package: Path) -> set[str]:
    tests = package / "tests"
    if not tests.exists():
        return set()
    covered: set[str] = set()
    for path in sorted(tests.rglob("*_test.lua")):
        if path.is_file():
            covered.update(covered_raisers_in_source(path.read_text(encoding="utf-8")))
    return covered


def declared_raiser(path: Path, root: Path) -> ProducerRaiser:
    package = path.parents[1].name
    source = strip_lua_comments(path.read_text(encoding="utf-8"))
    name_match = RAISER_NAME_RE.search(source)
    name = name_match.group("name") if name_match is not None else path.stem
    produces = [match.group("queue") for match in PRODUCES_STRING_RE.finditer(source)]
    for table in PRODUCES_TABLE_RE.finditer(source):
        produces.extend(match.group("value") for match in STRING_RE.finditer(table.group("body")))
    return ProducerRaiser(package, name, path.relative_to(root).as_posix(), tuple(dict.fromkeys(produces)))


def declared_raisers(root: Path) -> set[ProducerRaiser]:
    packages = root / "packages"
    if not packages.exists():
        return set()
    return {
        declared_raiser(path, root)
        for path in sorted(packages.glob("*/raisers/*.lua"))
        if path.is_file()
    }


def load_allowlist(path: Path) -> set[str]:
    if not path.exists():
        return set()
    entries: set[str] = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if re.fullmatch(r"[A-Za-z0-9_.-]+\.[A-Za-z0-9_.-]+", line) is None:
            raise ValueError(f"invalid {ALLOWLIST} line {number}: {raw}")
        entries.add(line)
    return entries


def allowlist_at_dev_base(root: Path) -> tuple[str, set[str] | None]:
    try:
        status, shown = ratchet_base.file_at_base(root, ALLOWLIST)
        if status != "present":
            return status, None
        assert shown is not None
        return "present", {
            line.strip()
            for line in shown.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
    except Exception:
        return "unresolved", None


def ratchet_messages(
    raisers: set[ProducerRaiser],
    coverage_by_package: dict[str, set[str]],
    allowlist: set[str],
    base_allowlist: set[str] | None = None,
) -> list[str]:
    messages: list[str] = []
    declared_by_key = {raiser.key(): raiser for raiser in raisers}
    covered = {
        raiser.key()
        for raiser in raisers
        if raiser.name in coverage_by_package.get(raiser.package, set())
    }
    uncovered = set(declared_by_key) - covered

    for key in sorted(uncovered - allowlist):
        messages.append(
            f"{declared_by_key[key].label()} lacks a trace-asserting fire_raiser test; add fire_raiser(\"{declared_by_key[key].name}\") with consumer_result/source_payload/raised assertions or list existing debt in {ALLOWLIST}"
        )
    for key in sorted(allowlist - uncovered):
        detail = "is covered" if key in covered else "has no declared raiser"
        messages.append(f"{key} is listed in {ALLOWLIST} but {detail}; prune the stale entry")
    if base_allowlist is not None:
        for key in sorted(allowlist - base_allowlist):
            messages.append(f"{key} grows {ALLOWLIST} relative to dev; add a fire_raiser trace assertion instead")
    return messages


def repository_messages(root: Path) -> list[str]:
    raisers = declared_raisers(root)
    coverage = {
        package.name: package_test_coverage(package)
        for package in sorted((root / "packages").iterdir())
        if package.is_dir()
    } if (root / "packages").exists() else {}
    allowlist = load_allowlist(root / ALLOWLIST)
    base_status, base_allowlist = allowlist_at_dev_base(root)
    messages: list[str] = []
    if base_status == "unresolved":
        messages.append("cannot resolve dev base allowlist to enforce shrink-only ratchet; ensure CI provides the dev ref")
    messages.extend(ratchet_messages(raisers, coverage, allowlist, base_allowlist))
    return messages
