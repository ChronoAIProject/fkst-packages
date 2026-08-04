#!/usr/bin/env python3
"""Tests for the G-DEVLOOP-INSTALLER shrink-only ratchet (install(M) composed-core coupling)."""
from __future__ import annotations

import importlib.util
import json
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
ratchet = load_module("check_repo_devloop_installer", scripts_dir / "check_repo_devloop_installer.py")


def scaffold(root: Path, *, mod_files: dict[str, str], core: str, readers: dict[str, str]) -> None:
    (root / "libraries" / "devloop").mkdir(parents=True, exist_ok=True)
    for rel, body in mod_files.items():
        p = root / "libraries" / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8")
    pkg = root / "packages" / "p"
    (pkg / "departments" / "d").mkdir(parents=True, exist_ok=True)
    (pkg / "core.lua").write_text(core, encoding="utf-8")
    for fname, body in readers.items():
        (pkg / "departments" / "d" / fname).write_text(body, encoding="utf-8")


def scaffold_package(root: Path, name: str, *, core: str, reader: str) -> None:
    pkg = root / "packages" / name
    (pkg / "departments" / "d").mkdir(parents=True, exist_ok=True)
    (pkg / "core.lua").write_text(core, encoding="utf-8")
    (pkg / "departments" / "d" / "main.lua").write_text(reader, encoding="utf-8")


