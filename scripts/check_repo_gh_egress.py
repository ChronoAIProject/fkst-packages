#!/usr/bin/env python3
"""G-GH-EGRESS: enforce the exact single GitHub raw argv execution sink.

G-ADAPTER keeps raw gh command construction inside forge.github, but deliberately
does not inspect that adapter path. This checker owns the complementary invariant:
all production GitHub execution inside the allowed adapter surface must collapse to
the one sanctioned callback invocation in forge.github.exec.run.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import check_repo_lua


INVENTORY = "migration/gh-egress.inventory"
SANCTIONED_EGRESS = "libraries/forge/github/exec.lua:M.run"
ENTRY_FILES = (
    "libraries/forge/github.lua",
    "libraries/forge/github_fake.lua",
)
FUNCTION_RE = re.compile(
    r"^\s*(?:local\s+)?function\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*(?:\s*[.:]\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\("
)
CALL_RE = re.compile(r"\b(?P<callee>[A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\{")
PARAMETER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
INVENTORY_ENTRY_RE = re.compile(
    r"^libraries/forge/(?:github(?:_fake)?\.lua|github/[^:]+\.lua):"
    r"[A-Za-z_][A-Za-z0-9_.:]*$"
)


@dataclass(frozen=True)
class FunctionBlock:
    name: str
    parameters: frozenset[str]
    start: int
    end: int


def _matching_close(source: str, open_index: int, opener: str, closer: str) -> int | None:
    depth = 0
    for cursor in range(open_index, len(source)):
        char = source[cursor]
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return cursor
    return None


def _line_offsets(lines: list[str]) -> list[int]:
    offsets: list[int] = []
    offset = 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)
    return offsets


def function_blocks(source: str) -> list[FunctionBlock]:
    masked = check_repo_lua.code_mask(source, recognize_long_brackets=False)
    lines = masked.splitlines(keepends=True)
    offsets = _line_offsets(lines)
    blocks: list[FunctionBlock] = []
    for index, line in enumerate(lines):
        match = FUNCTION_RE.match(line)
        if match is None:
            continue
        open_paren = offsets[index] + match.end() - 1
        close_paren = _matching_close(masked, open_paren, "(", ")")
        if close_paren is None:
            continue
        parameters = frozenset(
            parameter.strip()
            for parameter in masked[open_paren + 1 : close_paren].split(",")
            if PARAMETER_RE.fullmatch(parameter.strip()) is not None
        )
        depth = check_repo_lua.block_delta(line)
        end_index = index
        while depth > 0 and end_index + 1 < len(lines):
            end_index += 1
            depth += check_repo_lua.block_delta(lines[end_index])
        end = offsets[end_index] + len(lines[end_index])
        blocks.append(
            FunctionBlock(
                name=match.group("name").replace(" ", ""),
                parameters=parameters,
                start=offsets[index],
                end=end,
            )
        )
    return blocks


def _production_sources(root: Path) -> list[Path]:
    paths = [root / relpath for relpath in ENTRY_FILES]
    directory = root / "libraries" / "forge" / "github"
    if directory.is_dir():
        paths.extend(sorted(directory.rglob("*.lua")))
    return [
        path
        for path in sorted(set(paths))
        if path.is_file() and "tests" not in path.relative_to(root).parts
    ]


def _owner_for_call(blocks: list[FunctionBlock], call_index: int) -> FunctionBlock | None:
    enclosing = [block for block in blocks if block.start <= call_index < block.end]
    if not enclosing:
        return None
    return max(enclosing, key=lambda block: (block.start, -block.end))


def _is_execution_callback(
    blocks: list[FunctionBlock], call_index: int, callee: str
) -> bool:
    if callee == "exec_argv":
        return True
    return any(
        callee in block.parameters
        for block in blocks
        if block.start <= call_index < block.end
    )


def source_sinks(relpath: str, source: str) -> set[str]:
    masked = check_repo_lua.code_mask(source, recognize_long_brackets=False)
    blocks = function_blocks(source)
    sinks: set[str] = set()
    for match in CALL_RE.finditer(masked):
        open_brace = masked.find("{", match.start(), match.end())
        close_brace = _matching_close(masked, open_brace, "{", "}")
        if close_brace is None or re.search(r"\bargv\s*=", masked[open_brace:close_brace]) is None:
            continue
        if not _is_execution_callback(blocks, match.start(), match.group("callee")):
            continue
        owner = _owner_for_call(blocks, match.start())
        sinks.add(f"{relpath}:{owner.name if owner is not None else '<top-level>'}")
    return sinks


def current_sinks(root: Path) -> set[str]:
    sinks: set[str] = set()
    for path in _production_sources(root):
        relpath = path.relative_to(root).as_posix()
        sinks.update(source_sinks(relpath, path.read_text(encoding="utf-8")))
    return sinks


def parse_inventory_lines(lines: list[str]) -> set[str]:
    entries: set[str] = set()
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if INVENTORY_ENTRY_RE.fullmatch(line) is None:
            raise ValueError(f"invalid {INVENTORY} entry: {raw}")
        if line in entries:
            raise ValueError(f"duplicate {INVENTORY} entry: {line}")
        entries.add(line)
    return entries


def load_inventory(root: Path) -> set[str] | None:
    path = root / INVENTORY
    if not path.is_file():
        return None
    return parse_inventory_lines(path.read_text(encoding="utf-8").splitlines())


def repository_messages(root: Path):
    if not (root / "libraries" / "forge").is_dir():
        return
    inventory = load_inventory(root)
    if inventory is None:
        yield (
            f"missing {INVENTORY}; it must contain exactly {SANCTIONED_EGRESS} "
            "because the terminal floor is one, not zero"
        )
    else:
        if SANCTIONED_EGRESS not in inventory:
            yield (
                f"{INVENTORY} must contain {SANCTIONED_EGRESS}; "
                "the terminal floor is one, not zero"
            )
        for entry in sorted(inventory - {SANCTIONED_EGRESS}):
            yield (
                f"{INVENTORY} contains non-sanctioned egress {entry}; "
                f"exactly one entry is allowed: {SANCTIONED_EGRESS}"
            )

    current = current_sinks(root)
    for sink in sorted(current - {SANCTIONED_EGRESS}):
        yield (
            f"{sink} is an additional GitHub raw argv egress sink; "
            f"exactly one is sanctioned: {SANCTIONED_EGRESS}"
        )
    if SANCTIONED_EGRESS not in current:
        yield (
            f"sanctioned GitHub raw argv egress {SANCTIONED_EGRESS} is missing; "
            "the terminal contract requires exactly one egress"
        )


def check(root: Path, violations: list[str]) -> None:
    for message in repository_messages(root):
        violations.append(f"G-GH-EGRESS: {message}")


if __name__ == "__main__":
    project_root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    found: list[str] = []
    check(project_root, found)
    print("current:", json.dumps(sorted(current_sinks(project_root)), indent=2))
    print("baseline:", json.dumps(sorted(load_inventory(project_root) or set()), indent=2))
    for violation in found:
        print("VIOLATION:", violation)
    sys.exit(1 if found else 0)
