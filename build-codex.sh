#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

# This wrapper fetches upstream sources and applies two classes of Solaris
# adjustments:
# 1. versioned upstream-source patch series in patches/codex and patches/v8
# 2. post-vendor scripted rewrites for crates whose .cargo-checksum.json must
#    be refreshed after cargo vendor
#
# Keep the scripted rewrites idempotent: maintainers routinely rerun the full
# wrapper while validating a new Codex pin, and the repo is meant to remain
# understandable without the chat history that produced the Solaris fixes.

patch_vendored_nix_termios() {
  local nix_root=${CODEX_VENDOR_DIR}/nix-0.28.0
  local termios_rs=${nix_root}/src/sys/termios.rs
  local checksum_json=${nix_root}/.cargo-checksum.json

  [[ -f "${termios_rs}" ]] || die "missing vendored nix termios source: ${termios_rs}"
  [[ -f "${checksum_json}" ]] || die "missing vendored nix checksum: ${checksum_json}"

  python3 - "${termios_rs}" "${checksum_json}" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

termios_rs = Path(sys.argv[1])
checksum_json = Path(sys.argv[2])

text = termios_rs.read_text()
changed = False

replacements = [
    ("        #[cfg(any(freebsdlike, solarish))]\n        VERASE2,\n",
     "        #[cfg(freebsdlike)]\n        VERASE2,\n"),
    ("        #[cfg(any(bsd, solarish))]\n        VSTATUS,\n",
     "        #[cfg(bsd)]\n        VSTATUS,\n"),
]

for old, new in replacements:
    if old in text:
        text = text.replace(old, new, 1)
        changed = True
    elif new not in text:
        raise SystemExit(f"failed to patch nix termios cfg block: {old!r}")

if changed:
    termios_rs.write_text(text)

digest = hashlib.sha256(termios_rs.read_bytes()).hexdigest()
data = json.loads(checksum_json.read_text())
data["files"]["src/sys/termios.rs"] = digest
checksum_json.write_text(json.dumps(data, separators=(",", ":")))
PY
}

patch_vendored_tree_sitter_endian() {
  local tree_sitter_root=${CODEX_VENDOR_DIR}/tree-sitter
  local endian_h=${tree_sitter_root}/src/portable/endian.h
  local checksum_json=${tree_sitter_root}/.cargo-checksum.json

  [[ -f "${endian_h}" ]] || die "missing vendored tree-sitter endian header: ${endian_h}"
  [[ -f "${checksum_json}" ]] || die "missing vendored tree-sitter checksum: ${checksum_json}"

  python3 - "${endian_h}" "${checksum_json}" <<'PY2'
from pathlib import Path
import hashlib
import json
import sys

endian_h = Path(sys.argv[1])
checksum_json = Path(sys.argv[2])
text = endian_h.read_text()
changed = False

old = """#else

#    error platform not supported

#endif
"""
new = """#elif defined(__sun)

#    include <sys/byteorder.h>

#    if defined(_BIG_ENDIAN)

#        define htobe16(x) (x)
#        define htole16(x) BSWAP_16(x)
#        define be16toh(x) (x)
#        define le16toh(x) BSWAP_16(x)

#        define htobe32(x) (x)
#        define htole32(x) BSWAP_32(x)
#        define be32toh(x) (x)
#        define le32toh(x) BSWAP_32(x)

#        define htobe64(x) (x)
#        define htole64(x) BSWAP_64(x)
#        define be64toh(x) (x)
#        define le64toh(x) BSWAP_64(x)

#    elif defined(_LITTLE_ENDIAN)

#        define htobe16(x) BSWAP_16(x)
#        define htole16(x) (x)
#        define be16toh(x) BSWAP_16(x)
#        define le16toh(x) (x)

#        define htobe32(x) BSWAP_32(x)
#        define htole32(x) (x)
#        define be32toh(x) BSWAP_32(x)
#        define le32toh(x) (x)

#        define htobe64(x) BSWAP_64(x)
#        define htole64(x) (x)
#        define be64toh(x) BSWAP_64(x)
#        define le64toh(x) (x)

#    else

#        error byte order not supported

#    endif

#else

#    error platform not supported

#endif
"""

if old in text:
    text = text.replace(old, new, 1)
    changed = True
elif '__sun' not in text:
    raise SystemExit('failed to patch tree-sitter endian header')

if changed:
    endian_h.write_text(text)

digest = hashlib.sha256(endian_h.read_bytes()).hexdigest()
data = json.loads(checksum_json.read_text())
data['files']['src/portable/endian.h'] = digest
checksum_json.write_text(json.dumps(data, separators=(',', ':')))
PY2
}

