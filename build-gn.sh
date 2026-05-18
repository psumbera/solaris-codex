#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

need_cmd python3
need_cmd ninja
need_cmd /usr/bin/perl
need_cmd gtar

ensure_dirs
ensure_gn_source

log "Building gn"
(
  cd "${GN_SRC_DIR}"
  export CC=${CC:-gcc}
  export CXX=${CXX:-g++}
  export AR=${AR:-ar}
  python3 build/gen.py --no-last-commit-position --out-path out-solaris
  /usr/bin/perl -pi -e 's/rcsT/rcs/' out-solaris/build.ninja
  /usr/bin/perl -pi -e 's/-Werror\b/-Werror -Wno-error=comment -Wno-error=nonnull/g' out-solaris/build.ninja
  /usr/bin/printf '#ifndef LAST_COMMIT_POSITION_H_\n#define LAST_COMMIT_POSITION_H_\n#define LAST_COMMIT_POSITION "0"\n#define LAST_COMMIT_POSITION_NUM 0\n#endif\n' \
    > out-solaris/last_commit_position.h
  ninja -C out-solaris
)

mkdir -p "${GN_INSTALL_DIR}/bin"
cp "${GN_SRC_DIR}/out-solaris/gn" "${GN_INSTALL_DIR}/bin/gn"

log "Installed gn to ${GN_INSTALL_DIR}/bin/gn"
