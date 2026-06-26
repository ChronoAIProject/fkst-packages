#!/usr/bin/env python3
"""Unit tests for G10 stateless generator exemptions."""

from __future__ import annotations

import importlib.util
import sys
import textwrap
import unittest
from pathlib import Path


def load_check_repo():
    path = Path(__file__).with_name("check_repo.py")
    spec = importlib.util.spec_from_file_location("check_repo", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load check_repo.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


check_repo = load_check_repo()


class StatelessGeneratorRatchetTest(unittest.TestCase):
    path = "packages/site-gen/departments/generate/main.lua"

    def violations(self, source: str) -> list[str]:
        return check_repo.saga_handler_ratchet_violations({self.path: source}, set())

    def test_stateless_generator_free_form_pipeline_is_exempt(self) -> None:
        source = textwrap.dedent(
            """\
            local M = {}
            M.spec = {
              kind = "stateless_generator",
              consumes = {},
              produces = {},
            }

            function pipeline(_event)
              exec_sync("mkdir -p site/.generated")
              file.write("site/.generated/index.html", "<h1>ok</h1>")
              exec_sync("mv site/.generated site/dist")
            end

            return M
            """
        )

        self.assertTrue(check_repo.is_stateless_generator_source(source))
        self.assertEqual(self.violations(source), [])

    def test_empty_edges_without_kind_are_not_exempt(self) -> None:
        source = textwrap.dedent(
            """\
            M.spec = { consumes = {}, produces = {} }
            function pipeline(_event)
              exec_sync("mkdir -p site/.generated")
            end
            """
        )

        self.assertFalse(check_repo.is_stateless_generator_source(source))
        self.assertIn("free-form department not on saga-handler allowlist", self.violations(source)[0])

    def test_stateless_generator_with_lifecycle_or_state_effects_is_not_exempt(self) -> None:
        source = textwrap.dedent(
            """\
            M.spec = { kind = "stateless_generator", consumes = {}, produces = {} }
            function pipeline(_event)
              raise("done", { ok = true })
              write_state_marker()
              currentCAS()
            end
            """
        )

        self.assertFalse(check_repo.is_stateless_generator_source(source))
        self.assertIn("free-form department not on saga-handler allowlist", self.violations(source)[0])

    def test_free_form_lifecycle_department_is_still_flagged(self) -> None:
        source = textwrap.dedent(
            """\
            M.spec = { kind = "stateless_generator", consumes = { "build" }, produces = {} }
            function pipeline(event)
              return event
            end
            """
        )

        self.assertFalse(check_repo.is_stateless_generator_source(source))
        self.assertIn("free-form department not on saga-handler allowlist", self.violations(source)[0])


if __name__ == "__main__":
    unittest.main()
