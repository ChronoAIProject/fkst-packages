#!/usr/bin/env python3
"""Behavior test for dogfood.sh sweep_stale_tmp_receipts (#2616).

github-proxy writes transient gh --body-file receipt files under /tmp with no cleanup (no file.remove
primitive). This operator patrol reaps receipts older than DOGFOOD_RECEIPT_SWEEP_HOURS. This test drives
the real function (dogfood.sh is source-guarded) against a temp sweep root and asserts: an old receipt is
reaped, a fresh receipt is kept (in-flight safety), and an unrelated file is never touched.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DOGFOOD = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh"


def _run_sweep(root: Path) -> str:
    result = subprocess.run(
        ["/bin/bash", "-c", f'source "{DOGFOOD}"\nsweep_stale_tmp_receipts'],
        cwd=str(REPO_ROOT),
        env={**os.environ, "DOGFOOD_REPOS": "packages", "DOGFOOD_RECEIPT_SWEEP_ROOT": str(root)},
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.stdout + result.stderr


class TmpReceiptSweep(unittest.TestCase):
    def test_reaps_old_receipts_keeps_fresh_and_unrelated(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            seven_h = time.time() - 7 * 3600
            old_proxy = d / "fkst-github-proxy-comment-owner_x-issue-42.md"
            old_dash = d / "fkst-github-devloop-dashboard-owner_x-123-hash-abc.json"
            fresh_proxy = d / "fkst-github-proxy-created-issue-99.md"
            unrelated = d / "some-other-tool-scratch.md"
            for f in (old_proxy, old_dash, fresh_proxy, unrelated):
                f.write_text("body", encoding="utf-8")
            os.utime(old_proxy, (seven_h, seven_h))
            os.utime(old_dash, (seven_h, seven_h))
            # fresh_proxy + unrelated keep now-ish mtime

            out = _run_sweep(d)

            self.assertFalse(old_proxy.exists(), f"old github-proxy receipt must be reaped:\n{out}")
            self.assertFalse(old_dash.exists(), f"old dashboard receipt must be reaped:\n{out}")
            self.assertTrue(fresh_proxy.exists(), f"fresh receipt must be kept (in-flight safety):\n{out}")
            self.assertTrue(unrelated.exists(), f"unrelated /tmp file must never be touched:\n{out}")
            self.assertIn("stale-tmp-receipt sweep: 2 reaped", out, out)


if __name__ == "__main__":
    unittest.main()
