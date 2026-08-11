#!/usr/bin/env python3
"""Behavior tests for warming the pinned fkst-framework binary."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WARM_SCRIPT = REPO_ROOT / "scripts" / "warm_pinned_bin.sh"


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class WarmPinnedBinHarness:
    def __init__(self, project_pin: str, worktree_pin: str) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        tmp_root = Path(self.tmp.name)
        self.project_root = tmp_root / "project"
        self.worktree = tmp_root / "worktree"
        self.fake_bin = tmp_root / "fake-bin"
        self.cache = tmp_root / "cache"
        self.log = tmp_root / "calls.log"
        self.fake_bin.mkdir()
        self._create_repo(self.project_root, project_pin)
        self._create_repo(self.worktree, worktree_pin)
        self._install_fake_tools()

        self.env = os.environ.copy()
        for name in ("BIN", "FKST_FRAMEWORK_BIN", "FKST_CODEX_WORKER_BIN", "FKST_NO_AUTOBUILD"):
            self.env.pop(name, None)
        self.env.update(
            {
                "FKST_BIN_CACHE_ROOT": str(self.cache),
                "FKST_TEST_COMMAND_LOG": str(self.log),
                "PATH": f"{self.fake_bin}{os.pathsep}{self.env.get('PATH', '')}",
            }
        )

    def close(self) -> None:
        self.tmp.cleanup()

    @staticmethod
    def _create_repo(root: Path, pin: str) -> None:
        (root / ".fkst").mkdir(parents=True)
        (root / "scripts").mkdir()
        (root / ".fkst" / "substrate-ref").write_text(pin + "\n", encoding="utf-8")
        source = REPO_ROOT / "scripts" / "bin_cache.py"
        (root / "scripts" / "bin_cache.py").write_bytes(source.read_bytes())

    def _install_fake_tools(self) -> None:
        write_executable(
            self.fake_bin / "git",
            textwrap.dedent(
                """\
                #!/usr/bin/env sh
                echo "git $*" >> "$FKST_TEST_COMMAND_LOG"
                if [ "$1" = "clone" ]; then
                  mkdir -p "$4/.git"
                  exit 0
                fi
                if [ "$1" = "-C" ]; then
                  exit 0
                fi
                exit 1
                """
            ),
        )
        write_executable(
            self.fake_bin / "cargo",
            textwrap.dedent(
                """\
                #!/usr/bin/env sh
                echo "cargo $*" >> "$FKST_TEST_COMMAND_LOG"
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "--manifest-path" ]; then
                    checkout="${2%/Cargo.toml}"
                    mkdir -p "$checkout/target/debug"
                    printf '#!/usr/bin/env sh\\n' > "$checkout/target/debug/fkst-framework"
                    chmod +x "$checkout/target/debug/fkst-framework"
                    exit 0
                  fi
                  shift
                done
                exit 1
                """
            ),
        )

    def cache_bin(self, owner: str, repo: str, ref: str) -> Path:
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(REPO_ROOT / "scripts" / "bin_cache.py"),
                str(self.cache),
                owner,
                repo,
                ref,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return Path(result.stdout.strip())

    def run(self, worktree: str | None) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        if worktree is None:
            env.pop("FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE", None)
        else:
            env["FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE"] = worktree
        return subprocess.run(
            ["/bin/bash", str(WARM_SCRIPT)],
            cwd=self.project_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def calls(self) -> str:
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""


class WarmPinnedBinTest(unittest.TestCase):
    def test_warm_exact_pin_cache_exits_without_git_or_cargo(self) -> None:
        pin = "WarmOwner/warm-substrate@warm-ref"
        h = WarmPinnedBinHarness("ProjectOwner/project-substrate@project-ref", pin)
        try:
            cached_bin = h.cache_bin("WarmOwner", "warm-substrate", "warm-ref")
            cached_bin.parent.mkdir(parents=True)
            write_executable(cached_bin, "#!/usr/bin/env sh\n")

            result = h.run(str(h.worktree))

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), f"warm-pinned-bin pin={pin} result=hit")
            self.assertEqual(h.calls(), "")
        finally:
            h.close()

    def test_cold_cache_builds_pin_read_from_worktree(self) -> None:
        project_pin = "ProjectOwner/project-substrate@project-ref"
        worktree_pin = "WorktreeOwner/worktree-substrate@worktree-ref"
        h = WarmPinnedBinHarness(project_pin, worktree_pin)
        try:
            result = h.run(str(h.worktree))

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), f"warm-pinned-bin pin={worktree_pin} result=build")
            calls = h.calls()
            self.assertIn(
                "git clone --no-checkout https://github.com/WorktreeOwner/worktree-substrate.git",
                calls,
            )
            self.assertIn(" checkout --detach worktree-ref", calls)
            self.assertIn("cargo build --manifest-path", calls)
            self.assertNotIn("project-ref", calls)
            self.assertNotIn("ProjectOwner/project-substrate", calls)
        finally:
            h.close()

    def test_missing_or_relative_worktree_fails_with_narrow_error(self) -> None:
        h = WarmPinnedBinHarness(
            "ProjectOwner/project-substrate@project-ref",
            "WorktreeOwner/worktree-substrate@worktree-ref",
        )
        try:
            for worktree in (None, "relative/worktree"):
                with self.subTest(worktree=worktree):
                    result = h.run(worktree)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("warm-pinned-bin-invalid-worktree", result.stderr)
                    self.assertEqual(h.calls(), "")
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
