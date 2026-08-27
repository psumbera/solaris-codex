#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

prepare_v8_vendor_config() {
  local extra_config=${BUILD_DIR}/v8-upstream-config.toml

  rm -f "${extra_config}"
  if [[ -f "${V8_SRC_DIR}/.cargo/config.toml" ]]; then
    cp "${V8_SRC_DIR}/.cargo/config.toml" "${extra_config}"
    printf '%s\n' "${extra_config}"
  fi
}

patch_rusty_v8_build_rs() {
  local build_rs=${V8_SRC_DIR}/build.rs

  python3 - "${build_rs}" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
changed = False

old = """  if need_gn_ninja_download() {\n    download_ninja_gn_binaries();\n  }\n\n  download_rust_toolchain();\n\n  // `#[cfg(...)]` attributes don't work as expected from build.rs -- they refer to the configuration\n  // of the host system which the build.rs script will be running on. In short, `cfg!(target_<os/arch>)`\n  // is actually the host os/arch instead of target os/arch while cross compiling. Instead, Environment variables\n  // are the officially approach to get the target os/arch in build.rs.\n  let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();\n"""
new = """  if need_gn_ninja_download() {\n    download_ninja_gn_binaries();\n  }\n\n  // Solaris/Illumos builds use the workspace Rust toolchain instead of\n  // Chromium's packaged toolchain artifacts.\n  let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();\n  if target_os != "solaris" && target_os != "illumos" {\n    download_rust_toolchain();\n  }\n\n  // `#[cfg(...)]` attributes don't work as expected from build.rs -- they refer to the configuration\n  // of the host system which the build.rs script will be running on. In short, `cfg!(target_<os/arch>)`\n  // is actually the host os/arch instead of target os/arch while cross compiling. Instead, Environment variables\n  // are the officially approach to get the target os/arch in build.rs.\n"""

if 'target_os != "solaris" && target_os != "illumos"' not in text:
    if old not in text:
        raise SystemExit("failed to patch build.rs for Solaris toolchain handling")
    text = text.replace(old, new, 1)
    changed = True

old = """  // Filter out V8's custom libc++ and module args from GN, we'll add them back\n  // manually with correct ordering for bindgen\n  let filtered_args: Vec<&str> = args\n    .iter()\n    .filter(|arg| {\n      !arg.starts_with("-fmodule")\n        && !arg.starts_with("-fno-implicit-module")\n        && !arg.starts_with("-Xclang")\n        && !arg.contains("DUSE_LIBCXX_MODULES")\n        && !arg.contains("-nostdinc++")\n        && !arg.contains("-isystem")\n        && !arg.contains("libc++")\n    })\n    .copied()\n    .collect();\n\n  // Use V8's custom libc++ headers (requires Clang 19+ libclang via LIBCLANG_PATH)\n  // IMPORTANT: libc++ headers must come before clang builtins\n  let mut clang_args = vec![\n    "-x".to_string(),\n    "c++".to_string(),\n    "-std=c++20".to_string(),\n    "-nostdinc++".to_string(),\n    "-Iv8/include".to_string(),\n    "-I.".to_string(),\n    "-isystembuildtools/third_party/libc++".to_string(),\n    "-isystemthird_party/libc++/src/include".to_string(),\n    "-isystemthird_party/libc++abi/src/include".to_string(),\n  ];\n\n  let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();\n"""
new = """  let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();\n\n  // Solaris/Illumos bindgen works with the GN-generated preprocessor defines\n  // and the system default C++ headers. Injecting Chromium's libc++ headers\n  // there conflicts with the Solaris libc declarations in /usr/include.\n  let filtered_args: Vec<&str> = if target_os == "solaris" || target_os == "illumos" {\n    args\n      .iter()\n      .filter(|arg| {\n        !arg.starts_with("-fmodule")\n          && !arg.starts_with("-fno-implicit-module")\n          && !arg.starts_with("-Xclang")\n          && !arg.contains("DUSE_LIBCXX_MODULES")\n      })\n      .copied()\n      .collect()\n  } else {\n    // Filter out V8's custom libc++ and module args from GN, we'll add them back\n    // manually with correct ordering for bindgen.\n    args\n      .iter()\n      .filter(|arg| {\n        !arg.starts_with("-fmodule")\n          && !arg.starts_with("-fno-implicit-module")\n          && !arg.starts_with("-Xclang")\n          && !arg.contains("DUSE_LIBCXX_MODULES")\n          && !arg.contains("-nostdinc++")\n          && !arg.contains("-isystem")\n          && !arg.contains("libc++")\n      })\n      .copied()\n      .collect()\n  };\n\n  let mut clang_args = vec![\n    "-x".to_string(),\n    "c++".to_string(),\n    "-std=c++20".to_string(),\n    "-Iv8/include".to_string(),\n    "-I.".to_string(),\n  ];\n\n  if target_os != "solaris" && target_os != "illumos" {\n    // Use V8's custom libc++ headers (requires Clang 19+ libclang via LIBCLANG_PATH).\n    // IMPORTANT: libc++ headers must come before clang builtins.\n    clang_args.push("-nostdinc++".to_string());\n    clang_args.push("-isystembuildtools/third_party/libc++".to_string());\n    clang_args.push("-isystemthird_party/libc++/src/include".to_string());\n    clang_args.push("-isystemthird_party/libc++abi/src/include".to_string());\n  }\n"""

if 'Solaris/Illumos bindgen works with the GN-generated preprocessor defines' not in text:
    if old not in text:
        raise SystemExit("failed to patch build.rs bindgen handling for Solaris")
    text = text.replace(old, new, 1)
    changed = True

if changed:
    p.write_text(text)
PY
}

