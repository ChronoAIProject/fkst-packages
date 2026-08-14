#!/usr/bin/env python3
"""Tests for the unreachable local-function repository guard."""

from __future__ import annotations

import contextlib
import io
import tempfile
import textwrap
import unittest
from pathlib import Path

from script_test_support import load_module


SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
CHECKER_PATH = SCRIPTS / "check_repo_dead_locals.py"


class DeadLocalFunctionGuardTest(unittest.TestCase):
    def checker(self):
        self.assertTrue(CHECKER_PATH.is_file(), "dead-local checker is not implemented")
        return load_module(
            "check_repo_dead_locals",
            CHECKER_PATH,
            error_path="check_repo_dead_locals.py",
        )

    def findings(self, source: str) -> list[tuple[int, str]]:
        return self.checker().dead_local_functions(source)

    def test_flags_an_unreferenced_local_function(self) -> None:
        source = textwrap.dedent(
            """\
            local function used()
              return true
            end

            local function unreachable(value)
              return value
            end

            return used()
            """
        )

        self.assertEqual(self.findings(source), [(5, "unreachable")])

    def test_skips_comments_short_strings_and_levelled_long_literals(self) -> None:
        source = textwrap.dedent(
            '''\
            -- local function line_comment() end
            --[=[ local function block_comment() end ]=]
            local single = 'local function single_quoted() end'
            local double = "local function double_quoted() end"
            local template = [==[
              local function generated_only() end
              ]=] does not close this level
            ]==]

            local function live()
              return single .. double .. template
            end

            return live()
            '''
        )

        self.assertEqual(self.findings(source), [])

    def test_does_not_pair_brackets_inside_quoted_template_chunks(self) -> None:
        source = textwrap.dedent(
            '''\
            local function assignees_json(assignees)
              return "[]"
            end

            local function response(assignees)
              return '[[{"assignees":'
                .. assignees_json(assignees)
                .. "}]]"
            end

            return response({})
            '''
        )

        self.assertEqual(self.findings(source), [])

    def test_masked_name_occurrences_do_not_rescue_a_dead_function(self) -> None:
        source = textwrap.dedent(
            '''\
            local function dead() end
            -- dead in a line comment
            --[=[ dead in a long comment ]=]
            local single = 'dead in a single-quoted string'
            local double = "dead in a double-quoted string"
            local long = [==[ dead in a levelled long string ]==]
            return single .. double .. long
            '''
        )

        self.assertEqual(self.findings(source), [(1, "dead")])

    def test_repository_assignees_json_fixture_is_not_flagged(self) -> None:
        path = ROOT / "packages/github-devloop-intake-default/tests/run_graph_intake_replay_after_dlq_test.lua"

        names = {name for _line, name in self.findings(path.read_text(encoding="utf-8"))}

        self.assertNotIn("assignees_json", names)

    def test_repository_generated_source_fixtures_are_not_flagged(self) -> None:
        fixture_names = {
            "packages/archaudit/tests/fire_raiser_helpers.lua": {
                "mock_env",
                "mock_idle_observe_at",
                "mock_idle_observe",
                "mock_busy_observe_at",
                "mock_production_github",
                "mock_codex_findings",
            },
            "packages/integration-coverage-producer/tests/fire_raiser_helpers.lua": {
                "mock_checker",
                "mock_production_issue_reads",
            },
        }

        for relative_path, expected_absent in fixture_names.items():
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                names = {name for _line, name in self.findings(source)}
                self.assertTrue(expected_absent.isdisjoint(names), names & expected_absent)

    def test_repository_messages_scan_packages_and_libraries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package_path = root / "packages/example/core.lua"
            library_path = root / "libraries/shared/init.lua"
            ignored_path = root / "scripts/fixture.lua"
            for path in (package_path, library_path, ignored_path):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("local function dead() end\n", encoding="utf-8")

            messages = self.checker().repository_messages(root)

        self.assertEqual(
            messages,
            [
                "libraries/shared/init.lua:1 local function 'dead' is unreachable within its file",
                "packages/example/core.lua:1 local function 'dead' is unreachable within its file",
            ],
        )

    def test_repository_runner_reports_the_dead_local_gate(self) -> None:
        check_repo = load_module(
            "check_repo_dead_locals_runner",
            SCRIPTS / "check_repo.py",
            error_path="check_repo.py",
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "packages/example/core.lua"
            path.parent.mkdir(parents=True)
            path.write_text("local function dead() end\n", encoding="utf-8")
            stdout = io.StringIO()
            stderr = io.StringIO()

            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = check_repo.main(["--project-root", str(root)])

        self.assertEqual(result, check_repo.VIOLATIONS_EXIT)
        self.assertIn(
            "G-DEAD-LOCALS: packages/example/core.lua:1 "
            "local function 'dead' is unreachable within its file",
            stderr.getvalue(),
        )

    def test_current_repository_has_zero_findings(self) -> None:
        self.assertEqual(self.checker().repository_messages(ROOT), [])


if __name__ == "__main__":
    unittest.main()
