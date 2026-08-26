#!/usr/bin/env python3
"""Behavior tests for warming the pinned fkst-framework binary."""

from __future__ import annotations

import concurrent.futures
import os
import shutil
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

    def create_worktree(self, name: str, pin: str) -> Path:
        worktree = self.worktree.parent / name
        self._create_repo(worktree, pin)
        return worktree

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
                if [ -n "${FKST_TEST_CARGO_DELAY_SECONDS:-}" ]; then
                  sleep "$FKST_TEST_CARGO_DELAY_SECONDS"
                fi
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
    def test_identical_trusted_pin_reuses_binary_across_worktrees(self) -> None:
        pin = "ProjectOwner/project-substrate@project-ref"
        h = WarmPinnedBinHarness(pin, "CandidateOwner/candidate-substrate@candidate-ref")
        try:
            detached_base = h.create_worktree(
                "detached-base", "BaseOwner/base-substrate@base-ref"
            )

            candidate_result = h.run(str(h.worktree))
            base_result = h.run(str(detached_base))

            self.assertEqual(candidate_result.returncode, 0, candidate_result.stderr)
            self.assertEqual(base_result.returncode, 0, base_result.stderr)
            self.assertIn("result=build", candidate_result.stdout)
            self.assertIn("result=hit", base_result.stdout)
            self.assertEqual(h.calls().count("cargo build --manifest-path"), 1)
        finally:
            h.close()

    def test_changed_trusted_pin_uses_a_distinct_binary(self) -> None:
        first_pin = "SharedOwner/shared-substrate@first-ref"
        second_pin = "SharedOwner/shared-substrate@second-ref"
        h = WarmPinnedBinHarness(first_pin, "CandidateOwner/candidate-substrate@candidate-ref")
        try:
            first_result = h.run(str(h.worktree))
            (h.project_root / ".fkst" / "substrate-ref").write_text(
                second_pin + "\n", encoding="utf-8"
            )
            second_result = h.run(str(h.worktree))

            self.assertEqual(first_result.returncode, 0, first_result.stderr)
            self.assertEqual(second_result.returncode, 0, second_result.stderr)
            self.assertIn("result=build", first_result.stdout)
            self.assertIn("result=build", second_result.stdout)
            calls = h.calls()
            self.assertEqual(calls.count("cargo build --manifest-path"), 2)
            self.assertIn(" checkout --detach first-ref", calls)
            self.assertIn(" checkout --detach second-ref", calls)
        finally:
            h.close()

    def test_concurrent_identical_trusted_pins_share_one_build(self) -> None:
        pin = "SharedOwner/shared-substrate@concurrent-ref"
        h = WarmPinnedBinHarness(pin, "CandidateOwner/candidate-substrate@candidate-ref")
        try:
            peer_worktree = h.create_worktree(
                "concurrent-peer", "PeerOwner/peer-substrate@peer-ref"
            )
            h.env["FKST_TEST_CARGO_DELAY_SECONDS"] = "0.2"

            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                futures = [
                    executor.submit(h.run, str(h.worktree)),
                    executor.submit(h.run, str(peer_worktree)),
                ]
                results = [future.result() for future in futures]

            for result in results:
                self.assertEqual(result.returncode, 0, result.stderr)
            outcomes = {result.stdout.strip().rsplit("=", 1)[-1] for result in results}
            self.assertEqual(outcomes, {"build", "hit"})
            self.assertEqual(h.calls().count("cargo build --manifest-path"), 1)
        finally:
            h.close()

    def test_warm_exact_pin_cache_exits_without_git_or_cargo(self) -> None:
        pin = "WarmOwner/warm-substrate@warm-ref"
        h = WarmPinnedBinHarness(pin, "CandidateOwner/candidate-substrate@candidate-ref")
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

    def test_cold_cache_builds_pin_read_from_trusted_project(self) -> None:
        project_pin = "ProjectOwner/project-substrate@project-ref"
        worktree_pin = "WorktreeOwner/worktree-substrate@worktree-ref"
        h = WarmPinnedBinHarness(project_pin, worktree_pin)
        try:
            result = h.run(str(h.worktree))

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), f"warm-pinned-bin pin={project_pin} result=build")
            calls = h.calls()
            self.assertIn(
                "git clone --no-checkout https://github.com/ProjectOwner/project-substrate.git",
                calls,
            )
            self.assertIn(" checkout --detach project-ref", calls)
            self.assertIn("cargo build --manifest-path", calls)
            self.assertNotIn("worktree-ref", calls)
            self.assertNotIn("WorktreeOwner/worktree-substrate", calls)
        finally:
            h.close()

    def test_non_cargo_worktree_without_a_substrate_pin_is_not_applicable(self) -> None:
        h = WarmPinnedBinHarness(
            "ProjectOwner/project-substrate@project-ref",
            "WorktreeOwner/worktree-substrate@worktree-ref",
        )
        try:
            (h.project_root / ".fkst" / "substrate-ref").unlink()
            (h.worktree / ".fkst" / "substrate-ref").unlink()
            result = h.run(str(h.worktree))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("result=not-applicable", result.stdout)
            self.assertEqual(h.calls(), "")
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