patch_vendored_fslock() {
  local vendor_root=${V8_VENDOR_DIR}/fslock
  local unix_rs=${vendor_root}/src/unix.rs
  local checksum_json=${vendor_root}/.cargo-checksum.json

  python3 - "${unix_rs}" "${checksum_json}" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

unix_rs = Path(sys.argv[1])
checksum_json = Path(sys.argv[2])

text = unix_rs.read_text()
old = """/// Tries to lock a file and blocks until it is possible to lock.\npub fn lock(fd: FileDesc) -> Result<(), Error> {\n    let res = unsafe { libc::flock(fd, libc::LOCK_EX) };\n    if res >= 0 {\n        Ok(())\n    } else {\n        Err(Error::last_os_error())\n    }\n}\n\n/// Tries to lock a file but returns as soon as possible if already locked.\npub fn try_lock(fd: FileDesc) -> Result<bool, Error> {\n    let res = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };\n    if res >= 0 {\n        Ok(true)\n    } else {\n        let err = errno();\n        if err == libc::EWOULDBLOCK || err == libc::EINTR {\n            Ok(false)\n        } else {\n            Err(Error::from_raw_os_error(err as i32))\n        }\n    }\n}\n\n/// Unlocks the file.\npub fn unlock(fd: FileDesc) -> Result<(), Error> {\n    let res = unsafe { libc::flock(fd, libc::LOCK_UN) };\n    if res >= 0 {\n        Ok(())\n    } else {\n        Err(Error::last_os_error())\n    }\n}\n"""
new = """#[cfg(any(target_os = "solaris", target_os = "illumos"))]\nfn set_lock(fd: FileDesc, cmd: libc::c_int, lock_type: libc::c_short) -> Result<(), Error> {\n    let mut lock = libc::flock {\n        l_type: lock_type,\n        l_whence: libc::SEEK_SET as libc::c_short,\n        l_start: 0,\n        l_len: 0,\n        l_sysid: 0,\n        l_pid: 0,\n        l_pad: [0; 4],\n    };\n    let res = unsafe { libc::fcntl(fd, cmd, &mut lock) };\n    if res >= 0 {\n        Ok(())\n    } else {\n        Err(Error::last_os_error())\n    }\n}\n\n/// Tries to lock a file and blocks until it is possible to lock.\n#[cfg(not(any(target_os = "solaris", target_os = "illumos")))]\npub fn lock(fd: FileDesc) -> Result<(), Error> {\n    let res = unsafe { libc::flock(fd, libc::LOCK_EX) };\n    if res >= 0 {\n        Ok(())\n    } else {\n        Err(Error::last_os_error())\n    }\n}\n\n/// Tries to lock a file and blocks until it is possible to lock.\n#[cfg(any(target_os = "solaris", target_os = "illumos"))]\npub fn lock(fd: FileDesc) -> Result<(), Error> {\n    set_lock(fd, libc::F_SETLKW, libc::F_WRLCK)\n}\n\n/// Tries to lock a file but returns as soon as possible if already locked.\n#[cfg(not(any(target_os = "solaris", target_os = "illumos")))]\npub fn try_lock(fd: FileDesc) -> Result<bool, Error> {\n    let res = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };\n    if res >= 0 {\n        Ok(true)\n    } else {\n        let err = errno();\n        if err == libc::EWOULDBLOCK || err == libc::EINTR {\n            Ok(false)\n        } else {\n            Err(Error::from_raw_os_error(err as i32))\n        }\n    }\n}\n\n/// Tries to lock a file but returns as soon as possible if already locked.\n#[cfg(any(target_os = "solaris", target_os = "illumos"))]\npub fn try_lock(fd: FileDesc) -> Result<bool, Error> {\n    let mut lock = libc::flock {\n        l_type: libc::F_WRLCK,\n        l_whence: libc::SEEK_SET as libc::c_short,\n        l_start: 0,\n        l_len: 0,\n        l_sysid: 0,\n        l_pid: 0,\n        l_pad: [0; 4],\n    };\n    let res = unsafe { libc::fcntl(fd, libc::F_SETLK, &mut lock) };\n    if res >= 0 {\n        Ok(true)\n    } else {\n        let err = errno();\n        if err == libc::EWOULDBLOCK || err == libc::EAGAIN || err == libc::EACCES || err == libc::EINTR {\n            Ok(false)\n        } else {\n            Err(Error::from_raw_os_error(err as i32))\n        }\n    }\n}\n\n/// Unlocks the file.\n#[cfg(not(any(target_os = "solaris", target_os = "illumos")))]\npub fn unlock(fd: FileDesc) -> Result<(), Error> {\n    let res = unsafe { libc::flock(fd, libc::LOCK_UN) };\n    if res >= 0 {\n        Ok(())\n    } else {\n        Err(Error::last_os_error())\n    }\n}\n\n/// Unlocks the file.\n#[cfg(any(target_os = "solaris", target_os = "illumos"))]\npub fn unlock(fd: FileDesc) -> Result<(), Error> {\n    set_lock(fd, libc::F_SETLK, libc::F_UNLCK)\n}\n"""

if "fn set_lock(fd: FileDesc, cmd: libc::c_int, lock_type: libc::c_short)" not in text:
    if old not in text:
        raise SystemExit("failed to patch vendored fslock for Solaris")
    text = text.replace(old, new, 1)
    unix_rs.write_text(text)

digest = hashlib.sha256(unix_rs.read_bytes()).hexdigest()
data = json.loads(checksum_json.read_text())
data["files"]["src/unix.rs"] = digest
checksum_json.write_text(json.dumps(data, separators=(",", ":")))
PY
}

