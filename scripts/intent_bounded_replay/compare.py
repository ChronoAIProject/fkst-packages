#!/usr/bin/env python3
"""Pure artifact comparison helpers for the R9 semantic oracle."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from .normalize import (
    artifact_body_v1,
    canonical_artifact_hash_v1,
    canonical_json,
)


def artifacts_equal(a: Any, b: Any) -> bool:
    """Return whether two artifacts have the same canonical v1 hash."""
    return canonical_artifact_hash_v1(a) == canonical_artifact_hash_v1(b)


def _pointer_child(path: str, component: str) -> str:
    escaped = component.replace("~", "~0").replace("/", "~1")
    return f"{path}/{escaped}"


def _first_divergence(old: Any, new: Any, path: str = "") -> str | None:
    if canonical_json(old) == canonical_json(new):
        return None

    if isinstance(old, Mapping) and isinstance(new, Mapping):
        keys = sorted(set(old) | set(new), key=lambda key: key.encode("utf-8"))
        for key in keys:
            child_path = _pointer_child(path, key)
            if key not in old or key not in new:
                return child_path
            divergence = _first_divergence(old[key], new[key], child_path)
            if divergence is not None:
                return divergence
        return path

    if isinstance(old, (list, tuple)) and isinstance(new, (list, tuple)):
        for index, (old_child, new_child) in enumerate(zip(old, new)):
            child_path = _pointer_child(path, str(index))
            divergence = _first_divergence(old_child, new_child, child_path)
            if divergence is not None:
                return divergence
        if len(old) != len(new):
            return _pointer_child(path, str(min(len(old), len(new))))
        return path

    return path


def compare_report(old: Any, new: Any) -> dict[str, Any]:
    """Return canonical hashes and the first differing JSON Pointer, when any."""
    old_hash = canonical_artifact_hash_v1(old)
    new_hash = canonical_artifact_hash_v1(new)
    equal = old_hash == new_hash
    report: dict[str, Any] = {
        "equal": equal,
        "old_hash": old_hash,
        "new_hash": new_hash,
    }
    if not equal:
        old_body = artifact_body_v1(old)
        new_body = artifact_body_v1(new)
        report["first_divergence"] = _first_divergence(old_body, new_body)
    return report
