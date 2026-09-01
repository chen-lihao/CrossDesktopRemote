#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
proto_root="$repo_root/proto"
java_out="$repo_root/services/control-plane-java/build/generated/sources/proto/main/java"
dart_out="$repo_root/apps/client_flutter/build/generated/proto/dart"
proto_staging_root="$(mktemp -d "${TMPDIR:-/tmp}/crossdesktop-proto.XXXXXX")"
java_staging="$proto_staging_root/java"
dart_staging="$proto_staging_root/dart"
proto_files=(
    "$proto_root/crossdesktop/v1/common.proto"
    "$proto_root/crossdesktop/v1/clipboard.proto"
    "$proto_root/crossdesktop/v1/transfer.proto"
    "$proto_root/crossdesktop/v1/capability.proto"
    "$proto_root/crossdesktop/v1/device.proto"
    "$proto_root/crossdesktop/v1/input.proto"
    "$proto_root/crossdesktop/v1/session.proto"
    "$proto_root/crossdesktop/v1/signaling.proto"
)

cleanup_staging() {
    rm -rf -- "$proto_staging_root"
}
trap cleanup_staging EXIT

if [[ -n "${CROSSDESKTOP_FLUTTER_BIN:-}" ]]; then
    export PATH="$CROSSDESKTOP_FLUTTER_BIN:$PATH"
fi

if ! command -v protoc-gen-dart >/dev/null 2>&1 \
    && [[ -x "$HOME/.pub-cache/bin/protoc-gen-dart" ]]; then
    export PATH="$PATH:$HOME/.pub-cache/bin"
fi

for tool in protoc protoc-gen-dart; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '%s is required. See proto/README.md.\n' "$tool" >&2
        exit 2
    fi
done

if ! command -v dart >/dev/null 2>&1; then
    printf 'dart is required by protoc-gen-dart. Add Flutter bin to PATH or set CROSSDESKTOP_FLUTTER_BIN.\n' >&2
    exit 2
fi

mkdir -p "$java_staging" "$dart_staging"

protoc \
    --proto_path="$proto_root" \
    --java_out="$java_staging" \
    "${proto_files[@]}"

protoc \
    --proto_path="$proto_root" \
    --dart_out="$dart_staging" \
    "${proto_files[@]}"

if command -v buf >/dev/null 2>&1; then
    buf lint "$proto_root"
else
    printf 'buf is not installed; skipped compatibility lint.\n' >&2
fi

cargo_bin="$(command -v cargo || true)"
if [[ -z "$cargo_bin" && -x "$HOME/.cargo/bin/cargo" ]]; then
    cargo_bin="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$cargo_bin" ]]; then
    printf 'cargo is required. See docs/工程搭建.md.\n' >&2
    exit 2
fi

"$cargo_bin" check \
    --manifest-path "$repo_root/Cargo.toml" \
    -p protocol

# protoc only overwrites files it still generates and leaves classes removed
# from a schema behind. Replace both ignored build trees only after every
# generator and validation step succeeds, so Java/Dart never compile a mixture
# of old and new descriptors.
rm -rf -- "$java_out" "$dart_out"
mkdir -p "$(dirname "$java_out")" "$(dirname "$dart_out")"
mv "$java_staging" "$java_out"
mv "$dart_staging" "$dart_out"

printf 'Generated Java, Dart, and Rust protocol bindings.\n'