patch_vendored_bindgen_var() {
  local bindgen_var=${V8_VENDOR_DIR}/bindgen/ir/var.rs
  local checksum_json=${V8_VENDOR_DIR}/bindgen/.cargo-checksum.json

  python3 - "${bindgen_var}" "${checksum_json}" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

var_rs = Path(sys.argv[1])
checksum_json = Path(sys.argv[2])

text = var_rs.read_text()
old_diag = (
    '                        eprintln!("bindgen const parse failure name={name} '
    'cursor={:?} ty={ty:?}", cursor);\n'
)
if old_diag in text:
    text = text.replace(old_diag, "", 1)

marker = "                    Err(e) => {\n"
insert = (
    '                        if matches!(ty.kind(), CXType_Elaborated) && '
    'format!("{ty:?}").contains("size_t") {\n'
    '                            eprintln!("bindgen skipping unresolved size_t '
    'constant name={name} cursor={:?} ty={ty:?}", cursor);\n'
    '                            return Err(ParseError::Continue);\n'
    "                        }\n"
)

if insert not in text:
    if marker not in text:
        raise SystemExit("failed to patch bindgen var.rs for Solaris size_t handling")
    text = text.replace(marker, marker + insert, 1)
    var_rs.write_text(text)

digest = hashlib.sha256(var_rs.read_bytes()).hexdigest()
data = json.loads(checksum_json.read_text())
data["files"]["ir/var.rs"] = digest
checksum_json.write_text(json.dumps(data, separators=(",", ":")))
PY
}

