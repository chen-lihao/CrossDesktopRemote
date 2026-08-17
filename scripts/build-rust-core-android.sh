#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cargo_bin="$(command -v cargo || true)"
ndk_home="${CROSSDESKTOP_ANDROID_NDK_HOME:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"

if [[ -z "$cargo_bin" && -x "$HOME/.cargo/bin/cargo" ]]; then
    cargo_bin="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$cargo_bin" ]]; then
    printf 'cargo is required. See docs/工程搭建.md.\n' >&2
    exit 2
fi
if [[ ! -x "$HOME/.cargo/bin/cargo-ndk" ]] && ! command -v cargo-ndk >/dev/null 2>&1; then
    printf 'cargo-ndk is required. See docs/工程搭建.md.\n' >&2
    exit 2
fi
if [[ -z "$ndk_home" || ! -d "$ndk_home" ]]; then
    printf 'Set CROSSDESKTOP_ANDROID_NDK_HOME to an installed Android NDK directory.\n' >&2
    exit 2
fi

export ANDROID_NDK_HOME="$ndk_home"

"$cargo_bin" ndk \
    -t armeabi-v7a \
    -t arm64-v8a \
    -t x86_64 \
    -o "$repo_root/apps/client_flutter/android/app/src/main/jniLibs" \
    build \
    --manifest-path "$repo_root/Cargo.toml" \
    -p client-ffi \
    --release

printf 'Generated Android Rust libraries under apps/client_flutter/android/app/src/main/jniLibs.\n'
