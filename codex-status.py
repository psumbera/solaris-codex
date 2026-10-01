#!/usr/bin/env python3
"""Show the status of this user's running Codex TUI sessions on Solaris.

The monitor reads Solaris /proc descriptor links and Codex rollout JSONL files.
It does not connect to the app-server daemon or open Codex SQLite databases.
"""

import argparse
from dataclasses import dataclass
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


START_EVENTS = {"task_started", "turn_started"}
COMPLETE_EVENTS = {"task_complete", "turn_complete"}
VERSION_RE = re.compile(r"\b(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b")
THREAD_ID_RE = re.compile(
    r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$"
)
_VERSION_CACHE: dict[
    tuple[str, int | None, int | None, str | None], tuple[str, str]
] = {}


@dataclass(frozen=True)
class RolloutInfo:
    path: Path
    thread_id: str | None
    cli_version: str | None
    cwd: str | None
    source: object
    thread_source: str | None
    originator: str | None
    state: str
    lifecycle: str | None
    last_activity_at: float
    error: str | None = None


def _link_target(link: Path) -> Path:
    target = Path(os.readlink(link))
    if target.is_absolute():
        return target
    return link.parent.joinpath(target).resolve(strict=False)


def _thread_id_from_path(path: Path) -> str | None:
    match = THREAD_ID_RE.search(path.name)
    return match.group(1) if match else None


def _read_session_meta(path: Path) -> dict:
    with path.open("rb") as stream:
        raw = stream.readline()
    record = json.loads(raw)
    if record.get("type") != "session_meta":
        raise ValueError("first rollout record is not session_meta")
    payload = record.get("payload")
    if not isinstance(payload, dict):
        raise ValueError("session_meta payload is not an object")
    return payload


def _reverse_lines(path: Path, block_size: int = 64 * 1024):
    """Yield binary lines from a file in reverse order."""
    with path.open("rb") as stream:
        position = stream.seek(0, os.SEEK_END)
        remainder = b""
        while position:
            size = min(block_size, position)
            position -= size
            stream.seek(position)
            chunk = stream.read(size) + remainder
            lines = chunk.split(b"\n")
            remainder = lines[0]
            for line in reversed(lines[1:]):
                if line:
                    yield line
        if remainder:
            yield remainder


def _latest_lifecycle(path: Path) -> tuple[str, str | None]:
    for raw in _reverse_lines(path):
        try:
            record = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            # A writer may currently have an incomplete final record.
            continue
        if record.get("type") != "event_msg":
            continue
        payload = record.get("payload")
        if not isinstance(payload, dict):
            continue
        event_type = payload.get("type")
        if event_type in START_EVENTS:
            return "WORKING", event_type
        if event_type in COMPLETE_EVENTS:
            return "IDLE", event_type
        if event_type == "turn_aborted":
            return "IDLE", event_type
    return "UNKNOWN", None


def read_rollout(path: Path) -> RolloutInfo:
    metadata = _read_session_meta(path)
    state, lifecycle = _latest_lifecycle(path)
    modified = path.stat().st_mtime
    return RolloutInfo(
        path=path,
        thread_id=(
            metadata.get("id")
            or metadata.get("session_id")
            or _thread_id_from_path(path)
        ),
        cli_version=metadata.get("cli_version"),
        cwd=metadata.get("cwd"),
        source=metadata.get("source"),
        thread_source=metadata.get("thread_source"),
        originator=metadata.get("originator"),
        state=state,
        lifecycle=lifecycle,
        last_activity_at=modified,
    )


def unreadable_rollout(path: Path, error: Exception) -> RolloutInfo:
    try:
        modified = path.stat().st_mtime
    except OSError:
        modified = time.time()
    return RolloutInfo(
        path=path,
        thread_id=_thread_id_from_path(path),
        cli_version=None,
        cwd=None,
        source=None,
        thread_source=None,
        originator=None,
        state="UNKNOWN",
        lifecycle=None,
        last_activity_at=modified,
        error=str(error),
    )


def is_user_tui_rollout(info: RolloutInfo) -> bool:
    if info.originator not in (None, "codex-tui"):
        return False
    return info.thread_source == "user" or info.source == "cli"


def _rollout_links(path_dir: Path) -> set[Path]:
    paths = set()
    try:
        entries = list(path_dir.iterdir())
    except OSError:
        return paths
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            target = _link_target(entry)
        except OSError:
            continue
        if (
            target.name.startswith("rollout-")
            and target.suffix == ".jsonl"
            and "sessions" in target.parts
        ):
            paths.add(target)
    return paths


