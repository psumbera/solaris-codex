#!/usr/bin/env bash

set -euo pipefail

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=versions.sh
source "${TOP}/versions.sh"

BUILD_DIR=${BUILD_DIR:-${TOP}/build}
DOWNLOAD_DIR=${DOWNLOAD_DIR:-${BUILD_DIR}/downloads}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-${BUILD_DIR}/toolchains}
SRC_DIR=${SRC_DIR:-${BUILD_DIR}/src}
INSTALL_DIR=${INSTALL_DIR:-${BUILD_DIR}/install}
HOME_DIR=${HOME_DIR:-${BUILD_DIR}/home}
CARGO_HOME_DIR=${CARGO_HOME_DIR:-${BUILD_DIR}/cargo-home}

RUST_PREFIX=${TOOLCHAIN_DIR}/rust-${RUST_VERSION}
RUST_ARCHIVE=rust-${RUST_VERSION}-${RUST_TRIPLE}.tar.xz
RUST_ARCHIVE_URL=https://static.rust-lang.org/dist/${RUST_ARCHIVE}

GN_SRC_DIR=${SRC_DIR}/gn-${GN_VERSION}
V8_SRC_DIR=${SRC_DIR}/v8-${V8_VERSION}
V8_VENDOR_DIR=${SRC_DIR}/v8-${V8_VERSION}-vendored-sources
CODEX_REPO_DIR=${SRC_DIR}/codex-rust-v${SOLARIS_CODEX_VERSION}
CODEX_SRC_DIR=${CODEX_REPO_DIR}/codex-rs
CODEX_VENDOR_DIR=${SRC_DIR}/codex-rust-v${SOLARIS_CODEX_VERSION}-vendored-sources
BINDGEN_PREFIX=${TOOLCHAIN_DIR}/bindgen-cli-${BINDGEN_CLI_VERSION}
BINDGEN_ROOT_DIR=${TOOLCHAIN_DIR}/rust-bindgen-root

GN_INSTALL_DIR=${INSTALL_DIR}/gn
V8_INSTALL_DIR=${INSTALL_DIR}/v8
CODEX_INSTALL_DIR=${INSTALL_DIR}/codex

PATCH_TOOL=${PATCH_TOOL:-/usr/gnu/bin/patch}
if [[ ! -x "${PATCH_TOOL}" ]]; then
  PATCH_TOOL=patch
fi

log() {
  printf '[solaris-codex] %s\n' "$*"
}

die() {
  printf '[solaris-codex] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

detect_libclang_path() {
  local candidate
  local checked=()
  local vdir version major minor patch score best_score=-1 best_candidate=
  local old_nullglob

  if [[ -n "${LIBCLANG_PATH:-}" ]]; then
    if [[ -f "${LIBCLANG_PATH}/libclang.so" ]]; then
      printf '%s\n' "${LIBCLANG_PATH}"
      return 0
    fi
    die "LIBCLANG_PATH is set to ${LIBCLANG_PATH}, but ${LIBCLANG_PATH}/libclang.so was not found"
  fi

  checked+=(/usr/lib/64)
  if [[ -f /usr/lib/64/libclang.so ]]; then
    printf '%s\n' /usr/lib/64
    return 0
  fi

  if shopt -q nullglob; then
    old_nullglob=0
  else
    old_nullglob=1
  fi
  shopt -s nullglob

  for vdir in /usr/llvm/*; do
    [[ -d "${vdir}" ]] || continue
    version=${vdir##*/}
    IFS=. read -r major minor patch _ <<< "${version}"
    minor=${minor:-0}
    patch=${patch:-0}

    if [[ ! "${major}" =~ ^[0-9]+$ ||
          ! "${minor}" =~ ^[0-9]+$ ||
          ! "${patch}" =~ ^[0-9]+$ ]]; then
      continue
    fi

    for candidate in "${vdir}/lib/amd64" "${vdir}/lib"; do
      checked+=("${candidate}")
      [[ -f "${candidate}/libclang.so" ]] || continue
      score=$((major * 1000000 + minor * 1000 + patch))
      if (( score > best_score )); then
        best_score=${score}
        best_candidate=${candidate}
      fi
    done
  done

  if (( old_nullglob != 0 )); then
    shopt -u nullglob
  fi

  if [[ -n "${best_candidate}" ]]; then
    printf '%s\n' "${best_candidate}"
    return 0
  fi

  die "unable to find libclang.so; checked: ${checked[*]}"
}

