#!/usr/bin/env python3
"""G-GH-HANDLE-CONSTRUCTION: debt-only GitHub handle locator ratchet.

The canonical capability is constructed by forge.github and composed by the
forge.ports, devloop factory, package-core, and department port-wiring seams.
Those ownership facts are recognized here and are not migration debt.

Debt is a production consumer that obtains or constructs a GitHub handle
instead of receiving the typed handle. The inventory records only those
consumer sites. This is a lexical Lua scanner for the explicit factory forms
used by this repository, not a proof that arbitrary aliases cannot hide a
locator. Unclassified explicit construction is fail-closed, and the inventory
is compared with the target-branch inventory after the one-time scope change.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import check_repo_config
import check_repo_lua


INVENTORY = "migration/gh-handle-construction.inventory"
DEBT_HEADER = "# Debt-only, shrink-only production GitHub consumer handle locators."

ORIGINAL_CANONICAL_FACTS = {
    "libraries/forge/github.lua:M.new",
    "libraries/forge/ports.lua:M.production_handles",
    "libraries/forge/merge_commands.lua:M.install",
    "libraries/devloop/github_factory.lua:M.new",
    "libraries/devloop/github_factory.lua:M.production_handle",
    "packages/fkst-substrate-ref-maintainer/core.lua:forge.merge.install",
    "packages/github-devloop/core.lua:forge.merge.install",
    "packages/github-devloop/core/github_graphql.lua:M.github_graphql",
    "packages/github-devloop-pr/core.lua:forge.merge.install",
    "packages/github-devloop-integration/core.lua:forge.merge.install",
    "packages/github-devloop-integration/core/release_notes.lua:M.gh_pr_create_body",
    "packages/archaudit/departments/audit/main.lua:ports_lib.install",
    "packages/integration-coverage-producer/departments/produce/main.lua:ports_lib.install",
    "packages/github-external-pr-intake/departments/external_pr_intake/main.lua:ports_seam.install",
    "packages/idle-detector/departments/idle_gate/main.lua:ports_lib.install",
    "packages/github-ratchet-migration-slicer/departments/ratchet_migration_driver/main.lua:ports_seam.install",
}

_IMPORT_RE = re.compile(
    r"\blocal\s+(?P<alias>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r"require\(\s*['\"](?P<module>devloop\.github_factory|forge\.github|forge\.ports)['\"]\s*\)"
)
_DIRECT_FACTORY_RE = re.compile(
    r"\brequire\(\s*['\"](?P<module>devloop\.github_factory|forge\.github)['\"]\s*\)\s*\.\s*"
    r"(?P<method>production_handle|new)\b"
)
_FUNCTION_RE = re.compile(
    r"\b(?:local\s+function\s+(?P<local>[A-Za-z_][A-Za-z0-9_]*)|"
    r"function\s+(?P<named>[A-Za-z_][A-Za-z0-9_.:]*))\s*\("
)
_LOCAL_ASSIGN_RE = re.compile(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=")
_SITE_RE = re.compile(r"^[^:]+:[A-Za-z_][A-Za-z0-9_.:]*$")
_PACKAGE_CORE_WIRING_LINE_RE = re.compile(
    r"^\s*github_handle\s*=\s*require\(\s*['\"]devloop\.github_factory['\"]\s*\)\s*"
    r"\.\s*production_handle\s*,?\s*$"
)


def _production_lua_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for base in (root / "libraries", root / "packages"):
        if base.is_dir():
            paths.extend(
                path
                for path in sorted(base.rglob("*.lua"))
                if path.is_file() and "tests" not in path.relative_to(base).parts
            )
    return paths


def _is_code_start(mask: str, start: int, token: str) -> bool:
    return mask[start : start + len(token)] == token


def _imports(source: str, mask: str) -> dict[str, set[str]]:
    aliases = {
        "devloop.github_factory": set(),
        "forge.github": set(),
        "forge.ports": set(),
    }
    for match in _IMPORT_RE.finditer(source):
        if _is_code_start(mask, match.start(), "local"):
            aliases[match.group("module")].add(match.group("alias"))
    return aliases


def _function_spans(source: str) -> list[tuple[int, int, str]]:
    lines = check_repo_lua.code_mask(source).splitlines()
    spans: list[tuple[int, int, str]] = []
    for index, line in enumerate(lines):
        match = _FUNCTION_RE.search(line)
        if match is None:
            continue
        name = match.group("local") or match.group("named")
        depth = check_repo_lua.block_delta(line, count_header_keywords=True)
        end = index
        while depth > 0 and end + 1 < len(lines):
            end += 1
            depth += check_repo_lua.block_delta(lines[end], count_header_keywords=True)
        spans.append((index + 1, end + 1, name))
    return spans


def _owner(line_number: int, line: str, spans: list[tuple[int, int, str]], ordinal: int) -> str:
    enclosing = [span for span in spans if span[0] <= line_number <= span[1]]
    if enclosing:
        return max(enclosing, key=lambda span: (span[0], -span[1]))[2]
    assignment = _LOCAL_ASSIGN_RE.search(line)
    if assignment is not None:
        return assignment.group(1)
    return f"top_level_locator_{ordinal}"


def _candidate_lines(source: str) -> list[tuple[int, str]]:
    mask = check_repo_lua.code_mask(source)
    aliases = _imports(source, mask)
    matches: list[tuple[int, str]] = []
    patterns: list[re.Pattern[str]] = []
    factory_aliases = aliases["devloop.github_factory"]
    if factory_aliases:
        names = "|".join(re.escape(alias) for alias in sorted(factory_aliases))
        patterns.append(re.compile(rf"\b(?:{names})\s*\.\s*(?:production_handle|new)\b"))
    github_aliases = aliases["forge.github"]
    if github_aliases:
        names = "|".join(re.escape(alias) for alias in sorted(github_aliases))
        patterns.append(re.compile(rf"\b(?:{names})\s*\.\s*new\b"))
    for pattern in patterns:
        for match in pattern.finditer(mask):
            matches.append((source.count("\n", 0, match.start()) + 1, match.group(0)))
    for match in _DIRECT_FACTORY_RE.finditer(source):
        if _is_code_start(mask, match.start(), "require"):
            matches.append((source.count("\n", 0, match.start()) + 1, match.group(0)))
    return sorted(set(matches))


def _is_package_core_wiring(relpath: str, line: str, source: str) -> bool:
    return (
        re.fullmatch(r"packages/[^/]+/core\.lua", relpath) is not None
        and _PACKAGE_CORE_WIRING_LINE_RE.fullmatch(line) is not None
        and 'require("forge.merge").install' in source
    )


def _has_package_core_wiring(relpath: str, source: str) -> bool:
    return any(
        _is_package_core_wiring(relpath, line, source)
        for line in source.splitlines()
    )


def _is_canonical_candidate(relpath: str, owner: str, line: str, source: str) -> bool:
    if relpath in {
        "libraries/forge/ports.lua",
        "libraries/forge/merge_commands.lua",
        "libraries/devloop/github_factory.lua",
    }:
        return True
    if _is_package_core_wiring(relpath, line, source):
        return True
    return (
        relpath == "packages/github-devloop-integration/core/release_notes.lua"
        and owner == "M.gh_pr_create_body"
    )


def _port_install_sites(relpath: str, source: str) -> set[str]:
    mask = check_repo_lua.code_mask(source)
    aliases = _imports(source, mask)["forge.ports"]
    sites: set[str] = set()
    for alias in aliases:
        pattern = re.compile(rf"\b{re.escape(alias)}\s*\.\s*install\s*\(")
        if pattern.search(mask):
            sites.add(f"{relpath}:{alias}.install")
    return sites


def canonical_sites(root: Path) -> set[str]:
    sites: set[str] = set()
    for path in _production_lua_files(root):
        relpath = path.relative_to(root).as_posix()
        source = path.read_text(encoding="utf-8")
        mask = check_repo_lua.code_mask(source)
        sites.update(_port_install_sites(relpath, source))
        if relpath == "libraries/forge/github.lua" and re.search(r"\bfunction\s+M\.new\s*\(", mask):
            sites.add(f"{relpath}:M.new")
        if relpath == "libraries/forge/ports.lua" and re.search(r"\bfunction\s+M\.production_handles\s*\(", mask):
            sites.add(f"{relpath}:M.production_handles")
        if relpath == "libraries/forge/merge_commands.lua" and re.search(r"\bfunction\s+M\.install\s*\(", mask):
            sites.add(f"{relpath}:M.install")
        if relpath == "libraries/devloop/github_factory.lua":
            for symbol in ("new", "production_handle"):
                if re.search(rf"\bfunction\s+M\.{symbol}\s*\(", mask):
                    sites.add(f"{relpath}:M.{symbol}")
        if _has_package_core_wiring(relpath, source):
            sites.add(f"{relpath}:forge.merge.install")
        if relpath == "packages/github-devloop/core/github_graphql.lua" and "M.github_graphql" in mask:
            sites.add(f"{relpath}:M.github_graphql")
        if relpath == "packages/github-devloop-integration/core/release_notes.lua" and re.search(
            r"\bfunction\s+M\.gh_pr_create_body\s*\(", mask
        ):
            sites.add(f"{relpath}:M.gh_pr_create_body")
    return sites


def current_debt(root: Path) -> set[str]:
    debt: set[str] = set()
    for path in _production_lua_files(root):
        relpath = path.relative_to(root).as_posix()
        source = path.read_text(encoding="utf-8")
        lines = source.splitlines()
        spans = _function_spans(source)
        for ordinal, (line_number, _match) in enumerate(_candidate_lines(source), 1):
            line = lines[line_number - 1]
            owner = _owner(line_number, line, spans, ordinal)
            if not _is_canonical_candidate(relpath, owner, line, source):
                debt.add(f"{relpath}:{owner}")
    return debt


def parse_inventory_lines(lines: list[str], *, require_debt_header: bool = False) -> set[str] | None:
    if require_debt_header and DEBT_HEADER not in lines:
        return None
    entries: set[str] = set()
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if _SITE_RE.fullmatch(line) is None:
            raise ValueError(f"invalid {INVENTORY} entry: {raw}")
        if line in entries:
            raise ValueError(f"duplicate {INVENTORY} entry: {line}")
        entries.add(line)
    return entries


def load_inventory(root: Path) -> set[str] | None:
    path = root / INVENTORY
    if not path.is_file():
        return None
    return parse_inventory_lines(path.read_text(encoding="utf-8").splitlines(), require_debt_header=True)


def ratchet_messages(
    current: set[str], inventory: set[str], base_inventory: set[str] | None
) -> list[str]:
    messages: list[str] = []
    for site in sorted(current - inventory):
        messages.append(
            f"{site} is a new consumer-side GitHub handle locator not recorded in {INVENTORY}; "
            "inject the typed forge.github handle instead (the debt inventory cannot grow)"
        )
    for site in sorted(inventory - current):
        messages.append(
            f"{site} no longer exists; remove it from {INVENTORY} (the inventory must shrink with the debt)"
        )
    if base_inventory is not None:
        for site in sorted(inventory - base_inventory):
            messages.append(
                f"{INVENTORY} inventory grew relative to the base with {site}; "
                "new consumer handle locators are forbidden"
            )
    return messages


def repository_messages(root: Path, enforce_base: bool = True):
    if not (root / "libraries" / "forge").is_dir():
        return
    current = current_debt(root)
    inventory = load_inventory(root)
    if inventory is None:
        yield (
            f"missing or unscoped {INVENTORY}; write {DEBT_HEADER!r} followed only by the "
            "current consumer-side locator sites"
        )
        return
    base_inventory: set[str] | None = None
    if enforce_base:
        status, parsed = check_repo_config.allowlist_at_dev_base(
            root,
            allowlist=INVENTORY,
            parse_allowlist_lines=lambda lines: parse_inventory_lines(
                lines, require_debt_header=True
            ),
        )
        if status == "unresolved":
            yield (
                "cannot resolve target baseline inventory to enforce the shrink-only GitHub "
                "handle locator ratchet; ensure CI provides the target ref"
            )
        elif status == "present":
            base_inventory = parsed
    yield from ratchet_messages(current, inventory, base_inventory)


def check(root: Path, violations: list[str], enforce_base: bool = True) -> None:
    for message in repository_messages(root, enforce_base):
        violations.append(f"G-GH-HANDLE-CONSTRUCTION: {message}")


if __name__ == "__main__":
    project_root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    found: list[str] = []
    check(project_root, found)
    print("current:", json.dumps(sorted(current_debt(project_root)), indent=2))
    print("canonical:", json.dumps(sorted(canonical_sites(project_root)), indent=2))
    print("baseline:", json.dumps(sorted(load_inventory(project_root) or set()), indent=2))
    for violation in found:
        print("VIOLATION:", violation)
    sys.exit(1 if found else 0)
