#!/usr/bin/env python3
"""Mutation tests for the affected-test selection soundness checker."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import check_repo_test_selection as checker
import test_selection as selection


def fixture_payload(root: Path) -> dict:
    return {
        "ok": True,
        "workspace_root": str(root),
        "failures": [],
        "warnings": [],
        "units": [
            {
                "name": "alpha-engine-name",
                "kind": "package",
                "root": str(root / "packages" / "alpha"),
                "lib_deps": ["base"],
                "event_deps": [],
            },
            {
                "name": "base",
                "kind": "library",
                "root": str(root / "libraries" / "base"),
                "lib_deps": [],
                "event_deps": [],
            },
        ],
        "lib_edges": [{"from": "alpha-engine-name", "to": "base"}],
        "event_edges": [],
    }


class CheckRepoTestSelectionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "packages" / "alpha").mkdir(parents=True)
        (self.root / "libraries" / "base").mkdir(parents=True)
        (self.root / "scripts").mkdir()
        (self.root / ".github" / "workflows").mkdir(parents=True)
        (self.root / "packages" / "alpha" / "core.lua").write_text("return {}\n", encoding="utf-8")
        (self.root / "libraries" / "base" / "core.lua").write_text("return {}\n", encoding="utf-8")
        (self.root / "scripts" / "run.sh").write_text(
            '. "$ROOT/scripts/test_parallel.sh"\n\n'
            'cmd_test() { :; }\n'
            'cmd_test_composed() { :; }\n',
            encoding="utf-8",
        )
        (self.root / "scripts" / "test_parallel.sh").write_text("run_one_package() { :; }\n", encoding="utf-8")
        (self.root / "scripts" / "helper.py").write_text("# fixture\n", encoding="utf-8")
        self.graph = selection.DependencyGraph.from_payload(fixture_payload(self.root), self.root)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_totality_identity_rejects_an_underselecting_mutant(self) -> None:
        tracked = (
            "packages/alpha/core.lua",
            "libraries/base/core.lua",
            "scripts/run.sh",
            ".github/workflows/ci.yml",
            "README.md",
        )
        observations = []

        def observe(graph, paths, root):
            result = selection.select_paths(graph, paths, root)
            observations.append((tuple(paths), result))
            return result

        self.assertEqual(
            checker.totality_identity_messages(
                self.graph, tracked + ("scripts/helper.py",), self.root, select_fn=observe
            ),
            [],
        )
        self.assertEqual(
            {Path(paths[0]).parts[0] for paths, _result in observations},
            {"packages", "libraries", "scripts"},
        )
        self.assertTrue(all(not result.full for _paths, result in observations))

        def underselect(_graph, _paths, _root):
            return selection.Selection(False, frozenset())

        messages = checker.totality_identity_messages(
            self.graph,
            tracked,
            self.root,
            select_fn=underselect,
        )
        self.assertTrue(messages)
        self.assertTrue(all("TOTALITY IDENTITY" in message for message in messages))

        def overselect(_graph, _paths, _root):
            return selection.Selection.full_result()

        messages = checker.totality_identity_messages(
            self.graph,
            tracked,
            self.root,
            select_fn=overselect,
        )
        self.assertTrue(messages)
        self.assertTrue(all("selected FULL" in message for message in messages))

    def test_unresolved_script_tokens_select_the_owning_unit(self) -> None:
        (self.root / "scripts" / "radar_helper.sh").write_text(
            "#!/bin/sh\n",
            encoding="utf-8",
        )
        cases = {
            "table parts": (
                'local parts = {"scripts", "radar_helper.sh"}\n'
                'local path = table.concat(parts, "/")\n'
            ),
            "one-hop alias": (
                'local prefix = "scripts/"\n'
                "local copied_prefix = prefix\n"
                'local path = copied_prefix .. "radar_helper.sh"\n'
            ),
        }
        for name, source in cases.items():
            with self.subTest(name=name):
                (self.root / "packages" / "alpha" / "core.lua").write_text(
                    source,
                    encoding="utf-8",
                )
                result = selection.select_paths(
                    self.graph,
                    ("scripts/radar_helper.sh",),
                    self.root,
                )
                self.assertFalse(result.full)
                self.assertEqual(set(result.packages), {"alpha"})

    def test_exempted_script_token_does_not_create_a_wildcard_edge(self) -> None:
        (self.root / "migration").mkdir()
        (self.root / "packages" / "alpha" / "core.lua").write_text(
            'local prose = "scripts"\n',
            encoding="utf-8",
        )
        (self.root / "migration" / "test-selection-script-token-exempt.allowlist").write_text(
            "packages/alpha/core.lua:1 # why=fixture prose is not a repository script path\n",
            encoding="utf-8",
        )

        result = selection.select_paths(
            self.graph,
            ("scripts/helper.py",),
            self.root,
        )

        self.assertFalse(result.full)
        self.assertEqual(set(result.packages), set())

    def test_non_exempted_script_token_still_creates_a_wildcard_edge(self) -> None:
        (self.root / "packages" / "alpha" / "core.lua").write_text(
            'local prefix = "scripts"\n',
            encoding="utf-8",
        )

        result = selection.select_paths(
            self.graph,
            ("scripts/helper.py",),
            self.root,
        )

        self.assertFalse(result.full)
        self.assertEqual(set(result.packages), {"alpha"})

    def test_complete_script_path_keeps_an_exact_edge(self) -> None:
        for name in ("radar_helper.sh", "unrelated_helper.sh"):
            (self.root / "scripts" / name).write_text("#!/bin/sh\n", encoding="utf-8")
        (self.root / "packages" / "alpha" / "core.lua").write_text(
            'return "scripts/radar_helper.sh"\n',
            encoding="utf-8",
        )

        referenced = selection.select_paths(
            self.graph,
            ("scripts/radar_helper.sh",),
            self.root,
        )
        unrelated = selection.select_paths(
            self.graph,
            ("scripts/unrelated_helper.sh",),
            self.root,
        )

        self.assertEqual(set(referenced.packages), {"alpha"})
        self.assertEqual(set(unrelated.packages), set())

    def test_total_cover_rejects_unclaimed_and_accepts_explicit_allowlist(self) -> None:
        claimed = (
            "packages/alpha/core.lua",
            "libraries/base/core.lua",
            "scripts/run.sh",
            ".github/workflows/ci.yml",
            "migration/test-selection-script-token-exempt.allowlist",
        )
        self.assertEqual(checker.total_cover_messages(self.graph, claimed, set()), [])

        uncovered = claimed + ("README.md",)
        messages = checker.total_cover_messages(self.graph, uncovered, set())
        self.assertEqual(len(messages), 1)
        self.assertIn("TOTAL COVER", messages[0])
        self.assertIn("README.md", messages[0])
        self.assertEqual(
            checker.total_cover_messages(self.graph, uncovered, {"README.md"}),
            [],
        )

    def test_total_cover_rejects_unknown_package_or_library_roots(self) -> None:
        paths = ("packages/missing/core.lua", "libraries/missing/core.lua")
        messages = checker.total_cover_messages(self.graph, paths, set())
        self.assertEqual(len(messages), 2)
        self.assertTrue(all("TOTAL COVER" in message for message in messages))

    def test_runner_set_is_derived_from_source_and_test_execution_edges(self) -> None:
        run_sh = self.root / "scripts" / "run.sh"
        run_sh.write_text(
            '. "$ROOT/scripts/test_parallel.sh"\n'
            'load_roots() { bash "$ROOT/scripts/composed_test_graph_roots.sh"; }\n'
            'cmd_test() { load_roots; }\n'
            'cmd_test_composed() { load_roots; }\n'
            'cmd_doctor() { bash "$ROOT/scripts/doctor.sh"; }\n',
            encoding="utf-8",
        )
        (self.root / "scripts" / "composed_test_graph_roots.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        (self.root / "scripts" / "doctor.sh").write_text("#!/bin/sh\n", encoding="utf-8")

        runners = selection.runner_scripts(self.root)

        self.assertIn("scripts/run.sh", runners)
        self.assertIn("scripts/test_parallel.sh", runners)
        self.assertIn("scripts/composed_test_graph_roots.sh", runners)
        self.assertNotIn("scripts/doctor.sh", runners)

    def test_allowlist_growth_is_rejected_after_baseline_exists(self) -> None:
        messages = checker.allowlist_ratchet_messages(
            current={"README.md", "SECURITY.md"},
            allowlist={"README.md", "SECURITY.md"},
            base_allowlist={"README.md"},
        )
        self.assertEqual(len(messages), 1)
        self.assertIn("shrink-only", messages[0])
        self.assertIn("SECURITY.md", messages[0])

    def test_script_token_exemption_inventory_cannot_grow_silently(self) -> None:
        existing = selection.ScriptTokenSite("packages/alpha/core.lua", 1)
        added = selection.ScriptTokenSite("libraries/base/core.lua", 2)

        messages = checker.script_token_exemption_ratchet_messages(
            current={existing, added},
            exemptions={existing, added},
            base_exemptions={existing},
        )

        self.assertEqual(len(messages), 1)
        self.assertIn("shrink-only", messages[0])
        self.assertIn("libraries/base/core.lua:2", messages[0])

    def test_script_token_exemption_requires_a_why(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid"):
            selection.parse_script_token_exemption_lines(
                ["packages/alpha/core.lua:1"]
            )

    def test_repository_messages_reports_every_soundness_category(self) -> None:
        tracked = (
            "packages/alpha/core.lua",
            "libraries/base/core.lua",
            "scripts/run.sh",
            "scripts/test_parallel.sh",
            "scripts/helper.py",
            "UNCLAIMED.md",
        )

        def underselect(_graph, _paths, _root):
            return selection.Selection(False, frozenset())

        messages = checker.repository_messages(
            self.root,
            self.graph,
            tracked,
            {"stale.md"},
            set(),
            base_status="unresolved",
            select_fn=underselect,
        )
        categories = {
            "TOTALITY IDENTITY": False,
            "TOTAL COVER": False,
            f"{checker.ALLOWLIST} is shrink-only and grew": False,
            "cannot resolve protected-base": False,
        }
        for message in messages:
            for category in categories:
                categories[category] = categories[category] or category in message
        self.assertEqual(categories, {category: True for category in categories}, messages)


if __name__ == "__main__":
    unittest.main()
