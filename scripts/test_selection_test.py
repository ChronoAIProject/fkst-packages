#!/usr/bin/env python3
"""Behavior tests for graph-derived affected-test selection."""

from __future__ import annotations

import copy
import os
import unittest
from pathlib import Path

import test_selection as selection


REPO_ROOT = Path(__file__).resolve().parents[1]
GOLDEN_LIBRARY_CARDINALITIES = {
    "contract": 22,
    "consensus": 18,
    "devloop": 16,
}
EXPECTED_RUNNER_SCRIPTS = {
    "scripts/bin_bootstrap.sh",
    "scripts/composed_manifest.sh",
    "scripts/composed_test_graph_roots.sh",
    "scripts/host_entry.sh",
    "scripts/host_run.sh",
    "scripts/local_iteration_result.sh",
    "scripts/run.sh",
    "scripts/run_bin.sh",
    "scripts/run_department.sh",
    "scripts/test_affected.sh",
    "scripts/test_deadline.sh",
    "scripts/test_parallel.sh",
}
INTEGRATION_COVERAGE_SCRIPT_PACKAGES = {
    "archaudit",
    "autochrono",
    "git-branch-detector",
    "github-autochrono",
    "github-devloop",
    "github-devloop-decompose",
    "github-devloop-intake",
    "github-devloop-intake-default",
    "github-devloop-integration",
    "github-devloop-pr",
    "github-devloop-workflow",
    "github-devloop-worktree-gc",
    "integration-coverage-producer",
    "marketing-radar",
}
UNEXEMPT_SCRIPT_TOKEN_PACKAGES = {
    "frontend-devloop",
    "github-devloop-integration",
}


def package_target(unit: dict) -> str:
    return Path(unit["root"]).name


def naive_library_dependents(payload: dict, library: str) -> set[str]:
    """Deliberately simple fixed point, independent of the planner's DFS."""
    libraries = {
        unit["name"]: set(unit["lib_deps"])
        for unit in payload["units"]
        if unit["kind"] == "library"
    }
    dependents: set[str] = set()
    for unit in payload["units"]:
        if unit["kind"] != "package":
            continue
        closure = set(unit["lib_deps"])
        changed = True
        while changed:
            before = set(closure)
            for dependency in before:
                closure.update(libraries[dependency])
            changed = closure != before
        if library in closure:
            dependents.add(package_target(unit))
    return dependents


def naive_event_dependents(payload: dict, package: str) -> set[str]:
    """Independent fixed point over consumer -> event dependency edges."""
    package_targets = {
        unit["name"]: package_target(unit)
        for unit in payload["units"]
        if unit["kind"] == "package"
    }
    closure = {package}
    changed = True
    while changed:
        before = set(closure)
        closure.update(
            edge["from"]
            for edge in payload["event_edges"]
            if edge["to"] in before
        )
        changed = closure != before
    return {package_targets[name] for name in closure}


def naive_event_closure(payload: dict, targets: set[str]) -> set[str]:
    names = {
        unit["name"]
        for unit in payload["units"]
        if unit["kind"] == "package" and package_target(unit) in targets
    }
    result: set[str] = set()
    for name in names:
        result.update(naive_event_dependents(payload, name))
    return result


class TestSelectionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        binary = selection.resolve_engine_binary(REPO_ROOT, os.environ.get("BIN"))
        cls.payload = selection.read_engine_dependencies(REPO_ROOT, binary)
        cls.graph = selection.DependencyGraph.from_payload(cls.payload, REPO_ROOT)

    def plan(self, *paths: str) -> selection.Selection:
        return selection.select_paths(self.graph, paths, REPO_ROOT)

    def assert_selected(self, paths: tuple[str, ...], expected: set[str]) -> None:
        result = self.plan(*paths)
        self.assertFalse(result.full, paths)
        self.assertEqual(set(result.packages), expected, paths)
        self.assertEqual(len(result.packages), len(expected), paths)

    def test_every_package_path_selects_transitive_event_dependents(self) -> None:
        for unit in self.payload["units"]:
            if unit["kind"] != "package":
                continue
            target = package_target(unit)
            with self.subTest(unit=unit["name"], target=target):
                self.assert_selected(
                    (f"packages/{target}/core.lua",),
                    naive_event_dependents(self.payload, unit["name"]),
                )

    def test_github_devloop_selects_all_composed_dependents(self) -> None:
        self.assert_selected(
            ("packages/github-devloop/core.lua",),
            {
                "frontend-devloop",
                "github-devloop",
                "github-devloop-intake-default",
                "github-devloop-integration",
                "github-devloop-ops",
                "github-devloop-workflow",
            },
        )

    def test_every_library_selects_exact_transitive_declared_dependents(self) -> None:
        libraries = sorted(
            unit["name"] for unit in self.payload["units"] if unit["kind"] == "library"
        )
        self.assertEqual(len(libraries), 8)
        for library in libraries:
            with self.subTest(library=library):
                expected = naive_library_dependents(self.payload, library)
                self.assert_selected(
                    (f"libraries/{library}/core.lua",),
                    naive_event_closure(self.payload, expected),
                )

    def test_library_cardinality_golden_anchors(self) -> None:
        # These values intentionally move when the declared dependency graph moves.
        for library, cardinality in GOLDEN_LIBRARY_CARDINALITIES.items():
            with self.subTest(library=library):
                result = self.plan(f"libraries/{library}/core.lua")
                self.assertFalse(result.full)
                self.assertEqual(len(result.packages), cardinality)

    def test_repo_checker_selects_only_remaining_unexempt_wildcard_units(self) -> None:
        self.assert_selected(
            ("scripts/check_repo_test_selection.py",),
            UNEXEMPT_SCRIPT_TOKEN_PACKAGES,
        )

    def test_literal_script_reference_selects_owning_package(self) -> None:
        self.assert_selected(
            ("scripts/check_repo_restart_lifecycle.py",),
            UNEXEMPT_SCRIPT_TOKEN_PACKAGES,
        )

    def test_library_lua_script_references_select_all_package_consumers(self) -> None:
        path = "scripts/check_repo_integration_coverage.py"
        direct = selection._script_reference_packages(self.graph, {path})
        self.assertEqual(
            direct,
            INTEGRATION_COVERAGE_SCRIPT_PACKAGES | UNEXEMPT_SCRIPT_TOKEN_PACKAGES,
        )
        self.assert_selected(
            (path,),
            naive_event_closure(
                self.payload,
                INTEGRATION_COVERAGE_SCRIPT_PACKAGES | UNEXEMPT_SCRIPT_TOKEN_PACKAGES,
            ),
        )

    def test_literal_script_matching_includes_fail_closed_packages(self) -> None:
        expected_by_path = {
            "scripts/board.py": UNEXEMPT_SCRIPT_TOKEN_PACKAGES,
            "scripts/check_repo.py": UNEXEMPT_SCRIPT_TOKEN_PACKAGES
            | {"integration-coverage-producer"},
        }
        for path, expected in expected_by_path.items():
            with self.subTest(path=path):
                self.assert_selected((path,), expected)

    def test_every_derived_runner_script_selects_full_set(self) -> None:
        runners = selection.runner_scripts(REPO_ROOT)
        self.assertEqual(set(runners), EXPECTED_RUNNER_SCRIPTS)
        for runner in sorted(runners):
            with self.subTest(runner=runner):
                result = self.plan(runner)
                self.assertTrue(result.full)
                self.assertEqual(
                    selection.resolve_packages(result, self.graph),
                    set(self.graph.package_targets),
                )

    def test_github_path_selects_no_packages(self) -> None:
        self.assert_selected((".github/workflows/ci.yml",), set())

    def test_unknown_path_falls_back_to_full(self) -> None:
        result = self.plan("docs/README.md")
        self.assertTrue(result.full)

    def test_empty_path_set_falls_back_to_full(self) -> None:
        result = self.plan()
        self.assertTrue(result.full)

    def test_malformed_or_failed_dependency_data_fails_closed(self) -> None:
        malformed_payloads = (
            None,
            {},
            {"ok": False, "units": []},
            {"ok": True, "units": "not-a-list", "failures": []},
        )
        for payload in malformed_payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(selection.SelectionError):
                    selection.DependencyGraph.from_payload(payload, REPO_ROOT)

    def test_dependency_status_gates_fail_independently(self) -> None:
        failed_status = copy.deepcopy(self.payload)
        failed_status["ok"] = False
        failed_payload = copy.deepcopy(self.payload)
        failed_payload["failures"] = [{"kind": "fixture-failure"}]
        for field, payload in (("ok", failed_status), ("failures", failed_payload)):
            with self.subTest(field=field):
                with self.assertRaises(selection.SelectionError):
                    selection.DependencyGraph.from_payload(payload, REPO_ROOT)

    def test_dependency_schema_requires_edge_collections_and_declared_edge_parity(self) -> None:
        malformed_payloads = []
        for key in ("warnings", "lib_edges", "event_edges"):
            payload = copy.deepcopy(self.payload)
            del payload[key]
            malformed_payloads.append(payload)
        mismatched_edges = copy.deepcopy(self.payload)
        mismatched_edges["lib_edges"] = mismatched_edges["lib_edges"][:-1]
        malformed_payloads.append(mismatched_edges)

        for payload in malformed_payloads:
            with self.subTest(keys=sorted(payload)):
                with self.assertRaises(selection.SelectionError):
                    selection.DependencyGraph.from_payload(payload, REPO_ROOT)


if __name__ == "__main__":
    unittest.main()
