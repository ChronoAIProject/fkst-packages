#!/usr/bin/env python3
"""Scoped ratchet for monotone lifecycle gates.

The scanner only inspects surfaces declared as monotone gates in the migration
inventory or a responsibility_signature block with gate_kind="monotone_milestone".
Current-state routing code outside those declared surfaces remains legal.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

import ratchet_base


MANIFEST = "migration/monotone-gate.inventory"
ALLOWLIST = "migration/monotone-gate.allowlist"
APPROVED_ACCESSORS = {"std.devloop_state.reached", "reached", "pr_origin_fact"}
SURFACE_KINDS = {"monotone-gate", "visibility"}
PHASES = (
    "thinking",
    "dependency_wait",
    "ready",
    "implementing",
    "awaiting-pr",
    "pr-open",
    "reviewing",
    "review-meta",
    "merge-ready",
    "merging",
    "merged",
    "closed-unmerged",
    "fixing",
    "impl-failed",
    "blocked",
)
PHASE_LITERAL = "|".join(re.escape(phase) for phase in PHASES)
CURSOR_RE = re.compile(r"\b(?:current_entity_state|current_state)\s*\(")
STATE_EQ_RE = re.compile(
    r"\.\s*state\s*==\s*(?P<quote1>['\"])(?P<phase1>" + PHASE_LITERAL + r")(?P=quote1)"
    r"|(?P<quote2>['\"])(?P<phase2>" + PHASE_LITERAL + r")(?P=quote2)\s*==\s*[^)\n]*\.\s*state"
)
FUNCTION_RE = re.compile(
    r"^\s*(?:local\s+)?function\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*(?:\s*[.:]\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\("
    r"|^\s*(?P<assign>[A-Za-z_][A-Za-z0-9_]*(?:\s*[.:]\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*=\s*function\b"
)
LUA_WORD_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")
GATE_KIND_RE = re.compile(r"\bgate_kind\s*=\s*['\"]monotone_milestone['\"]")
RESPONSIBILITY_RE = re.compile(r"\bresponsibility_signature\s*\(")


@dataclass(frozen=True, order=True)
class Surface:
    path: str
    function: str
    kind: str
    gate_kind: str
    milestone_accessor: str
    milestone: str
    milestone_domain: str
    why: str


@dataclass(frozen=True, order=True)
class Violation:
    path: str
    surface: str
    kind: str
    token: str
    line: int

    @classmethod
    def parse(cls, line: str) -> "Violation":
        parts = line.split("|")
        if len(parts) < 7:
            raise ValueError(f"invalid {ALLOWLIST} line: {line}")
        path, surface, kind, token, line_part, issue, why = parts[:7]
        if not path.endswith((".lua", ".py")):
            raise ValueError(f"invalid {ALLOWLIST} path: {line}")
        if kind not in {"cursor-read", "state-equality"}:
            raise ValueError(f"invalid {ALLOWLIST} kind: {line}")
        if not line_part.startswith("line="):
            raise ValueError(f"invalid {ALLOWLIST} line number: {line}")
        if re.fullmatch(r"issue=#?\d+", issue) is None:
            raise ValueError(f"invalid {ALLOWLIST} issue link: {line}")
        if not why.startswith("why=") or why == "why=":
            raise ValueError(f"invalid {ALLOWLIST} WHY: {line}")
        return cls(path=path, surface=surface, kind=kind, token=token, line=int(line_part.removeprefix("line=")))

    def key(self) -> tuple[str, str, str, str]:
        return self.path, self.surface, self.kind, self.token

    def label(self) -> str:
        return f"{self.path}:{self.line} {self.surface} {self.kind} {self.token}"


@dataclass(frozen=True)
class Block:
    name: str
    start: int
    end: int
    source: str


def strip_lua_line_comment(line: str) -> str:
    quote = None
    escaped = False
    for index, char in enumerate(line):
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in {"'", '"'}:
            quote = char
            continue
        if line.startswith("--", index):
            return line[:index]
    return line


def code_without_lua_line_comments(source: str) -> str:
    return "\n".join(strip_lua_line_comment(line) for line in source.splitlines())


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


def function_blocks(source: str) -> list[Block]:
    code_lines = code_without_lua_line_comments(source).splitlines()
    original_lines = source.splitlines()
    blocks: list[Block] = []
    index = 0
    while index < len(code_lines):
        match = FUNCTION_RE.match(code_lines[index])
        if match is None:
            index += 1
            continue
        depth = block_delta(code_lines[index])
        end = index
        while depth > 0 and end + 1 < len(code_lines):
            end += 1
            depth += block_delta(code_lines[end])
        name = (match.group("name") or match.group("assign") or "unknown").replace(" ", "")
        blocks.append(Block(name=name, start=index + 1, end=end + 1, source="\n".join(original_lines[index:end + 1])))
        index += 1
    return blocks


def block_for_function(source: str, function_name: str) -> Block | None:
    wanted = function_name.split(".")[-1].split(":")[-1]
    for block in function_blocks(source):
        if block.name == function_name or block.name.split(".")[-1].split(":")[-1] == wanted:
            return block
    return None


def responsibility_blocks(source: str) -> list[Block]:
    lines = source.splitlines()
    code_lines = code_without_lua_line_comments(source).splitlines()
    blocks: list[Block] = []
    index = 0
    while index < len(code_lines):
        if RESPONSIBILITY_RE.search(code_lines[index]) is None:
            index += 1
            continue
        depth = code_lines[index].count("(") + code_lines[index].count("{") - code_lines[index].count(")") - code_lines[index].count("}")
        end = index
        while depth > 0 and end + 1 < len(code_lines):
            end += 1
            depth += code_lines[end].count("(") + code_lines[end].count("{") - code_lines[end].count(")") - code_lines[end].count("}")
        source_block = "\n".join(lines[index:end + 1])
        if GATE_KIND_RE.search(source_block):
            blocks.append(Block(name="responsibility_signature", start=index + 1, end=end + 1, source=source_block))
        index = end + 1
    return blocks


def load_manifest(path: Path) -> tuple[list[Surface], list[str]]:
    if not path.exists():
        return [], [f"manifest-missing: {MANIFEST} is required"]
    surfaces: list[Surface] = []
    messages: list[str] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            doc = json.loads(stripped)
        except json.JSONDecodeError as exc:
            messages.append(f"manifest-invalid-json: {MANIFEST}:{number}: {exc.msg}")
            continue
        surface = Surface(
            path=str(doc.get("path", "")),
            function=str(doc.get("function", "")),
            kind=str(doc.get("kind", "")),
            gate_kind=str(doc.get("gate_kind", "")),
            milestone_accessor=str(doc.get("milestone_accessor", "")),
            milestone=str(doc.get("milestone", "")),
            milestone_domain=str(doc.get("milestone_domain", "")),
            why=str(doc.get("why", "")),
        )
        if surface.kind not in SURFACE_KINDS:
            messages.append(f"manifest-invalid-kind: {surface.path} {surface.function}")
        if surface.gate_kind != "monotone_milestone":
            messages.append(f"manifest-invalid-gate-kind: {surface.path} {surface.function}")
        if surface.milestone_accessor not in APPROVED_ACCESSORS:
            messages.append(f"manifest-invalid-accessor: {surface.path} {surface.function} {surface.milestone_accessor}")
        if surface.milestone not in PHASES:
            messages.append(f"manifest-invalid-milestone: {surface.path} {surface.function} {surface.milestone}")
        if not surface.milestone_domain:
            messages.append(f"manifest-missing-domain: {surface.path} {surface.function}")
        if not surface.why:
            messages.append(f"manifest-missing-why: {surface.path} {surface.function}")
        surfaces.append(surface)
    return surfaces, messages


def block_violations(path: str, surface: str, block: Block) -> set[Violation]:
    violations: set[Violation] = set()
    for offset, line in enumerate(code_without_lua_line_comments(block.source).splitlines()):
        line_number = block.start + offset
        for match in CURSOR_RE.finditer(line):
            violations.add(Violation(path, surface, "cursor-read", match.group(0).strip(), line_number))
        for match in STATE_EQ_RE.finditer(line):
            phase = match.group("phase1") or match.group("phase2") or "state"
            violations.add(Violation(path, surface, "state-equality", phase, line_number))
    return violations


def current_violations(root: Path) -> tuple[set[Violation], list[str]]:
    surfaces, messages = load_manifest(root / MANIFEST)
    found: set[Violation] = set()
    for surface in surfaces:
        path = root / surface.path
        if not path.exists():
            messages.append(f"manifest-stale-path: {surface.path}")
            continue
        source = path.read_text(encoding="utf-8")
        block = block_for_function(source, surface.function)
        if block is None:
            messages.append(f"manifest-stale-function: {surface.path} {surface.function}")
            continue
        found.update(block_violations(surface.path, surface.function, block))
    for path in sorted((root / "packages").rglob("*.lua")) + sorted((root / "std").rglob("*.lua")):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        source = path.read_text(encoding="utf-8")
        for block in responsibility_blocks(source):
            found.update(block_violations(rel, block.name, block))
    return found, messages


def load_allowlist(path: Path) -> set[Violation]:
    if not path.exists():
        return set()
    return {
        Violation.parse(line.strip())
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def allowlist_at_dev_base(root: Path) -> tuple[str, set[Violation] | None]:
    try:
        status, shown = ratchet_base.file_at_base(root, ALLOWLIST)
        if status == "absent":
            return "present", set()
        if status != "present":
            return status, None
        assert shown is not None
        return "present", {
            Violation.parse(line.strip())
            for line in shown.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
    except Exception:
        return "unresolved", None


def repository_messages(root: Path) -> list[str]:
    current, messages = current_violations(root)
    allowlist = load_allowlist(root / ALLOWLIST)
    base_status, base_allowlist = allowlist_at_dev_base(root)
    if base_status == "unresolved":
        messages.append("cannot resolve dev base allowlist to enforce shrink-only ratchet; ensure CI provides the dev ref")
    for violation in sorted(current):
        if not any(entry.key() == violation.key() for entry in allowlist):
            messages.append(f"{violation.label()} reads a transient cursor inside a declared monotone gate; use std.devloop_state.reached() or an approved milestone fact")
    for entry in sorted(allowlist):
        if not any(violation.key() == entry.key() for violation in current):
            messages.append(f"{entry.label()} no longer matches monotone-gate debt; prune the stale entry")
    if base_allowlist is not None:
        for entry in sorted(allowlist):
            if not any(base.key() == entry.key() for base in base_allowlist):
                messages.append(f"{entry.label()} grows monotone-gate allowlist relative to dev; migrate to reached() instead")
    return messages
