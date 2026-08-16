"""Mutation tests for the department failure-surface ratchet (#2996).

These are deliberately mutation-shaped rather than example-shaped. A check that still passes
when the thing it checks is removed is not a check, and a check satisfied by an unrelated edit
is worse than none -- both failure modes were observed on an earlier harness for #2991, which
survived deleting every guard it claimed to protect.

So each test either breaks the property and demands a message, or perturbs something irrelevant
and demands silence.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import check_repo_dept_failure_surface as check

REPO_ROOT = Path(__file__).resolve().parents[1]
PROTECTED = "packages/pkg/departments/worker/main.lua"
NAKED = "packages/pkg/departments/scanner/main.lua"
DEAD_LETTER = "packages/pkg/departments/dead_letter/main.lua"
PROBE = "packages/pkg/departments/test_probe/main.lua"

WITH_RETRY = """local spec = {
  consumes = { "q" },
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}
"""
WITH_WRAPPER = """local spec = { consumes = { "q" } }
return devloop_logging.wrap_pipeline_failure("worker", pipeline)
"""
NO_SURFACE = """local spec = { consumes = { "q" } }
"""


def messages(sources, allowlist, base=None):
    current = check.exposed_departments(sources)
    return check.ratchet_messages(current, allowlist, base if base is not None else allowlist)


def write_file(root: Path, relative: str, content: str) -> Path:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


class DeptFailureSurfaceTest(unittest.TestCase):
    def test_department_with_retry_policy_is_silent(self):
        self.assertEqual(messages({PROTECTED: WITH_RETRY}, set()), [])

    def test_department_with_failure_wrapper_is_silent(self):
        self.assertEqual(messages({PROTECTED: WITH_WRAPPER}, set()), [])

    def test_removing_the_retry_policy_makes_the_check_fire(self):
        """MUTATION: the property is removed, so the check MUST fail."""
        before = messages({PROTECTED: WITH_RETRY}, set())
        after = messages({PROTECTED: NO_SURFACE}, set())
        self.assertEqual(before, [])
        self.assertTrue(after, "removing retry+wrapper must produce a message")
        self.assertIn("neither an enabled `retry` table nor `wrap_pipeline_failure`", after[0])
        self.assertIn("pkg.worker", after[0])

    def test_removing_the_wrapper_makes_the_check_fire(self):
        """MUTATION: same property, other mechanism."""
        stripped = WITH_WRAPPER.replace("wrap_pipeline_failure", "some_other_helper")
        self.assertTrue(messages({PROTECTED: stripped}, set()))

    def test_unrelated_edit_does_not_satisfy_or_trip_the_check(self):
        """NEGATIVE CONTROL: an irrelevant change must not move the verdict either way.

        An earlier harness passed because *any* perturbation satisfied it. This asserts the
        check is coupled to the property and nothing else.
        """
        noisy = WITH_RETRY + "\n-- unrelated trailing comment\nlocal unused = 1\n"
        self.assertEqual(messages({PROTECTED: noisy}, set()), [])
        noisy_naked = NO_SURFACE + "\n-- unrelated trailing comment\n"
        self.assertTrue(messages({NAKED: noisy_naked}, set()))

    def test_dead_letter_is_structurally_exempt(self):
        self.assertTrue(check.is_structurally_exempt("pkg.dead_letter"))
        self.assertEqual(messages({DEAD_LETTER: NO_SURFACE}, set()), [])

    def test_test_probe_is_structurally_exempt(self):
        self.assertTrue(check.is_structurally_exempt("pkg.test_probe"))
        self.assertEqual(messages({PROBE: NO_SURFACE}, set()), [])

    def test_exemption_is_by_role_not_by_substring(self):
        """`dead_letter_replay` is not a DLQ consumer and must not inherit the exemption."""
        self.assertFalse(check.is_structurally_exempt("pkg.dead_letter_replay"))
        self.assertFalse(check.is_structurally_exempt("pkg.audit_test"))

    def test_allowlisted_department_is_silent_but_stale_entry_is_reported(self):
        allow = {"pkg.scanner"}
        self.assertEqual(messages({NAKED: NO_SURFACE}, allow), [])
        stale = messages({NAKED: WITH_RETRY}, allow)
        self.assertTrue(stale, "an allowlisted department that gained a surface must be reported")
        self.assertIn("stale allowlist entry", stale[0])

    def test_allowlist_growth_is_rejected(self):
        """MUTATION: the ratchet must only shrink."""
        base = set()
        grown = {"pkg.scanner"}
        grew = messages({NAKED: NO_SURFACE}, grown, base)
        self.assertTrue(grew)
        self.assertTrue(any("shrink-only" in m for m in grew))

    def test_new_department_cannot_be_silently_introduced(self):
        """A brand-new unprotected department is not covered by any existing allowlist."""
        allow = {"pkg.scanner"}
        fresh = messages({NAKED: NO_SURFACE, "packages/np/departments/nd/main.lua": NO_SURFACE}, allow)
        self.assertTrue(any("np.nd" in m for m in fresh))

    def test_wrapper_only_is_an_accepted_package_owned_log_surface(self):
        """The wrapper supplies an explicit log fact independently of engine retry materialization."""
        self.assertEqual(messages({PROTECTED: WITH_WRAPPER}, set()), [])

    def test_message_states_that_omitted_retry_inherits_reliable_host_defaults(self):
        fired = messages({NAKED: NO_SURFACE}, set())
        self.assertTrue(fired)
        self.assertIn("omitted `retry` inherits the engine's reliable host defaults", fired[0])
        self.assertIn("equivalent to `retry = {}`", fired[0])
        self.assertNotIn("dropped_no_retry_policy", fired[0])
        self.assertNotIn("only `retry`", fired[0])

    def test_dept_id_parses_package_and_department(self):
        self.assertEqual(check.dept_id(PROTECTED), "pkg.worker")
        self.assertIsNone(check.dept_id("packages/pkg/core.lua"))

    def test_retry_regex_requires_a_spec_table_not_a_mention(self):
        """A `retry` mentioned in prose or an unrelated require must not count as a surface."""
        mention = 'local spec = { consumes = { "q" } }\nlocal ci_repair_retry = require("core.ci_repair_retry")\n'
        self.assertIsNone(check.RETRY_RE.search(mention))
        self.assertTrue(messages({NAKED: mention}, set()))


class PinnedEngineRetryEquivalenceTest(unittest.TestCase):
    def test_omitted_retry_equals_empty_retry_under_host_overrides(self):
        framework = Path(os.environ["BIN"]).resolve()
        self.assertTrue(framework.is_file(), f"BIN is not a file: {framework}")
        self.assertTrue(os.access(framework, os.X_OK), f"BIN is not executable: {framework}")
        expected_pin = (REPO_ROOT / ".fkst/substrate-ref").read_text(encoding="utf-8").strip()

        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            provenance = temp / "provenance"
            provenance.mkdir()
            subprocess.run(
                ["git", "init", "--quiet"],
                cwd=provenance,
                check=True,
                text=True,
                capture_output=True,
            )
            init = subprocess.run(
                [str(framework), "init-package-repo"],
                cwd=provenance,
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(init.returncode, 0, init.stdout + init.stderr)
            actual_pin = (provenance / ".fkst-substrate-ref").read_text(encoding="utf-8").strip()
            self.assertEqual(actual_pin, expected_pin, "BIN was not built from the pinned substrate")

            fixture = temp / "fixture"
            fixture.mkdir()
            write_file(
                fixture,
                "fkst.toml",
                """kind = "package"
