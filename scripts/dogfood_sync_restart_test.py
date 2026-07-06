#!/usr/bin/env python3
"""Regression tests for dogfood sync restart ordering."""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def run_git(args: list[str], cwd: Path, env: dict[str, str]) -> None:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")


def git_stdout(args: list[str], cwd: Path, env: dict[str, str]) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return result.stdout.strip()


def pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def kill_if_alive(pid: int) -> None:
    if not pid_is_alive(pid):
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and pid_is_alive(pid):
        time.sleep(0.05)


class DogfoodSyncHarness:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dogfood_root = self.root / "dogfood"
        self.skill_dir = self.root / "skill"
        self.bin_dir = self.root / "bin"
        self.fake_bin = self.root / "fake-fkst-framework"
        self.substrate_src = self.root / "not-a-substrate-checkout"
        self.skill_dir.mkdir()
        self.bin_dir.mkdir()
        self.script = self.skill_dir / "dogfood.sh"
        shutil.copy2(REPO_ROOT / ".claude/skills/dogfood-github-devloop/dogfood.sh", self.script)
        self.script.chmod(0o755)
        shutil.copy2(REPO_ROOT / ".claude/skills/dogfood-github-devloop/workspace_manifest.py", self.skill_dir)
        self._make_fake_tools()

    def close(self) -> None:
        self.tmp.cleanup()

    def env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{os.environ.get('PATH', '')}",
                "DOGFOOD_ROOT": str(self.dogfood_root),
                "DOGFOOD_REPOS": "substrate",
                "DOGFOOD_CONFIG": str(self.root / "missing-config.sh"),
                "SUBSTRATE_SRC": str(self.substrate_src),
                "BIN": str(self.fake_bin),
                "BOT": "test-bot",
                "GH_ORG": "ExampleOrg",
                "UPSTREAM_BRANCH": "dev",
                "INTEGRATION_BRANCH": "integration-test",
                "FKST_DEVLOOP_UPSTREAM_BRANCH": "dev",
                "FKST_DEVLOOP_INTEGRATION_BRANCH": "integration-test",
                "ROLLUP_MERGE": "auto",
                "RATE_POOL": str(self.root / "rate-pools"),
                "LOGDIR": str(self.dogfood_root),
                "DUR_SUBSTRATE": str(self.dogfood_root / "stable-durable-substrate"),
            }
        )
        return env

    def run_sync(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.script), "sync", "substrate"],
            cwd=self.root,
            env=self.env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def _make_fake_tools(self) -> None:
        write_executable(self.bin_dir / "cargo", "#!/usr/bin/env bash\nexit 0\n")
        write_executable(
            self.bin_dir / "date",
            "#!/usr/bin/env bash\n[ \"${1:-}\" = '+%s' ] && { printf '1760000000\\n'; exit 0; }\nexec /bin/date \"$@\"\n",
        )

    def create_remote(self, name: str, old_files: dict[str, str], new_files: dict[str, str]) -> Path:
        env = self.git_env()
        source = self.root / f"{name}-source"
        remote = self.root / name
        source.mkdir()
        run_git(["init", "-q"], source, env)
        for rel, content in old_files.items():
            path = source / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            if rel == "scripts/run.sh":
                path.chmod(0o755)
        run_git(["add", "."], source, env)
        run_git(["commit", "-q", "-m", "integration base"], source, env)
        run_git(["branch", "integration-test"], source, env)
        for rel, content in new_files.items():
            path = source / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            if rel == "scripts/run.sh":
                path.chmod(0o755)
        run_git(["add", "."], source, env)
        run_git(["commit", "-q", "-m", "dev advance"], source, env)
        run_git(["branch", "dev"], source, env)
        run_git(["init", "--bare", "-q", str(remote)], self.root, env)
        run_git(["remote", "add", "origin", str(remote)], source, env)
        run_git(["push", "-q", "origin", "dev", "integration-test"], source, env)
        return remote

    def clone_integration(self, remote: Path, checkout: Path) -> None:
        checkout.parent.mkdir(parents=True, exist_ok=True)
        run_git(["clone", "-q", "--branch", "integration-test", str(remote), str(checkout)], checkout.parent, self.git_env())

    def git_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "GIT_AUTHOR_NAME": "Dogfood Sync Test",
                "GIT_AUTHOR_EMAIL": "dogfood-sync-test@example.invalid",
                "GIT_COMMITTER_NAME": "Dogfood Sync Test",
                "GIT_COMMITTER_EMAIL": "dogfood-sync-test@example.invalid",
                "GIT_AUTHOR_DATE": "2001-09-09T01:46:40Z",
                "GIT_COMMITTER_DATE": "2001-09-09T01:46:40Z",
            }
        )
        return env


