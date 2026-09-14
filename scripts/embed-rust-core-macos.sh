#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "${PROJECT_DIR}/../../.." && pwd)"
cargo_bin="$(command -v cargo || true)"
if [[ -z "$cargo_bin" && -x "$HOME/.cargo/bin/cargo" ]]; then
  cargo_bin="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$cargo_bin" ]]; then
  printf 'cargo is required to build the trusted security core.\n' >&2
  exit 2
fi

cargo_arguments=(
  build
  --manifest-path "$repo_root/Cargo.toml"
  -p client-ffi
)
rust_profile="debug"
if [[ "${CONFIGURATION:-Debug}" != "Debug" ]]; then
  cargo_arguments+=(--release)
  rust_profile="release"
fi

"$cargo_bin" "${cargo_arguments[@]}"

source_library="$repo_root/target/$rust_profile/libcrossdesktop_core.dylib"
destination_directory="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
destination_library="$destination_directory/libcrossdesktop_core.dylib"
if [[ ! -f "$source_library" ]]; then
  printf 'Rust core library was not produced at %s\n' "$source_library" >&2
  exit 1
fi

mkdir -p "$destination_directory"
cp "$source_library" "$destination_library"
/usr/bin/install_name_tool -id \
  '@rpath/libcrossdesktop_core.dylib' \
  "$destination_library"

signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
fi
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
  "$destination_library"