check_supported_host() {
  local os arch

  os=$(uname -s)
  arch=$(uname -p)

  [[ "${os}" == "SunOS" ]] || die "only Solaris is supported"
  [[ "${arch}" == "i386" ]] || die "only Solaris x86/i386 is currently supported"
}

ensure_dirs() {
  mkdir -p "${BUILD_DIR}" "${DOWNLOAD_DIR}" "${TOOLCHAIN_DIR}" "${SRC_DIR}" \
    "${INSTALL_DIR}" "${HOME_DIR}" "${CARGO_HOME_DIR}"
}

maybe_enable_proxy() {
  if [[ -n "${SOLARIS_CODEX_PROXY_SETUP:-}" && -f "${SOLARIS_CODEX_PROXY_SETUP}" ]]; then
    # shellcheck disable=SC1091
    . "${SOLARIS_CODEX_PROXY_SETUP}"
  fi
}

fetch_git_source() {
  local url=$1
  local ref=$2
  local dst=$3
  local stamp=${dst}.source-ref
  local current=

  ensure_dirs
  need_cmd git

  if [[ -f "${stamp}" ]]; then
    current=$(tr '\n' ' ' < "${stamp}" | sed 's/ $//')
  fi
  if [[ -d "${dst}" && "${current}" == "${url} ${ref}" ]]; then
    return 0
  fi

  maybe_enable_proxy

  rm -rf "${dst}" "${stamp}"
  mkdir -p "$(dirname "${dst}")"

  log "Fetching ${url} (${ref})"
  git init -q "${dst}"
  (
    cd "${dst}"
    git remote add origin "${url}"
    local fetch_timeout=${SOLARIS_CODEX_FETCH_TIMEOUT:-120}
    /usr/bin/timeout "${fetch_timeout}" git fetch --depth 1 origin "${ref}"       || die "timed out fetching ${url} (${ref}); configure SOLARIS_CODEX_PROXY_SETUP or pre-seed ${dst}"
    git -c advice.detachedHead=false checkout --detach FETCH_HEAD
    if [[ -f .gitmodules ]]; then
      git submodule sync --recursive
      git submodule update --init --recursive
    fi
  )
  rm -rf "${dst}/.git"

  printf '%s\n%s\n' "${url}" "${ref}" > "${stamp}"
}

relative_path() {
  need_cmd python3
  python3 - "$1" "$2" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
}

prepare_rust() {
  ensure_dirs
  need_cmd /usr/bin/curl
  need_cmd gtar

  if [[ -x "${RUST_PREFIX}/bin/rustc" && -x "${RUST_PREFIX}/bin/cargo" ]]; then
    return 0
  fi

  maybe_enable_proxy

  local archive_path=${DOWNLOAD_DIR}/${RUST_ARCHIVE}
  local stage_dir=${BUILD_DIR}/rust-stage-${RUST_VERSION}

  if [[ ! -f "${archive_path}" ]]; then
    log "Downloading Rust ${RUST_VERSION}"
    /usr/bin/curl -L -f -o "${archive_path}" "${RUST_ARCHIVE_URL}"
  fi

  rm -rf "${stage_dir}"
  mkdir -p "${stage_dir}"
  gtar xf "${archive_path}" -C "${stage_dir}"
  (
    cd "${stage_dir}/rust-${RUST_VERSION}-${RUST_TRIPLE}"
    ./install.sh --prefix="${RUST_PREFIX}"
  )
}

ensure_gn_source() {
  fetch_git_source "${GN_GIT_URL}" "${GN_GIT_REF}" "${GN_SRC_DIR}"
}

