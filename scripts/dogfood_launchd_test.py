#!/usr/bin/env python3
"""Acceptance tests for rendering dogfood launchd plists."""

from __future__ import annotations

import plistlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from dogfood_test_helpers import DogfoodLayout, REPO_ROOT, write_executable


class DogfoodLaunchdTest(unittest.TestCase):
    def test_render_launchd_emits_structural_launchagent_without_host_mutation(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "launchd", script)
            write_executable(
                layout.bin_dir / "launchctl",
                "#!/usr/bin/env bash\nprintf 'launchctl must not be called\\n' >&2\nexit 99\n",
            )

            result = subprocess.run(
                [str(layout.script), "render-launchd", "website"],
                cwd=layout.root,
                env=layout.env("website"),
                text=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8") + result.stdout.decode("utf-8"))
            self.assertFalse(layout.capture.exists(), "render-launchd must not start supervise")
            plist = plistlib.loads(result.stdout)
            self.assertEqual(plist["Label"], "com.fkst.dogfood.ExampleOrg.website")
            self.assertTrue(plist["KeepAlive"])
            self.assertTrue(plist["AbandonProcessGroup"])
            self.assertNotIn("RunAtLoad", plist)

            argv = plist["ProgramArguments"]
            self.assertEqual(argv[0], str(layout.dogfood_root / "website-dogfood" / "pkgs" / "scripts" / "run.sh"))
            self.assertEqual(argv[1], "supervise")
            self.assertIn("--restart", argv)
            self.assertIn("--project-root", argv)
            self.assertEqual(
                argv[argv.index("--project-root") + 1],
                str(layout.dogfood_root / "website-dogfood" / "site"),
            )
            self.assertIn("--platform-root", argv)
            self.assertEqual(
                argv[argv.index("--platform-root") + 1],
                str(layout.dogfood_root / "website-dogfood" / "pkgs"),
            )
            self.assertIn("--durable-root", argv)
            self.assertEqual(
                argv[argv.index("--durable-root") + 1],
                str(layout.dogfood_root / "stable-durable-website"),
            )
            self.assertIn("--host-packages", argv)
            self.assertEqual(argv[argv.index("--host-packages") + 1], "site-board")
            self.assertNotIn("nohup", argv)
            self.assertNotIn("launchctl", argv)

            env = plist["EnvironmentVariables"]
            self.assertEqual(env["FKST_GITHUB_REPO"], "ExampleOrg/fkst-website")
            self.assertEqual(env["FKST_GITHUB_WRITE"], "1")
            self.assertEqual(env["FKST_DEVLOOP_INTEGRATION_BRANCH"], "integration-test")
            self.assertEqual(env["FKST_RATE_POOL_ROOT"], str(layout.dogfood_root / "rate-pools"))
            self.assertEqual(plist["StandardOutPath"], str(layout.dogfood_root / "website-sv.log"))
            self.assertEqual(plist["StandardErrorPath"], str(layout.dogfood_root / "website-sv.log"))

    def test_install_launchd_writes_canonical_plist_and_bootstraps_idempotently(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "install", script)

            first = subprocess.run(
                [str(layout.script), "install-launchd", "packages"],
                cwd=layout.root,
                env=layout.env("packages"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            second = subprocess.run(
                [str(layout.script), "install-launchd", "packages"],
                cwd=layout.root,
                env=layout.env("packages"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
            self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
            plist_path = layout.root / "LaunchAgents" / "com.fkst.dogfood.ExampleOrg.packages.plist"
            self.assertTrue(plist_path.exists())
            plist = plistlib.loads(plist_path.read_bytes())
            self.assertEqual(plist["Label"], "com.fkst.dogfood.ExampleOrg.packages")
            self.assertTrue(plist["AbandonProcessGroup"])
            self.assertTrue(plist["KeepAlive"])
            self.assertNotIn("RunAtLoad", plist)
            self.assertFalse(layout.capture.exists(), "install-launchd must not directly start supervise")
            log = layout.launchctl_log.read_text(encoding="utf-8")
            self.assertIn(f"bootstrap gui/501 {plist_path}", log)
            self.assertIn("kickstart -k gui/501/com.fkst.dogfood.ExampleOrg.packages", log)
            self.assertFalse(list(layout.root.glob("*.plist")), "LaunchAgent artifacts must stay outside the repo root")

    def test_start_and_restart_route_through_launchd_not_nohup(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "start-restart", script)

            start = layout.run_start("website")

            self.assertEqual(start.returncode, 0, start.stderr + start.stdout)
            self.assertFalse(layout.capture.exists())
            start_log = layout.launchctl_log.read_text(encoding="utf-8")
            self.assertIn("bootstrap gui/501", start_log)
            self.assertIn("kickstart -k gui/501/com.fkst.dogfood.ExampleOrg.website", start_log)
            self.assertNotIn("nohup", script)

            layout.launchctl_log.unlink(missing_ok=True)
            write_executable(
                layout.bin_dir / "git",
                "#!/usr/bin/env bash\ncase \"$*\" in *rev-parse*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' ;; *) exit 0 ;; esac\n",
            )
            restart = subprocess.run(
                [str(layout.script), "restart", "website"],
                cwd=layout.root,
                env=layout.env("website"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(restart.returncode, 0, restart.stderr + restart.stdout)
            restart_log = layout.launchctl_log.read_text(encoding="utf-8")
            self.assertIn("bootstrap gui/501", restart_log)
            self.assertIn("kickstart -k gui/501/com.fkst.dogfood.ExampleOrg.website", restart_log)
            self.assertFalse(layout.capture.exists())

    def test_stale_launchd_units_are_removed_on_reconcile(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "stale", script)
            agents = layout.root / "LaunchAgents"
            agents.mkdir()
            stale_deleted = agents / "com.fkst.dogfood.ExampleOrg.packages-old.plist"
            stale_missing_abandon = agents / "com.fkst.dogfood.ExampleOrg.packages.plist"
            stale_deleted.write_bytes(
                plistlib.dumps(
                    {
                        "Label": "com.fkst.dogfood.ExampleOrg.packages-old",
                        "ProgramArguments": [str(layout.root / "deleted-run.sh"), "supervise"],
                        "EnvironmentVariables": {},
                        "KeepAlive": True,
                    }
                )
            )
            stale_missing_abandon.write_bytes(
                plistlib.dumps(
                    {
                        "Label": "com.fkst.dogfood.ExampleOrg.packages",
                        "ProgramArguments": ["noncanonical"],
                        "EnvironmentVariables": {},
                        "KeepAlive": True,
                    }
                )
            )

            result = subprocess.run(
                [str(layout.script), "install-launchd", "packages"],
                cwd=layout.root,
                env=layout.env("packages"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertFalse(stale_deleted.exists())
            canonical = plistlib.loads(stale_missing_abandon.read_bytes())
            self.assertTrue(canonical["AbandonProcessGroup"])
            self.assertNotEqual(canonical["ProgramArguments"], ["noncanonical"])
            self.assertIn("removing stale launchd unit", result.stdout)

    def test_reconcile_preserves_conflicting_plist_when_bootout_fails(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "failed-reconcile-bootout", script)
            agents = layout.root / "LaunchAgents"
            agents.mkdir()
            stale = agents / "com.fkst.dogfood.ExampleOrg.packages-old.plist"
            stale.write_bytes(
                plistlib.dumps(
                    {
                        "Label": "com.fkst.dogfood.ExampleOrg.packages-old",
                        "ProgramArguments": [str(layout.root / "deleted-run.sh"), "supervise"],
                        "EnvironmentVariables": {},
                        "KeepAlive": True,
                    }
                )
            )
            write_executable(
                layout.bin_dir / "launchctl",
                "#!/usr/bin/env bash\n[ \"${1:-}\" != \"bootout\" ]\n",
            )

            result = subprocess.run(
                [str(layout.script), "install-launchd", "packages"],
                cwd=layout.root,
                env=layout.env("packages"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(stale.exists())
            self.assertIn("failed to unload stale launchd unit", result.stderr)

    def test_uninstall_preserves_canonical_plist_when_bootout_fails(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "failed-uninstall-bootout", script)
            install = subprocess.run(
                [str(layout.script), "install-launchd", "packages"],
                cwd=layout.root,
                env=layout.env("packages"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(install.returncode, 0, install.stderr + install.stdout)
            plist_path = layout.root / "LaunchAgents" / "com.fkst.dogfood.ExampleOrg.packages.plist"
            write_executable(
                layout.bin_dir / "launchctl",
                "#!/usr/bin/env bash\n[ \"${1:-}\" != \"bootout\" ]\n",
            )

            result = subprocess.run(
                [str(layout.script), "uninstall-launchd", "packages"],
                cwd=layout.root,
                env=layout.env("packages"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(plist_path.exists())
            self.assertIn("failed to unload launchd authority", result.stderr)

    def test_doctor_reports_missing_restart_authority_for_direct_supervise(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "doctor", script)
            env = layout.env("packages")
            write_executable(layout.bin_dir / "pgrep", "#!/usr/bin/env bash\nprintf '12345\\n'\n")
            write_executable(
                layout.bin_dir / "ps",
                "#!/usr/bin/env bash\ncase \"$*\" in *command*) printf 'scripts/run.sh supervise --project-root "
                + str(layout.dogfood_root / "pkgs-dogfood")
                + " --durable-root "
                + str(layout.dogfood_root / "stable-durable-packages")
                + "\\n' ;; *) printf '00:01\\n' ;; esac\n",
            )
            (layout.dogfood_root / "packages-sv-100.log").write_text(
                "TIMESTAMP=2026-01-01T00:00:00Z LEVEL=info EVENT=code_provenance "
                "ENGINE_VER=aaaaaaaa PKG_VERS=github-devloop@bbbbbbbb\n",
                encoding="utf-8",
            )
            write_executable(
                layout.bin_dir / "git",
                "#!/usr/bin/env bash\ncase \"$*\" in *rev-parse*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' ;; *) exit 0 ;; esac\n",
            )

            result = subprocess.run(
                [str(layout.script), "doctor", "packages"],
                cwd=layout.root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("NO-RESTART-AUTHORITY", result.stdout)

    def test_kill_test_requires_new_pid_with_canonical_argv(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "kill-test", script)
            install = subprocess.run(
                [str(layout.script), "install-launchd", "packages"],
                cwd=layout.root,
                env=layout.env("packages"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(install.returncode, 0, install.stderr + install.stdout)
            state = json.loads(layout.launchctl_state.read_text(encoding="utf-8"))
            state["com.fkst.dogfood.ExampleOrg.packages"]["pid"] = 111
            layout.launchctl_state.write_text(json.dumps(state), encoding="utf-8")
            plist = plistlib.loads((layout.root / "LaunchAgents" / "com.fkst.dogfood.ExampleOrg.packages.plist").read_bytes())
            canonical_argv = " ".join(plist["ProgramArguments"])
            write_executable(
                layout.bin_dir / "ps",
                "#!/usr/bin/env bash\nif [ \"${*: -1}\" = \"222\" ]; then printf '%s\\n'; else exit 1; fi\n"
                % canonical_argv.replace("%", "%%"),
            )
            env = layout.env("packages")
            env["DOGFOOD_FAKE_KILL_REDIRECT_PID"] = "222"
            env["DOGFOOD_LAUNCHD_RESTART_BUDGET_SECONDS"] = "1"

            result = subprocess.run(
                [str(layout.script), "kill-test", "packages"],
                cwd=layout.root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("kill-test ok old_pid=111 new_pid=222", result.stdout)
            self.assertEqual(layout.kill_log.read_text(encoding="utf-8"), "-TERM 111\n")

    def test_kill_test_fails_for_same_pid_or_noncanonical_argv(self) -> None:
        script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(Path(tmp) / "kill-test-fail", script)
            install = subprocess.run(
                [str(layout.script), "install-launchd", "packages"],
                cwd=layout.root,
                env=layout.env("packages"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(install.returncode, 0, install.stderr + install.stdout)
            state = json.loads(layout.launchctl_state.read_text(encoding="utf-8"))
            state["com.fkst.dogfood.ExampleOrg.packages"]["pid"] = 111
            layout.launchctl_state.write_text(json.dumps(state), encoding="utf-8")
            write_executable(layout.bin_dir / "ps", "#!/usr/bin/env bash\nprintf 'wrong command\\n'\n")
            env = layout.env("packages")
            env["DOGFOOD_FAKE_KILL_REDIRECT_PID"] = "222"
            env["DOGFOOD_LAUNCHD_RESTART_BUDGET_SECONDS"] = "1"

            result = subprocess.run(
                [str(layout.script), "kill-test", "packages"],
                cwd=layout.root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("noncanonical argv", result.stdout)


if __name__ == "__main__":
    unittest.main()
