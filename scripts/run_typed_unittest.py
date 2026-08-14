#!/usr/bin/env python3
"""Run one repository unittest module with producer-owned exit typing."""

from __future__ import annotations

import importlib.util
import sys
import traceback
import unittest
from pathlib import Path


SEMANTIC_FAILURE_EXIT = 10
CONFIGURATION_FAILURE_EXIT = 11


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location("fkst_typed_unittest_target", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load unittest module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        print("typed unittest runner requires exactly one module path", file=sys.stderr)
        return CONFIGURATION_FAILURE_EXIT

    path = Path(args[0]).resolve()
    try:
        module = load_module(path)
    except BaseException:
        # Import/bootstrap failures did not produce a unittest result, so their
        # domain attribution remains unknown to the aggregate caller.
        traceback.print_exc()
        return 1

    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    if suite.countTestCases() == 0:
        print(f"typed unittest runner discovered no tests in {path}", file=sys.stderr)
        return CONFIGURATION_FAILURE_EXIT

    result = unittest.TextTestRunner().run(suite)
    if result.errors:
        return 1
    return 0 if result.wasSuccessful() else SEMANTIC_FAILURE_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
