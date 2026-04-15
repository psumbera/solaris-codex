#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

check_supported_host
ensure_dirs

usage() {
  cat <<EOF
Usage:
  bash prepare-sources.sh

This is an optional cache warmer.
It fetches the pinned GN, V8, and Codex sources and vendors the Rust
dependencies under:
  ${SRC_DIR}

After that, the normal build remains:
  bash build-codex.sh
EOF
}

prepare_rust
build_env_common
ensure_gn_source
ensure_v8_source
vendor_rust_sources "${V8_SRC_DIR}" "${V8_VENDOR_DIR}"
ensure_codex_source
vendor_rust_sources "${CODEX_SRC_DIR}" "${CODEX_VENDOR_DIR}"

log "Prepared source trees:"
printf '  %s\n' \
  "${GN_SRC_DIR}" \
  "${V8_SRC_DIR}" \
  "${V8_VENDOR_DIR}" \
  "${CODEX_REPO_DIR}" \
  "${CODEX_VENDOR_DIR}"
