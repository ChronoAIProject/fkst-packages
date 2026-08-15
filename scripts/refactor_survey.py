#!/usr/bin/env python3
"""Report the refactoring surface: one command instead of a day of rebuilt instruments.

Advisory only. This is NOT a gate and must never fail a build -- reversible, low-harm drift gets
detection plus correction, not an up-front gate (CLAUDE.md 执法分级). The one unit here that IS
gated has its own checker, `check_repo_dead_locals.py`.

Written because `docs/dev/2026-08-13-refactor-measurement-ledger.md` recorded the METHOD in prose
while the instruments lived in a scratch directory. Prose does not run.

Each unit below carries the trap that broke it the first time. Do not remove a trap comment without
re-deriving why it is there; three of these units return confident, entirely wrong answers without
them.
"""

from __future__ import annotations

import collections
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_repo_lua  # noqa: E402

EXPORT_RE = re.compile(r"^function ([MSCIT])\.(\w+)\(", re.M)
INSTALLER_RE = re.compile(r"\b(function|if|for|while|do|repeat)\b")
PAIRED_DO_RE = re.compile(r"\b(for|while)\b(.*?)\bdo\b")
END_RE = re.compile(r"\bend\b")


def tracked(root: Path, *globs: str) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", *globs],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    return out


def unused_exports(root: Path) -> list[str]:
    """Exported library functions no consumer references.

    TRAP: an earlier version matched `.name(` and called 62 LIVE functions dead, because callers
    also write `local key_set = values.key_set`. Match the bare word across ALL tracked file types
    -- a name can be referenced from a manifest, a doc, or a checker, not only from Lua.
    """
    files = {f: (root / f).read_text(encoding="utf-8", errors="ignore")
             for f in tracked(root, "*")}
    exports = [
        (f, m.group(2))
        for f, t in files.items()
        if f.startswith("libraries/") and f.endswith(".lua")
        for m in EXPORT_RE.finditer(t)
    ]
    dead = []
    for f, name in exports:
        pat = re.compile(r"\b" + re.escape(name) + r"\b")
        if not any(pat.search(t) for g, t in files.items() if g != f):
            dead.append(f"{f}: {name}")
    return sorted(dead)


def unused_lib_deps(root: Path) -> list[str]:
    """Declared `[lib_deps] libraries = [...]` entries the package never requires.

    TRAP: the array is nested under the section; a regex for `^\\s*(\\w+)\\s*=` captures the KEY
    `libraries`, not its contents, and every package then reads as fully unused.
    """
    out = []
    for manifest in sorted((root / "packages").glob("*/fkst.toml")):
        pkg = manifest.parent
        section = re.search(r"^\[lib_deps\](.*?)(^\[|\Z)", manifest.read_text(), re.M | re.S)
        if not section:
            continue
        array = re.search(r"libraries\s*=\s*\[(.*?)\]", section.group(1), re.S)
        if not array:
            continue
        declared = set(re.findall(r'"([\w-]+)"', array.group(1)))
        required: set[str] = set()
        for lua in pkg.rglob("*.lua"):
            for req in re.findall(r"""require\(\s*['"]([\w.-]+)['"]""", lua.read_text(errors="ignore")):
                required.add(req.split(".")[0])
        for name in sorted(declared - required):
            out.append(f"{pkg.name}: {name}")
    return out


def oversized_files(root: Path, limit: int = 900) -> list[str]:
    """Source files at or over the soft split threshold. CLAUDE.md covers .lua/.sh/.py/.rs."""
    out = []
    for f in tracked(root, "*.lua", "*.sh", "*.py", "*.rs"):
        n = (root / f).read_text(errors="ignore").count("\n") + 1
        if n >= limit:
            out.append(f"{f}: {n} lines")
    return sorted(out, reverse=True)


def long_leaf_functions(root: Path, limit: int = 150) -> list[str]:
    """Leaf functions (containing no nested function) over `limit` lines.

    TRAP: raw function length is dominated by the dependency-injection installer shape,
    `function S.install(M, restart_policy)` wrapping a whole module -- 700-800 lines and correct.
    Only LEAF functions are extract-method candidates. Even then, see the ledger: this repo sets a
    file limit and no function-length rule, so these are informational, not defects.
    """
    out = []
    for f in tracked(root, "*.lua"):
        code = check_repo_lua.code_mask((root / f).read_text(errors="ignore"))
        spans, stack = [], []
        for i, raw in enumerate(code.split("\n")):
            line = PAIRED_DO_RE.sub(r"\1\2", raw)  # `for x do` opens ONE block, not two
            for m in INSTALLER_RE.finditer(line):
                stack.append((i, m.group(1)))
            for _ in END_RE.finditer(line):
                if stack:
                    start, kind = stack.pop()
                    if kind == "function":
                        spans.append((start + 1, i + 1))
        for a, b in spans:
            if b - a + 1 > limit and not any(a < x and y < b for x, y in spans):
                out.append(f"{f}:{a}-{b} ({b - a + 1} lines)")
    return sorted(out, key=lambda s: -int(s.rsplit("(", 1)[1].split()[0]))


