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



prepare_rust
build_env_common

[[ -f "${V8_INSTALL_DIR}/lib/librusty_v8.a" ]] || bash "${TOP}/build-v8.sh"

ensure_codex_source
apply_patch_series "${CODEX_REPO_DIR}" "${TOP}/patches/codex"
vendor_rust_sources "${CODEX_SRC_DIR}" "${CODEX_VENDOR_DIR}"

# Apply the remaining Solaris vendored-crate rewrites after cargo vendor.
# These stay scripted because each change must also refresh the vendored
# crate checksum metadata in .cargo-checksum.json.
patch_vendored_nix_termios
patch_vendored_tree_sitter_endian
patch_vendored_fslock
patch_vendored_onig_sys_alloca

export GN="${GN_INSTALL_DIR}/bin/gn"
export RUSTY_V8_ARCHIVE="${V8_INSTALL_DIR}/lib/librusty_v8.a"
export RUSTY_V8_SRC_BINDING_PATH="${V8_INSTALL_DIR}/share/src_binding.rs"
export CARGO_PROFILE_RELEASE_LTO=false
export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }-C link-arg=-lstdc++ -C link-arg=-lssp"
export LD_OPTIONS=
export LD_EXEC_OPTIONS=
export LD_PIE_OPTIONS=
export LD_SHARED_OPTIONS=

jobs=${SOLARIS_CODEX_JOBS:-$(psrinfo | wc -l 2>/dev/null || printf 40)}
jobs=$(printf %s "${jobs}" | tr -cd '0-9')
[[ -n "${jobs}" ]] || jobs=40

log "Building codex with ${jobs} jobs"
(
  cd "${CODEX_SRC_DIR}"
  "${CARGO}" build --release --offline -j "${jobs}" -p codex-cli --bin codex
)

mkdir -p "${CODEX_INSTALL_DIR}/bin"
cp "${CODEX_SRC_DIR}/target/release/codex" "${CODEX_INSTALL_DIR}/bin/codex"

log "Installed codex to ${CODEX_INSTALL_DIR}/bin/codex"
