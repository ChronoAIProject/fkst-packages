#!/usr/bin/env python3
"""Tests for peer package and workspace library name collisions."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
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


def write(path: Path, source: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")


class CrossPackageWorkspaceLibraryTest(unittest.TestCase):
    def fixture(self, root: Path, declared: bool) -> None:
        write(
            root / "libraries" / "consensus" / "fkst.toml",
            'kind = "library"\nname = "consensus"\n\n[lib_deps]\nlibraries = []\n',
        )
        write(
            root / "packages" / "consumer" / "fkst.toml",
            'kind = "package"\nname = "consumer"\n\n[lib_deps]\nlibraries = '
            + ('["consensus"]\n' if declared else "[]\n"),
        )
        write(root / "packages" / "consumer" / "main.lua", 'return require("consensus")\n')
        write(root / "packages" / "consensus" / "fkst.toml", 'kind = "package"\nname = "consensus"\n')

    def messages(self, root: Path) -> list[str]:
        return check_repo.check_repo_cross_package.messages(
            root,
            check_repo.package_dirs,
            check_repo.read_text,
            check_repo.rel,
            check_repo.strip_lua_comments_and_strings,
            check_repo.is_unmasked_range,
        )

    def test_allows_declared_same_name_workspace_library(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root, declared=True)
            messages = self.messages(root)

        self.assertEqual(messages, [])

    def test_rejects_undeclared_same_name_workspace_library(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root, declared=False)
            messages = self.messages(root)

        self.assertEqual(len(messages), 1)
        self.assertIn("peer cross-package require of 'consensus'", messages[0])


if __name__ == "__main__":
    unittest.main()
