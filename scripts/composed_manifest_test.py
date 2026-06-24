#!/usr/bin/env python3
"""Behavior tests for package composition manifest shell helpers."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class ComposedManifestHarness:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin = self.root / "fkst-framework"
        self.composed = self.root / "composed"
        self.flat = self.root / "flat"
        self.bad = self.root / "bad"
        for pkg in (self.composed, self.flat, self.bad):
            pkg.mkdir()
            (pkg / "fkst.toml").write_text(f'name = "{pkg.name}"\n', encoding="utf-8")
        write_executable(
            self.bin,
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                expected="$(printf '%s%s%s\\n' composed - deps)"
                if [ "${{1:-}}" != "manifest" ] || [ "${{2:-}}" != "$expected" ] || [ "${{3:-}}" != "--manifest" ]; then
                  echo "unexpected argv: $*" >&2
                  exit 64
                fi
                case "$4" in
                  {self.composed / "fkst.toml"})
                    printf '%s\\n' github-proxy consensus
                    exit 0
                    ;;
                  {self.flat / "fkst.toml"})
                    exit 10
                    ;;
                  {self.bad / "fkst.toml"})
                    echo "malformed manifest" >&2
                    exit 1
                    ;;
                  *)
                    echo "unknown manifest: $4" >&2
                    exit 64
                    ;;
                esac
                """
            ),
        )

    def close(self) -> None:
        self.tmp.cleanup()

    def run_helper(self, body: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["BIN"] = str(self.bin)
        env["COMPOSED_PKG"] = str(self.composed)
        env["FLAT_PKG"] = str(self.flat)
        env["BAD_PKG"] = str(self.bad)
        return subprocess.run(
            ["/bin/bash", "-c", body],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )


class ComposedManifestTest(unittest.TestCase):
    def test_deps_helper_preserves_engine_order(self) -> None:
        h = ComposedManifestHarness()
        try:
            result = h.run_helper(
                textwrap.dedent(
                    """\
                    set -euo pipefail
                    source scripts/composed_manifest.sh
                    composition_siblings_of "$COMPOSED_PKG"
                    """
                )
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["github-proxy", "consensus"])
        finally:
            h.close()

    def test_is_composed_distinguishes_composed_from_flat(self) -> None:
        h = ComposedManifestHarness()
        try:
            result = h.run_helper(
                textwrap.dedent(
                    """\
                    set -euo pipefail
                    source scripts/composed_manifest.sh
                    if is_composed "$COMPOSED_PKG"; then echo composed; fi
                    if is_composed "$FLAT_PKG"; then echo wrong; else
                      rc=$?
                      echo "flat_rc=$rc"
                    fi
                    """
                )
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["composed", "flat_rc=1"])
        finally:
            h.close()

    def test_manifest_errors_are_not_flat(self) -> None:
        h = ComposedManifestHarness()
        try:
            result = h.run_helper(
                textwrap.dedent(
                    """\
                    set -euo pipefail
                    source scripts/composed_manifest.sh
                    if is_composed "$BAD_PKG"; then
                      echo wrong
                    else
                      rc=$?
                      echo "bad_rc=$rc"
                      exit "$rc"
                    fi
                    """
                )
            )
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("bad_rc=2", result.stdout)
            self.assertIn("manifest composition query failed", result.stderr)
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
