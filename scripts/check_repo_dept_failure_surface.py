"""Shrink-only ratchet: a department must declare a package-owned failure surface.

The pinned engine supplies reliable retry by default. An omitted `M.spec.retry` and an explicit
`retry = {}` both materialize the host-resolved retry defaults; `retry = false` is the explicit
opt-out. `wrap_pipeline_failure` is independent: it emits a structured package log fact and
rethrows, after which the materialized engine retry policy still applies.

This ratchet deliberately requires one of two package-visible surfaces:

  * an enabled `retry = { ... }` table makes the engine policy explicit in the Department spec;
  * `wrap_pipeline_failure` makes the package-owned structured log fact explicit.

Therefore an allowlist entry means the package leaves both accepted surfaces implicit. It does
NOT mean an omitted retry is disabled, dropped, or unable to dead-letter. The detection remains
a source-level formalization ratchet, not a claim that the engine lacks a runtime failure path.
See #2996.

Two roles are STRUCTURALLY exempt, derived from the department's role rather than a name
list that rots:

  * `dead_letter` departments ARE the DLQ consumer; retrying them into themselves is wrong.
  * `test_*` departments are test-mode probes and never run under a production supervise.
"""

from __future__ import annotations

import re
from pathlib import Path

ALLOWLIST = "migration/dept-failure-surface.allowlist"

# An enabled retry table at spec indentation, and the structured failure wrapper.
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
    """Departments outside both package-owned surfaces accepted by this ratchet."""
    exposed: set[str] = set()
    for rel_path, source in sources.items():
        dept = dept_id(rel_path)
        if dept is None or is_structurally_exempt(dept):
            continue
        if not has_failure_surface(source):
            exposed.add(dept)
    return exposed


def parse_allowlist_lines(lines: list[str]) -> set[str]:
    entries: set[str] = set()
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        entries.add(line.split("|", 1)[0].strip())
    return entries


def parse_allowlist(text: str) -> set[str]:
    return parse_allowlist_lines(text.splitlines())


# Current-file loading preserves the complete-text parser surface.
def load_allowlist(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return parse_allowlist(path.read_text(encoding="utf-8"))


def ratchet_messages(
    current: set[str],
    allowlist: set[str],
    base_allowlist: set[str] | None,
) -> list[str]:
    messages: list[str] = []

    for dept in sorted(current - allowlist):
        messages.append(
            f"department `{dept}` uses neither an enabled `retry` table nor "
            "`wrap_pipeline_failure`, so neither package-owned failure surface accepted by this "
            "ratchet is explicit (see #2996). An omitted `retry` inherits the engine's reliable "
            "host defaults, equivalent to `retry = {}`; `retry = false` explicitly disables retry. "
            "Declare `retry = {}` to formalize the inherited policy, use "
            "`wrap_pipeline_failure` for a structured package log fact, or add a "
            f"shrink-only allowlist entry in {ALLOWLIST} with an issue link and a reason."
        )

    for dept in sorted(allowlist - current):
        messages.append(
            f"`{dept}` is listed in {ALLOWLIST} but now uses an accepted failure surface "
            "(or no longer exists). Remove the stale allowlist entry so the ratchet keeps shrinking."
        )

    if base_allowlist is not None:
        for dept in sorted(allowlist - base_allowlist):
            messages.append(
                f"{ALLOWLIST} grew by `{dept}`; this inventory is shrink-only. "
                "Give the new department an enabled `retry` table or `wrap_pipeline_failure` instead."
            )

    return messages