patch_rustc_wrapper() {
  local rustc_wrapper=${V8_SRC_DIR}/build/rust/gni_impl/rustc_wrapper.py

  python3 - "${rustc_wrapper}" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()

old = """  abs_build_root = os.getcwd().replace('\\\\', '/') + '/'\n  is_windows = sys.platform == 'win32' or args.target_windows\n\n  rustc_args.extend(["-Clink-arg=%s" % arg for arg in ldflags])\n"""
new = """  abs_build_root = os.getcwd().replace('\\\\', '/') + '/'\n  is_windows = sys.platform == 'win32' or args.target_windows\n\n  solaris_unsupported_ldflags = {\n      "-Wl,--as-needed",\n      "-Wl,--build-id",\n      "-Wl,--disable-new-dtags",\n      "-Wl,--gc-sections",\n      "-Wl,-z,noexecstack",\n      "-Wl,-z,relro",\n  }\n  ldflags = [arg for arg in ldflags if arg not in solaris_unsupported_ldflags]\n  rustc_args.extend(["-Clink-arg=%s" % arg for arg in ldflags])\n"""
if "solaris_unsupported_ldflags = {" not in text:
    if old not in text:
        raise SystemExit("failed to patch rustc_wrapper.py ldflags block")
    text = text.replace(old, new, 1)

old = """  with open(args.rsp) as rspfile:\n    rsp_args = [l.rstrip() for l in rspfile.read().split(' ') if l.rstrip()]\n"""
new = """  with open(args.rsp) as rspfile:\n    rsp_args = shlex.split(rspfile.read())\n"""
if "rsp_args = shlex.split(rspfile.read())" not in text:
    if old not in text:
        raise SystemExit("failed to patch rustc_wrapper.py rsp parsing")
    text = text.replace(old, new, 1)

old = """  rsp_args = [remove_gn_escaping_from_rsp_args(arg) for arg in rsp_args]\n  rsp_args = _ExpandNestedRustStyleRspFiles(rsp_args)\n  out_rsp = str(args.rsp) + ".rust"\n"""
new = """  rsp_args = [remove_gn_escaping_from_rsp_args(arg) for arg in rsp_args]\n  rsp_args = _ExpandNestedRustStyleRspFiles(rsp_args)\n  # The Solaris wrapper uses stable Rust, so drop Chromium nightly-only\n  # -Z flags before invoking rustc.\n  rsp_args = [arg for arg in rsp_args if not arg.startswith("-Z")]\n  out_rsp = str(args.rsp) + ".rust"\n"""
if 'arg.startswith("-Z")' not in text:
    if old not in text:
        raise SystemExit("failed to patch rustc_wrapper.py rsp block")
    text = text.replace(old, new, 1)

if 'env.setdefault("RUSTC_BOOTSTRAP", "1")' not in text:
    marker = '  env = os.environ.copy() | rustenv\n'
    if marker not in text:
        raise SystemExit("failed to patch rustc_wrapper.py env marker")
    text = text.replace(marker, marker + '  env.setdefault("RUSTC_BOOTSTRAP", "1")\n', 1)

if 'if not os.path.exists(args.depfile):' not in text:
    marker = '\n  final_depfile_lines = []\n'
    insert = """\n  if not os.path.exists(args.depfile):\n    dep_target = normalize_path(str(args.o), abs_build_root)\n    dep_inputs = " ".join(sorted(normalize_path(src, abs_build_root) for src in sources))\n    with action_helpers.atomic_output(args.depfile, only_if_changed=False) as output:\n      output.write(f"{dep_target}: {dep_inputs}\\n".encode("utf-8"))\n\n  final_depfile_lines = []\n"""
    if marker not in text:
        raise SystemExit("failed to patch rustc_wrapper.py depfile marker")
    text = text.replace(marker, insert, 1)

old = """  if dirty:  # we made a change, let's write out the file\n    with action_helpers.atomic_output(args.depfile,\n                                      only_if_changed=False) as output:\n      output.write("\\n".join(final_depfile_lines).encode("utf-8"))\n  return r.returncode\n\n\nif __name__ == '__main__':\n"""
new = """  if dirty:  # we made a change, let's write out the file\n    with action_helpers.atomic_output(args.depfile,\n                                      only_if_changed=False) as output:\n      output.write("\\n".join(final_depfile_lines).encode("utf-8"))\n\n\nif __name__ == '__main__':\n"""
if "return r.returncode" in text:
    if old not in text:
        raise SystemExit("failed to patch rustc_wrapper.py return block")
    text = text.replace(old, new, 1)

p.write_text(text)
PY
}
patch_gcc_toolchain_ar() {
  local gcc_toolchain=${V8_SRC_DIR}/build/toolchain/gcc_toolchain.gni
  local linux_toolchain=${V8_SRC_DIR}/build/toolchain/linux/BUILD.gn

  python3 - "${gcc_toolchain}" "${linux_toolchain}" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
old = """      if (current_os == "aix") {\n        # AIX does not support either -D (deterministic output) or response\n        # files.\n        command = "$ar -X64 {{arflags}} -r -c {{output}} {{inputs}}"\n      } else {\n        rspfile = "{{output}}.rsp"\n        rspfile_content = "{{inputs}}"\n        command = "\\"$ar\\" {{arflags}} -r -c -D {{output}} @\\"$rspfile\\""\n      }\n"""
new = """      if (current_os == "aix") {\n        # AIX does not support either -D (deterministic output) or response\n        # files.\n        command = "$ar -X64 {{arflags}} -r -c {{output}} {{inputs}}"\n      } else if (target_os == "solaris") {\n        # Solaris /usr/bin/ar does not support GNU -D or @rsp syntax.\n        command = "$ar {{arflags}} -r -c {{output}} {{inputs}}"\n      } else {\n        rspfile = "{{output}}.rsp"\n        rspfile_content = "{{inputs}}"\n        command = "\\"$ar\\" {{arflags}} -r -c -D {{output}} @\\"$rspfile\\""\n      }\n"""
if 'target_os == "solaris"' not in text:
    if old not in text:
        raise SystemExit("failed to patch gcc_toolchain.gni alink block")
    text = text.replace(old, new, 1)
p.write_text(text)

# Recent GN versions track the archiver executable as an explicit Ninja input.
# A bare "ar" is then interpreted relative to the output directory rather than
# resolved through PATH.  Use Solaris' absolute archiver path for every
# toolchain instantiated during this native build.
p = Path(sys.argv[2])
text = p.read_text()
old = '  ar = "ar"\n'
invalid = '  ar = target_os == "solaris" ? "/usr/bin/ar" : "ar"\n'
new = '''  ar = "ar"
  if (target_os == "solaris") {
    ar = "/usr/bin/ar"
  }
'''
if new not in text:
    if invalid in text:
        text = text.replace(invalid, new)
    elif old in text:
        text = text.replace(old, new)
    else:
        raise SystemExit("failed to patch linux/BUILD.gn ar assignments")
p.write_text(text)
PY
}

