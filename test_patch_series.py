#!/usr/bin/env python3
"""Regression tests for patch validation before source modification."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
PATCH = os.environ.get("PATCH_TOOL", "/usr/gnu/bin/patch")
VALID = """--- a/input.txt
+++ b/input.txt
@@ -1,3 +1,3 @@
-old
+new
 context
-wal
+delete
"""
MALFORMED = """--- a/input.txt
+++ b/input.txt
@@ -1,1 +1,1 @@
-old
+new
 context
@@ -3,1 +3,1 @@
-wal
+delete
"""


class PatchSeriesTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "build").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "build")
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.patches = self.root / "patches"
        self.patches.mkdir()
        self.input = self.source / "input.txt"
        self.input.write_text("old\ncontext\nwal\n")

    def tearDown(self):
        self.temp.cleanup()

    def apply_series(self):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; apply_patch_series "$2" "$3"',
             "patch-test", str(ROOT / "common.sh"), str(self.source),
             str(self.patches)],
            env=dict(os.environ, PATCH_TOOL=PATCH),
            capture_output=True, text=True, timeout=30,
        )

    def test_valid_patch_applies_and_rerun_is_idempotent(self):
        (self.patches / "0001.patch").write_text(VALID)
        for _ in range(2):
            result = self.apply_series()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.input.read_text(), "new\ncontext\ndelete\n")

    def test_rejects_hunk_gnu_patch_silently_omits(self):
        patch = self.patches / "0001.patch"
        patch.write_text(MALFORMED)
        result = subprocess.run(
            [PATCH, "--batch", "--forward", "--fuzz=0", "-p1",
             "-d", str(self.source), "-i", str(patch)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.input.read_text(), "new\ncontext\nwal\n")
        self.input.write_text("old\ncontext\nwal\n")

        result = self.apply_series()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid patch syntax", result.stderr)
        self.assertEqual(self.input.read_text(), "old\ncontext\nwal\n")

    def test_validates_entire_series_before_applying_first_patch(self):
        (self.patches / "0001.patch").write_text(VALID)
        (self.patches / "0002.patch").write_text(MALFORMED)
        result = self.apply_series()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid patch syntax", result.stderr)
        self.assertEqual(self.input.read_text(), "old\ncontext\nwal\n")


if __name__ == "__main__":
    unittest.main()