class SharedCargoTargetHarness:
    def __init__(self) -> None:
        cargo = shutil.which("cargo")
        if cargo is None:
            raise RuntimeError("cargo is required for shared Cargo target behavior tests")

        self.tmp = tempfile.TemporaryDirectory()
        tmp_root = Path(self.tmp.name)
        self.project_root = tmp_root / "trusted-project"
        self.checkout = tmp_root / "source-checkout"
        self.common_git_dir = self.checkout / ".git"
        self.shared_dependency = tmp_root / "shared-dependency"
        self.candidate = tmp_root / "candidate-worktree"
        self.detached_base = tmp_root / "detached-base-worktree"
        self.rustc_log = tmp_root / "rustc.log"
        self.project_root.mkdir()
        self._write_shared_dependency(1)
        self._create_repository()
        self.rustc_wrapper = tmp_root / "rustc-wrapper.sh"
        write_executable(
            self.rustc_wrapper,
            textwrap.dedent(
                """\
                #!/usr/bin/env sh
                printf '%s\\n' "$*" >> "$FKST_TEST_RUSTC_LOG"
                exec "$@"
                """
            ),
        )

        self.env = os.environ.copy()
        self.env.pop("CARGO_TARGET_DIR", None)
        self.env.update(
            {
                "FKST_TEST_RUSTC_LOG": str(self.rustc_log),
                "RUSTC_WRAPPER": str(self.rustc_wrapper),
            }
        )

    def close(self) -> None:
        self.tmp.cleanup()

    def _write_shared_dependency(self, value: int) -> None:
        (self.shared_dependency / "src").mkdir(parents=True, exist_ok=True)
        (self.shared_dependency / "Cargo.toml").write_text(
            textwrap.dedent(
                """\
                [package]
                name = "shared_dependency"
                version = "0.1.0"
                edition = "2021"
                """
            ),
            encoding="utf-8",
        )
        (self.shared_dependency / "src" / "lib.rs").write_text(
            f"pub fn value() -> u8 {{ {value} }}\n", encoding="utf-8"
        )

    def _create_repository(self) -> None:
        self.checkout.mkdir()
        self._run_git("init", str(self.checkout))
        self._write_project(self.checkout)
        self._run_git("-C", str(self.checkout), "add", ".")
        self._run_git(
            "-C",
            str(self.checkout),
            "-c",
            "user.name=Cache Test",
            "-c",
            "user.email=cache-test@example.invalid",
            "commit",
            "-m",
            "fixture",
        )
        for worktree in (self.candidate, self.detached_base):
            self._run_git(
                "-C", str(self.checkout), "worktree", "add", "--detach", str(worktree), "HEAD"
            )

    def _write_project(self, root: Path) -> None:
        (root / "src").mkdir(parents=True)
        dependency_path = str(self.shared_dependency).replace("\\", "\\\\")
        (root / ".gitignore").write_text("/target\n", encoding="utf-8")
        (root / "Cargo.toml").write_text(
            textwrap.dedent(
                f"""\
                [package]
                name = "cache_probe"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                shared_dependency = {{ path = "{dependency_path}" }}
                """
            ),
            encoding="utf-8",
        )
        (root / "src" / "main.rs").write_text(
            'fn main() { println!("{}", shared_dependency::value()); }\n',
            encoding="utf-8",
        )

    @staticmethod
    def _run_git(*args: str) -> None:
        subprocess.run(
            ["git", *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    def prepare(self, worktree: Path) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        env["FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE"] = str(worktree)
        return subprocess.run(
            ["/bin/bash", str(WARM_SCRIPT)],
            cwd=self.project_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def build(self, worktree: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["cargo", "build", "--manifest-path", str(worktree / "Cargo.toml")],
            cwd=worktree,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def shared_dependency_compiles(self) -> int:
        if not self.rustc_log.exists():
            return 0
        return self.rustc_log.read_text(encoding="utf-8").count(
            "--crate-name shared_dependency"
        )


class SharedCargoTargetTest(unittest.TestCase):
    def test_identical_native_action_reuses_artifact_across_worktrees(self) -> None:
        h = SharedCargoTargetHarness()
        try:
            candidate_prepare = h.prepare(h.candidate)
            base_prepare = h.prepare(h.detached_base)

            self.assertEqual(candidate_prepare.returncode, 0, candidate_prepare.stderr)
            self.assertEqual(base_prepare.returncode, 0, base_prepare.stderr)
            shared_target = h.checkout.joinpath("target").resolve()
            self.assertEqual(h.candidate.joinpath("target").resolve(), shared_target)
            self.assertEqual(h.detached_base.joinpath("target").resolve(), shared_target)
            self.assertEqual(h.shared_dependency_compiles(), 0)

            candidate_build = h.build(h.candidate)
            base_build = h.build(h.detached_base)

            self.assertEqual(candidate_build.returncode, 0, candidate_build.stderr)
            self.assertEqual(base_build.returncode, 0, base_build.stderr)
            self.assertEqual(h.shared_dependency_compiles(), 1)
        finally:
            h.close()

    def test_changed_native_source_input_invalidates_artifact(self) -> None:
        h = SharedCargoTargetHarness()
        try:
            for worktree in (h.candidate, h.detached_base):
                prepared = h.prepare(worktree)
                self.assertEqual(prepared.returncode, 0, prepared.stderr)

            first_build = h.build(h.candidate)
            h._write_shared_dependency(2)
            second_build = h.build(h.detached_base)

            self.assertEqual(first_build.returncode, 0, first_build.stderr)
            self.assertEqual(second_build.returncode, 0, second_build.stderr)
            self.assertEqual(h.shared_dependency_compiles(), 2)
        finally:
            h.close()

    def test_concurrent_native_actions_share_one_artifact_build(self) -> None:
        h = SharedCargoTargetHarness()
        try:
            for worktree in (h.candidate, h.detached_base):
                prepared = h.prepare(worktree)
                self.assertEqual(prepared.returncode, 0, prepared.stderr)

            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                futures = [
                    executor.submit(h.build, h.candidate),
                    executor.submit(h.build, h.detached_base),
                ]
                results = [future.result() for future in futures]

            for result in results:
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(h.shared_dependency_compiles(), 1)
        finally:
            h.close()

if __name__ == "__main__":
    unittest.main()
