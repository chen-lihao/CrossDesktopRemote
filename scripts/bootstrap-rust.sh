#!/usr/bin/env bash
set -euo pipefail

if ! command -v cargo >/dev/null 2>&1; then
    printf 'Rust/Cargo is not installed. Follow docs/工程搭建.md, then rerun this script.\n' >&2
    exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
crate_names=(session-core protocol media-core transfer-core security-core)

for crate_name in "${crate_names[@]}"; do
    target="$repo_root/crates/$crate_name"
    mkdir -p "$target"

    if [[ -f "$target/Cargo.toml" ]]; then
        printf 'Cargo package already exists: %s\n' "$crate_name"
        continue
    fi

    cargo init \
        --lib \
        --edition 2024 \
        --vcs none \
        --name "$crate_name" \
        "$target"
done

if [[ ! -f "$repo_root/Cargo.toml" ]]; then
    cp "$repo_root/scripts/templates/Cargo.toml" "$repo_root/Cargo.toml"
fi

cargo fmt --manifest-path "$repo_root/Cargo.toml" --all -- --check
cargo check --manifest-path "$repo_root/Cargo.toml" --workspace
cargo test --manifest-path "$repo_root/Cargo.toml" --workspace
