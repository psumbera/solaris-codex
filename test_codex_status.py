#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("codex-status.py")
SPEC = importlib.util.spec_from_file_location("codex_status", SCRIPT)
codex_status = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = codex_status
SPEC.loader.exec_module(codex_status)


def record(record_type, payload):
    return json.dumps({"type": record_type, "payload": payload}) + "\n"


def write_rollout(path, events, **metadata):
    payload = {
        "id": metadata.pop(
            "id", "019ec9de-5d76-7bc3-87da-4815c76455eb"
        ),
        "cli_version": metadata.pop("cli_version", "1.2.3"),
        "cwd": metadata.pop("cwd", "/work/project"),
        "source": metadata.pop("source", "cli"),
        "thread_source": metadata.pop("thread_source", "user"),
        "originator": metadata.pop("originator", "codex-tui"),
        **metadata,
    }
    lines = [record("session_meta", payload)]
    lines.extend(record("event_msg", {"type": event}) for event in events)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(lines))
    return path


class RolloutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.rollout = self.root / (
            "home/sessions/2026/10/01/"
            "rollout-2026-10-01T00-00-00-"
            "019ec9de-5d76-7bc3-87da-4815c76455eb.jsonl"
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_started_turn_is_working(self):
        write_rollout(self.rollout, ["task_started"])
        info = codex_status.read_rollout(self.rollout)
        self.assertEqual(info.state, "WORKING")
        self.assertEqual(info.lifecycle, "task_started")

    def test_completed_and_aborted_turns_are_idle(self):
        for event in ["task_complete", "turn_complete", "turn_aborted"]:
            with self.subTest(event=event):
                write_rollout(self.rollout, ["task_started", event])
                info = codex_status.read_rollout(self.rollout)
                self.assertEqual(info.state, "IDLE")
                self.assertEqual(info.lifecycle, event)

    def test_turn_started_alias_is_working(self):
        write_rollout(self.rollout, ["turn_started"])
        self.assertEqual(
            codex_status.read_rollout(self.rollout).state, "WORKING"
        )

    def test_incomplete_final_record_is_ignored(self):
        write_rollout(self.rollout, ["task_started", "task_complete"])
        with self.rollout.open("ab") as stream:
            stream.write(b'{"type":"event_msg","payload":')
        self.assertEqual(codex_status.read_rollout(self.rollout).state, "IDLE")

    def test_guardian_is_not_a_user_tui_rollout(self):
        write_rollout(
            self.rollout,
            [],
            source={"subagent": {"other": "guardian"}},
            thread_source="guardian_review",
        )
        info = codex_status.read_rollout(self.rollout)
        self.assertFalse(codex_status.is_user_tui_rollout(info))


class ProcTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.proc = self.root / "proc"
        self.pid_path = self.proc / "123" / "path"
        self.pid_path.mkdir(parents=True)
        self.executable = self.root / "bin" / "codex"
        self.executable.parent.mkdir()
        self.executable.write_text("#!/bin/sh\necho 'codex-cli 9.8.7'\n")
        self.executable.chmod(0o755)
        self.cwd = self.root / "project"
        self.cwd.mkdir()
        os.symlink(self.executable, self.pid_path / "a.out")
        os.symlink(self.cwd, self.pid_path / "cwd")

    def tearDown(self):
        self.temp.cleanup()

    def test_running_version_is_cached(self):
        codex_status._VERSION_CACHE.clear()
        subprocess_result = mock.Mock(
            returncode=0, stdout="codex-cli 9.8.7\n"
        )
        with mock.patch.object(
            codex_status.subprocess, "run", return_value=subprocess_result
        ) as run:
            self.assertEqual(
                codex_status._running_version(self.executable, None),
                ("9.8.7", "executable"),
            )
            self.assertEqual(
                codex_status._running_version(self.executable, None),
                ("9.8.7", "executable"),
            )
        self.assertEqual(run.call_count, 1)

    def rollout_path(self, name, events, **metadata):
        path = self.root / "home/sessions/2026/10/01" / name
        return write_rollout(path, events, **metadata)

    def test_collects_current_user_tui(self):
        path = self.rollout_path(
            "rollout-2026-10-01T00-00-00-"
            "019ec9de-5d76-7bc3-87da-4815c76455eb.jsonl",
            ["task_started"],
        )
        os.symlink(path, self.pid_path / "10")
        sessions = codex_status.collect_sessions(self.proc, os.geteuid())
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["pid"], 123)
        self.assertEqual(sessions[0]["version"], "9.8.7")
        self.assertEqual(sessions[0]["version_source"], "executable")
        self.assertEqual(sessions[0]["state"], "WORKING")
        self.assertEqual(sessions[0]["cwd"], "/work/project")

    def test_newer_guardian_does_not_replace_user_rollout(self):
        user = self.rollout_path(
            "rollout-2026-10-01T00-00-00-"
            "019ec9de-5d76-7bc3-87da-4815c76455eb.jsonl",
            ["task_complete"],
        )
        guardian = self.rollout_path(
            "rollout-2026-10-01T00-01-00-"
            "01a0f3b5-2ead-74c3-a0b1-cc18788c4a28.jsonl",
            ["task_started"],
            source={"subagent": {"other": "guardian"}},
            thread_source="guardian_review",
        )
        os.utime(user, (time.time() - 10, time.time() - 10))
        os.symlink(user, self.pid_path / "10")
        os.symlink(guardian, self.pid_path / "11")
        sessions = codex_status.collect_sessions(self.proc, os.geteuid())
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["state"], "IDLE")
        self.assertEqual(
            sessions[0]["thread_id"],
            "019ec9de-5d76-7bc3-87da-4815c76455eb",
        )

    def test_process_without_rollout_is_ignored(self):
        self.assertEqual(
            codex_status.collect_sessions(self.proc, os.geteuid()), []
        )

    def test_broken_process_links_are_ignored(self):
        (self.proc / "456" / "path").mkdir(parents=True)
        self.assertEqual(
            codex_status.collect_sessions(self.proc, os.geteuid()), []
        )


if __name__ == "__main__":
    unittest.main()