ensure_v8_source() {
  fetch_git_source "${V8_GIT_URL}" "${V8_GIT_REF}" "${V8_SRC_DIR}"
}

ensure_codex_source() {
  fetch_git_source "${CODEX_GIT_URL}" "${CODEX_GIT_REF}" "${CODEX_REPO_DIR}"
  [[ -d "${CODEX_SRC_DIR}" ]] || die "missing codex-rs/ in fetched Codex source"
}

apply_patch_series() {
  local root=$1
  local patch_dir=$2
  local patch

  [[ -d "${patch_dir}" ]] || return 0

  for patch in "${patch_dir}"/*.patch; do
    [[ -e "${patch}" ]] || continue
    if (
      cd "${root}"
      "${PATCH_TOOL}" --dry-run -p1 < "${patch}" >/dev/null 2>&1
    ); then
      log "Applying $(basename "${patch}")"
      (
        cd "${root}"
        "${PATCH_TOOL}" -p1 < "${patch}"
      )
    else
      log "Skipping $(basename "${patch}")"
    fi
  done
}

write_vendored_config() {
  local src_dir=$1
  local vendor_dir=$2
  local generated_file=$3
  local extra_file=${4:-}

  mkdir -p "${src_dir}/.cargo"

  local config=${src_dir}/.cargo/config.toml
  local tmp=${config}.new

  : > "${tmp}"
  cat "${generated_file}" >> "${tmp}"

  if [[ -n "${extra_file}" ]]; then
    printf '\n' >> "${tmp}"
    cat "${extra_file}" >> "${tmp}"
  fi

  mv "${tmp}" "${config}"
}

vendor_rust_sources() {
  local src_dir=$1
  local vendor_dir=$2
  local extra_file=${3:-}
  local cargo_dir=${src_dir}/.cargo
  local raw=${vendor_dir}.config.raw
  local generated=${vendor_dir}.config.toml
  local stamp=${vendor_dir}/.solaris-codex-vendored
  local rel_vendor=

  [[ -d "${src_dir}" ]] || die "source tree not found: ${src_dir}"
  [[ -f "${src_dir}/Cargo.lock" ]] || die "missing Cargo.lock in ${src_dir}"

  if [[ -d "${vendor_dir}" && -f "${cargo_dir}/config.toml" && -f "${stamp}" ]]; then
    return 0
  fi

  rm -rf "${vendor_dir}" "${raw}" "${generated}"
  mkdir -p "${cargo_dir}"

  maybe_enable_proxy

  log "Vendoring Rust dependencies for $(basename "${src_dir}")"
  (
    cd "${src_dir}"
    if ! "${CARGO}" vendor --locked "${vendor_dir}" > "${raw}"; then
      log "cargo vendor --locked requested a lockfile refresh; retrying without --locked"
      rm -rf "${vendor_dir}" "${raw}"
      "${CARGO}" vendor "${vendor_dir}" > "${raw}"
    fi
  )

  # Cargo resolves vendored source paths relative to the workspace root, not
  # the .cargo/ directory that contains config.toml.
  rel_vendor=$(relative_path "${src_dir}" "${vendor_dir}")
  sed "s|^directory = \".*\"$|directory = \"${rel_vendor}\"|" "${raw}" \
    > "${generated}"

  write_vendored_config "${src_dir}" "${vendor_dir}" "${generated}" \
    "${extra_file}"
  : > "${stamp}"

  rm -f "${raw}" "${generated}"
}

build_env_common() {
  check_supported_host
  export HOME="${HOME_DIR}"
  export CARGO_HOME="${CARGO_HOME_DIR}"
  export PATH="${RUST_PREFIX}/bin:/usr/gnu/bin:/usr/bin:${PATH}"
  export RUSTC="${RUST_PREFIX}/bin/rustc"
  export CARGO="${RUST_PREFIX}/bin/cargo"
  export NINJA=/usr/bin/ninja
  export LIBCLANG_PATH="$(detect_libclang_path)"
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
}

verify_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}
