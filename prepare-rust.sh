#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

prepare_rust
"${RUST_PREFIX}/bin/rustc" --version
"${RUST_PREFIX}/bin/cargo" --version