def never_required_modules(root: Path) -> list[str]:
    """Reported for completeness. EXPECT FALSE POSITIVES -- read the trap before acting.

    TRAP: `core/restart/{transitions,marker_fields,liveness_signal_producers}/*.lua` are loaded by a
    registry -- `devloop_wiring.lua` calls `load_entries("core.restart.transitions", index)` and
    requires each entry by a COMPUTED name. A scan for literal `require("...")` reports all 30 as
    dead, and all 30 are live. Any result under a directory family like that is a registry, not a
    corpse.
    """
    files = {f: (root / f).read_text(errors="ignore") for f in tracked(root, "*.lua")}
    out = []
    for f in files:
        if f.endswith("_test.lua") or re.search(r"/(main|core|init)\.lua$", f):
            continue
        if "/raisers/" in f or "/departments/" in f:
            continue
        tail = f.rsplit("/", 1)[-1][:-4]
        pat = re.compile(r"""require\(\s*['"][\w.]*""" + re.escape(tail) + r"""['"]""")
        if not any(pat.search(t) for g, t in files.items() if g != f):
            out.append(f)
    return sorted(out)


def ambient_exports_without_readers(root: Path) -> list[str]:
    """devloop symbols bound onto the composed package table that nothing actually reads.

    TRAP 1 -- a definition is not a read. `function M.has_label(labels, expected)` matches
    `M.has_label` and was counted as a reader of devloop's `has_label`. This is the same defect
    that `check_repo_devloop_decouple.py` carried until #3823; it was then re-derived by hand in an
    ad-hoc script four rounds later (#3832), which is why the logic lives here now instead of being
    rewritten each time.

    TRAP 2 -- membership before matching. A package that never calls
    `require("devloop.<mod>").install(M)` cannot have devloop symbols on its table at all, so every
    same-named function it defines is noise. `log_line` showed 13 "readers", all of them in three
    packages that do not compose devloop and each own an unrelated `log_line`.
    """
    composing = set()
    for f in tracked(root, "packages/**/*.lua"):
        if re.search(r'require\(\s*"devloop\.[\w.]+"\s*\)\s*\.install\(', (root / f).read_text(encoding="utf-8", errors="ignore")):
            composing.add(f.split("/")[1])
    installers = [f for f in tracked(root, "libraries/devloop/**/*.lua")
                  if ".install(M)" in (root / f).read_text(encoding="utf-8", errors="ignore")]
    readers = {f: (root / f).read_text(encoding="utf-8", errors="ignore")
               for f in tracked(root, "packages/**/*.lua", "libraries/**/*.lua")
               if not f.startswith("libraries/devloop/commands")}
    dead = []
    for inst in installers:
        body = (root / inst).read_text(encoding="utf-8", errors="ignore")
        body = body[body.find(".install(M)"):]
        names = set(re.findall(r"M\.([A-Za-z_]\w*)\s*=", body))
        for listed in re.findall(r"ipairs\(\s*\{([^}]*)\}\s*\)\s*do\s*M\[", body):
            names |= set(re.findall(r'"([A-Za-z_]\w*)"', listed))
        for name in sorted(names):
            read = re.compile(rf"(?<![.\w])(?:core|M)\.{re.escape(name)}\b")
            define = re.compile(rf"^\s*(?:local\s+)?function\s+(?:core|M)\.{re.escape(name)}\s*\(")
            live = False
            for f, text in readers.items():
                if f == inst:
                    continue
                if f.startswith("packages/") and f.split("/")[1] not in composing:
                    continue
                if any(read.search(define.sub("", line, count=1)) for line in text.splitlines()):
                    live = True
                    break
            if not live:
                dead.append(f"{inst}: {name}")
    return sorted(dead)


UNITS = [
    ("exported library functions with no consumer", unused_exports),
    ("declared-but-unused lib_deps", unused_lib_deps),
    ("ambient devloop exports with no real reader", ambient_exports_without_readers),
    ("source files >= 900 lines", oversized_files),
    ("leaf functions > 150 lines (informational; repo has no function-length rule)",
     long_leaf_functions),
    ("modules never required (EXPECT FALSE POSITIVES -- registry loading)",
     never_required_modules),
]


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    print(f"refactor survey at {root}\n")
    for title, fn in UNITS:
        found = fn(root)
        print(f"{title}: {len(found)}")
        for item in found[:15]:
            print(f"    {item}")
        if len(found) > 15:
            print(f"    ... and {len(found) - 15} more")
        print()
    print("Advisory only -- this script never fails a build.")
    print("See docs/dev/2026-08-13-refactor-measurement-ledger.md for what each result means,")
    print("and for the units already measured to zero that are not repeated here.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
