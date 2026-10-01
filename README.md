# OpenAI Codex CLI for Oracle Solaris 11.4

Build and run the OpenAI Codex CLI on Oracle Solaris 11.4 x64 and SPARC. This
standalone Solaris Codex build wrapper fetches pinned upstream sources, applies
the required Solaris-specific patches, and builds Codex together with its
native dependencies.

This repo fetches and builds pinned versions of:

1. `gn`
2. `v8-solaris` (`librusty_v8.a` + `src_binding.rs`)
3. [`openai/codex`](https://github.com/openai/codex)

Current support status:

- Solaris x64 (`uname -p` reports `i386`): full build, including V8 and
  `codex-code-mode-host`.
- Solaris SPARC (`uname -p` reports `sparc`): native 64-bit `codex` with direct
  tool calls. GN, V8, and the code-mode host are not built or installed.
  Code-mode configuration flags and model metadata cannot activate code mode
  on this architecture. Node.js is not required.

Use a separate checkout/build directory for each architecture; build output
and installed toolchains must not be shared between x64 and SPARC.

The wrapper keeps its own build state under:

- `build/downloads`
- `build/toolchains`
- `build/src`
- `build/install`
- `support/src_binding_prebuilt.rs`

## Normal Use

```sh
cd solaris-codex
bash build-codex.sh
```

`build-codex.sh` is the main entry point. It:

1. checks that the host is Solaris x64 or SPARC
2. downloads the pinned Rust toolchain into `build/toolchains`
3. fetches the pinned GN, V8, and Codex sources into `build/src`
4. vendors the Rust crate dependencies needed for V8 and Codex
5. installs the pinned `bindgen-cli` helper needed by the V8 GN build
6. builds and installs `gn`
7. builds and installs `v8-solaris`
8. builds and installs `codex` and, on x64, its code-mode host

On SPARC, steps involving GN, V8, and its bindgen helper are skipped. Rust,
native protoc, and the CLI's remaining native dependencies are still required.

Installed artifacts end up in:

- `build/install/gn/bin/gn`
- `build/install/v8/lib/librusty_v8.a`
- `build/install/v8/share/src_binding.rs`
- `build/install/codex/bin/codex`
- `build/install/codex/bin/codex-code-mode-host`

On x64, Codex enables the separate code-mode host by default. Keep
`codex-code-mode-host` beside `codex` when copying or packaging this build.

Quick verification:

```sh
build/install/gn/bin/gn --version
ls -l build/install/v8/lib/librusty_v8.a
build/install/codex/bin/codex --version
build/install/codex/bin/codex-code-mode-host --help
```

On SPARC, verify only `codex --version`; the GN, V8 and host paths above are
not installed. To run the local integration fixture on either architecture:

```sh
python3.13 smoke-tools.py \
  --codex "$PWD/build/install/codex/bin/codex" \
  --catalog "$PWD/build/src/codex-rust-v0.159.2/codex-rs/models-manager/models.json" \
  --output "$PWD/build/smoke-results"
```

Add `--expect-v8` on x64. Use a new output directory for each run. The fixture
uses a local fake model server to verify file edits, shell execution and saved
sessions; on x64 it also executes JavaScript through V8. It does not require
credentials. It runs fixed commands in its scratch directory with sandboxing
disabled, so it does not validate Solaris sandbox enforcement.

## Monitoring Running Sessions

`codex-status.py` shows this user's running Codex TUI sessions without a
shared app-server daemon or access to Codex's SQLite databases:

```sh
python3.13 codex-status.py
python3.13 codex-status.py --watch 5
python3.13 codex-status.py --json
```

The monitor obtains the executable, working directory and open rollout files
from Solaris `/proc`. It uses only rollout metadata and lifecycle event types;
it does not print prompts, responses, titles or tool contents. `WORKING` means
the latest turn started and has not recorded completion, while `IDLE` means
the process is alive and its latest turn completed or was aborted. The `LAST`
column shows the age of the most recent rollout write, which helps identify a
possibly stalled `WORKING` session. Approval and user-input waits remain
`WORKING` because their turn is still active.

Only processes owned by the invoking user are reported. This avoids the
permissions and privacy problems associated with inspecting other users'
process descriptors and session files. Because the monitor never opens
SQLite, it adds no database locks and works with both local and NFS-backed
`CODEX_HOME` directories.

## Notes

- Rust is downloaded only once into `build/toolchains`.
- The wrapper selects the official Rust standalone installer for
  `x86_64-pc-solaris` or `sparcv9-sun-solaris` from the native host architecture.
- The pinned Codex source is the upstream `openai/codex` release tag
  `rust-v0.159.2`, built from its `codex-rs/` workspace.
- Set `SOLARIS_CODEX_PROXY_SETUP=/path/to/proxy.sh` if your host needs an
  environment hook before downloads.
- The codex build clears inherited Solaris `LD_*` hardening variables because
  they broke the final Rust link with Solaris `ld`.

## Solaris-specific Codex Workarounds

The wrapper builds upstream Codex mostly as-is, but Solaris still needs a small
patch series under `patches/codex/` before vendoring:

- `0001-process-hardening-enable-solaris-runtime-hardening.patch` adds Solaris
  to the existing Unix runtime hardening path so Codex clears `LD_*` at startup
  and disables core dumps the same way it already does on the BSD targets.
- `0002-tui-disable-unsupported-clipboard-backends-on-solaris.patch` disables
  native clipboard image and text paths that have no maintained Solaris backend
  and leaves the SSH and OSC 52 text-copy path available.
- `0004-config-host-name-use-solaris-ai-canonname-fallback.patch` supplies the
  Solaris `AI_CANONNAME` value that the Rust `libc` crate does not expose.
- `0005-state-use-rollback-journal-on-solaris.patch` keeps Codex state
  databases in SQLite WAL mode on local Solaris filesystems, while using
  rollback journals on NFS-backed homes to avoid `-shm` mmap failures.
- `0006-arg0-tolerate-solaris-stale-temp-cleanup.patch` keeps stale arg0 temp
  cleanup best-effort when Solaris/NFS reports non-empty directory races during
  startup.
- `0007-app-server-daemon-use-fcntl-locks-on-solaris.patch` replaces
  unsupported `flock(2)` daemon lifecycle locks with Solaris `fcntl(2)` locks.
- `0008-http-client-honor-no-proxy-before-system-proxy.patch` enables Codex's
  route-aware system-proxy policy by default on Solaris so shared HTTP clients
  honor `NO_PROXY`/`no_proxy` without reqwest system proxy autodetection.
- `0010-exec-server-drain-fs-helper-output-concurrently.patch` keeps large
  filesystem-helper responses from blocking on a full stdout pipe.
- `0014-features-disable-daemon-auto-start-on-solaris.patch` keeps ordinary
  TUI startup in embedded mode because this distribution does not install the
  complete standalone package tree required for daemon bootstrap.

Before vendoring, `patch_tui_solaris_terminal_input()` keeps the TUI off
terminal capability probes that stalled some Solaris PTYs, replaces the
unreliable default `crossterm::event::EventStream` path with a Solaris input
reader, prefers an ASCII-safe presentation on older terminals, and redraws the
onboarding flow so the actionable step stays visible on smaller PTYs.

After `cargo vendor`, `build-codex.sh` still applies the remaining Solaris
vendored-crate rewrites in place:

- `patch_vendored_nix_termios()`
- `patch_vendored_tree_sitter_endian()`
- `patch_vendored_fslock()`
- `patch_vendored_onig_sys_alloca()`
- `patch_vendored_mio_event_ports()`

Those helpers remain scripted because they also update vendored crate
`.cargo-checksum.json`, which makes static patch files awkward to maintain.
The mio event-ports rewrite applies the upstream accepted changes from
`https://github.com/tokio-rs/mio/pull/1962`, refreshed against the `mio 1.2.0`
crate version locked by Codex. The fallback polling fix is the production
change from `https://github.com/tokio-rs/mio/pull/2005` at commit `c045606`.
It retains bounded `poll(2)` fallback for readiness that Solaris event ports
can lose. Follow-up patches coalesce repeated event-port wakeups and preserve
bounded writable re-notification across consecutive zero-timeout polls. The
latter is required when Tokio clears cached write readiness and continues
polling without blocking; without it, network writes can stall while the
runtime spins on Solaris.

## Maintainer Notes

### Updating pinned refs

Pinned upstream refs live in `versions.sh`:

- `GN_GIT_URL`
- `GN_GIT_REF`
- `V8_GIT_URL`
- `V8_GIT_REF`
- `CODEX_GIT_URL`
- `CODEX_GIT_REF`

You can override any of these temporarily with environment variables, but the
normal published workflow is still just:

```sh
bash build-codex.sh
```

The wrapper intentionally does not hardcode host-local absolute paths so the
repository can be published on GitHub and reused on another Solaris system.

If you are refreshing this wrapper for a newer Codex pin, review the
`patches/codex/*.patch` series first. Those are the versioned upstream-source
Solaris workarounds and are the most likely places to need source-shape
updates. After that, check the remaining `patch_vendored_*` helpers in
`build-codex.sh`, because those still patch vendored crates and refresh
`.cargo-checksum.json`.

If you want to warm all fetches and vendored crates ahead of time, you can use:

```sh
bash prepare-sources.sh
```

- The wrapper keeps patch files in `patches/`.
- The V8 patch set still applies against the fetched `rusty_v8` source tree and
  its vendored dependencies.