name = "fixture"
persistence_class = "stateless_adapter"

[code]
root = "."

[lib_deps]
libraries = []
""",
            )
            write_file(fixture, "fkst.workspace.toml", '[workspace]\nunits = ["."]\n')
            host_retry = {
                "max_attempts": "7",
                "base": "13s",
                "cap": "2m",
            }
            write_file(
                fixture,
                "fkst.env",
                "".join(
                    [
                        f"FKST_RETRY_DEFAULT_MAX_ATTEMPTS={host_retry['max_attempts']}\n",
                        f"FKST_RETRY_DEFAULT_BASE={host_retry['base']}\n",
                        f"FKST_RETRY_DEFAULT_CAP={host_retry['cap']}\n",
                    ]
                ),
            )
            probe = write_file(
                fixture,
                "departments/probe/main.lua",
                """local M = {}
M.spec = {
  consumes = { "trigger" },
  produces = { "omitted_jobs", "explicit_jobs" },
  graph_json = true,
  retry = false,
}
function pipeline(_)
  print("RETRY_GRAPH:" .. graph_json())
end
return M
""",
            )
            write_file(
                fixture,
                "departments/omitted/main.lua",
                """local M = {}
M.spec = { consumes = { "omitted_jobs" } }
function pipeline(_) end
return M
""",
            )
            write_file(
                fixture,
                "departments/explicit/main.lua",
                """local M = {}
M.spec = {
  consumes = { "explicit_jobs" },
  retry = {},
}
function pipeline(_) end
return M
""",
            )
            write_file(
                fixture,
                "raisers/tick.lua",
                'return { type = "cron", interval = "10s", produces = "trigger" }\n',
            )

            environment = os.environ.copy()
            for key in (
                "FKST_RETRY_DEFAULT_MAX_ATTEMPTS",
                "FKST_RETRY_DEFAULT_BASE",
                "FKST_RETRY_DEFAULT_CAP",
                "FKST_PACKAGE_ROOT",
                "FKST_PACKAGE_ROOTS",
            ):
                environment.pop(key, None)
            run = subprocess.run(
                [
                    str(framework),
                    "run",
                    str(probe),
                    "--project-root",
                    str(fixture),
                    "--package-root",
                    str(fixture),
                    "--owner-namespace",
                    "fixture",
                    "--event",
                    '{"queue":"fixture.trigger","payload":{},"ts":0}',
                ],
                cwd=fixture,
                env=environment,
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            graph_line = next(
                (line for line in run.stdout.splitlines() if line.startswith("RETRY_GRAPH:")),
                None,
            )
            self.assertIsNotNone(graph_line, run.stdout)
            graph = json.loads(graph_line.removeprefix("RETRY_GRAPH:"))
            departments = {
                node["name"]: node
                for node in graph["nodes"]
                if node["kind"] == "department"
            }
            omitted = departments["omitted"]["retry"]
            explicit = departments["explicit"]["retry"]
            expected = {
                "max_attempts": int(host_retry["max_attempts"]),
                "base": host_retry["base"],
                "cap": host_retry["cap"],
            }
            self.assertEqual(omitted, expected, "omitted retry did not inherit host overrides")
            self.assertEqual(explicit, expected, "retry = {} did not inherit host overrides")
            self.assertEqual(omitted, explicit)


if __name__ == "__main__":
    unittest.main()
