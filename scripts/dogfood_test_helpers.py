#!/usr/bin/env python3
"""Shared fixtures for dogfood operator script tests."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import textwrap
import time
import tomllib
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GOLDEN_PATH = REPO_ROOT / "scripts" / "host_run_equivalence_golden.json"
TARGETS = ("packages", "substrate", "website")
WEBSITE_PLATFORM_PACKAGES = " ".join(
    (
        "github-devloop",
        "github-devloop-pr",
        "github-devloop-integration",
        "github-devloop-intake",
        "github-devloop-workflow",
        "github-devloop-decompose",
        "github-devloop-ops",
        "github-proxy",
        "consensus",
        "github-external-pr-intake",
        "github-ratchet-migration-slicer",
        "idle-detector",
    )
)
STALE_WEBSITE_PACKAGES = "github-devloop github-devloop-pr github-devloop-integration"
FIXED_TS = "1760000000"


def self_workspace_platform_packages() -> str:
    workspace = tomllib.loads((REPO_ROOT / "fkst.workspace.toml").read_text(encoding="utf-8"))
    packages: list[str] = []
    for package in workspace.get("package", []):
        if isinstance(package, dict) and package.get("source", "workspace") == "workspace":
            name = package.get("name")
            if isinstance(name, str) and name:
                packages.append(name)
    if not packages:
        raise AssertionError("fkst.workspace.toml must declare self-host dogfood platform packages")
    return " ".join(packages)


PLATFORM_PACKAGES = self_workspace_platform_packages()
ALL_PLATFORM_PACKAGES = sorted(set(PLATFORM_PACKAGES.split()) | set(WEBSITE_PLATFORM_PACKAGES.split()))


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def make_fake_bin(path: Path) -> None:
    write_executable(
        path,
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import json
            import os
            import sys
            import time
            from pathlib import Path

            out = Path(os.environ["CAPTURE_FILE"])
            keys = [
                "BIN",
                "FKST_GITHUB_REPO",
                "FKST_GITHUB_WRITE",
                "FKST_GITHUB_BOT_LOGIN",
                "FKST_DEVLOOP_UPSTREAM_BRANCH",
                "FKST_DEVLOOP_INTEGRATION_BRANCH",
                "FKST_DEVLOOP_ROLLUP_MERGE",
                "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
                "FKST_GITHUB_PROXY_POLL_LABEL_PREFIX",
                "FKST_RUNTIME_ROOT",
                "FKST_DURABLE_ROOT",
                "FKST_RATE_POOL_ROOT",
                "FKST_DEVLOOP_BOARD_CMD",
            ]
            payload = {
                "cwd": os.getcwd(),
                "argv": sys.argv,
                "env": {key: os.environ[key] for key in keys if key in os.environ},
            }
            out.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\\n", encoding="utf-8")
            print("TIMESTAMP=2026-01-01T00:00:00Z LEVEL=info EVENT=code_provenance ENGINE_VER=test-engine PKG_VERS=github-devloop@test-package", flush=True)
            print("TIMESTAMP=2026-01-01T00:00:00Z LEVEL=INFO handles=1 MSG=event runtime running", flush=True)
            time.sleep(15)
            """
        ),
    )


