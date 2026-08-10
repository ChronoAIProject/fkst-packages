#!/usr/bin/env python3
"""Mechanical soundness checks for graph-derived affected-test selection.

Declared ``lib_deps`` edges are PREVENT: the engine makes an undeclared library
require unresolvable. Declared ``event_deps`` are checked only for agreement with
the emitted event-edge projection; that self-consistency does not prove a package
declares every sibling it loads. Lua-to-script edges are lexical and fail closed:
complete known ``scripts/<path>`` occurrences create exact edges, while any
remaining non-exempt ``scripts`` token creates a wildcard edge from that unit to
every script. Lua that synthesizes the token without spelling it is outside this
lexical tier.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable, Optional

import check_repo_config
import test_selection


ALLOWLIST = "migration/test-selection-uncovered.allowlist"
SCRIPT_TOKEN_EXEMPT_ALLOWLIST = test_selection.SCRIPT_TOKEN_EXEMPT_ALLOWLIST


def tracked_paths(root: Path) -> tuple[str, ...]:
    result = subprocess.run(
        ["git", "ls-files"],
        cwd=root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise test_selection.SelectionError(
            f"git ls-files exited {result.returncode}: {result.stderr.strip()}"
        )
    paths = tuple(line for line in result.stdout.splitlines() if line)
    if not paths:
        raise test_selection.SelectionError("git ls-files returned no tracked paths")
    return paths


def parse_allowlist_lines(lines: Iterable[str]) -> set[str]:
    entries: set[str] = set()
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = Path(line).parts
        if line.startswith("/") or ".." in parts or "\\" in line:
            raise ValueError(f"invalid {ALLOWLIST} path: {line}")
        if line in entries:
            raise ValueError(f"duplicate {ALLOWLIST} path: {line}")
        entries.add(line)
    return entries


def load_allowlist(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    return parse_allowlist_lines(path.read_text(encoding="utf-8").splitlines())


def path_is_claimed(graph: test_selection.DependencyGraph, path: str) -> bool:
    if path in {ALLOWLIST, SCRIPT_TOKEN_EXEMPT_ALLOWLIST}:
        return True
    parts = Path(path).parts
    if len(parts) >= 3 and parts[0] == "packages":
        return parts[1] in graph.packages_by_target
    if len(parts) >= 3 and parts[0] == "libraries":
        return parts[1] in graph.library_units
    if len(parts) >= 2 and parts[0] in {"scripts", ".github"}:
        return True
    return False


def totality_identity_messages(
    graph: test_selection.DependencyGraph,
    paths: Iterable[str],
    root: Path,
    select_fn: Callable = test_selection.select_paths,
) -> list[str]:
    path_set = set(paths)
    try:
        runners = test_selection.runner_scripts(root)
        classes = (
            (
                "packages",
                tuple(sorted(path for path in path_set if Path(path).parts[:1] == ("packages",))),
                set(graph.package_targets),
            ),
            (
                "libraries",
                tuple(sorted(path for path in path_set if Path(path).parts[:1] == ("libraries",))),
                set().union(
                    *(graph.dependent_packages(name) for name in graph.library_units)
                ),
            ),
            (
                "scripts",
                tuple(
                    sorted(
                        path
                        for path in path_set
                        if Path(path).parts[:1] == ("scripts",) and path not in runners
                    )
                ),
                test_selection._script_reference_packages(
                    graph,
                    {
                        path
                        for path in path_set
                        if Path(path).parts[:1] == ("scripts",) and path not in runners
                    },
                ),
            ),
        )
    except Exception as exc:
        return [f"TOTALITY IDENTITY planner error: {exc}"]
    messages: list[str] = []
    for class_name, class_paths, direct_expected in classes:
        if not class_paths:
            continue
        expected = set(graph.event_dependent_packages(direct_expected))
        try:
            result = select_fn(graph, class_paths, root)
        except Exception as exc:
            messages.append(f"TOTALITY IDENTITY {class_name} planner error: {exc}")
            continue
        if result.full:
            messages.append(
                f"TOTALITY IDENTITY {class_name} failed: claimed class selected FULL instead of the narrow path"
            )
            continue
        selected = set(result.packages)
        if selected != expected:
            missing = ",".join(sorted(expected - selected)) or "<none>"
            extra = ",".join(sorted(selected - expected)) or "<none>"
            messages.append(
                f"TOTALITY IDENTITY {class_name} failed: missing={missing} extra={extra}"
            )
    return messages


def total_cover_messages(
    graph: test_selection.DependencyGraph,
    paths: Iterable[str],
    allowlist: set[str],
) -> list[str]:
    return [
        f"TOTAL COVER failed: tracked path is unclaimed and absent from {ALLOWLIST}: {path}"
        for path in sorted(set(paths))
        if not path_is_claimed(graph, path) and path not in allowlist
    ]


def allowlist_ratchet_messages(
    current: set[str],
    allowlist: set[str],
    base_allowlist: Optional[set[str]],
) -> list[str]:
    messages: list[str] = []
    for path in sorted(allowlist - current - {ALLOWLIST}):
        messages.append(f"stale {ALLOWLIST} entry must be removed: {path}")
    if base_allowlist is not None:
        for path in sorted(allowlist - base_allowlist):
            messages.append(f"{ALLOWLIST} is shrink-only and grew by: {path}")
    return messages


def script_token_exemption_ratchet_messages(
    current: set[test_selection.ScriptTokenSite],
    exemptions: set[test_selection.ScriptTokenSite],
    base_exemptions: Optional[set[test_selection.ScriptTokenSite]],
) -> list[str]:
    messages = [
        f"stale {SCRIPT_TOKEN_EXEMPT_ALLOWLIST} entry must be removed: {site.label()}"
        for site in sorted(exemptions - current)
    ]
    if base_exemptions is not None:
        messages.extend(
            f"{SCRIPT_TOKEN_EXEMPT_ALLOWLIST} is shrink-only and grew by: {site.label()}"
            for site in sorted(exemptions - base_exemptions)
        )
    return messages


def repository_messages(
    root: Path,
    graph: test_selection.DependencyGraph,
    paths: tuple[str, ...],
    allowlist: set[str],
    base_allowlist: Optional[set[str]],
    base_status: str = "resolved",
    select_fn: Callable = test_selection.select_paths,
) -> list[str]:
    uncovered = {path for path in paths if not path_is_claimed(graph, path)}
    messages: list[str] = []
    if base_status == "unresolved":
        messages.append(
            f"cannot resolve protected-base {ALLOWLIST} to enforce its shrink-only ratchet"
        )
    messages.extend(totality_identity_messages(graph, paths, root, select_fn=select_fn))
    messages.extend(total_cover_messages(graph, paths, allowlist))
    messages.extend(allowlist_ratchet_messages(uncovered, allowlist, base_allowlist))
    return messages


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--bin")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = _parser().parse_args(argv)
    root = args.project_root.resolve()
    try:
        binary = test_selection.resolve_engine_binary(root, args.bin)
        payload = test_selection.read_engine_dependencies(root, binary)
        graph = test_selection.DependencyGraph.from_payload(payload, root)
        paths = tracked_paths(root)
        allowlist = load_allowlist(root / ALLOWLIST)
        base_status, base_allowlist = check_repo_config.allowlist_at_dev_base(
            root,
            allowlist=ALLOWLIST,
            parse_allowlist_lines=parse_allowlist_lines,
        )
        script_token_sites = test_selection.unresolved_script_token_sites(graph)
        script_token_exemptions = test_selection.load_script_token_exemptions(root)
        script_token_base_status, base_script_token_exemptions = (
            check_repo_config.allowlist_at_dev_base(
                root,
                allowlist=SCRIPT_TOKEN_EXEMPT_ALLOWLIST,
                parse_allowlist_lines=test_selection.parse_script_token_exemption_lines,
            )
        )
        messages = repository_messages(
            root,
            graph,
            paths,
            allowlist,
            base_allowlist,
            base_status=base_status,
        )
        if script_token_base_status == "unresolved":
            messages.append(
                f"cannot resolve protected-base {SCRIPT_TOKEN_EXEMPT_ALLOWLIST} "
                "to enforce its shrink-only ratchet"
            )
        messages.extend(
            script_token_exemption_ratchet_messages(
                script_token_sites,
                script_token_exemptions,
                base_script_token_exemptions,
            )
        )
    except (OSError, UnicodeError, ValueError, test_selection.SelectionError) as exc:
        print(f"test selection soundness check failed closed: {exc}", file=sys.stderr)
        return 1
    if messages:
        for message in messages:
            print(f"test selection soundness violation: {message}", file=sys.stderr)
        return 1
    print(
        f"OK: test selection soundness ({len(paths)} tracked paths, "
        f"{len(graph.package_targets)} packages)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
