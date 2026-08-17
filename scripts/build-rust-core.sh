#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cargo_bin="$(command -v cargo || true)"

if [[ -z "$cargo_bin" && -x "$HOME/.cargo/bin/cargo" ]]; then
    cargo_bin="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$cargo_bin" ]]; then
    printf 'cargo is required. See docs/工程搭建.md.\n' >&2
    exit 2
fi

"$cargo_bin" build \
    --manifest-path "$repo_root/Cargo.toml" \
    -p client-ffi

case "$(uname -s)" in
    Darwin)
        library_path="$repo_root/target/debug/libcrossdesktop_core.dylib"
        ;;
    Linux)
        library_path="$repo_root/target/debug/libcrossdesktop_core.so"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        library_path="$repo_root/target/debug/crossdesktop_core.dll"
        ;;
    *)
        printf 'Unsupported host platform: %s\n' "$(uname -s)" >&2
        exit 2
        ;;
esac

if [[ ! -f "$library_path" ]]; then
    printf 'Rust core library was not produced at %s\n' "$library_path" >&2
    exit 1
fi

printf '%s\n' "$library_path"
