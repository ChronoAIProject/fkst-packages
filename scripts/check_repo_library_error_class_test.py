#!/usr/bin/env python3
"""Tests for the production-library error-class shrink-only ratchet."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


scripts_dir = Path(__file__).resolve().parent
check_repo = load_module("check_repo", scripts_dir / "check_repo.py")
check_repo_runner = load_module("check_repo_runner", scripts_dir / "check_repo_runner.py")


class LibraryErrorClassRatchetTest(unittest.TestCase):
    def violations_for(self, source_text: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "libraries" / "example" / "core.lua"
            source.parent.mkdir(parents=True)
            source.write_text(source_text, encoding="utf-8")
            migration = root / "migration"
            migration.mkdir()
            (migration / "library-error-class.allowlist").write_text("", encoding="utf-8")

            violations: list[str] = []
            check_repo_runner.check_library_error_class(
                check_repo,
                root,
                violations,
                enforce_base=False,
            )
            return violations

    def test_unclassified_library_error_fails(self) -> None:
        violations = self.violations_for('error("missing class")\n')

        self.assertEqual(len(violations), 1)
        self.assertEqual(
            violations[0],
            "G-LIB-ERROR-CLASS: libraries/example/core.lua:1 production library error(...) string "
            "lacks a greppable class prefix and is not in migration/library-error-class.allowlist",
        )

    def test_classified_library_error_passes(self) -> None:
        violations = self.violations_for('error("example: missing-capability: adapter is required")\n')

        self.assertEqual(violations, [])

    def test_library_inventory_growth_fails(self) -> None:
        site = "libraries/example/core.lua:1"

        messages = check_repo.check_repo_error_class.library_ratchet_messages(
            {site},
            {site},
            base_allowlist=set(),
        )

        self.assertEqual(
            messages,
            [
                f"{site} grows migration/library-error-class.allowlist relative to dev; "
                "classify the error string instead"
            ],
        )


if __name__ == "__main__":
    unittest.main()
