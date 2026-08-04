#!/usr/bin/env python3
"""G-DEVLOOP-INSTALLER: a shrink-only ratchet measuring the OTHER half of the devloop ambient-M
god-table — the install(M) composed-core coupling that G-DEVLOOP-DECOUPLE does not see.

G-DEVLOOP-DECOUPLE counts the copy-onto-M FACADE (`M.fn = mod.fn` explicit bindings in package
cores). It is blind to the `install(M)` COMPOSED-CORE: package cores call
`require("devloop.commands").install(M)` / `require("devloop.logging").install(M)` /
`require("devloop.state").install(M)`, and those modules define `function M.<name>` INSIDE the
installer, so department reads `core.log_raise(...)` / `core.current_state(...)` are genuine
ambient-M god-table coupling that no explicit `M.name=` binding exists for — invisible to the
facade ratchet. This ratchet makes that coupling VISIBLE and drives it to zero as the composed
core is re-architected to explicit typed capability injection (caps.log.raise(...), etc.), per
docs/devloop-decouple-endpoint.md and the typed-DI SPEC.

For each package, it resolves that package core's `require("devloop.<mod>").install(M)` calls,
collects the `function M.<name>` symbols those modules (and, for aggregator modules, their listed
submodules) install onto M, and counts `(core|M).<symbol>(` reader call-sites only in that same
package's production code (excluding */core.lua and tests). The inventory stores the resulting
reader sites per package, so every baseline unit is auditable. Shrink-only comparison is also per
package: coupling removed from one package cannot mask growth in another. Deterministic, read-only.
Not a full proof (a reader could reach an installed method under another alias), so it is a
shrink-only ratchet, not a "gaming is impossible" claim.
"""
import json
import re
import sys
from pathlib import Path

INVENTORY = "migration/devloop-installer.inventory"

_INSTALL = re.compile(r'require\(\s*["\'](devloop\.[A-Za-z0-9_.]+)["\']\s*\)\.install\(\s*M\s*\)')
_SUBMOD = re.compile(r'["\'](devloop\.[A-Za-z0-9_./]+)["\']')
# Installer methods are declared both as `function M.name(...)` and as `M.name = ...`
# assignments (e.g. M.payload_field = logging.payload_field); catch both so a method installed
# via assignment is not silently uncounted (a false-negative that would hide coupling).
_M_METHOD = re.compile(
    r'^\s*(?:function M\.([A-Za-z_][A-Za-z0-9_]*)|M\.([A-Za-z_][A-Za-z0-9_]*)\s*=)', re.M
)
# A self-contained module may loop-bind its own C functions onto M in the installer, e.g.
#   function S.install(M) for _, n in ipairs({"a", "b", ...}) do M[n] = C[n] end end
# Those names ARE installed onto M just as much as an explicit `M.name =`, so they must be
# counted; otherwise a self-contain that switches to loop-binding would silently hide the
# module's whole surface from the ratchet (a false drop). Capture the ipairs name list guarded
# by a dynamic `M[<var>] = ...` binding in the same module.
_LOOP_BIND = re.compile(r'ipairs\(\s*\{([^}]*)\}\s*\)\s*do\s*M\[[A-Za-z_][A-Za-z0-9_]*\]\s*=')
_QUOTED = re.compile(r'["\']([A-Za-z_][A-Za-z0-9_]*)["\']')


def _install_method_names(text: str) -> set[str]:
    names = {(m.group(1) or m.group(2)) for m in _M_METHOD.finditer(text)}
    for loop in _LOOP_BIND.finditer(text):
        names.update(_QUOTED.findall(loop.group(1)))
    return names


def _module_path(root: Path, mod: str) -> Path:
    return root / "libraries" / (mod.replace(".", "/") + ".lua")


def _installer_symbols_for_core(root: Path, core: Path) -> set[str]:
    """Symbols installed onto M by the devloop modules one package core installs."""
    install_mods = {
        match.group(1)
        for match in _INSTALL.finditer(core.read_text(encoding="utf-8"))
    }
    symbols: set[str] = set()
    for mod in install_mods:
        path = _module_path(root, mod)
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        symbols.update(_install_method_names(text))
        for sub in _SUBMOD.findall(text):
            sub_path = _module_path(root, sub)
            if sub_path.exists():
                symbols.update(_install_method_names(sub_path.read_text(encoding="utf-8")))
    return symbols