def make_fake_date(bin_dir: Path) -> None:
    write_executable(
        bin_dir / "date",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            if [ "${{1:-}}" = "+%s" ]; then
              printf '%s\\n' "{FIXED_TS}"
              exit 0
            fi
            exec /bin/date "$@"
            """
        ),
    )


def make_fake_tools(bin_dir: Path) -> None:
    write_executable(
        bin_dir / "cargo",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    make_fake_date(bin_dir)


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


class DogfoodLayout:
    def __init__(
        self,
        root: Path,
        dogfood_script: str,
        *,
        stale_website_manifest: bool = False,
    ) -> None:
        self.root = root
        self.dogfood_root = root / "dogfood"
        self.skill_dir = root / "skill"
        self.bin_dir = root / "bin"
        self.capture = root / "capture.json"
        self.fake_bin = root / "fake-fkst-framework"
        self.launchctl_log = root / "launchctl.log"
        self.launchctl_state = root / "launchctl-state.json"
        self.kill_log = root / "kill.log"
        self.substrate_src = root / "substrate-src"
        self.script = self.skill_dir / "dogfood.sh"

        self.skill_dir.mkdir(parents=True)
        self.bin_dir.mkdir()
        self.substrate_src.mkdir()
        (self.substrate_src / "crates").mkdir()
        make_fake_tools(self.bin_dir)
        make_fake_bin(self.fake_bin)
        write_executable(self.script, dogfood_script)
        shutil.copy2(
            REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "workspace_manifest.py",
            self.skill_dir / "workspace_manifest.py",
        )
        shutil.copy2(
            REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood_launchd.sh",
            self.skill_dir / "dogfood_launchd.sh",
        )
        self._write_fake_launchctl()
        self._write_fake_kill()
        self.stale_website_manifest = stale_website_manifest
        self.platform_revs: dict[Path, str] = {}
        self._populate_repos()

    def _write_fake_launchctl(self) -> None:
        write_executable(
            self.bin_dir / "launchctl",
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import plistlib
                import subprocess
                import sys
                from pathlib import Path

                log = Path(os.environ["LAUNCHCTL_LOG"])
                state_path = Path(os.environ["LAUNCHCTL_STATE"])
                state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
                log.write_text(log.read_text(encoding="utf-8") + " ".join(sys.argv[1:]) + "\\n" if log.exists() else " ".join(sys.argv[1:]) + "\\n", encoding="utf-8")

                def save() -> None:
                    state_path.write_text(json.dumps(state, sort_keys=True, indent=2) + "\\n", encoding="utf-8")

                cmd = sys.argv[1] if len(sys.argv) > 1 else ""
                if cmd == "bootstrap":
                    plist_path = Path(sys.argv[3])
                    payload = plistlib.loads(plist_path.read_bytes())
                    label = payload["Label"]
                    state[label] = {
                        "plist": str(plist_path),
                        "argv": payload["ProgramArguments"],
                        "env": payload.get("EnvironmentVariables", {}),
                        "pid": 0,
                    }
                    save()
                    raise SystemExit(0)
                if cmd == "bootout":
                    target = sys.argv[-1]
                    for label, record in list(state.items()):
                        if record.get("plist") == target or target.endswith("/" + label):
                            state.pop(label, None)
                    save()
                    raise SystemExit(0)
                if cmd == "kickstart":
                    label = sys.argv[-1].split("/")[-1]
                    record = state.get(label)
                    if record is not None and os.environ.get("DOGFOOD_FAKE_LAUNCHCTL_SPAWN") == "1":
                        env = os.environ.copy()
                        env.update(record.get("env", {}))
                        proc = subprocess.Popen(record["argv"], env=env)
                        record["pid"] = proc.pid
                        save()
                    raise SystemExit(0)
                if cmd == "print":
                    label = sys.argv[-1].split("/")[-1]
                    pid = state.get(label, {}).get("pid", 0)
                    print(f"    pid = {pid}")
                    raise SystemExit(0)
                raise SystemExit(0)
                """
            ),
        )

    def _write_fake_kill(self) -> None:
        write_executable(
            self.bin_dir / "fake-kill",
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import sys
                from pathlib import Path

                Path(os.environ["DOGFOOD_KILL_LOG"]).write_text(
                    " ".join(sys.argv[1:]) + "\\n",
                    encoding="utf-8",
                )
                new_pid = os.environ.get("DOGFOOD_FAKE_KILL_REDIRECT_PID")
                state_path = Path(os.environ["LAUNCHCTL_STATE"])
                if new_pid and state_path.exists():
                    state = json.loads(state_path.read_text(encoding="utf-8"))
                    old_pid = int(sys.argv[-1])
                    for record in state.values():
                        if int(record.get("pid", 0)) == old_pid:
                            record["pid"] = int(new_pid)
                    state_path.write_text(json.dumps(state, sort_keys=True, indent=2) + "\\n", encoding="utf-8")
                """
            ),
        )

    def _populate_repos(self) -> None:
        for host in (
            self.dogfood_root / "pkgs-dogfood",
            self.dogfood_root / "substrate-dogfood" / "pkgs",
            self.dogfood_root / "substrate-dogfood" / "sub",
            self.dogfood_root / "website-dogfood" / "pkgs",
            self.dogfood_root / "website-dogfood" / "site",
        ):
            (host / ".git").mkdir(parents=True)

        platform_roots = (
            self.dogfood_root / "pkgs-dogfood",
            self.dogfood_root / "substrate-dogfood" / "pkgs",
            self.dogfood_root / "website-dogfood" / "pkgs",
        )
        for platform in platform_roots:
            for package in ALL_PLATFORM_PACKAGES:
                (platform / "packages" / package).mkdir(parents=True, exist_ok=True)
                (platform / "packages" / package / "fkst.toml").write_text(
                    f'kind = "package"\nname = "{package}"\n',
                    encoding="utf-8",
                )
            (platform / "scripts").mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO_ROOT / "scripts" / "run.sh", platform / "scripts" / "run.sh")
            shutil.copy2(REPO_ROOT / "scripts" / "test_affected.sh", platform / "scripts" / "test_affected.sh")
            shutil.copy2(REPO_ROOT / "scripts" / "host_entry.sh", platform / "scripts" / "host_entry.sh")
            shutil.copy2(REPO_ROOT / "scripts" / "host_run.sh", platform / "scripts" / "host_run.sh")
            shutil.copy2(REPO_ROOT / "scripts" / "composed_manifest.sh", platform / "scripts" / "composed_manifest.sh")
            shutil.copy2(REPO_ROOT / "scripts" / "composed_conformance.sh", platform / "scripts" / "composed_conformance.sh")
            shutil.copy2(REPO_ROOT / "scripts" / "check_repo_intake_routing.py", platform / "scripts" / "check_repo_intake_routing.py")
            shutil.copy2(REPO_ROOT / "scripts" / "intake_policy_slots.json", platform / "scripts" / "intake_policy_slots.json")
            shutil.copy2(REPO_ROOT / "scripts" / "bin_bootstrap.sh", platform / "scripts" / "bin_bootstrap.sh")
            shutil.copy2(REPO_ROOT / "scripts" / "bin_cache.py", platform / "scripts" / "bin_cache.py")
            self.platform_revs[platform] = self._make_platform_git_repo(platform)

        (self.dogfood_root / "website-dogfood" / "site" / ".fkst" / "local-packages" / "site-board").mkdir(
            parents=True,
            exist_ok=True,
        )

        for host, platform in (
            (self.dogfood_root / "pkgs-dogfood", self.dogfood_root / "pkgs-dogfood"),
            (self.dogfood_root / "substrate-dogfood" / "sub", self.dogfood_root / "substrate-dogfood" / "pkgs"),
            (self.dogfood_root / "website-dogfood" / "site", self.dogfood_root / "website-dogfood" / "pkgs"),
        ):
            self._write_host_workspace(host, platform)
        for platform in platform_roots:
            self._advance_platform_git_repo(platform)

    def _write_host_workspace(self, host: Path, platform: Path) -> None:
        if host == platform:
            manifest = "[workspace]\nunits = [\"packages/*\"]\n"
            for package in PLATFORM_PACKAGES.split():
                manifest += (
                    "\n[[package]]\n"
                    f"name = {json.dumps(package)}\n"
                    'source = "workspace"\n'
                    'version = "workspace"\n'
                )
            (host / "fkst.workspace.toml").write_text(manifest, encoding="utf-8")
            return

        packages = PLATFORM_PACKAGES.split()
        if host == self.dogfood_root / "website-dogfood" / "site":
            packages = WEBSITE_PLATFORM_PACKAGES.split()
            if self.stale_website_manifest:
                packages = STALE_WEBSITE_PACKAGES.split()
        (host / "fkst.workspace.toml").write_text(
            textwrap.dedent(
                f"""\
                [workspace]
                units = [".fkst/local-packages/*"]

                [[external_sources]]
                id = "fkst-packages-platform"
                git = {json.dumps(str(platform))}
                packages = {json.dumps(packages)}
                """
            ),
            encoding="utf-8",
        )
        (host / "fkst.lock").write_text(
            textwrap.dedent(
                f"""\
                [[external_source]]
                id = "fkst-packages-platform"
                git = {json.dumps(str(platform))}

                [external_source.resolved]
                rev = {json.dumps(self.platform_revs[platform])}
                tree_sha256 = "sha256-test"
                """
            ),
            encoding="utf-8",
        )

    def _make_platform_git_repo(self, platform: Path) -> str:
        git_env = self._git_env()
        run_git(["init", "-q"], cwd=platform, env=git_env)
        run_git(["add", "."], cwd=platform, env=git_env)
        run_git(["commit", "-q", "-m", "seed"], cwd=platform, env=git_env)
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=platform,
            env=git_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def _advance_platform_git_repo(self, platform: Path) -> None:
        marker = platform / "packages" / "github-proxy" / "current.txt"
        marker.write_text("advanced local platform checkout\n", encoding="utf-8")
        git_env = self._git_env()
        run_git(["add", "packages/github-proxy/current.txt"], cwd=platform, env=git_env)
        run_git(["commit", "-q", "-m", "advance local platform"], cwd=platform, env=git_env)

    def _git_env(self) -> dict[str, str]:
        git_env = os.environ.copy()
        git_env.update(
            {
                "GIT_AUTHOR_NAME": "Host Run Equivalence",
                "GIT_AUTHOR_EMAIL": "host-run-equivalence@example.invalid",
                "GIT_COMMITTER_NAME": "Host Run Equivalence",
                "GIT_COMMITTER_EMAIL": "host-run-equivalence@example.invalid",
                "GIT_AUTHOR_DATE": "2001-09-09T01:46:40Z",
                "GIT_COMMITTER_DATE": "2001-09-09T01:46:40Z",
            }
        )
        return git_env

    def env(self, target: str) -> dict[str, str]:
        base_path = os.environ.get("PATH", "")
        env = {
            "PATH": f"{self.bin_dir}:{base_path}",
            "DOGFOOD_ROOT": str(self.dogfood_root),
            "DOGFOOD_REPOS": target,
            "DOGFOOD_CONFIG": str(self.root / "missing-config.sh"),
            "SUBSTRATE_SRC": str(self.substrate_src),
            "BIN": str(self.fake_bin),
            "BOT": "test-bot",
            "GH_ORG": "ExampleOrg",
            "UPSTREAM_BRANCH": "dev",
            "INTEGRATION_BRANCH": "integration-test",
            "ROLLUP_MERGE": "auto",
            "MANAGED_BOT_LOGINS": "test-bot,peer-bot",
            "RATE_POOL": str(self.dogfood_root / "rate-pools"),
            "LOGDIR": str(self.dogfood_root),
            "CAPTURE_FILE": str(self.capture),
            "LAUNCHCTL_LOG": str(self.launchctl_log),
            "LAUNCHCTL_STATE": str(self.launchctl_state),
            "DOGFOOD_LAUNCH_AGENTS_DIR": str(self.root / "LaunchAgents"),
            "DOGFOOD_LAUNCHD_DOMAIN": "gui/501",
            "DOGFOOD_KILL_CMD": str(self.bin_dir / "fake-kill"),
            "DOGFOOD_KILL_LOG": str(self.kill_log),
            "FKST_NO_AUTOBUILD": "1",
            "FKST_GITHUB_WRITE": "0",
            "DUR_PACKAGES": str(self.dogfood_root / "stable-durable-packages"),
            "DUR_SUBSTRATE": str(self.dogfood_root / "stable-durable-substrate"),
            "DUR_WEBSITE": str(self.dogfood_root / "stable-durable-website"),
        }
        env["DOGFOOD_REPOS"] = target
        return env

    def launch(self, target: str) -> dict[str, object]:
        self.capture.unlink(missing_ok=True)
        env = self.env(target)
        env["DOGFOOD_FAKE_LAUNCHCTL_SPAWN"] = "1"
        result = subprocess.run(
            [str(self.script), "start", target],
            cwd=self.root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"dogfood start {target} failed with {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.capture.exists():
                return json.loads(self.capture.read_text(encoding="utf-8"))
            time.sleep(0.05)
        raise AssertionError(f"dogfood start {target} did not invoke fake supervise\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")

    def run_start(self, target: str) -> subprocess.CompletedProcess[str]:
        self.capture.unlink(missing_ok=True)
        return subprocess.run(
            [str(self.script), "start", target],
            cwd=self.root,
            env=self.env(target),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_sync(self, target: str) -> subprocess.CompletedProcess[str]:
        self.capture.unlink(missing_ok=True)
        return subprocess.run(
            [str(self.script), "sync", target],
            cwd=self.root,
            env=self.env(target),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