class InstallerRatchetTest(unittest.TestCase):
    def _count(self, *, mod_files, core, readers) -> int:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            scaffold(root, mod_files=mod_files, core=core, readers=readers)
            return ratchet.current_count(root)

    def test_installed_symbol_read_counts(self):
        n = self._count(
            mod_files={"devloop/logging.lua": "function S.install(M)\nfunction M.log_raise(a) end\nend\nreturn S\n"},
            core='require("devloop.logging").install(M)\n',
            readers={"main.lua": "core.log_raise(x)\n"},
        )
        self.assertEqual(n, 1)

    def test_assignment_style_installer_symbol_counts(self):
        # methods installed via `M.name = ...` (not `function M.name`) must also count
        n = self._count(
            mod_files={"devloop/logging.lua": "function S.install(M)\nM.payload_field = other.payload_field\nend\nreturn S\n"},
            core='require("devloop.logging").install(M)\n',
            readers={"main.lua": "core.payload_field(x)\n"},
        )
        self.assertEqual(n, 1)

    def test_non_installed_symbol_does_not_count(self):
        n = self._count(
            mod_files={"devloop/logging.lua": "function S.install(M)\nfunction M.log_raise(a) end\nend\nreturn S\n"},
            core='require("devloop.logging").install(M)\n',
            readers={"main.lua": "core.some_other_fn(x)\n"},
        )
        self.assertEqual(n, 0)

    def test_module_not_installed_does_not_count(self):
        # logging defines log_raise but the core never install()s it -> not an installer symbol
        n = self._count(
            mod_files={"devloop/logging.lua": "function S.install(M)\nfunction M.log_raise(a) end\nend\nreturn S\n"},
            core='local x = 1\n',
            readers={"main.lua": "core.log_raise(x)\n"},
        )
        self.assertEqual(n, 0)

    def test_reader_calls_are_scoped_to_each_packages_installed_symbols(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            module = root / "libraries" / "devloop" / "logging.lua"
            module.parent.mkdir(parents=True)
            module.write_text(
                "function S.install(M)\nfunction M.log_line(a) end\nend\nreturn S\n",
                encoding="utf-8",
            )
            scaffold_package(
                root,
                "package-a",
                core='require("devloop.logging").install(M)\nfunction M.local_member() end\n',
                reader="core.log_line(a)\n",
            )
            scaffold_package(
                root,
                "package-b",
                core="function M.log_line(a) end\nfunction M.local_member() end\n",
                reader="core.log_line(b)\n",
            )

            self.assertEqual(ratchet.current_counts(root), {"package-a": 1})
            self.assertEqual(
                ratchet.current_inventory(root),
                {
                    "package-a": [
                        {
                            "path": "packages/package-a/departments/d/main.lua",
                            "line": 1,
                            "column": 1,
                            "symbol": "log_line",
                        }
                    ]
                },
            )

    def test_aggregator_submodule_symbols_count(self):
        # commands aggregator loops submodules; a submodule's installed method must count
        n = self._count(
            mod_files={
                "devloop/commands.lua": 'local modules = {"devloop.commands.prs"}\nfunction S.install(M)\nfor _,m in ipairs(modules) do require(m).install(M) end\nend\nreturn S\n',
                "devloop/commands/prs.lua": "function S.install(M)\nfunction M.gh_pr_view_observe(a) end\nend\nreturn S\n",
            },
            core='require("devloop.commands").install(M)\n',
            readers={"main.lua": "core.gh_pr_view_observe(x)\n"},
        )
        self.assertEqual(n, 1)

    def test_loop_binding_install_names_count(self):
        # a self-contained module that loop-binds its C fns onto M installs those names
        n = self._count(
            mod_files={"devloop/state.lua": 'function C.current_state(a) end\nfunction S.install(M)\n  for _, k in ipairs({"current_state"}) do M[k] = C[k] end\nend\nreturn C\n'},
            core='require("devloop.state").install(M)\n',
            readers={"main.lua": "core.current_state(x)\n"},
        )
        self.assertEqual(n, 1)

    def test_core_and_test_readers_excluded(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            scaffold(
                root,
                mod_files={"devloop/logging.lua": "function S.install(M)\nfunction M.log_raise(a) end\nend\nreturn S\n"},
                core='require("devloop.logging").install(M)\ncore.log_raise(inside_core)\n',
                readers={},
            )
            (root / "packages" / "p" / "tests").mkdir(parents=True, exist_ok=True)
            (root / "packages" / "p" / "tests" / "t_test.lua").write_text("core.log_raise(x)\n", encoding="utf-8")
            self.assertEqual(ratchet.current_count(root), 0)

    def test_package_growth_message_includes_current_site_diagnostics(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            scaffold(
                root,
                mod_files={"devloop/logging.lua": "function S.install(M)\nfunction M.log_raise(a) end\nend\nreturn S\n"},
                core='require("devloop.logging").install(M)\n',
                readers={"main.lua": "core.log_raise(x)\n"},
            )
            inventory = root / ratchet.INVENTORY
            inventory.parent.mkdir(parents=True)
            inventory.write_text(json.dumps({"packages": {"p": []}}), encoding="utf-8")

            messages = list(ratchet.repository_messages(root))

            self.assertEqual(len(messages), 1)
            self.assertIn("package p has 1", messages[0])
            self.assertIn("packages/p/departments/d/main.lua:1:1 core.log_raise", messages[0])

    def test_package_growth_cannot_be_offset_by_another_packages_shrink(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            module = root / "libraries" / "devloop" / "logging.lua"
            module.parent.mkdir(parents=True)
            module.write_text(
                "function S.install(M)\nfunction M.log_line(a) end\nend\nreturn S\n",
                encoding="utf-8",
            )
            install = 'require("devloop.logging").install(M)\n'
            scaffold_package(root, "package-a", core=install, reader="")
            scaffold_package(root, "package-b", core=install, reader="core.log_line(b)\n")
            inventory = root / ratchet.INVENTORY
            inventory.parent.mkdir(parents=True)
            inventory.write_text(
                json.dumps(
                    {
                        "packages": {
                            "package-a": [
                                {
                                    "path": "packages/package-a/departments/d/main.lua",
                                    "line": 1,
                                    "column": 1,
                                    "symbol": "log_line",
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )

            messages = list(ratchet.repository_messages(root))

            self.assertEqual(len(messages), 1)
            self.assertIn("package package-b has 1", messages[0])
            self.assertIn("baseline 0", messages[0])

    def test_exact_per_package_site_inventory_is_accepted_as_baseline(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            scaffold(
                root,
                mod_files={"devloop/logging.lua": "function S.install(M)\nfunction M.log_raise(a) end\nend\nreturn S\n"},
                core='require("devloop.logging").install(M)\n',
                readers={"main.lua": "core.log_raise(x)\n"},
            )
            inventory = root / ratchet.INVENTORY
            inventory.parent.mkdir(parents=True)
            inventory.write_text(
                json.dumps({"packages": ratchet.current_inventory(root)}),
                encoding="utf-8",
            )

            self.assertEqual(list(ratchet.repository_messages(root)), [])


if __name__ == "__main__":
    unittest.main()
