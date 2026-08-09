#!/usr/bin/env python3
"""Zero-bypass ratchet for recognizable bot-login trust decisions.

This checker intentionally covers legacy normalizer references, direct Lua
equality comparisons whose operands have recognizable identity names, and
recognizable trust-set membership reads. It is a source-syntax detector, not a
proof of semantic identity mediation.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import check_repo_config
import check_repo_lua


ALLOWLIST = "migration/bot-login-mediation.allowlist"
CANONICAL_HELPER_PATH = "libraries/forge/strings.lua"
LEGACY_NORMALIZER_RE = re.compile(r"\b(?:strip_bot_login_suffix|canon_login)\b")
COMPARISON_RE = re.compile(r"==|~=")
OPERAND_RE = re.compile(
    r"(?:[A-Za-z_][A-Za-z0-9_.]*\s*\([^()]*\)|[A-Za-z_][A-Za-z0-9_.]*)"
)
SIMPLE_ASSIGNMENT_RE = re.compile(
    r"(?m)^[ \t]*(?P<local>local[ \t]+)?"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)[ \t]*=(?!=)[ \t]*"
    r"(?P<callee>[A-Za-z_][A-Za-z0-9_.]*)?"
)
TRUST_MEMBERSHIP_RE = re.compile(
    r"(?P<table>[A-Za-z_][A-Za-z0-9_.]*)\s*\[\s*"
    r"(?P<key>" + OPERAND_RE.pattern + r")\s*\]"
)
STRONG_IDENTITY_NAME_RE = re.compile(
    r"(?:^|[._])(?:"
    r"author_login|bot_login|claim_owner|comment_author_login|created_by|login|"
    r"owner_login|self_login|trusted_bot_login|trusted_login"
    r")$"
)
ACCESSOR_NAME_RE = re.compile(
    r"(?:author_login|claim_owner|comment_author_login|trusted_bot_login)$"
)
CANONICAL_IDENTITY_NAME_RE = re.compile(
    r"^(?:canonical|normalized)_[A-Za-z0-9_]*(?:author|owner|login)$"
)
MEMBERSHIP_IDENTITY_NAME_RE = re.compile(r"(?:^|[._])(?:author|owner|login)$")
TRUST_SET_NAME_RE = re.compile(
    r"(?:^|[._])(?:"
    r"allowlist|managed|managed_bot_logins?|trust_set|trusted_(?:bot_)?logins?|whitelist"
    r")$"
)
CONSTANT_RE = re.compile(r"(?:nil|true|false|\d+(?:\.\d+)?)$")
CANONICAL_HELPERS = frozenset({
    "forge_strings.canonical_login",
    "parsers_misc.canonical_login",
})
LUA_KEYWORDS = frozenset({
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
})


@dataclass(frozen=True, order=True)
class BotLoginSite:
    kind: str
    path: str
    surface: str
    line: int

    @classmethod
    def parse(cls, raw: str) -> "BotLoginSite":
        parts = raw.split("|")
        if len(parts) != 4:
            raise ValueError(f"invalid {ALLOWLIST} line: {raw}")
        kind, path, surface, why = parts
        if kind not in {"legacy-normalizer", "raw-login-comparison", "raw-login-membership"}:
            raise ValueError(f"invalid {ALLOWLIST} kind: {raw}")
        if not (path.startswith("libraries/") or path.startswith("packages/")) or not path.endswith(".lua"):
            raise ValueError(f"invalid {ALLOWLIST} path: {raw}")
        if not surface:
            raise ValueError(f"invalid {ALLOWLIST} surface: {raw}")
        if not why.startswith("why=") or why == "why=":
            raise ValueError(f"invalid {ALLOWLIST} WHY: {raw}")
        return cls(kind=kind, path=path, surface=surface, line=0)

    def key(self) -> tuple[str, str, str]:
        return self.kind, self.path, self.surface

    def label(self) -> str:
        return f"{self.path}:{self.line} {self.kind} {self.surface}"


def _is_test_path(path: str) -> bool:
    parts = Path(path).parts
    return "tests" in parts or Path(path).name.endswith("_test.lua")


def _compact_operand(operand: str) -> str:
    return re.sub(r"\s+", "", operand)


def _operand_before(code: str, index: int) -> str | None:
    cursor = index - 1
    while cursor >= 0 and code[cursor].isspace():
        cursor -= 1
    if cursor < 0:
        return None
    end = cursor + 1
    if code[cursor] == ")":
        depth = 1
        cursor -= 1
        while cursor >= 0 and depth > 0:
            if code[cursor] == ")":
                depth += 1
            elif code[cursor] == "(":
                depth -= 1
            cursor -= 1
        if depth != 0:
            return None
        while cursor >= 0 and code[cursor].isspace():
            cursor -= 1
        match = re.search(r"[A-Za-z_][A-Za-z0-9_.]*$", code[:cursor + 1])
        if match is None or match.group(0) in LUA_KEYWORDS:
            return None
        return _compact_operand(code[match.start():end])
    match = re.search(r"[A-Za-z_][A-Za-z0-9_.]*$", code[:end])
    if match is None or match.group(0) in LUA_KEYWORDS:
        return None
    return match.group(0)


def _operand_after(code: str, index: int) -> str | None:
    cursor = index
    while cursor < len(code) and code[cursor].isspace():
        cursor += 1
    match = re.match(r"[A-Za-z_][A-Za-z0-9_.]*", code[cursor:])
    if match is None or match.group(0) in LUA_KEYWORDS:
        return None
    name_end = cursor + match.end()
    call_cursor = name_end
    while call_cursor < len(code) and code[call_cursor].isspace():
        call_cursor += 1
    if call_cursor >= len(code) or code[call_cursor] != "(":
        return match.group(0)
    depth = 0
    call_end = call_cursor
    while call_end < len(code):
        if code[call_end] == "(":
            depth += 1
        elif code[call_end] == ")":
            depth -= 1
            if depth == 0:
                return _compact_operand(code[cursor:call_end + 1])
        call_end += 1
    return None


def _name(operand: str) -> str:
    return operand.split("(", 1)[0]


def _binding_assignments(code: str) -> tuple[tuple[int, str, bool], ...]:
    assignments: list[tuple[int, str, bool]] = []
    brace_depth = 0
    scan_cursor = 0
    for match in SIMPLE_ASSIGNMENT_RE.finditer(code):
        for char in code[scan_cursor:match.start()]:
            if char == "{":
                brace_depth += 1
            elif char == "}" and brace_depth > 0:
                brace_depth -= 1
        scan_cursor = match.start()
        if match.group("local") is None and brace_depth > 0:
            continue
        callee = match.group("callee")
        followed_by_call = (
            callee is not None
            and re.match(r"[ \t]*\(", code[match.end("callee"):]) is not None
        )
        assignments.append((
            match.start(),
            match.group("name"),
            followed_by_call and callee in CANONICAL_HELPERS,
        ))
    return tuple(assignments)


def _canonical_bindings_before(
    assignments: tuple[tuple[int, str, bool], ...],
    index: int,
) -> set[str]:
    bindings: set[str] = set()
    for position, name, canonical in assignments:
        if position >= index:
            break
        if canonical:
            bindings.add(name)
        else:
            bindings.discard(name)
    return bindings


def _is_canonical(operand: str, bindings: set[str]) -> bool:
    name = _name(operand)
    if "(" in operand:
        return name in CANONICAL_HELPERS
    return name in bindings


def _looks_canonical_identity(operand: str) -> bool:
    return CANONICAL_IDENTITY_NAME_RE.fullmatch(_name(operand).split(".")[-1]) is not None


def _is_strong_identity(operand: str) -> bool:
    name = _name(operand)
    return STRONG_IDENTITY_NAME_RE.search(name) is not None or ACCESSOR_NAME_RE.search(name) is not None


def _is_author_owner_pair(left: str, right: str) -> bool:
    left_name = _name(left).split(".")[-1]
    right_name = _name(right).split(".")[-1]
    return {left_name, right_name} == {"author", "owner"}


def _comparison_surface(left: str, operator: str, right: str) -> str:
    return f"{left}{operator}{right}"


def _is_trust_set(operand: str) -> bool:
    return TRUST_SET_NAME_RE.search(operand) is not None


def _is_membership_identity(operand: str) -> bool:
    name = _name(operand)
    return (
        _is_strong_identity(operand)
        or MEMBERSHIP_IDENTITY_NAME_RE.search(name) is not None
        or _looks_canonical_identity(operand)
        or name.split(".")[-1] in {"canonical", "normalized"}
    )


def source_sites(path: str, source: str) -> set[BotLoginSite]:
    if _is_test_path(path) or path == CANONICAL_HELPER_PATH:
        return set()
    code = check_repo_lua.code_mask(source)
    assignments = _binding_assignments(code)
    sites: set[BotLoginSite] = set()
    for match in LEGACY_NORMALIZER_RE.finditer(code):
        sites.add(BotLoginSite(
            kind="legacy-normalizer",
            path=path,
            surface=match.group(0),
            line=source.count("\n", 0, match.start()) + 1,
        ))
    for match in COMPARISON_RE.finditer(code):
        left = _operand_before(code, match.start())
        right = _operand_after(code, match.end())
        if left is None or right is None:
            continue
        if CONSTANT_RE.fullmatch(left) is not None or CONSTANT_RE.fullmatch(right) is not None:
            continue
        bindings = _canonical_bindings_before(assignments, match.start())
        if _is_canonical(left, bindings) and _is_canonical(right, bindings):
            continue
        if not (
            _is_strong_identity(left)
            or _is_strong_identity(right)
            or _is_author_owner_pair(left, right)
            or _looks_canonical_identity(left)
            or _looks_canonical_identity(right)
        ):
            continue
        sites.add(BotLoginSite(
            kind="raw-login-comparison",
            path=path,
            surface=_comparison_surface(left, match.group(0), right),
            line=source.count("\n", 0, match.start()) + 1,
        ))
    for match in TRUST_MEMBERSHIP_RE.finditer(code):
        table = match.group("table")
        key = match.group("key").replace(" ", "")
        if not _is_trust_set(table):
            continue
        if re.match(r"[ \t]*=(?!=)", code[match.end():]) is not None:
            continue
        bindings = _canonical_bindings_before(assignments, match.start())
        if _is_canonical(key, bindings) or not _is_membership_identity(key):
            continue
        sites.add(BotLoginSite(
            kind="raw-login-membership",
            path=path,
            surface=f"{table}[{key}]",
            line=source.count("\n", 0, match.start()) + 1,
        ))
    return sites


def repository_sites(root: Path) -> set[BotLoginSite]:
    sites: set[BotLoginSite] = set()
    for source_root in (root / "libraries", root / "packages"):
        if not source_root.exists():
            continue
        for path in sorted(source_root.rglob("*.lua")):
            if path.is_file():
                relpath = path.relative_to(root).as_posix()
                sites.update(source_sites(relpath, path.read_text(encoding="utf-8")))
    return sites


def load_allowlist(path: Path) -> set[BotLoginSite]:
    if not path.exists():
        return set()
    return {
        BotLoginSite.parse(line.strip())
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def parse_allowlist_lines(lines: list[str]) -> set[BotLoginSite]:
    return {
        BotLoginSite.parse(line.strip())
        for line in lines
        if line.strip() and not line.lstrip().startswith("#")
    }


def _covered(site: BotLoginSite, allowlist: set[BotLoginSite]) -> bool:
    return any(entry.key() == site.key() for entry in allowlist)


def ratchet_messages(
    current: set[BotLoginSite],
    allowlist: set[BotLoginSite],
    base_allowlist: set[BotLoginSite] | None = None,
) -> list[str]:
    messages: list[str] = []
    for site in sorted(current):
        if not _covered(site, allowlist):
            messages.append(
                f"{site.label()} bypasses bot-login mediation outside forge_strings.canonical_login"
            )
    for entry in sorted(allowlist):
        if not any(site.key() == entry.key() for site in current):
            messages.append(f"{entry.label()} no longer matches bot-login mediation debt; prune the stale entry")
    if base_allowlist is not None:
        for entry in sorted(allowlist):
            if not _covered(entry, base_allowlist):
                messages.append(
                    f"{entry.label()} grows the bot-login mediation allowlist relative to dev"
                )
    return messages


def repository_messages(root: Path, enforce_base: bool = True) -> list[str]:
    current = repository_sites(root)
    allowlist = load_allowlist(root / ALLOWLIST)
    base_status, base_allowlist = (
        check_repo_config.allowlist_at_dev_base(
            root,
            allowlist=ALLOWLIST,
            parse_allowlist_lines=parse_allowlist_lines,
        )
        if enforce_base
        else ("absent", None)
    )
    messages: list[str] = []
    if base_status == "unresolved":
        messages.append("cannot resolve dev base allowlist to enforce the shrink-only ratchet")
    messages.extend(ratchet_messages(current, allowlist, base_allowlist))
    return messages