patch_vendored_fslock() {
  local fslock_root=${CODEX_VENDOR_DIR}/fslock
  local unix_rs=${fslock_root}/src/unix.rs
  local checksum_json=${fslock_root}/.cargo-checksum.json

  [[ -f "${unix_rs}" ]] || die "missing vendored fslock source: ${unix_rs}"
  [[ -f "${checksum_json}" ]] || die "missing vendored fslock checksum: ${checksum_json}"

  python3 - "${unix_rs}" "${checksum_json}" <<'PY2'
from pathlib import Path
import hashlib
import json
import sys

unix_rs = Path(sys.argv[1])
checksum_json = Path(sys.argv[2])
text = unix_rs.read_text()
changed = False

old = """/// Tries to lock a file and blocks until it is possible to lock.
pub fn lock(fd: FileDesc) -> Result<(), Error> {
    let res = unsafe { libc::flock(fd, libc::LOCK_EX) };
    if res >= 0 {
        Ok(())
    } else {
        Err(Error::last_os_error())
    }
}

/// Tries to lock a file but returns as soon as possible if already locked.
pub fn try_lock(fd: FileDesc) -> Result<bool, Error> {
    let res = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };
    if res >= 0 {
        Ok(true)
    } else {
        let err = errno();
        if err == libc::EWOULDBLOCK || err == libc::EINTR {
            Ok(false)
        } else {
            Err(Error::from_raw_os_error(err as i32))
        }
    }
}

/// Unlocks the file.
pub fn unlock(fd: FileDesc) -> Result<(), Error> {
    let res = unsafe { libc::flock(fd, libc::LOCK_UN) };
    if res >= 0 {
        Ok(())
    } else {
        Err(Error::last_os_error())
    }
}
"""
new = """#[cfg(not(target_os = \"solaris\"))]
/// Tries to lock a file and blocks until it is possible to lock.
pub fn lock(fd: FileDesc) -> Result<(), Error> {
    let res = unsafe { libc::flock(fd, libc::LOCK_EX) };
    if res >= 0 {
        Ok(())
    } else {
        Err(Error::last_os_error())
    }
}

#[cfg(target_os = \"solaris\")]
fn solaris_flock(fd: FileDesc, cmd: libc::c_int, lock_type: libc::c_short) -> Result<(), Error> {
    let mut lock: libc::flock = unsafe { core::mem::zeroed() };
    lock.l_type = lock_type;
    lock.l_whence = libc::SEEK_SET as libc::c_short;
    lock.l_start = 0;
    lock.l_len = 0;

    let res = unsafe { libc::fcntl(fd, cmd, &lock) };
    if res >= 0 {
        Ok(())
    } else {
        Err(Error::last_os_error())
    }
}

#[cfg(target_os = \"solaris\")]
/// Tries to lock a file and blocks until it is possible to lock.
pub fn lock(fd: FileDesc) -> Result<(), Error> {
    solaris_flock(fd, libc::F_SETLKW, libc::F_WRLCK as libc::c_short)
}

#[cfg(not(target_os = \"solaris\"))]
/// Tries to lock a file but returns as soon as possible if already locked.
pub fn try_lock(fd: FileDesc) -> Result<bool, Error> {
    let res = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };
    if res >= 0 {
        Ok(true)
    } else {
        let err = errno();
        if err == libc::EWOULDBLOCK || err == libc::EINTR {
            Ok(false)
        } else {
            Err(Error::from_raw_os_error(err as i32))
        }
    }
}

#[cfg(target_os = \"solaris\")]
/// Tries to lock a file but returns as soon as possible if already locked.
pub fn try_lock(fd: FileDesc) -> Result<bool, Error> {
    match solaris_flock(fd, libc::F_SETLK, libc::F_WRLCK as libc::c_short) {
        Ok(()) => Ok(true),
        Err(err) => match err.raw_os_error() {
            Some(code) if code == libc::EAGAIN || code == libc::EACCES || code == libc::EINTR => Ok(false),
            _ => Err(err),
        },
    }
}

#[cfg(not(target_os = \"solaris\"))]
/// Unlocks the file.
pub fn unlock(fd: FileDesc) -> Result<(), Error> {
    let res = unsafe { libc::flock(fd, libc::LOCK_UN) };
    if res >= 0 {
        Ok(())
    } else {
        Err(Error::last_os_error())
    }
}

#[cfg(target_os = \"solaris\")]
/// Unlocks the file.
pub fn unlock(fd: FileDesc) -> Result<(), Error> {
    solaris_flock(fd, libc::F_SETLK, libc::F_UNLCK as libc::c_short)
}
"""

if old in text:
    text = text.replace(old, new, 1)
    changed = True
elif 'solaris_flock(' not in text:
    raise SystemExit('failed to patch fslock unix.rs')

if changed:
    unix_rs.write_text(text)

digest = hashlib.sha256(unix_rs.read_bytes()).hexdigest()
data = json.loads(checksum_json.read_text())
data['files']['src/unix.rs'] = digest
checksum_json.write_text(json.dumps(data, separators=(',', ':')))
PY2
}

