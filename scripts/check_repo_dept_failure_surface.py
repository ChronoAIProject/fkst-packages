"""Shrink-only ratchet: a department that throws must at least emit an error fact.

Three tiers, and this ratchet enforces only the boundary between the first and the rest:

  tier 1  neither mechanism            -- no error fact, no dead letter. SILENT. <- enforced here
  tier 2  `wrap_pipeline_failure` only -- error fact in the log, but NO dead letter
  tier 3  `retry` policy               -- error fact AND dead letter

`wrap_pipeline_failure` (libraries/devloop/logging.lua:44-58) pcalls, emits a structured
`log_error_fact`, then RETHROWS. The rethrow still reaches the engine, and with no `retry`
policy the engine ACKs it as `dropped_no_retry_policy` and returns before `store.retry(...)`
(fkst-substrate crates/fkst-framework/src/supervise/consumer.rs:702-710). So tier 2 is
greppable but never dead-lettered -- do NOT read a passing check as "reaches the DLQ".

Reaching the DLQ requires `retry`. Tier 2 is tracked as follow-up work, not by this ratchet;
tightening to retry-only would move ~27 further departments into the allowlist and is a
separate decision. See #2996.

Two roles are STRUCTURALLY exempt, derived from the department's role rather than a name
list that rots:

  * `dead_letter` departments ARE the DLQ consumer; retrying them into themselves is wrong.
  * `test_*` departments are test-mode probes and never run under a production supervise.
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
            "`wrap_pipeline_failure`, so a thrown error produces NO error fact at all and is ACKed as "
            "`dropped_no_retry_policy` (see #2996). Declare one. Note `wrap_pipeline_failure` alone "
            "emits a log fact but still does NOT reach the DLQ -- only `retry` does. Or add a "
            f"shrink-only allowlist entry in {ALLOWLIST} with an issue link and a reason."
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