def installer_symbols_by_package(root: Path) -> dict[str, set[str]]:
    """Return each package's own installed devloop symbols.

    For each `require("devloop.<mod>").install(M)` in a package core, collect the `function M.<name>`
    definitions in that module; for aggregator modules (whose install loops over a list of
    submodules), also collect from every `"devloop.<submod>"` string the module references.
    """
    return {
        core.parent.name: _installer_symbols_for_core(root, core)
        for core in sorted(root.glob("packages/*/core.lua"))
    }


def _reader_sites(root: Path, package: str, symbols: set[str]) -> list[dict[str, object]]:
    if not symbols:
        return []
    alt = "|".join(re.escape(s) for s in sorted(symbols, key=len, reverse=True))
    pattern = re.compile(rf"\b(?:core|M)\.({alt})\s*\(")
    sites: list[dict[str, object]] = []
    definition = re.compile(r"\bfunction\s+$")
    package_root = root / "packages" / package
    for lua in sorted(package_root.glob("**/*.lua")):
        rel = lua.relative_to(root).as_posix()
        if rel.endswith("/core.lua") or "/tests/" in rel:
            continue
        for line_number, line in enumerate(lua.read_text(encoding="utf-8").splitlines(), 1):
            for match in pattern.finditer(line):
                if definition.search(line[: match.start()]):
                    continue
                sites.append(
                    {
                        "path": rel,
                        "line": line_number,
                        "column": match.start() + 1,
                        "symbol": match.group(1),
                    }
                )
    return sites


def current_inventory(root: Path) -> dict[str, list[dict[str, object]]]:
    by_package = installer_symbols_by_package(root)
    inventory = {
        package: _reader_sites(root, package, symbols)
        for package, symbols in sorted(by_package.items())
    }
    return {package: sites for package, sites in inventory.items() if sites}


def current_counts(root: Path) -> dict[str, int]:
    return {package: len(sites) for package, sites in current_inventory(root).items()}


def current_count(root: Path) -> int:
    return sum(current_counts(root).values())


def baseline(root: Path) -> dict[str, list[dict[str, object]]] | None:
    path = root / INVENTORY
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    packages = data.get("packages")
    if not isinstance(packages, dict):
        raise ValueError(f"invalid {INVENTORY}: expected a packages object")
    for package, sites in packages.items():
        if not isinstance(package, str) or not isinstance(sites, list):
            raise ValueError(f"invalid {INVENTORY}: package baselines must be site lists")
    return packages


def _format_site(site: dict[str, object]) -> str:
    return f"{site['path']}:{site['line']}:{site['column']} core.{site['symbol']}"


def repository_messages(root: Path):
    if not (root / "libraries" / "devloop").exists():
        return
    cur = current_inventory(root)
    base = baseline(root)
    if base is None:
        yield (
            f"missing baseline {INVENTORY}; create a packages object containing the current "
            f"per-package reader-site inventory (shrink-only; migrate install(M) composed-core "
            f"reads to explicit typed capability injection to lower each package toward zero)"
        )
        return
    for package, sites in sorted(cur.items()):
        base_count = len(base.get(package, []))
        if len(sites) > base_count:
            diagnostics = ", ".join(_format_site(site) for site in sites)
            yield (
                f"package {package} has {len(sites)} production reader-calls through the ambient "
                f"M to its install(M) composed-core symbols (baseline {base_count}); this GREW. "
                f"Current sites: {diagnostics}. Do not add new install(M) composed-core reads; "
                f"migrate readers to explicit capability handles (caps.log/state/egress). Update "
                f"{INVENTORY} only when that package's real count drops."
            )


def check(root: Path, violations: list[str]) -> None:
    for message in repository_messages(root):
        violations.append(f"G-DEVLOOP-INSTALLER: {message}")


if __name__ == "__main__":
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    v: list[str] = []
    check(root, v)
    current = current_inventory(root)
    print("current:", json.dumps({"packages": current}, indent=2, sort_keys=True))
    print("baseline:", json.dumps({"packages": baseline(root)}, indent=2, sort_keys=True))
    for m in v:
        print("VIOLATION:", m)
    sys.exit(1 if v else 0)