patch_vendored_onig_sys_alloca() {
  local onig_root=${CODEX_VENDOR_DIR}/onig_sys
  local regint_h=${onig_root}/oniguruma/src/regint.h
  local checksum_json=${onig_root}/.cargo-checksum.json

  [[ -f "${regint_h}" ]] || die "missing vendored onig_sys header: ${regint_h}"
  [[ -f "${checksum_json}" ]] || die "missing vendored onig_sys checksum: ${checksum_json}"

  python3 - "${regint_h}" "${checksum_json}" <<'PY2'
from pathlib import Path
import hashlib
import json
import sys

regint_h = Path(sys.argv[1])
checksum_json = Path(sys.argv[2])
text = regint_h.read_text()
changed = False

old = """#if defined(HAVE_ALLOCA_H)
#include <alloca.h>
#endif
"""
new = """#if defined(HAVE_ALLOCA_H) || defined(__sun)
#include <alloca.h>
#endif
"""

if old in text:
    text = text.replace(old, new, 1)
    changed = True
elif new not in text:
    raise SystemExit("failed to patch onig_sys regint.h")

if changed:
    regint_h.write_text(text)

digest = hashlib.sha256(regint_h.read_bytes()).hexdigest()
data = json.loads(checksum_json.read_text())
data["files"]["oniguruma/src/regint.h"] = digest
checksum_json.write_text(json.dumps(data, separators=(",", ":")))
PY2
}