class DogfoodSyncRestartTest(unittest.TestCase):
    def test_sync_resolves_platform_packages_after_host_checkout_reaches_target_branch(self) -> None:
        h = DogfoodSyncHarness()
        try:
            pkgs = h.dogfood_root / "substrate-dogfood" / "pkgs"
            host = h.dogfood_root / "substrate-dogfood" / "sub"
            run_sh = "#!/usr/bin/env bash\nshift\nexec \"$BIN\" \"$@\"\n"
            packages_remote = h.create_remote(
                "packages-remote",
                {"packages/github-devloop/fkst.toml": 'kind = "package"\nname = "github-devloop"\n', "scripts/run.sh": run_sh},
                {"packages/github-devloop/current.txt": "current\n", "scripts/run.sh": run_sh},
            )
            old_manifest = "[workspace]\nunits = []\n"
            new_manifest = textwrap.dedent(
                f"""\
                [workspace]
                units = []

                [[external_sources]]
                id = "fkst-packages-platform"
                git = {json.dumps(str(pkgs))}
                packages = ["github-devloop"]
                """
            )
            host_remote = h.create_remote("host-remote", {"fkst.workspace.toml": old_manifest}, {"fkst.workspace.toml": new_manifest})
            h.clone_integration(packages_remote, pkgs)
            h.clone_integration(host_remote, host)
            write_executable(
                h.fake_bin,
                "#!/usr/bin/env bash\nprintf 'EVENT=code_provenance ENGINE_VER=test PKG_VERS=github-devloop@test\\nMSG=event runtime running\\n'; sleep 15\n",
            )

            result = h.run_sync()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertNotIn("config-error", result.stdout + result.stderr)
            self.assertIn("substrate: stopped (use 'start' to launch)", result.stdout)
            self.assertIn('packages = ["github-devloop"]', (host / "fkst.workspace.toml").read_text(encoding="utf-8"))
        finally:
            h.close()

    def test_running_sync_validation_failure_does_not_kill_existing_supervise(self) -> None:
        h = DogfoodSyncHarness()
        old_pid = None
        old_proc = None
        try:
            pkgs = h.dogfood_root / "substrate-dogfood" / "pkgs"
            host = h.dogfood_root / "substrate-dogfood" / "sub"
            run_sh = "#!/usr/bin/env bash\nshift\nexec \"$BIN\" \"$@\"\n"
            packages_remote = h.create_remote(
                "packages-remote",
                {"packages/github-devloop/fkst.toml": 'kind = "package"\nname = "github-devloop"\n', "scripts/run.sh": run_sh},
                {"packages/github-devloop/current.txt": "current\n", "scripts/run.sh": run_sh},
            )
            manifest = textwrap.dedent(
                f"""\
                [workspace]
                units = []

                [[external_sources]]
                id = "fkst-packages-platform"
                git = {json.dumps(str(pkgs))}
                packages = ["github-devloop"]
                """
            )
            host_remote = h.create_remote(
                "host-remote",
                {"fkst.workspace.toml": manifest},
                {"fkst.workspace.toml": manifest, "README.md": "dev advance\n"},
            )
            h.clone_integration(packages_remote, pkgs)
            h.clone_integration(host_remote, host)
            old_platform_head = git_stdout(["rev-parse", "HEAD"], pkgs, h.git_env())[:8]
            durable = h.dogfood_root / "stable-durable-substrate"
            durable.mkdir(parents=True)
            old_proc = subprocess.Popen(["sleep", "60"])
            old_pid = old_proc.pid
            (durable / ".fkst-supervise.pid").write_text(f"{old_pid}\n", encoding="utf-8")
            write_executable(h.bin_dir / "pgrep", f"#!/usr/bin/env bash\nprintf '%s\\n' {old_pid}\n")
            (h.dogfood_root / "substrate-sv-100.log").write_text(
                "TIMESTAMP=2026-01-01T00:00:00Z LEVEL=info EVENT=code_provenance "
                f"ENGINE_VER=aaaaaaaa PKG_VERS=github-devloop@{old_platform_head}\n",
                encoding="utf-8",
            )
            write_executable(
                h.fake_bin,
                "#!/usr/bin/env bash\nprintf 'startup error: graph validation failed\\n'\nexit 17\n",
            )

            result = h.run_sync()

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("validation failed", result.stdout + result.stderr)
            self.assertTrue(pid_is_alive(old_pid), result.stdout + result.stderr)
            self.assertEqual((durable / ".fkst-supervise.pid").read_text(encoding="utf-8").strip(), str(old_pid))
        finally:
            if old_proc is not None:
                if old_proc.poll() is None:
                    old_proc.kill()
                old_proc.wait(timeout=3)
            elif old_pid is not None:
                kill_if_alive(old_pid)
            h.close()


if __name__ == "__main__":
    unittest.main()
