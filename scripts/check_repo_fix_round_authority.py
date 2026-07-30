#!/usr/bin/env python3
"""Forbid fix-round advancement outside its cap-checked authority."""

from __future__ import annotations

import re
from pathlib import Path


AUTHORITY_PATH = "libraries/devloop/fix_round_authority.lua"
RAW_ADVANCE_RE = re.compile(r"\b(?:next_fix_version|fix_version_from_review_version|next_fix)\s*\(")
ROUND_ARITHMETIC_RE = re.compile(r"\b(?:version_fix_round|fix_round)\s*\([^\n]*\)\s*\+\s*1\b")
FIX_SUFFIX_RE = re.compile(r"(['\"])/fix/\1\s*\.\.")


def _production_sources(root: Path) -> list[Path]:
    sources: set[Path] = set()
    libraries = root / "libraries/devloop"
    if libraries.exists():
        sources.update(path for path in libraries.rglob("*.lua") if "tests" not in path.parts)
    packages = root / "packages"
    if packages.exists():
        for package in packages.glob("github-devloop*"):
            sources.update(path for path in package.rglob("*.lua") if "tests" not in path.parts)
    return sorted(sources)


def _code_before_comment(line: str) -> str:
    quote: str | None = None
    escaped = False
    for index, char in enumerate(line):
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in {"'", '"'}:
            quote = char
        elif line.startswith("--", index):
            return line[:index]
    return line


def repository_messages(root: Path) -> list[str]:
    messages: list[str] = []
    for path in _production_sources(root):
        relative = path.relative_to(root).as_posix()
        for line_number, original in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            line = _code_before_comment(original)
            findings: list[str] = []
            if relative != AUTHORITY_PATH:
                raw = RAW_ADVANCE_RE.search(line)
                if raw is not None:
                    findings.append(raw.group(0).removesuffix("("))
                if ROUND_ARITHMETIC_RE.search(line) is not None:
                    findings.append("version_fix_round arithmetic")
                if FIX_SUFFIX_RE.search(line) is not None:
                    findings.append("fix suffix construction")
            for finding in findings:
                messages.append(
                    f"{relative}:{line_number}: {finding} bypasses {AUTHORITY_PATH}; "
                    "all fix-round advancement must be cap-checked by the canonical authority"
                )
    return messages
