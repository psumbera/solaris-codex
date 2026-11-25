#!/usr/bin/env python3
"""Regression tests for checksum-aware Solaris dependency adjustments."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent


class VendorPatchTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "build").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "build")
        self.vendor = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def crate(self, name, files):
        root = self.vendor / name
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (root / ".cargo-checksum.json").write_text(json.dumps({
            "files": {name: "stale" for name in files}, "package": "preserve",
        }))
        return root

    def run_patch(self, name, **environment):
        script = (ROOT / "build-codex.sh").read_text()
        function = (script.split(name + "() {", 1)[1]
                    .split("\npatch_", 1)[0].rsplit("\n}", 1)[0])
        return subprocess.run(
            ["bash", "-c", "set -e\ndie() { exit 1; }\nlog() { :; }\n" + name +
             "() {" + function + "\n}\n" + name],
            env=dict(os.environ, CODEX_VENDOR_DIR=str(self.vendor), **environment),
            capture_output=True, text=True, timeout=30,
        )

    def check_checksums(self, root):
        data = json.loads((root / ".cargo-checksum.json").read_text())
        self.assertEqual(data["package"], "preserve")
        for name, digest in data["files"].items():
            self.assertEqual(digest, hashlib.sha256((root / name).read_bytes()).hexdigest())

    def assert_idempotent(self, name, **environment):
        first = self.run_patch(name, **environment)
        self.assertEqual(first.returncode, 0, first.stderr)
        before = {p: p.stat().st_mtime_ns for p in self.vendor.rglob("*") if p.is_file()}
        second = self.run_patch(name, **environment)
        self.assertEqual(second.returncode, 0, second.stderr)
        after = {p: p.stat().st_mtime_ns for p in self.vendor.rglob("*") if p.is_file()}
        self.assertEqual(before, after, "unchanged rewrites must not invalidate Cargo caches")

    def test_all_nix_versions_and_already_portable_versions(self):
        old = ("        #[cfg(any(freebsdlike, solarish))]\n        VERASE2,\n"
               "        #[cfg(any(bsd, solarish))]\n        VSTATUS,\n")
        roots = [self.crate(name, {"src/sys/termios.rs": text})
                 for name, text in [("nix-0.28.0", old), ("nix-0.29.0", old),
                                    ("nix", old.replace("solarish", 'target_os = "illumos"'))]]
        self.assert_idempotent("patch_vendored_nix_termios")
        for root in roots:
            self.assertNotIn("solarish", (root / "src/sys/termios.rs").read_text())
            self.check_checksums(root)

    def test_unknown_nix_layout_fails(self):
        self.crate("nix", {"src/sys/termios.rs": "unknown layout\n"})
        self.assertNotEqual(self.run_patch("patch_vendored_nix_termios").returncode, 0)

    def test_tree_sitter_endian_patch_does_not_repeat_or_invalidate_caches(self):
        root = self.crate("tree-sitter", {
            "src/portable/endian.h":
                "#else\n\n#    error platform not supported\n\n#endif\n",
        })
        self.assert_idempotent("patch_vendored_tree_sitter_endian")
        self.assertEqual((root / "src/portable/endian.h").read_text().count(
            "#elif defined(__sun)"), 1)
        self.check_checksums(root)

    def test_unknown_tree_sitter_endian_layout_fails(self):
        self.crate("tree-sitter", {"src/portable/endian.h": "unknown layout\n"})
        self.assertNotEqual(self.run_patch("patch_vendored_tree_sitter_endian").returncode, 0)

    def test_mxc_keeps_unsupported_host_rejection_and_patches_idempotently(self):
        root = self.crate("mxc-sdk", {
            "src/core/mxc_engine/dispatch.rs":
                "    ensure_host_supported()?;\n" +
                "    crate::mxc_engine::run::log_policy_hash(request, logger);\n" * 3,
            "src/core/mxc_common/telemetry/correlation_state.rs":
                "#[cfg(unix)]\nfn try_lock_file(file: &fs::File) -> bool {\n}\n",
        })
        self.assert_idempotent("patch_vendored_mxc")
        dispatch = (root / "src/core/mxc_engine/dispatch.rs").read_text()
        self.assertIn("ensure_host_supported()?;", dispatch)
        self.assertEqual(dispatch.count("#[cfg(any("), 3)
        self.assertIn("file.try_lock().is_ok()", (
            root / "src/core/mxc_common/telemetry/correlation_state.rs").read_text())
        self.check_checksums(root)

    def test_unknown_mxc_dispatch_layout_fails(self):
        self.crate("mxc-sdk", {
            "src/core/mxc_engine/dispatch.rs":
                "    crate::mxc_engine::run::log_policy_hash(request, logger);\n" * 2,
            "src/core/mxc_common/telemetry/correlation_state.rs":
                "#[cfg(unix)]\nfn try_lock_file(file: &fs::File) -> bool {\n}\n",
        })
        result = self.run_patch("patch_vendored_mxc")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed to patch mxc-sdk", result.stderr)

    def mio(self, waker=None):
        for name in ("event_ports.rs", "selector.rs"):
            if name != waker:
                (self.vendor / "mio/src/sys/unix/waker" / name).unlink(missing_ok=True)
        files = {name: "fixture\n" for name in (
            "src/poll.rs", "src/sys/unix/mod.rs",
            "src/sys/unix/selector/event_ports.rs",
        )}
        if waker:
            files["src/sys/unix/waker/" + waker] = "selector-backed waker\n"
        root = self.crate("mio", files)
        digest = hashlib.sha256()
        for patch in sorted((ROOT / "patches/mio").glob("*.patch")):
            digest.update(patch.name.encode())
            digest.update(b"\0")
            digest.update(patch.read_bytes())
        (root / ".solaris-mio-patch-series.sha256").write_text(digest.hexdigest())
        target = self.vendor / "target"
        target.mkdir(exist_ok=True)
        (target / ".solaris-mio-event-ports.sha256").write_text(
            hashlib.sha256(files["src/sys/unix/selector/event_ports.rs"].encode()).hexdigest()
        )
        return root

    def test_mio_checksums_support_both_selector_waker_layouts(self):
        for waker in ("event_ports.rs", "selector.rs"):
            with self.subTest(waker=waker):
                root = self.mio(waker)
                self.assert_idempotent(
                    "patch_vendored_mio_event_ports", TOP=str(ROOT),
                    CODEX_SRC_DIR=str(self.vendor),
                )
                self.check_checksums(root)

    def test_mio_unknown_waker_layout_fails(self):
        self.mio()
        result = self.run_patch(
            "patch_vendored_mio_event_ports", TOP=str(ROOT),
            CODEX_SRC_DIR=str(self.vendor),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing vendored mio selector-backed waker", result.stderr)


if __name__ == "__main__":
    unittest.main()
