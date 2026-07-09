#!/usr/bin/env python3
"""Acceptance tests for rendering dogfood launchd plists."""

from __future__ import annotations

import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from host_run_equivalence_test import DogfoodLayout, REPO_ROOT, write_executable


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


if __name__ == "__main__":
    unittest.main()