patch_wrapper_utils() {
  local wrapper_utils=${V8_SRC_DIR}/build/toolchain/wrapper_utils.py

  python3 - "${wrapper_utils}" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
old = """  # We want to link rlibs as --whole-archive if they are part of a unit test\n  # target. This is determined by switch `-LinkWrapper,add-whole-archive`.\n  command = whole_archive.wrap_with_whole_archive(command)\n\n  result = subprocess.call(command, env=env)\n"""
new = """  # We want to link rlibs as --whole-archive if they are part of a unit test\n  # target. This is determined by switch `-LinkWrapper,add-whole-archive`.\n  command = whole_archive.wrap_with_whole_archive(command)\n\n  if sys.platform.startswith("sunos"):\n    solaris_unsupported_ldflags = {\n        "-Wl,--as-needed",\n        "-Wl,--build-id",\n        "-Wl,--disable-new-dtags",\n        "-Wl,--gc-sections",\n        "-Wl,-z,noexecstack",\n        "-Wl,-z,relro",\n    }\n    command = [arg for arg in command if arg not in solaris_unsupported_ldflags]\n\n    # GN threads Rust sysroot .rlibs through ldflags, which places them before\n    # the main object and crate groups. Solaris ld is order-sensitive for static\n    # archives, so move those .rlibs into the trailing --start-group/--end-group.\n    late_rust_archives = []\n\n    def add_late_archive(path):\n      if path not in late_rust_archives:\n        late_rust_archives.append(path)\n\n    if "-o" in command:\n      output_index = command.index("-o")\n      filtered = command[:1]\n      for arg in command[1:output_index]:\n        if arg.endswith(".rlib"):\n          add_late_archive(arg)\n        else:\n          filtered.append(arg)\n      filtered.extend(command[output_index:])\n      command = filtered\n\n    for arg in command:\n      if not arg.startswith("@"):\n        continue\n      rsp_path = arg[1:].strip("\\"")\n      if not os.path.exists(rsp_path):\n        continue\n      with open(rsp_path) as rsp_file:\n        for rsp_arg in shlex.split(rsp_file.read()):\n          if rsp_arg.startswith("obj/build/rust/") and rsp_arg.endswith(".a"):\n            add_late_archive(rsp_arg)\n\n    if late_rust_archives:\n      end_group = "-Wl,--end-group"\n      insert_at = len(command)\n      if end_group in command:\n        insert_at = len(command) - 1 - command[::-1].index(end_group)\n      command[insert_at:insert_at] = late_rust_archives\n\n    command.extend(["-lssp", "-lssp_nonshared"])\n\n  result = subprocess.call(command, env=env)\n"""
if "late_rust_archives = []" not in text:
    if old not in text:
        raise SystemExit("failed to patch wrapper_utils.py Solaris link block")
    text = text.replace(old, new, 1)
p.write_text(text)
PY
}

