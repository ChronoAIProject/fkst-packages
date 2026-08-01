"""Shrink-only ratchet: a department that can throw must be able to report it.

A department declaring neither a `retry` policy nor `devloop_logging.wrap_pipeline_failure`
cannot produce a failure fact or a dead letter. When it throws, the engine ACKs the delivery
and returns -- see fkst-substrate crates/fkst-framework/src/supervise/consumer.rs:702-710,
which journals `reason=dropped_no_retry_policy` and returns BEFORE the `store.retry(...)`
path at :713. The error is gone and the safety net sees a successful pass.

Two roles are STRUCTURALLY exempt, derived from the department's role rather than a name
list that rots:

  * `dead_letter` departments ARE the DLQ consumer; retrying them into themselves is wrong.
  * `test_*` departments are test-mode probes and never run under a production supervise.

Everything else is inventoried in a shrink-only allowlist. See issue #2996.
"""

from __future__ import annotations

import re
from pathlib import Path

import ratchet_base

ALLOWLIST = "migration/dept-failure-surface.allowlist"

# `retry = {` at spec indentation, and the structured failure wrapper.
RETRY_RE = re.compile(r"^\s*retry\s*=\s*\{", re.MULTILINE)
WRAP_RE = re.compile(r"\bwrap_pipeline_failure\b")

DEPT_PATH_RE = re.compile(r"packages/(?P<pkg>[^/]+)/departments/(?P<dept>[^/]+)/main\.lua$")


def dept_id(rel_path: str) -> str | None:
    match = DEPT_PATH_RE.search(rel_path.replace("\\", "/"))
    if match is None:
        return None
    return f"{match.group('pkg')}.{match.group('dept')}"


def is_structurally_exempt(dept: str) -> bool:
    """Exempt by ROLE, not by a hardcoded inventory of names."""
    leaf = dept.rsplit(".", 1)[-1]
    return leaf == "dead_letter" or leaf.startswith("test_")


def has_failure_surface(source: str) -> bool:
    return RETRY_RE.search(source) is not None or WRAP_RE.search(source) is not None


def exposed_departments(sources: dict[str, str]) -> set[str]:
    """Departments that can throw but cannot report it."""
    exposed: set[str] = set()
    for rel_path, source in sources.items():
        dept = dept_id(rel_path)
        if dept is None or is_structurally_exempt(dept):
            continue
        if not has_failure_surface(source):
            exposed.add(dept)
    return exposed


def parse_allowlist(text: str) -> set[str]:
    entries: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        entries.add(line.split("|", 1)[0].strip())
    return entries


def load_allowlist(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return parse_allowlist(path.read_text(encoding="utf-8"))


def allowlist_at_dev_base(root: Path) -> tuple[str, set[str] | None]:
    status, text = ratchet_base.file_at_base(root, ALLOWLIST)
    if text is None:
        return status, None
    return status, parse_allowlist(text)


def ratchet_messages(
    current: set[str],
    allowlist: set[str],
    base_allowlist: set[str] | None,
) -> list[str]:
    messages: list[str] = []

    for dept in sorted(current - allowlist):
        messages.append(
            f"department `{dept}` declares neither a `retry` policy nor "
            "`wrap_pipeline_failure`, so a thrown error is ACKed as `dropped_no_retry_policy` with no "
            "failure fact and no dead letter (see #2996). Declare one, or add a shrink-only allowlist "
            f"entry in {ALLOWLIST} with an issue link and a reason."
        )

    for dept in sorted(allowlist - current):
        messages.append(
            f"`{dept}` is listed in {ALLOWLIST} but now has a failure surface "
            "(or no longer exists). Remove the stale allowlist entry so the ratchet keeps shrinking."
        )

    if base_allowlist is not None:
        for dept in sorted(allowlist - base_allowlist):
            messages.append(
                f"{ALLOWLIST} grew by `{dept}`; this inventory is shrink-only. "
                "Give the new department a `retry` policy or `wrap_pipeline_failure` instead."
            )

    return messages
