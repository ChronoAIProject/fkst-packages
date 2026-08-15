#!/usr/bin/env python3
"""Behavior tests for the devloop god-table decoupling ratchet.

The property under test is the one the counter got wrong: a `function M.<symbol>(...)` header
is a DEFINITION and must not be charged as a reader call. The checker excludes the assembler
file `*/core.lua`, but the modules it assembles live in `*/core/*.lua` and define the same
names there, so before this every such definition inflated the count by one and could never be
removed by decoupling work -- a floor the ratchet could not reach past.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path


CHECKER = Path(__file__).with_name("check_repo_devloop_decouple.py")


def write(root: Path, relpath: str, source: str) -> None:
    path = root / relpath
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(source), encoding="utf-8")


def current_count(files: dict[str, str]) -> int:
    """Run the checker over a synthetic repo and return its reported `current:` count."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write(root, "migration/devloop-decouple.inventory", '{"reader_calls_through_m": 999}\n')
        for relpath, source in files.items():
            write(root, relpath, source)
        proc = subprocess.run(
            [sys.executable, "-B", str(CHECKER), str(root)],
            capture_output=True,
            text=True,
            check=False,
        )
        match = re.search(r"current:\s*(\d+)", proc.stdout)
        assert match, f"no `current:` in output: {proc.stdout!r} {proc.stderr!r}"
        return int(match.group(1))


ASSEMBLER = """
    local M = {}
    M.widget = require("devloop.widget").widget
    return M
    """


def test_reader_call_is_counted() -> None:
    count = current_count(
        {
            "packages/p/core.lua": ASSEMBLER,
            "packages/p/departments/d/main.lua": """
                local core = require("core")
                local function pipeline(event)
                  return core.widget(event)
                end
                """,
        }
    )
    assert count == 1, f"a genuine reader call must be counted, got {count}"


def test_definition_header_is_not_counted() -> None:
    count = current_count(
        {
            "packages/p/core.lua": ASSEMBLER,
            "packages/p/core/widget_impl.lua": """
                local M = {}
                function M.widget(event)
                  return event
                end
                return M
                """,
        }
    )
    assert count == 0, f"a definition header is supply, not consumption, got {count}"


def test_one_line_definition_still_counts_its_reader_call() -> None:
    """Only the header is stripped, not the line -- otherwise the fix would hide real calls."""
    count = current_count(
        {
            "packages/p/core.lua": ASSEMBLER,
            "packages/p/core/widget_impl.lua": """
                local M = {}
                function M.widget(e) return core.widget(e) end
                return M
                """,
        }
    )
    assert count == 1, f"the embedded reader call must survive header stripping, got {count}"


def test_tests_and_assembler_stay_excluded() -> None:
    count = current_count(
        {
            "packages/p/core.lua": ASSEMBLER + "\nlocal _ = M.widget(1)\n",
            "packages/p/tests/widget_test.lua": "local core = require('core'); core.widget(1)\n",
        }
    )
    assert count == 0, f"assembler and tests are excluded, got {count}"


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"ok {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
