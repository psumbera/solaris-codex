# solaris-codex

Standalone Solaris build wrapper for Codex and its native dependencies.

This repo fetches and builds pinned versions of:

1. `gn`
2. `v8-solaris` (`librusty_v8.a` + `src_binding.rs`)
3. `codex`

Current support status:

- Solaris/x86 only for now
- `uname -p` must report `i386`
- SPARC is not supported in this wrapper

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

1. checks that the host is Solaris/x86
2. downloads the pinned Rust toolchain into `build/toolchains`
3. fetches the pinned GN, V8, and Codex sources into `build/src`
4. vendors the Rust crate dependencies needed for V8 and Codex
5. installs the pinned `bindgen-cli` helper needed by the V8 GN build
6. builds and installs `gn`
7. builds and installs `v8-solaris`
8. builds and installs `codex`

Installed artifacts end up in:

- `build/install/gn/bin/gn`
- `build/install/v8/lib/librusty_v8.a`
- `build/install/v8/share/src_binding.rs`
- `build/install/codex/bin/codex`

Quick verification:

```sh
build/install/gn/bin/gn --version
ls -l build/install/v8/lib/librusty_v8.a
build/install/codex/bin/codex --version
```

## Notes

- Rust is downloaded only once into `build/toolchains`.
- The wrapper uses the official Solaris Rust standalone installer target
  `x86_64-pc-solaris`.
- The pinned Codex source is the upstream `openai/codex` release tag
  `rust-v0.122.0`, built from its `codex-rs/` workspace.
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
- `0003-tui-work-around-solaris-terminal-input-and-layout.patch` keeps the TUI
  off terminal capability probes that stalled some Solaris PTYs, replaces the
  unreliable default `crossterm::event::EventStream` path with a Solaris input
  reader, prefers an ASCII-safe presentation on older terminals, and redraws the
  onboarding flow so the actionable step stays visible on smaller PTYs.

After `cargo vendor`, `build-codex.sh` still applies the remaining Solaris
vendored-crate rewrites in place:

- `patch_vendored_nix_termios()`
- `patch_vendored_tree_sitter_endian()`
- `patch_vendored_fslock()`
- `patch_vendored_onig_sys_alloca()`

Those helpers remain scripted because they also update vendored crate
`.cargo-checksum.json`, which makes static patch files awkward to maintain.

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