patch_vendored_mio_event_ports() {
  local mio_root=${CODEX_VENDOR_DIR}/mio
  local checksum_json=${mio_root}/.cargo-checksum.json
  local event_ports_rs=${mio_root}/src/sys/unix/selector/event_ports.rs
  local base_patch=${TOP}/patches/mio/0001-selector-use-solaris-event-ports.patch
  local cache_stamp=${CODEX_SRC_DIR}/target/.solaris-mio-event-ports.sha256
  local event_ports_hash
  local cached_hash=
  local patch

  [[ -d "${mio_root}" ]] || die "missing vendored mio source: ${mio_root}"
  [[ -f "${checksum_json}" ]] || die "missing vendored mio checksum: ${checksum_json}"

  if [[ ! -f "${event_ports_rs}" ]]; then
    [[ -f "${base_patch}" ]] || die "missing mio Solaris event ports patch: ${base_patch}"
    log "Applying vendored mio $(basename "${base_patch}")"
    (
      cd "${mio_root}"
      "${PATCH_TOOL}" --batch --forward --fuzz=0 -p1 < "${base_patch}"
    ) || die "failed to apply vendored mio patch: ${base_patch}"
  fi

  [[ -f "${event_ports_rs}" ]] || die "vendored mio Solaris event ports source was not created"

  # Newer Mio revisions may already contain the base event-ports
  # implementation. Apply Solaris correctness fixes independently so they are
  # also used when the base patch is unnecessary.
  for patch in "${TOP}/patches/mio"/*.patch; do
    [[ -e "${patch}" ]] || continue
    [[ "${patch}" == "${base_patch}" ]] && continue
    if (
      cd "${mio_root}"
      "${PATCH_TOOL}" --dry-run --batch --forward --fuzz=0 -p1 < "${patch}" >/dev/null 2>&1
    ); then
      log "Applying vendored mio $(basename "${patch}")"
      (
        cd "${mio_root}"
        "${PATCH_TOOL}" --batch --forward --fuzz=0 -p1 < "${patch}"
      )
    elif (
      cd "${mio_root}"
      "${PATCH_TOOL}" --dry-run --batch --forward --fuzz=0 -R -p1 < "${patch}" >/dev/null 2>&1
    ); then
      log "Already applied vendored mio $(basename "${patch}")"
    else
      die "failed to apply vendored mio patch: ${patch}"
    fi
  done

  python3 - "${mio_root}" "${checksum_json}" <<'PY2'
from pathlib import Path
import hashlib
import json
import sys

root = Path(sys.argv[1])
checksum_json = Path(sys.argv[2])
paths = [
    "src/poll.rs",
    "src/sys/unix/mod.rs",
    "src/sys/unix/selector/event_ports.rs",
    "src/sys/unix/waker/event_ports.rs",
]

data = json.loads(checksum_json.read_text())
files = data.setdefault("files", {})
for rel in paths:
    path = root / rel
    if not path.is_file():
        raise SystemExit(f"missing vendored mio file: {path}")
    files[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
checksum_json.write_text(json.dumps(data, separators=(",", ":")))
PY2

  # Cargo assumes registry sources are immutable and can retain a stale Mio
  # artifact after a vendored source patch changes. Invalidate only when the
  # patched selector content changes so ordinary rebuilds keep their cache.
  event_ports_hash=$(python3 - "${event_ports_rs}" <<'PY2'
from pathlib import Path
import hashlib
import sys

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY2
)
  if [[ -f "${cache_stamp}" ]]; then
    cached_hash=$(<"${cache_stamp}")
  fi
  if [[ "${cached_hash}" != "${event_ports_hash}" ]]; then
    log "Invalidating cached mio artifacts after Solaris selector update"
    (
      cd "${CODEX_SRC_DIR}"
      "${CARGO}" clean -p mio --release
    )
    mkdir -p "$(dirname "${cache_stamp}")"
    printf '%s\n' "${event_ports_hash}" > "${cache_stamp}"
  fi
}

patch_tui_solaris_terminal_input() {
  local tui_rs=${CODEX_SRC_DIR}/tui/src/tui.rs
  local event_stream_rs=${CODEX_SRC_DIR}/tui/src/tui/event_stream.rs

  python3 - "${tui_rs}" "${event_stream_rs}" <<'PY'
from pathlib import Path
import sys

tui_rs = Path(sys.argv[1])
text = tui_rs.read_text()

old = """use crossterm::event::DisableBracketedPaste;
use crossterm::event::DisableFocusChange;
use crossterm::event::EnableBracketedPaste;
#[cfg(not(windows))]
use crossterm::event::EnableFocusChange;
"""
new = """#[cfg(not(target_os = \"solaris\"))]
use crossterm::event::DisableBracketedPaste;
#[cfg(not(target_os = \"solaris\"))]
use crossterm::event::DisableFocusChange;
#[cfg(not(target_os = \"solaris\"))]
use crossterm::event::EnableBracketedPaste;
#[cfg(all(not(windows), not(target_os = \"solaris\")))]
use crossterm::event::EnableFocusChange;
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch tui.rs crossterm mode imports")
    text = text.replace(old, new, 1)

old = """pub fn set_modes() -> Result<()> {
    ensure_virtual_terminal_processing()?;

    execute!(stdout(), EnableBracketedPaste)?;

    enable_raw_mode()?;
    #[cfg(windows)]
    windows_console::set_input_record_mode()?;
    // Enable keyboard enhancement flags so modifiers for keys like Enter are disambiguated.
    // chat_composer.rs is using a keyboard event listener to enter for any modified keys
    // to create a new line that require this.
    // Some terminals (notably legacy Windows consoles) do not support
    // keyboard enhancement flags. Attempt to enable them, but continue
    // gracefully if unsupported.
    keyboard_modes::enable_keyboard_enhancement();

    #[cfg(not(windows))]
    let _ = execute!(stdout(), EnableFocusChange);
    #[cfg(windows)]
    let _ = execute!(stdout(), DisableFocusChange);
    Ok(())
}
"""
new = """pub fn set_modes() -> Result<()> {
    ensure_virtual_terminal_processing()?;

    enable_raw_mode()?;
    #[cfg(windows)]
    windows_console::set_input_record_mode()?;

    #[cfg(not(target_os = \"solaris\"))]
    {
        execute!(stdout(), EnableBracketedPaste)?;

        // Enable keyboard enhancement flags so modifiers for keys like Enter are disambiguated.
        // chat_composer.rs is using a keyboard event listener to enter for any modified keys
        // to create a new line that require this.
        // Some terminals (notably legacy Windows consoles) do not support
        // keyboard enhancement flags. Attempt to enable them, but continue
        // gracefully if unsupported.
        keyboard_modes::enable_keyboard_enhancement();

        #[cfg(not(windows))]
        let _ = execute!(stdout(), EnableFocusChange);
        #[cfg(windows)]
        let _ = execute!(stdout(), DisableFocusChange);
    }

    Ok(())
}
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch tui.rs set_modes")
    text = text.replace(old, new, 1)

old = """    match keyboard_restore {
        KeyboardRestore::PopStack => keyboard_modes::restore_keyboard_enhancement_stack(),
        KeyboardRestore::ResetAfterExit => keyboard_modes::reset_keyboard_reporting_after_exit(),
    }

    if let Err(err) = execute!(stdout(), DisableBracketedPaste) {
        first_error.get_or_insert(err);
    }
    let _ = execute!(stdout(), DisableFocusChange);
"""
new = """    #[cfg(target_os = \"solaris\")]
    let _ = keyboard_restore;

    #[cfg(not(target_os = \"solaris\"))]
    match keyboard_restore {
        KeyboardRestore::PopStack => keyboard_modes::restore_keyboard_enhancement_stack(),
        KeyboardRestore::ResetAfterExit => keyboard_modes::reset_keyboard_reporting_after_exit(),
    }

    #[cfg(not(target_os = \"solaris\"))]
    if let Err(err) = execute!(stdout(), DisableBracketedPaste) {
        first_error.get_or_insert(err);
    }
    #[cfg(not(target_os = \"solaris\"))]
    let _ = execute!(stdout(), DisableFocusChange);
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch tui.rs restore_common")
    text = text.replace(old, new, 1)

old = """    #[cfg(unix)]
    let startup_probe = {
        use crate::terminal_probe::StartupKeyboardEnhancementProbe;

        let started_at = std::time::Instant::now();
        let keyboard_probe = if keyboard_modes::keyboard_enhancement_disabled() {
            StartupKeyboardEnhancementProbe::Skip
        } else {
            StartupKeyboardEnhancementProbe::Query
        };
        match crate::terminal_probe::startup(crate::terminal_probe::DEFAULT_TIMEOUT, keyboard_probe)
        {
            Ok(probe) => {
                tracing::info!(
                    duration_ms = %started_at.elapsed().as_millis(),
                    cursor_position = probe.cursor_position.is_some(),
                    default_colors = probe.default_colors.is_some(),
                    keyboard_enhancement_supported = ?probe.keyboard_enhancement_supported,
                    \"terminal startup probes completed\"
                );
                probe
            }
            Err(err) => {
                tracing::warn!(
                    duration_ms = %started_at.elapsed().as_millis(),
                    \"terminal startup probes failed: {err}\"
                );
                crate::terminal_probe::StartupProbe {
                    cursor_position: None,
                    default_colors: None,
                    keyboard_enhancement_supported: None,
                }
            }
        }
    };
"""
new = """    #[cfg(all(unix, not(target_os = \"solaris\")))]
    let startup_probe = {
        use crate::terminal_probe::StartupKeyboardEnhancementProbe;

        let started_at = std::time::Instant::now();
        let keyboard_probe = if keyboard_modes::keyboard_enhancement_disabled() {
            StartupKeyboardEnhancementProbe::Skip
        } else {
            StartupKeyboardEnhancementProbe::Query
        };
        match crate::terminal_probe::startup(crate::terminal_probe::DEFAULT_TIMEOUT, keyboard_probe)
        {
            Ok(probe) => {
                tracing::info!(
                    duration_ms = %started_at.elapsed().as_millis(),
                    cursor_position = probe.cursor_position.is_some(),
                    default_colors = probe.default_colors.is_some(),
                    keyboard_enhancement_supported = ?probe.keyboard_enhancement_supported,
                    \"terminal startup probes completed\"
                );
                probe
            }
            Err(err) => {
                tracing::warn!(
                    duration_ms = %started_at.elapsed().as_millis(),
                    \"terminal startup probes failed: {err}\"
                );
                crate::terminal_probe::StartupProbe {
                    cursor_position: None,
                    default_colors: None,
                    keyboard_enhancement_supported: None,
                }
            }
        }
    };

    #[cfg(all(unix, target_os = \"solaris\"))]
    let startup_probe = crate::terminal_probe::StartupProbe {
        cursor_position: None,
        default_colors: None,
        keyboard_enhancement_supported: None,
    };
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch tui.rs startup probes")
    text = text.replace(old, new, 1)

tui_rs.write_text(text)

event_stream_rs = Path(sys.argv[2])
text = event_stream_rs.read_text()

old = """use std::task::Context;
use std::task::Poll;

use crossterm::event::Event;
use tokio::sync::broadcast;
"""
new = """use std::task::Context;
use std::task::Poll;
#[cfg(target_os = \"solaris\")]
use std::time::Duration;

use crossterm::event::Event;
#[cfg(target_os = \"solaris\")]
use crossterm::event::KeyCode;
#[cfg(target_os = \"solaris\")]
use crossterm::event::KeyEvent;
#[cfg(target_os = \"solaris\")]
use crossterm::event::KeyEventKind;
#[cfg(target_os = \"solaris\")]
use crossterm::event::KeyModifiers;
use tokio::sync::broadcast;
#[cfg(target_os = \"solaris\")]
use tokio::sync::mpsc;
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch event_stream.rs imports")
    text = text.replace(old, new, 1)

old = """/// Real crossterm-backed event source.
pub struct CrosstermEventSource(pub crossterm::event::EventStream);

impl Default for CrosstermEventSource {
    fn default() -> Self {
        Self(crossterm::event::EventStream::new())
    }
}

impl EventSource for CrosstermEventSource {
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<EventResult>> {
        // Crossterm's Windows backend expects Win32 input records. If VT input is inherited or
        // restored by another console client, navigation keys arrive as literal escape bytes.
        #[cfg(windows)]
        let _ = super::windows_console::ensure_input_record_mode();

        let result = Pin::new(&mut self.get_mut().0).poll_next(cx);

        // EventStream starts its blocking reader before returning Pending, so reassert the mode
        // after that transition as well.
        #[cfg(windows)]
        if result.is_pending() {
            let _ = super::windows_console::ensure_input_record_mode();
        }

        result
    }
}
"""
new = """/// Real crossterm-backed event source.
#[cfg(not(target_os = \"solaris\"))]
pub struct CrosstermEventSource(pub crossterm::event::EventStream);

#[cfg(not(target_os = \"solaris\"))]
impl Default for CrosstermEventSource {
    fn default() -> Self {
        Self(crossterm::event::EventStream::new())
    }
}

#[cfg(not(target_os = \"solaris\"))]
impl EventSource for CrosstermEventSource {
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<EventResult>> {
        // Crossterm's Windows backend expects Win32 input records. If VT input is inherited or
        // restored by another console client, navigation keys arrive as literal escape bytes.
        #[cfg(windows)]
        let _ = super::windows_console::ensure_input_record_mode();

        let result = Pin::new(&mut self.get_mut().0).poll_next(cx);

        // EventStream starts its blocking reader before returning Pending, so reassert the mode
        // after that transition as well.
        #[cfg(windows)]
        if result.is_pending() {
            let _ = super::windows_console::ensure_input_record_mode();
        }

        result
    }
}

#[cfg(target_os = \"solaris\")]
pub struct CrosstermEventSource {
    rx: mpsc::UnboundedReceiver<EventResult>,
    running: Arc<AtomicBool>,
}

#[cfg(target_os = \"solaris\")]
fn solaris_poll_stdin(timeout: Duration) -> std::io::Result<bool> {
    let timeout_ms = timeout.as_millis().min(i32::MAX as u128) as i32;
    let mut pollfd = libc::pollfd {
        fd: libc::STDIN_FILENO,
        events: libc::POLLIN,
        revents: 0,
    };
    let rc = unsafe { libc::poll(&mut pollfd, 1, timeout_ms) };
    if rc < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(rc > 0 && (pollfd.revents & libc::POLLIN) != 0)
}

#[cfg(target_os = \"solaris\")]
fn solaris_read_stdin(buf: &mut [u8]) -> std::io::Result<usize> {
    let rc = unsafe { libc::read(libc::STDIN_FILENO, buf.as_mut_ptr().cast(), buf.len()) };
    if rc < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(rc as usize)
    }
}

#[cfg(target_os = \"solaris\")]
fn solaris_utf8_char_width(byte: u8) -> usize {
    match byte {
        0x00..=0x7f => 1,
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf7 => 4,
        _ => 0,
    }
}

#[cfg(target_os = \"solaris\")]
fn solaris_key(code: KeyCode, modifiers: KeyModifiers) -> Event {
    Event::Key(KeyEvent::new(code, modifiers))
}

#[cfg(target_os = \"solaris\")]
fn solaris_parse_plain_key(bytes: &[u8]) -> Option<(Event, usize)> {
    let first = *bytes.first()?;
    match first {
        b'\\r' | b'\\n' => return Some((solaris_key(KeyCode::Enter, KeyModifiers::NONE), 1)),
        b'\\t' => return Some((solaris_key(KeyCode::Tab, KeyModifiers::NONE), 1)),
        0x7f | 0x08 => return Some((solaris_key(KeyCode::Backspace, KeyModifiers::NONE), 1)),
        0x01..=0x1a => {
            let ch = (b'a' + (first - 1)) as char;
            return Some((solaris_key(KeyCode::Char(ch), KeyModifiers::CONTROL), 1));
        }
        0x1c => return Some((solaris_key(KeyCode::Char('4'), KeyModifiers::CONTROL), 1)),
        0x1d => return Some((solaris_key(KeyCode::Char('5'), KeyModifiers::CONTROL), 1)),
        0x1e => return Some((solaris_key(KeyCode::Char('6'), KeyModifiers::CONTROL), 1)),
        0x1f => return Some((solaris_key(KeyCode::Char('7'), KeyModifiers::CONTROL), 1)),
        0x20..=0x7e => {
            return Some((solaris_key(KeyCode::Char(first as char), KeyModifiers::NONE), 1));
        }
        _ => {}
    }

    let width = solaris_utf8_char_width(first);
    if width == 0 || bytes.len() < width {
        return None;
    }
    let slice = &bytes[..width];
    let s = std::str::from_utf8(slice).ok()?;
    let ch = s.chars().next()?;
    Some((solaris_key(KeyCode::Char(ch), KeyModifiers::NONE), width))
}

#[cfg(target_os = \"solaris\")]
fn solaris_apply_alt(event: Event) -> Event {
    match event {
        Event::Key(key) => Event::Key(KeyEvent::new(key.code, key.modifiers | KeyModifiers::ALT)),
        other => other,
    }
}

#[cfg(target_os = \"solaris\")]
fn solaris_parse_escape(bytes: &[u8], flush_escape: bool) -> Option<(Event, usize)> {
    if bytes.first().copied()? != 0x1b {
        return None;
    }
    if bytes.len() == 1 {
        return flush_escape.then(|| (solaris_key(KeyCode::Esc, KeyModifiers::NONE), 1));
    }

    if bytes[1] == b'[' || bytes[1] == b'O' {
        for idx in 2..bytes.len() {
            let final_byte = bytes[idx];
            if !(0x40..=0x7e).contains(&final_byte) {
                continue;
            }
            let params = std::str::from_utf8(&bytes[2..idx]).unwrap_or(\"\");
            let event = match final_byte {
                b'A' => solaris_key(KeyCode::Up, KeyModifiers::NONE),
                b'B' => solaris_key(KeyCode::Down, KeyModifiers::NONE),
                b'C' => solaris_key(KeyCode::Right, KeyModifiers::NONE),
                b'D' => solaris_key(KeyCode::Left, KeyModifiers::NONE),
                b'H' => solaris_key(KeyCode::Home, KeyModifiers::NONE),
                b'F' => solaris_key(KeyCode::End, KeyModifiers::NONE),
                b'Z' => solaris_key(KeyCode::BackTab, KeyModifiers::SHIFT),
                b'~' => match params {
                    \"1\" | \"7\" => solaris_key(KeyCode::Home, KeyModifiers::NONE),
                    \"2\" => solaris_key(KeyCode::Insert, KeyModifiers::NONE),
                    \"3\" => solaris_key(KeyCode::Delete, KeyModifiers::NONE),
                    \"4\" | \"8\" => solaris_key(KeyCode::End, KeyModifiers::NONE),
                    \"5\" => solaris_key(KeyCode::PageUp, KeyModifiers::NONE),
                    \"6\" => solaris_key(KeyCode::PageDown, KeyModifiers::NONE),
                    _ => solaris_key(KeyCode::Esc, KeyModifiers::NONE),
                },
                _ => solaris_key(KeyCode::Esc, KeyModifiers::NONE),
            };
            return Some((event, idx + 1));
        }
        return None;
    }

    solaris_parse_plain_key(&bytes[1..])
        .map(|(event, consumed)| (solaris_apply_alt(event), consumed + 1))
}

#[cfg(target_os = \"solaris\")]
fn solaris_parse_event(bytes: &[u8], flush_escape: bool) -> Option<(Event, usize)> {
    match bytes.first().copied()? {
        0x1b => solaris_parse_escape(bytes, flush_escape),
        _ => solaris_parse_plain_key(bytes),
    }
}

#[cfg(target_os = \"solaris\")]
impl Default for CrosstermEventSource {
    fn default() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        let running = Arc::new(AtomicBool::new(true));
        let thread_running = Arc::clone(&running);

        std::thread::Builder::new()
            .name(\"solaris-stdin-input\".to_string())
            .spawn(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let mut pending = Vec::new();
                    let mut buf = [0u8; 64];
                    while thread_running.load(Ordering::Relaxed) {
                        match solaris_poll_stdin(Duration::from_millis(100)) {
                            Ok(true) => match solaris_read_stdin(&mut buf) {
                                Ok(0) => {}
                                Ok(n) => {
                                    pending.extend_from_slice(&buf[..n]);
                                    while let Some((event, consumed)) =
                                        solaris_parse_event(&pending, false)
                                    {
                                        if tx.send(Ok(event)).is_err() {
                                            tracing::warn!(\"solaris input receiver dropped\");
                                            return;
                                        }
                                        pending.drain(..consumed);
                                    }
                                }
                                Err(err) => {
                                    tracing::warn!(error = %err, \"solaris stdin read failed\");
                                }
                            },
                            Ok(false) => {
                                if let Some((event, consumed)) = solaris_parse_event(&pending, true)
                                {
                                    if tx.send(Ok(event)).is_err() {
                                        tracing::warn!(\"solaris input receiver dropped\");
                                        return;
                                    }
                                    pending.drain(..consumed);
                                }
                            }
                            Err(err) => {
                                tracing::warn!(error = %err, \"solaris stdin poll failed\");
                            }
                        }
                    }
                }));
                if let Err(payload) = result {
                    let panic_msg = if let Some(msg) = payload.downcast_ref::<&str>() {
                        *msg
                    } else if let Some(msg) = payload.downcast_ref::<String>() {
                        msg.as_str()
                    } else {
                        \"unknown panic payload\"
                    };
                    tracing::error!(panic_msg, \"solaris stdin input thread panicked\");
                }
            })
            .expect(\"failed to spawn solaris stdin input thread\");

        Self { rx, running }
    }
}

#[cfg(target_os = \"solaris\")]
impl Drop for CrosstermEventSource {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
    }
}

#[cfg(target_os = \"solaris\")]
impl EventSource for CrosstermEventSource {
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<EventResult>> {
        self.get_mut().rx.poll_recv(cx)
    }
}
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch event_stream.rs crossterm source")
    text = text.replace(old, new, 1)

old = """                    Poll::Ready(Some(Err(_))) | Poll::Ready(None) => {
                        *state = EventBrokerState::Start;
                        return Poll::Ready(None);
                    }
"""
new = """                    Poll::Ready(Some(Err(err))) => {
                        #[cfg(target_os = \"solaris\")]
                        tracing::warn!(error = %err, \"resetting tui event source after read error\");
                        *state = EventBrokerState::Start;
                        continue;
                    }
                    Poll::Ready(None) => {
                        #[cfg(target_os = \"solaris\")]
                        tracing::warn!(\"resetting tui event source after unexpected EOF\");
                        *state = EventBrokerState::Start;
                        continue;
                    }
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch event_stream.rs error handling")
    text = text.replace(old, new, 1)

old = """            Event::Key(key_event) => {
                #[cfg(unix)]
                if crate::tui::job_control::SUSPEND_KEY.is_press(key_event) {
"""
new = """            Event::Key(key_event) => {
                #[cfg(target_os = \"solaris\")]
                let key_event = crossterm::event::KeyEvent {
                    kind: KeyEventKind::Press,
                    ..key_event
                };

                #[cfg(unix)]
                if crate::tui::job_control::SUSPEND_KEY.is_press(key_event) {
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch event_stream.rs solaris key kind")
    text = text.replace(old, new, 1)

event_stream_rs.write_text(text)
PY
}

v8_install_matches_pin() {
  local stamp=${V8_INSTALL_DIR}/.source-ref
  local current=

  [[ -f "${V8_INSTALL_DIR}/lib/librusty_v8.a" ]] || return 1
  [[ -f "${V8_INSTALL_DIR}/share/src_binding.rs" ]] || return 1
  [[ -f "${stamp}" ]] || return 1

  current=$(tr '\n' ' ' < "${stamp}" | sed 's/ $//')
  [[ "${current}" == "${V8_GIT_URL} ${V8_GIT_REF}" ]]
}

refresh_cached_rusty_v8_archive() {
  local cached_dir=${CODEX_SRC_DIR}/target/release/gn_out/obj
  local cached_archive=${cached_dir}/librusty_v8.a
  local cached_stamp=${cached_dir}/.source-ref
  local target_dir=${CODEX_SRC_DIR}/target/release
  local v8_rlib=
  local current=
  local desired="${V8_GIT_URL} ${V8_GIT_REF}"
  local refresh=0

  [[ -f "${cached_archive}" ]] || return 0

  if [[ -f "${cached_stamp}" ]]; then
    current=$(tr '\n' ' ' < "${cached_stamp}" | sed 's/ $//')
  fi

  if ! cmp -s "${V8_INSTALL_DIR}/lib/librusty_v8.a" "${cached_archive}" ||
     [[ "${current}" != "${desired}" ]]; then
    refresh=1
  fi

  for v8_rlib in "${target_dir}"/deps/libv8-*.rlib; do
    [[ -e "${v8_rlib}" ]] || continue
    if [[ -f "${cached_stamp}" && "${v8_rlib}" -ot "${cached_stamp}" ]]; then
      refresh=1
      break
    fi
  done

  if (( refresh )); then
    log "Refreshing cargo cached librusty_v8.a"
    rm -f "${target_dir}/deps/libv8-"*.rlib
    rm -f "${target_dir}/deps/libv8-"*.rmeta
    rm -f "${target_dir}/deps/v8-"*.d
    rm -rf "${target_dir}/build/v8-"*
    rm -rf "${target_dir}/.fingerprint/v8-"*
    mkdir -p "${cached_dir}"
    cp "${V8_INSTALL_DIR}/lib/librusty_v8.a" "${cached_archive}"
    printf '%s\n%s\n' "${V8_GIT_URL}" "${V8_GIT_REF}" > "${cached_stamp}"
  fi
}



prepare_rust
build_env_common

v8_install_matches_pin || bash "${TOP}/build-v8.sh"

ensure_codex_source
apply_patch_series "${CODEX_REPO_DIR}" "${TOP}/patches/codex"
patch_tui_solaris_terminal_input
vendor_rust_sources "${CODEX_SRC_DIR}" "${CODEX_VENDOR_DIR}" "" unlocked

# Apply the remaining Solaris vendored-crate rewrites after cargo vendor.
# These stay scripted because each change must also refresh the vendored
# crate checksum metadata in .cargo-checksum.json.
patch_vendored_nix_termios
patch_vendored_tree_sitter_endian
patch_vendored_fslock
patch_vendored_onig_sys_alloca
patch_vendored_mio_event_ports

export GN="${GN_INSTALL_DIR}/bin/gn"
export RUSTY_V8_ARCHIVE="${V8_INSTALL_DIR}/lib/librusty_v8.a"
export RUSTY_V8_SRC_BINDING_PATH="${V8_INSTALL_DIR}/share/src_binding.rs"
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_PROFILE_RELEASE_DEBUG=none
export CARGO_PROFILE_RELEASE_STRIP=symbols
# The upstream release profile's default opt/codegen settings can spend hours
# in LLVM on large Codex crates on Solaris. Keep the installed binary stripped
# and optimized, but use a profile that reliably finishes on the build hosts.
export CARGO_PROFILE_RELEASE_OPT_LEVEL=${CARGO_PROFILE_RELEASE_OPT_LEVEL:-1}
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-16}
export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }-C link-arg=-lstdc++ -C link-arg=-lssp"
export LD_OPTIONS=
export LD_EXEC_OPTIONS=
export LD_PIE_OPTIONS=
export LD_SHARED_OPTIONS=

refresh_cached_rusty_v8_archive

jobs=${SOLARIS_CODEX_JOBS:-4}
jobs=$(printf %s "${jobs}" | tr -cd '0-9')
[[ -n "${jobs}" ]] || jobs=4

log "Building codex and codex-code-mode-host with ${jobs} jobs"
(
  cd "${CODEX_SRC_DIR}"
  # Avoid carrying Solaris local dynamic symbol names in the installed binary.
  "${CARGO}" rustc --release --offline -j "${jobs}" -p codex-cli --bin codex -- \
    -C link-arg=-z -C link-arg=noldynsym
  "${CARGO}" rustc --release --offline -j "${jobs}" \
    -p codex-code-mode-host --bin codex-code-mode-host -- \
    -C link-arg=-z -C link-arg=noldynsym
)

codex_install_dir="${CODEX_INSTALL_DIR}/bin"
mkdir -p "${codex_install_dir}"
for codex_executable in codex codex-code-mode-host; do
  (
    codex_install_tmp=$(mktemp "${codex_install_dir}/.${codex_executable}.XXXXXX")
    trap 'rm -f "${codex_install_tmp}"' EXIT
    cp -p "${CODEX_SRC_DIR}/target/release/${codex_executable}" "${codex_install_tmp}"
    mv -f "${codex_install_tmp}" "${codex_install_dir}/${codex_executable}"
  )
done

log "Installed codex and codex-code-mode-host to ${codex_install_dir}"
