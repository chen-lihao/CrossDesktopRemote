#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "${PROJECT_DIR}/../../.." && pwd)"
cargo_bin="$(command -v cargo || true)"
rustup_bin="$(command -v rustup || true)"
if [[ -z "$cargo_bin" && -x "$HOME/.cargo/bin/cargo" ]]; then
  cargo_bin="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$rustup_bin" && -x "$HOME/.cargo/bin/rustup" ]]; then
  rustup_bin="$HOME/.cargo/bin/rustup"
fi
if [[ -z "$cargo_bin" || -z "$rustup_bin" ]]; then
  printf 'cargo and rustup are required to build the trusted security core.\n' >&2
  exit 2
fi

case "${PLATFORM_NAME:-}" in
  iphoneos)
    rust_targets=("aarch64-apple-ios")
    ;;
  iphonesimulator)
    rust_targets=()
    for requested_arch in ${ARCHS:-${NATIVE_ARCH_ACTUAL:-arm64}}; do
      case "$requested_arch" in
        arm64) rust_targets+=("aarch64-apple-ios-sim") ;;
        x86_64) rust_targets+=("x86_64-apple-ios") ;;
        undefined_arch) ;;
        *)
          printf 'Unsupported iOS simulator architecture: %s\n' \
            "$requested_arch" >&2
          exit 2
          ;;
      esac
    done
    if [[ ${#rust_targets[@]} -eq 0 ]]; then
      case "$(/usr/bin/uname -m)" in
        arm64) rust_targets=("aarch64-apple-ios-sim") ;;
        x86_64) rust_targets=("x86_64-apple-ios") ;;
        *)
          printf 'Unable to determine the iOS simulator architecture.\n' >&2
          exit 2
          ;;
      esac
    fi
    ;;
  *)
    printf 'Unsupported Apple platform for iOS Rust core: %s\n' \
      "${PLATFORM_NAME:-unknown}" >&2
    exit 2
    ;;
esac

rust_profile="debug"
if [[ "${CONFIGURATION:-Debug}" != "Debug" ]]; then
  rust_profile="release"
fi

destination_library="$BUILT_PRODUCTS_DIR/libcrossdesktop_core.a"
source_libraries=()
for rust_target in "${rust_targets[@]}"; do
  if ! "$rustup_bin" target list --installed \
    | /usr/bin/grep -Fxq "$rust_target"; then
    printf 'Rust target %s is not installed. Run: rustup target add %s\n' \
      "$rust_target" "$rust_target" >&2
    exit 2
  fi
  cargo_arguments=(
    build
    --manifest-path "$repo_root/Cargo.toml"
    -p client-ffi
    --target "$rust_target"
  )
  if [[ "$rust_profile" == "release" ]]; then
    cargo_arguments+=(--release)
  fi
  "$cargo_bin" "${cargo_arguments[@]}"
  source_library="$repo_root/target/$rust_target/$rust_profile/libcrossdesktop_core.a"
  if [[ ! -f "$source_library" ]]; then
    printf 'Rust core library was not produced at %s\n' "$source_library" >&2
    exit 1
  fi
  source_libraries+=("$source_library")
done

if [[ ${#source_libraries[@]} -eq 1 ]]; then
  /usr/bin/install -m 0644 "${source_libraries[0]}" "$destination_library"
else
  /usr/bin/xcrun lipo -create "${source_libraries[@]}" \
    -output "$destination_library"
fi