def _running_version(
    executable: Path, fallback: str | None
) -> tuple[str, str]:
    try:
        stat = executable.stat()
        cache_key = (
            str(executable),
            stat.st_mtime_ns,
            stat.st_size,
            fallback,
        )
    except OSError:
        cache_key = (str(executable), None, None, fallback)
    cached = _VERSION_CACHE.get(cache_key)
    if cached is not None:
        return cached

    try:
        result = subprocess.run(
            [str(executable), "--version"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=3,
            check=False,
        )
        match = VERSION_RE.search(result.stdout)
        if result.returncode == 0 and match:
            version = (match.group(1), "executable")
            _VERSION_CACHE[cache_key] = version
            return version
    except (OSError, subprocess.SubprocessError):
        pass
    if fallback:
        version = (fallback, "rollout")
    else:
        version = ("unknown", "unknown")
    _VERSION_CACHE[cache_key] = version
    return version


def _codex_home_from_rollout(path: Path) -> str | None:
    indexes = [
        index for index, part in enumerate(path.parts) if part == "sessions"
    ]
    if not indexes:
        return None
    home = Path(*path.parts[: indexes[-1]])
    return str(home) or "/"


def collect_sessions(
    proc_root: Path = Path("/proc"), uid: int | None = None
) -> list[dict]:
    """Collect one record per current-user Codex TUI process."""
    if uid is None:
        uid = os.geteuid()
    processes = []
    try:
        pid_dirs = list(proc_root.iterdir())
    except OSError:
        return processes

    for pid_dir in pid_dirs:
        if not pid_dir.name.isdigit():
            continue
        try:
            if pid_dir.stat().st_uid != uid:
                continue
            executable = _link_target(pid_dir / "path" / "a.out")
            if executable.name != "codex":
                continue
            process_cwd = str(_link_target(pid_dir / "path" / "cwd"))
        except OSError:
            continue

        valid = []
        unreadable = []
        for rollout_path in _rollout_links(pid_dir / "path"):
            try:
                info = read_rollout(rollout_path)
            except (
                OSError,
                ValueError,
                UnicodeDecodeError,
                json.JSONDecodeError,
            ) as error:
                unreadable.append(unreadable_rollout(rollout_path, error))
                continue
            if is_user_tui_rollout(info):
                valid.append(info)

        if valid:
            rollout = max(valid, key=lambda item: item.last_activity_at)
        elif unreadable:
            rollout = max(unreadable, key=lambda item: item.last_activity_at)
        else:
            # Exclude daemons, --version invocations and non-TUI processes.
            continue

        version, version_source = _running_version(
            executable, rollout.cli_version
        )
        processes.append(
            {
                "pid": int(pid_dir.name),
                "version": version,
                "version_source": version_source,
                "state": rollout.state,
                "lifecycle": rollout.lifecycle,
                "last_activity_at": rollout.last_activity_at,
                "last_activity_seconds": max(
                    0, int(time.time() - rollout.last_activity_at)
                ),
                "thread_id": rollout.thread_id,
                "cwd": rollout.cwd or process_cwd,
                "process_cwd": process_cwd,
                "executable": str(executable),
                "rollout": str(rollout.path),
                "codex_home": _codex_home_from_rollout(rollout.path),
                "error": rollout.error,
            }
        )

    return sorted(processes, key=lambda item: (item["cwd"], item["pid"]))


def _format_age(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m{seconds:02d}s"
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return f"{hours}h{minutes:02d}m"
    days, hours = divmod(hours, 24)
    return f"{days}d{hours:02d}h"


def render_table(sessions: list[dict]) -> str:
    if not sessions:
        return "No running Codex TUI sessions found."
    headers = ["PID", "VERSION", "STATE", "LAST", "THREAD", "DIRECTORY"]
    rows = [
        [
            str(item["pid"]),
            item["version"],
            item["state"],
            _format_age(item["last_activity_seconds"]),
            (item["thread_id"] or "-")[:12],
            item["cwd"],
        ]
        for item in sessions
    ]
    widths = [
        max(len(headers[index]), *(len(row[index]) for row in rows))
        for index in range(len(headers) - 1)
    ]

    def format_row(row):
        columns = [
            value.ljust(widths[index]) for index, value in enumerate(row[:-1])
        ]
        return "  ".join([*columns, row[-1]])

    return "\n".join([format_row(headers), *map(format_row, rows)])


def _positive_interval(value: str) -> float:
    interval = float(value)
    if interval <= 0:
        raise argparse.ArgumentTypeError(
            "watch interval must be greater than zero"
        )
    return interval


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--watch",
        nargs="?",
        const=5.0,
        type=_positive_interval,
        metavar="SECONDS",
        help="refresh continuously (default interval: 5 seconds)",
    )
    parser.add_argument(
        "--json", action="store_true", help="print a single JSON snapshot"
    )
    args = parser.parse_args(argv)
    if args.json and args.watch is not None:
        parser.error("--json and --watch cannot be used together")
    return args


def main(argv=None) -> int:
    args = parse_args(argv)
    if args.json:
        print(json.dumps(collect_sessions(), indent=2, sort_keys=True))
        return 0
    if args.watch is None:
        print(render_table(collect_sessions()))
        return 0

    try:
        while True:
            if sys.stdout.isatty():
                print("\033[H\033[2J", end="")
            now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
            print(f"Codex sessions at {now}")
            print(render_table(collect_sessions()), flush=True)
            time.sleep(args.watch)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
