"""Conformance guard for package-side monotone gate DSL definitions."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import ratchet_base


ALLOWLIST = "migration/monotone-gate-dsl.allowlist"
PACKAGE_GLOB = "github-devloop*"
GATE_PARTS = ("core", "gates")
ALLOWED_REQUIRES = {"std.devloop_gate"}
RAW_MODULES = {"std.devloop_state", "std.devloop_markers", "std.devloop_markers.facts"}
RAW_TOKENS = (
    "current_state",
    "current_entity_state",
    "pr_origin_fact",
    "_trusted_marker_comments",
    "_comment_body",
    "_comment_created_at",
    "fkst:github-devloop:state:v1",
    "fkst:github-devloop:pr-origin:v1",
)
REQUIRE_RE = re.compile(
    r"""\brequire\s*(?:\(\s*)?(?:"([A-Za-z0-9_.\-]+)"|'([A-Za-z0-9_.\-]+)'|\[(=*)\[([A-Za-z0-9_.\-]+)\]\3\])"""
)


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    kind: str
    token: str
    line: int

    @classmethod
    def parse(cls, line: str) -> "Finding":
        parts = line.split("|")
        if len(parts) < 6:
            raise ValueError(f"invalid {ALLOWLIST} line: {line}")
        path, kind, token, line_part, issue, why = parts[:6]
        if not path.startswith("packages/github-devloop") or "/core/gates/" not in path or not path.endswith(".lua"):
            raise ValueError(f"invalid {ALLOWLIST} path: {line}")
        if kind not in {"require", "raw-token"}:
            raise ValueError(f"invalid {ALLOWLIST} kind: {line}")
        if not line_part.startswith("line="):
            raise ValueError(f"invalid {ALLOWLIST} line number: {line}")
        if re.fullmatch(r"issue=#?\d+", issue) is None:
            raise ValueError(f"invalid {ALLOWLIST} issue link: {line}")
        if not why.startswith("why=") or why == "why=":
            raise ValueError(f"invalid {ALLOWLIST} WHY: {line}")
        return cls(path=path, kind=kind, token=token, line=int(line_part.removeprefix("line=")))

    def key(self) -> tuple[str, str, str, str]:
        return self.path, self.kind, self.token, str(self.line)

    def label(self) -> str:
        return f"{self.path}:{self.line} {self.kind} {self.token}"


def _mask(chars: list[str], start: int, end: int) -> None:
    for index in range(start, end):
        if chars[index] != "\n":
            chars[index] = " "


def _quoted_string_end(text: str, start: int) -> int:
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


def strip_lua_comments_and_strings(text: str) -> str:
    chars = list(text)
    cursor = 0
    while cursor < len(text):
        if text.startswith("--", cursor):
            newline = text.find("\n", cursor)
            end = len(text) if newline == -1 else newline
            _mask(chars, cursor, end)
            cursor = end
            continue
        if text[cursor] in {"'", '"'}:
            end = _quoted_string_end(text, cursor)
            _mask(chars, cursor, end)
            cursor = end
            continue
        cursor += 1
    return "".join(chars)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def required_module(match: re.Match[str]) -> str:
    return next(group for group in (match.group(1), match.group(2), match.group(4)) if group is not None)


def gate_sources(root: Path) -> dict[str, str]:
    sources: dict[str, str] = {}
    for package in sorted((root / "packages").glob(PACKAGE_GLOB)):
      gate_root = package.joinpath(*GATE_PARTS)
      if not gate_root.is_dir():
        continue
      for path in sorted(gate_root.rglob("*.lua")):
        if path.is_file():
          sources[path.relative_to(root).as_posix()] = path.read_text(encoding="utf-8")
    return sources


def source_findings(path: str, source: str) -> set[Finding]:
    findings: set[Finding] = set()
    stripped = strip_lua_comments_and_strings(source)
    for match in REQUIRE_RE.finditer(source):
        module = required_module(match)
        if module not in ALLOWED_REQUIRES:
            findings.add(Finding(path, "require", module, line_number(source, match.start())))
        if module in RAW_MODULES:
            findings.add(Finding(path, "require", module, line_number(source, match.start())))
    for token in RAW_TOKENS:
        start = 0
        while True:
            index = stripped.find(token, start)
            if index == -1:
                break
            findings.add(Finding(path, "raw-token", token, line_number(source, index)))
            start = index + len(token)
    return findings


def current_findings(root: Path) -> set[Finding]:
    found: set[Finding] = set()
    for path, source in gate_sources(root).items():
        found.update(source_findings(path, source))
    return found


def load_allowlist(path: Path) -> set[Finding]:
    if not path.exists():
        return set()
    return {
        Finding.parse(line.strip())
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def allowlist_at_dev_base(root: Path) -> tuple[str, set[Finding] | None]:
    try:
        status, shown = ratchet_base.file_at_base(root, ALLOWLIST)
        if status == "absent":
            return status, set()
        if status != "present":
            return status, None
        assert shown is not None
        return "present", {
            Finding.parse(line.strip())
            for line in shown.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
    except Exception:
        return "unresolved", None


def repository_messages(root: Path, enforce_base: bool = True) -> list[str]:
    current = current_findings(root)
    allowlist = load_allowlist(root / ALLOWLIST)
    messages: list[str] = []
    base_allowlist: set[Finding] | None = None
    if enforce_base:
        base_status, base_allowlist = allowlist_at_dev_base(root)
        if base_status == "unresolved":
            messages.append("cannot resolve dev base allowlist to enforce shrink-only ratchet; ensure CI provides the dev ref")
    for finding in sorted(current):
        if not any(entry.key() == finding.key() for entry in allowlist):
            messages.append(f"{finding.label()} is forbidden in a core/gates DSL definition; gate definitions may require only std.devloop_gate and must not read raw marker/cursor helpers")
    for entry in sorted(allowlist):
        if not any(finding.key() == entry.key() for finding in current):
            messages.append(f"{entry.label()} no longer matches monotone-gate-dsl debt; prune the stale entry")
    if base_allowlist is not None:
        for entry in sorted(allowlist):
            if not any(base.key() == entry.key() for base in base_allowlist):
                messages.append(f"{entry.label()} grows monotone-gate-dsl allowlist relative to dev; migrate to std.devloop_gate data specs instead")
    return messages