patch_rust_custom_sysroot_inputs() {
  local rust_gni=${V8_SRC_DIR}/build/config/rust.gni
  local std_build=${V8_SRC_DIR}/build/rust/std/BUILD.gn
  local cargo_crate_gni=${V8_SRC_DIR}/build/rust/cargo_crate.gni

  python3 - "${rust_gni}" "${std_build}" "${cargo_crate_gni}" <<'PY'
from pathlib import Path
import sys

rust_gni = Path(sys.argv[1])
text = rust_gni.read_text()
old = """if (host_os == "win") {
  rustc_wrapper_inputs += [ "//third_party/rust-toolchain/bin/rustc.exe" ]
} else {
  rustc_wrapper_inputs += [ "//third_party/rust-toolchain/bin/rustc" ]
}
"""
new = """if (host_os == "win") {
  rustc_wrapper_inputs += [ "${rust_sysroot}/bin/rustc.exe" ]
} else {
  rustc_wrapper_inputs += [ "${rust_sysroot}/bin/rustc" ]
}
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch rust.gni rustc_wrapper_inputs")
    text = text.replace(old, new, 1)
    rust_gni.write_text(text)

std_build = Path(sys.argv[2])
text = std_build.read_text()
old = """      if (host_os == "win") {
        inputs = [ "//third_party/rust-toolchain/bin/rustc.exe" ]
      } else {
        inputs = [ "//third_party/rust-toolchain/bin/rustc" ]
      }
"""
new = """      if (host_os == "win") {
        inputs = [ "${rust_sysroot}/bin/rustc.exe" ]
      } else {
        inputs = [ "${rust_sysroot}/bin/rustc" ]
      }
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch std BUILD.gn rustc input")
    text = text.replace(old, new, 1)
    std_build.write_text(text)

cargo_crate_gni = Path(sys.argv[3])
text = cargo_crate_gni.read_text()
old = """      if (host_os == "win") {
        inputs += [ "//third_party/rust-toolchain/bin/rustc.exe" ]
      } else {
        inputs += [ "//third_party/rust-toolchain/bin/rustc" ]
      }
"""
new = """      if (host_os == "win") {
        inputs += [ "${rust_sysroot}/bin/rustc.exe" ]
      } else {
        inputs += [ "${rust_sysroot}/bin/rustc" ]
      }
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch cargo_crate.gni rustc input")
    text = text.replace(old, new, 1)
    cargo_crate_gni.write_text(text)
PY
}

patch_v8_has_warning_fallback() {
  local macros_h=${V8_SRC_DIR}/v8/src/base/macros.h

  python3 - "${macros_h}" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
insert = """#if !defined(__has_warning)
#define __has_warning(x) 0
#endif

"""
marker = "#define V8_BASE_MACROS_H_\n\n"
if insert not in text:
    if marker not in text:
        raise SystemExit("failed to patch macros.h __has_warning fallback")
    text = text.replace(marker, marker + insert, 1)
    p.write_text(text)
PY
}

patch_disable_solaris_thin_archives() {
  local compiler_build=${V8_SRC_DIR}/build/config/compiler/BUILD.gn

  python3 - "${compiler_build}" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
old = """config("thin_archive") {
  if ((is_apple && use_lld) || (is_linux && !is_clang) || current_os == "aix" ||
      current_os == "zos") {
"""
new = """config("thin_archive") {
  if ((is_apple && use_lld) ||
      (is_linux && target_os != "solaris" && !is_clang) ||
      current_os == "aix" || current_os == "zos") {
"""
if new not in text:
    if old not in text:
        raise SystemExit("failed to patch first thin_archive branch")
    text = text.replace(old, new, 1)

second_branch_variants = [
    (
        '  } else if ((is_posix && current_os != "solaris" && (!is_apple || use_lld)) || is_fuchsia) {\n',
        '  } else if ((is_posix && target_os != "solaris" && (!is_apple || use_lld)) || is_fuchsia) {\n',
    ),
    (
        '  } else if ((is_posix && (!is_apple || use_lld)) || is_fuchsia) {\n',
        '  } else if ((is_posix && target_os != "solaris" && (!is_apple || use_lld)) || is_fuchsia) {\n',
    ),
    (
        '  } else if ((is_posix && (!is_apple || (use_lld || use_mold))) || is_fuchsia) {\n',
        '  } else if ((is_posix && target_os != "solaris" &&\n'
        '              (!is_apple || (use_lld || use_mold))) || is_fuchsia) {\n',
    ),
]
if 'is_posix && target_os != "solaris"' not in text:
    for old, new in second_branch_variants:
        if old in text:
            text = text.replace(old, new, 1)
            break
    else:
        raise SystemExit("failed to patch second thin_archive branch")

p.write_text(text)
PY
}

patch_v8_managed_inline_include() {
  local constant_expression=${V8_SRC_DIR}/v8/src/wasm/constant-expression-interface.cc

  python3 - "${constant_expression}" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
include = '#include "src/objects/managed-inl.h"\n'
marker = '#include "src/objects/map-inl.h"\n'
if include not in text:
    if marker not in text:
        raise SystemExit("failed to patch constant-expression-interface.cc managed include")
    text = text.replace(marker, marker + include, 1)
    p.write_text(text)
PY
}

resolve_generated_src_binding() {
  local candidate

  for candidate in \
    "${V8_SRC_DIR}/target/release/gn_out"/src_binding*.rs \
    "${V8_SRC_DIR}/gen"/src_binding*.rs; do
    [[ -f "${candidate}" ]] || continue
    printf '%s\n' "${candidate}"
    return 0
  done

  die "missing generated src_binding.rs under ${V8_SRC_DIR}/target/release/gn_out or ${V8_SRC_DIR}/gen"
}

ensure_bindgen_root() {
  local bindgen_bin=${BINDGEN_PREFIX}/bin/bindgen
  local libclang_path=${LIBCLANG_PATH:-}

  if [[ ! -x "${bindgen_bin}" ]]; then
    maybe_enable_proxy
    log "Installing bindgen-cli ${BINDGEN_CLI_VERSION}"
    "${CARGO}" install --locked --version "${BINDGEN_CLI_VERSION}" \
      bindgen-cli --root "${BINDGEN_PREFIX}"
  fi

  verify_file "${bindgen_bin}"
  verify_file "${RUST_PREFIX}/bin/rustfmt"
  [[ -n "${libclang_path}" ]] || die "LIBCLANG_PATH is not set"
  verify_file "${libclang_path}/libclang.so"

  mkdir -p "${BINDGEN_ROOT_DIR}/bin"
  ln -sf "${bindgen_bin}" "${BINDGEN_ROOT_DIR}/bin/bindgen"
  ln -sf "${RUST_PREFIX}/bin/rustfmt" "${BINDGEN_ROOT_DIR}/bin/rustfmt"
  rm -rf "${BINDGEN_ROOT_DIR}/lib"
  ln -s "${libclang_path}" "${BINDGEN_ROOT_DIR}/lib"
  log "Using libclang from ${libclang_path}"
}

prepare_rust
build_env_common

[[ -x "${GN_INSTALL_DIR}/bin/gn" ]] || "${TOP}/build-gn.sh"

ensure_v8_source
v8_extra_config=$(prepare_v8_vendor_config)
vendor_rust_sources "${V8_SRC_DIR}" "${V8_VENDOR_DIR}" "${v8_extra_config}"
apply_patch_series "${SRC_DIR}" "${TOP}/patches/v8"
patch_rusty_v8_build_rs
patch_vendored_fslock
patch_vendored_bindgen_var
patch_rustc_wrapper
patch_gcc_toolchain_ar
patch_wrapper_utils
patch_rust_custom_sysroot_inputs
patch_v8_has_warning_fallback
patch_disable_solaris_thin_archives
patch_v8_managed_inline_include
ensure_bindgen_root

export GN="${GN_INSTALL_DIR}/bin/gn"
export V8_FROM_SOURCE=1
export DISABLE_CLANG=1
export RUSTC_BOOTSTRAP=1
rustc_version=$("${RUSTC}" -V)
export GN_ARGS="is_clang=false use_custom_libcxx=false use_custom_libcxx_for_host=false host_os=\"linux\" target_os=\"solaris\" rust_sysroot_absolute=\"${RUST_PREFIX}\" rustc_version=\"${rustc_version}\" rust_bindgen_root=\"${BINDGEN_ROOT_DIR}\" rust_abi_target_override=\"${RUST_TRIPLE}\" removed_rust_skip_stdlib_libs=[\"profiler_builtins\"] treat_warnings_as_errors=false fatal_linker_warnings=false"

log "Building v8-solaris"
(
  cd "${V8_SRC_DIR}"
  "${CARGO}" build --release --offline --frozen -q
)

generated_src_binding=$(resolve_generated_src_binding)

mkdir -p "${V8_INSTALL_DIR}/lib" "${V8_INSTALL_DIR}/share" "${TOP}/support"
cp "${V8_SRC_DIR}/target/release/gn_out/obj/librusty_v8.a" "${V8_INSTALL_DIR}/lib/"
cp "${generated_src_binding}" "${V8_INSTALL_DIR}/share/src_binding.rs"
cp "${generated_src_binding}" "${TOP}/support/src_binding_prebuilt.rs"
v8_source_identity > "${V8_INSTALL_DIR}/.source-ref"

log "Installed v8 artifacts to ${V8_INSTALL_DIR}"
