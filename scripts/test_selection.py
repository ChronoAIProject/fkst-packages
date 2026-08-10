#!/usr/bin/env python3
"""Derive affected package tests from the engine-emitted dependency graph."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Optional


FULL_SENTINEL = "FULL"
TARGET_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*\Z")
SOURCE_RE = re.compile(
    r"(?m)^\s*(?:\.|source)\s+[\"']?\$ROOT/scripts/(?P<name>[A-Za-z0-9_.-]+\.sh)"
)
FUNCTION_RE = re.compile(r"(?m)^(?P<name>[A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
SCRIPT_LITERAL_RE = re.compile(r"(?:\$ROOT/)?scripts/(?P<name>[A-Za-z0-9_./-]+\.sh)")
SCRIPT_TOKEN_RE = re.compile(r"\bscripts\b")
SCRIPT_TOKEN_EXEMPT_ALLOWLIST = "migration/test-selection-script-token-exempt.allowlist"


class SelectionError(RuntimeError):
    """The planner cannot prove a narrow selection."""


@dataclass(frozen=True)
class Unit:
    name: str
    kind: str
    root: Path
    target: Optional[str]
    lib_deps: tuple[str, ...]
    event_deps: tuple[str, ...]


@dataclass(frozen=True)
class Selection:
    full: bool
    packages: frozenset[str]

    @classmethod
    def full_result(cls) -> "Selection":
        return cls(True, frozenset())


@dataclass(frozen=True, order=True)
class ScriptTokenSite:
    path: str
    line: int

    def label(self) -> str:
        return f"{self.path}:{self.line}"


def parse_script_token_exemption_lines(lines: Iterable[str]) -> set[ScriptTokenSite]:
    exemptions: set[ScriptTokenSite] = set()
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        site_text, separator, why = stripped.partition(" # why=")
        path, colon, line_text = site_text.rpartition(":")
        parts = Path(path).parts
        if (
            not separator
            or not why.strip()
            or not colon
            or not line_text.isdigit()
            or int(line_text) < 1
            or path.startswith("/")
            or ".." in parts
            or "\\" in path
            or len(parts) < 3
            or parts[0] not in {"packages", "libraries"}
            or not path.endswith(".lua")
        ):
            raise ValueError(f"invalid {SCRIPT_TOKEN_EXEMPT_ALLOWLIST} entry: {stripped}")
        site = ScriptTokenSite(path, int(line_text))
        if site in exemptions:
            raise ValueError(f"duplicate {SCRIPT_TOKEN_EXEMPT_ALLOWLIST} entry: {site.label()}")
        exemptions.add(site)
    return exemptions


def load_script_token_exemptions(project_root: Path) -> set[ScriptTokenSite]:
    path = project_root / SCRIPT_TOKEN_EXEMPT_ALLOWLIST
    if not path.is_file():
        return set()
    return parse_script_token_exemption_lines(
        path.read_text(encoding="utf-8").splitlines()
    )


class DependencyGraph:
    def __init__(
        self,
        package_units: dict[str, Unit],
        library_units: dict[str, Unit],
        project_root: Path,
    ) -> None:
        self.package_units = package_units
        self.library_units = library_units
        self.project_root = project_root
        self.packages_by_target = {
            unit.target: unit for unit in package_units.values() if unit.target is not None
        }
        self.package_targets = frozenset(self.packages_by_target)
        self.event_consumers: dict[str, set[str]] = {}
        for unit in package_units.values():
            for dependency in unit.event_deps:
                self.event_consumers.setdefault(dependency, set()).add(unit.name)

    @classmethod
    def from_payload(cls, payload: object, project_root: Path) -> "DependencyGraph":
        if not isinstance(payload, dict) or payload.get("ok") is not True:
            raise SelectionError("dependency JSON does not report ok=true")
        failures = payload.get("failures")
        if not isinstance(failures, list) or failures:
            raise SelectionError("dependency JSON contains failures or lacks a failures list")
        warnings = payload.get("warnings")
        lib_edges = payload.get("lib_edges")
        event_edges = payload.get("event_edges")
        if not isinstance(warnings, list):
            raise SelectionError("dependency JSON warnings must be a list")
        if not isinstance(lib_edges, list):
            raise SelectionError("dependency JSON lib_edges must be a list")
        if not isinstance(event_edges, list) or any(not isinstance(edge, dict) for edge in event_edges):
            raise SelectionError("dependency JSON event_edges must be a list of objects")
        units = payload.get("units")
        if not isinstance(units, list):
            raise SelectionError("dependency JSON units must be a list")

        expected_root = project_root.resolve()
        workspace_root = payload.get("workspace_root")
        if not isinstance(workspace_root, str) or Path(workspace_root).resolve() != expected_root:
            raise SelectionError("dependency JSON workspace_root does not match the project root")

        package_units: dict[str, Unit] = {}
        library_units: dict[str, Unit] = {}
        seen_names: set[str] = set()
        seen_targets: set[str] = set()
        for raw in units:
            if not isinstance(raw, dict):
                raise SelectionError("dependency JSON contains a non-object unit")
            name = raw.get("name")
            kind = raw.get("kind")
            root_value = raw.get("root")
            lib_deps = raw.get("lib_deps")
            event_deps = raw.get("event_deps")
            if not isinstance(name, str) or TARGET_RE.fullmatch(name) is None:
                raise SelectionError("dependency JSON contains an invalid unit name")
            if name in seen_names:
                raise SelectionError(f"dependency JSON contains duplicate unit name: {name}")
            seen_names.add(name)
            if kind not in {"package", "library"}:
                raise SelectionError(f"dependency JSON contains invalid kind for {name}")
            if not isinstance(root_value, str) or not root_value:
                raise SelectionError(f"dependency JSON contains invalid root for {name}")
            if not isinstance(lib_deps, list) or any(not isinstance(dep, str) for dep in lib_deps):
                raise SelectionError(f"dependency JSON contains invalid lib_deps for {name}")
            if len(set(lib_deps)) != len(lib_deps):
                raise SelectionError(f"dependency JSON contains duplicate lib_deps for {name}")
            if not isinstance(event_deps, list) or any(not isinstance(dep, str) for dep in event_deps):
                raise SelectionError(f"dependency JSON contains invalid event_deps for {name}")
            if len(set(event_deps)) != len(event_deps):
                raise SelectionError(f"dependency JSON contains duplicate event_deps for {name}")

            unit_root = Path(root_value)
            if not unit_root.is_absolute():
                unit_root = project_root / unit_root
            unit_root = unit_root.resolve()
            parent = expected_root / ("packages" if kind == "package" else "libraries")
            try:
                relative = unit_root.relative_to(parent)
            except ValueError as exc:
                raise SelectionError(f"dependency unit {name} root is outside {parent}") from exc
            if len(relative.parts) != 1 or TARGET_RE.fullmatch(relative.name) is None:
                raise SelectionError(f"dependency unit {name} root is not a direct workspace unit")

            target = relative.name if kind == "package" else None
            if target is not None:
                if target in seen_targets:
                    raise SelectionError(f"dependency JSON maps multiple packages to target: {target}")
                seen_targets.add(target)
            elif relative.name != name:
                raise SelectionError(f"library unit name does not match its root: {name}")
            unit = Unit(name, kind, unit_root, target, tuple(lib_deps), tuple(event_deps))
            (package_units if kind == "package" else library_units)[name] = unit

        if not package_units:
            raise SelectionError("dependency JSON contains no package units")
        for unit in tuple(package_units.values()) + tuple(library_units.values()):
            for dependency in unit.lib_deps:
                if dependency not in library_units:
                    raise SelectionError(
                        f"dependency unit {unit.name} names unresolved library: {dependency}"
                    )
            for dependency in unit.event_deps:
                if unit.kind != "package" or dependency not in package_units:
                    raise SelectionError(
                        f"dependency unit {unit.name} names unresolved event dependency: {dependency}"
                    )
        declared_edges = {
            (unit.name, dependency)
            for unit in tuple(package_units.values()) + tuple(library_units.values())
            for dependency in unit.lib_deps
        }
        emitted_edges: set[tuple[str, str]] = set()
        for edge in lib_edges:
            if not isinstance(edge, dict) or not isinstance(edge.get("from"), str) or not isinstance(edge.get("to"), str):
                raise SelectionError("dependency JSON lib_edges must contain from/to strings")
            emitted_edges.add((edge["from"], edge["to"]))
        if len(emitted_edges) != len(lib_edges) or emitted_edges != declared_edges:
            raise SelectionError("dependency JSON lib_edges disagree with declared unit.lib_deps")
        declared_event_edges = {
            (unit.name, dependency)
            for unit in package_units.values()
            for dependency in unit.event_deps
        }
        emitted_event_edges: set[tuple[str, str]] = set()
        for edge in event_edges:
            if not isinstance(edge.get("from"), str) or not isinstance(edge.get("to"), str):
                raise SelectionError("dependency JSON event_edges must contain from/to strings")
            emitted_event_edges.add((edge["from"], edge["to"]))
        if len(emitted_event_edges) != len(event_edges) or emitted_event_edges != declared_event_edges:
            raise SelectionError("dependency JSON event_edges disagree with declared unit.event_deps")
        return cls(package_units, library_units, expected_root)

    def library_closure(self, unit: Unit) -> frozenset[str]:
        closure: set[str] = set()
        visiting: set[str] = set()

        def visit(library: str) -> None:
            if library in closure:
                return
            if library in visiting:
                raise SelectionError(f"library dependency cycle reaches {library}")
            dependency = self.library_units.get(library)
            if dependency is None:
                raise SelectionError(f"unresolved library dependency: {library}")
            visiting.add(library)
            for child in dependency.lib_deps:
                visit(child)
            visiting.remove(library)
            closure.add(library)

        for library in unit.lib_deps:
            visit(library)
        return frozenset(closure)

    def dependent_packages(self, library: str) -> frozenset[str]:
        if library not in self.library_units:
            raise SelectionError(f"unresolved changed library: {library}")
        return frozenset(
            unit.target
            for unit in self.package_units.values()
            if unit.target is not None and library in self.library_closure(unit)
        )

    def event_dependent_packages(self, targets: Iterable[str]) -> frozenset[str]:
        closure = set(targets)
        pending = [self.packages_by_target[target].name for target in closure]
        while pending:
            dependency = pending.pop()
            for consumer in self.event_consumers.get(dependency, set()):
                unit = self.package_units[consumer]
                assert unit.target is not None
                if unit.target not in closure:
                    closure.add(unit.target)
                    pending.append(consumer)
        return frozenset(closure)


def _shell_sources(path: Path) -> set[str]:
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise SelectionError(f"cannot read runner source {path}") from exc
    return {f"scripts/{match.group('name')}" for match in SOURCE_RE.finditer(source)}


def _shell_functions(paths: Iterable[Path]) -> dict[str, str]:
    functions: dict[str, str] = {}
    for path in paths:
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise SelectionError(f"cannot read runner source {path}") from exc
        matches = list(FUNCTION_RE.finditer(source))
        for index, match in enumerate(matches):
            name = match.group("name")
            if name in functions:
                raise SelectionError(f"duplicate sourced shell function prevents runner derivation: {name}")
            end = matches[index + 1].start() if index + 1 < len(matches) else len(source)
            functions[name] = source[match.start():end]
    return functions


def runner_scripts(project_root: Path) -> frozenset[str]:
    run_path = project_root / "scripts" / "run.sh"
    pending = ["scripts/run.sh"]
    sourced: set[str] = set()
    while pending:
        relative = pending.pop()
        if relative in sourced:
            continue
        path = project_root / relative
        if not path.is_file():
            raise SelectionError(f"runner source does not exist: {relative}")
        sourced.add(relative)
        pending.extend(sorted(_shell_sources(path) - sourced))

    functions = _shell_functions(project_root / path for path in sorted(sourced))
    roots = {"cmd_test", "cmd_test_composed"}
    if not roots.issubset(functions):
        raise SelectionError("run.sh test functions are missing from runner source")
    reachable = set(roots)
    pending_functions = list(roots)
    while pending_functions:
        function = pending_functions.pop()
        body = functions[function]
        for candidate in functions:
            if candidate not in reachable and re.search(r"\b" + re.escape(candidate) + r"\b", body):
                reachable.add(candidate)
                pending_functions.append(candidate)

    executed: set[str] = set()
    for function in reachable:
        for match in SCRIPT_LITERAL_RE.finditer(functions[function]):
            executed.add(f"scripts/{match.group('name')}")
    for relative in executed:
        if not (project_root / relative).is_file():
            raise SelectionError(f"test runner executes missing script: {relative}")
    return frozenset(sourced | executed)


def _known_script_paths(
    graph: DependencyGraph,
    scripts: set[str],
) -> tuple[str, ...]:
    known_scripts = set(scripts)
    scripts_root = graph.project_root / "scripts"
    if not scripts_root.is_dir():
        raise SelectionError(f"scripts root is unavailable for Lua scan: {scripts_root}")
    for path in scripts_root.rglob("*"):
        if path.is_file():
            known_scripts.add(path.relative_to(graph.project_root).as_posix())
    return tuple(sorted(known_scripts, key=lambda path: (-len(path), path)))


def _unresolved_script_token_sites(
    path: str,
    source: str,
    known_script_paths: tuple[str, ...],
) -> set[ScriptTokenSite]:
    sites: set[ScriptTokenSite] = set()
    for match in SCRIPT_TOKEN_RE.finditer(source):
        for script in known_script_paths:
            if not source.startswith(script, match.start()):
                continue
            end = match.start() + len(script)
            if end == len(source) or not (
                source[end].isalnum() or source[end] in "_./-"
            ):
                break
        else:
            sites.add(ScriptTokenSite(path, source.count("\n", 0, match.start()) + 1))
    return sites


def _read_unit_lua_sources(
    graph: DependencyGraph,
    unit: Unit,
) -> tuple[tuple[str, str], ...]:
    if not unit.root.is_dir():
        raise SelectionError(f"dependency unit root is unavailable for Lua scan: {unit.root}")
    sources: list[tuple[str, str]] = []
    for path in sorted(unit.root.rglob("*.lua")):
        if not path.is_file():
            continue
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise SelectionError(f"cannot read Lua source {path}") from exc
        sources.append((path.relative_to(graph.project_root).as_posix(), source))
    return tuple(sources)


def unresolved_script_token_sites(graph: DependencyGraph) -> set[ScriptTokenSite]:
    known_script_paths = _known_script_paths(graph, set())
    sites: set[ScriptTokenSite] = set()
    for unit in tuple(graph.package_units.values()) + tuple(graph.library_units.values()):
        for path, source in _read_unit_lua_sources(graph, unit):
            sites.update(_unresolved_script_token_sites(path, source, known_script_paths))
    return sites


def _script_reference_packages(
    graph: DependencyGraph,
    scripts: set[str],
) -> set[str]:
    known_script_paths = _known_script_paths(graph, scripts)
    exemptions = load_script_token_exemptions(graph.project_root)

    selected: set[str] = set()
    for unit in tuple(graph.package_units.values()) + tuple(graph.library_units.values()):
        referenced = False
        unresolved = False
        for path, source in _read_unit_lua_sources(graph, unit):
            referenced = referenced or any(script in source for script in scripts)
            unresolved = unresolved or bool(
                _unresolved_script_token_sites(path, source, known_script_paths) - exemptions
            )
        if not referenced and not unresolved:
            continue
        if unit.kind == "package":
            assert unit.target is not None
            selected.add(unit.target)
        else:
            selected.update(graph.dependent_packages(unit.name))
    return selected


def select_paths(
    graph: DependencyGraph,
    changed_paths: Iterable[str],
    project_root: Path,
) -> Selection:
    paths = tuple(sorted(set(changed_paths)))
    if not paths:
        return Selection.full_result()

    selected: set[str] = set()
    changed_libraries: set[str] = set()
    changed_scripts: set[str] = set()
    runners: Optional[frozenset[str]] = None
    for path in paths:
        parts = Path(path).parts
        if not path or path.startswith("/") or ".." in parts or "\\" in path:
            return Selection.full_result()
        if len(parts) >= 3 and parts[0] == "packages":
            unit = graph.packages_by_target.get(parts[1])
            if unit is None:
                return Selection.full_result()
            assert unit.target is not None
            selected.add(unit.target)
        elif len(parts) >= 3 and parts[0] == "libraries":
            if parts[1] not in graph.library_units:
                return Selection.full_result()
            changed_libraries.add(parts[1])
        elif len(parts) >= 2 and parts[0] == "scripts":
            if runners is None:
                runners = runner_scripts(project_root)
            if path in runners:
                return Selection.full_result()
            changed_scripts.add(path)
        elif len(parts) >= 2 and parts[0] == ".github":
            continue
        else:
            return Selection.full_result()

    for library in changed_libraries:
        selected.update(graph.dependent_packages(library))
    if changed_scripts:
        selected.update(_script_reference_packages(graph, changed_scripts))
    return Selection(False, graph.event_dependent_packages(selected))


def resolve_packages(result: Selection, graph: DependencyGraph) -> set[str]:
    return set(graph.package_targets if result.full else result.packages)


def resolve_engine_binary(project_root: Path, explicit: Optional[str] = None) -> Path:
    resolver = project_root / "scripts" / "bin_bootstrap.sh"
    if not resolver.is_file():
        raise SelectionError(f"binary resolver is missing: {resolver}")
    env = os.environ.copy()
    if explicit:
        env["BIN"] = explicit
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            'source "$1"\n'
            'if ! resolve_bin_contract "$2" bootstrap; then\n'
            '  printf "%s\\n" "$RESOLVE_BIN_ERROR" >&2\n'
            "  exit 1\n"
            "fi\n"
            'printf "%s\\n" "$RESOLVED_BIN"',
            "resolve-test-selection-bin",
            str(resolver),
            str(project_root),
        ],
        check=False,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "canonical resolver returned no error detail"
        raise SelectionError(f"cannot resolve an executable fkst-framework binary: {detail}")
    candidate = Path(result.stdout.strip())
    if not candidate.is_file() or not os.access(str(candidate), os.X_OK):
        raise SelectionError("canonical resolver returned a non-executable fkst-framework binary")
    return candidate.resolve()


def read_engine_dependencies(project_root: Path, binary: Path) -> dict:
    result = subprocess.run(
        [str(binary), "deps", "--project-root", str(project_root), "--json"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise SelectionError(
            f"fkst-framework deps --json exited {result.returncode}: {result.stderr.strip()}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SelectionError("fkst-framework deps --json emitted malformed JSON") from exc
    DependencyGraph.from_payload(payload, project_root)
    return payload


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--changed-paths", type=Path, required=True)
    parser.add_argument("--deps-json", type=Path)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        source = args.deps_json.read_text(encoding="utf-8") if args.deps_json else sys.stdin.read()
        payload = json.loads(source)
        graph = DependencyGraph.from_payload(payload, args.project_root)
        paths = args.changed_paths.read_text(encoding="utf-8").splitlines()
        result = select_paths(graph, paths, args.project_root)
    except (OSError, UnicodeError, json.JSONDecodeError, SelectionError) as exc:
        print(FULL_SENTINEL)
        print(f"test selection error: {exc}; selecting FULL", file=sys.stderr)
        return 2
    if result.full:
        print(FULL_SENTINEL)
    else:
        for package in sorted(result.packages):
            print(package)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
