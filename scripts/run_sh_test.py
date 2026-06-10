#!/usr/bin/env python3
"""Behavior tests for scripts/run.sh engine resolution."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import textwrap
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]


def write_executable(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RunShHarness:
    def __init__(self, case: unittest.TestCase, pin: str = "dev") -> None:
        self.case = case
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        self.home = Path(self.tmp.name) / "home"
        self.xdg_cache = Path(self.tmp.name) / "cache"
        self.bin_dir = Path(self.tmp.name) / "bin"
        self.log = Path(self.tmp.name) / "calls.log"
        self.root.mkdir()
        self.home.mkdir()
        self.xdg_cache.mkdir()
        self.bin_dir.mkdir()
        self._copy_runner(pin)
        self._write_fake_tools()

    def close(self) -> None:
        self.tmp.cleanup()

    def _copy_runner(self, pin: str) -> None:
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(ROOT / "scripts" / "run.sh", scripts / "run.sh")
        shutil.copy2(ROOT / "scripts" / "resolve_substrate_ref.py", scripts / "resolve_substrate_ref.py")
        write_executable(
            scripts / "check_repo.py",
            "#!/usr/bin/env python3\nraise SystemExit(0)\n",
        )
        write_executable(
            scripts / "check_repo_test.py",
            "#!/usr/bin/env python3\nraise SystemExit(0)\n",
        )
        write_executable(
            scripts / "run_sh_test.py",
            "#!/usr/bin/env python3\nraise SystemExit(0)\n",
        )
        (self.root / ".fkst-substrate-ref").write_text(pin + "\n", encoding="utf-8")
        test_dir = self.root / "packages" / "sample" / "tests"
        test_dir.mkdir(parents=True)
        (test_dir / "sample_test.lua").write_text("return { test_sample = function(t) t.ok(true) end }\n", encoding="utf-8")

    def _write_fake_tools(self) -> None:
        write_executable(
            self.bin_dir / "git",
            r"""#!/usr/bin/env bash
            set -euo pipefail
            echo "git $*" >> "$FKST_RUN_SH_TEST_LOG"
            if [ "${1:-}" = "clone" ]; then
              checkout="$3"
              mkdir -p "$checkout/.git"
              printf '[package]\nname = "fake"\n' > "$checkout/Cargo.toml"
              exit 0
            fi
            if [ "${1:-}" = "-C" ]; then
              shift 2
              case "${1:-}" in
                remote|fetch|checkout) exit 0 ;;
                rev-parse)
                  ref="${4:-}"
                  case "$ref" in
                    refs/remotes/origin/*) exit 0 ;;
                    *) exit 1 ;;
                  esac
                  ;;
              esac
            fi
            exit 0
            """,
        )
        write_executable(
            self.bin_dir / "cargo",
            r"""#!/usr/bin/env bash
            set -euo pipefail
            echo "cargo $*" >> "$FKST_RUN_SH_TEST_LOG"
            manifest=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--manifest-path" ]; then
                manifest="$2"
                shift 2
              else
                shift
              fi
            done
            checkout="$(dirname "$manifest")"
            mkdir -p "$checkout/target/debug"
            cat > "$checkout/target/debug/fkst-framework" <<'ENGINE'
#!/usr/bin/env bash
set -euo pipefail
echo "engine $*" >> "$FKST_RUN_SH_TEST_LOG"
if [ "${1:-}" = "--self-test" ]; then
  exit 0
fi
if [ "${1:-}" = "conformance" ]; then
  exit 0
fi
if [ "${1:-}" = "test" ]; then
  report=""
  owner=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report-json) report="$2"; shift 2 ;;
      --package-root) owner="$(basename "$2")"; shift 2 ;;
      *) shift ;;
    esac
  done
  cat > "$report" <<JSON
{"schema":"fkst.test.report.v1","summary":{"failed":0},"tests":[{"status":"pass","owner_namespace":"$owner","file":"tests/sample_test.lua"}]}
JSON
  exit 0
fi
exit 1
ENGINE
            chmod +x "$checkout/target/debug/fkst-framework"
            """,
        )

    def env(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        env = {
            "HOME": str(self.home),
            "XDG_CACHE_HOME": str(self.xdg_cache),
            "PATH": f"{self.bin_dir}:/usr/bin:/bin",
            "FKST_RUN_SH_TEST_LOG": str(self.log),
        }
        if extra:
            env.update(extra)
        return env

    def run(self, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "scripts/run.sh", "test"],
            cwd=self.root,
            env=self.env(extra_env),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def log_text(self) -> str:
        if not self.log.exists():
            return ""
        return self.log.read_text(encoding="utf-8")


class RunShBootstrapTest(unittest.TestCase):
    def test_all_miss_bootstraps_and_reuses_cached_checkout(self) -> None:
        harness = RunShHarness(self)
        try:
            first = harness.run()
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            second = harness.run()
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            log = harness.log_text()
            self.assertEqual(log.count("git clone https://github.com/ChronoAIProject/fkst-substrate.git"), 1)
            self.assertGreaterEqual(log.count("git -C "), 2)
            self.assertGreaterEqual(log.count("cargo build --manifest-path"), 2)
            self.assertIn("engine --self-test", log)
        finally:
            harness.close()

    def test_owner_repo_pin_controls_bootstrap_repository_and_ref(self) -> None:
        harness = RunShHarness(self, pin="ExampleOrg/example-substrate@feature/ref")
        try:
            result = harness.run()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            log = harness.log_text()
            self.assertIn("git clone https://github.com/ExampleOrg/example-substrate.git", log)
            self.assertIn("checkout --detach refs/remotes/origin/feature/ref", log)
        finally:
            harness.close()

    def test_autobuild_disabled_fails_without_git_or_cargo_calls(self) -> None:
        harness = RunShHarness(self)
        try:
            result = harness.run({"FKST_NO_AUTOBUILD": "1"})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fkst-bin-unresolved-autobuild-disabled", result.stderr)
            self.assertEqual(harness.log_text(), "")
        finally:
            harness.close()

    def test_invalid_explicit_bin_does_not_fallback(self) -> None:
        harness = RunShHarness(self)
        try:
            result = harness.run({"BIN": str(harness.root / "missing-framework")})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("binary is not executable from $BIN", result.stderr)
            self.assertEqual(harness.log_text(), "")
        finally:
            harness.close()

    def test_invalid_env_bin_does_not_fallback(self) -> None:
        harness = RunShHarness(self)
        try:
            (harness.root / ".env").write_text("BIN=/definitely/not/fkst-framework\n", encoding="utf-8")
            result = harness.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("binary is not executable from .env", result.stderr)
            self.assertEqual(harness.log_text(), "")
        finally:
            harness.close()


if __name__ == "__main__":
    unittest.main()
