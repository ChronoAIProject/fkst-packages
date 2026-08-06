"""Shared helpers for tests of repository scripts."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def load_module(name: str, path: Path, *, error_path: str | Path | None = None):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        displayed_path = path if error_path is None else error_path
        raise RuntimeError(f"could not load {displayed_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module
