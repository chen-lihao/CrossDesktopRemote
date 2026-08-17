#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
flutter_bin_dir="${CROSSDESKTOP_FLUTTER_BIN:-}"
cargo_bin="$(command -v cargo || true)"

if [[ -z "$flutter_bin_dir" ]] && command -v flutter >/dev/null 2>&1; then
    flutter_bin_dir="$(dirname "$(command -v flutter)")"
fi
if [[ -z "$flutter_bin_dir" || ! -x "$flutter_bin_dir/flutter" ]]; then
    printf 'Set CROSSDESKTOP_FLUTTER_BIN to the Flutter SDK bin directory.\n' >&2
    exit 2
fi
if [[ -z "$cargo_bin" && -x "$HOME/.cargo/bin/cargo" ]]; then
    cargo_bin="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$cargo_bin" ]]; then
    printf 'cargo is required. See docs/工程搭建.md.\n' >&2
    exit 2
fi

export CROSSDESKTOP_FLUTTER_BIN="$flutter_bin_dir"
export PATH="$flutter_bin_dir:$PATH"

"$repo_root/scripts/dev-up.sh"
"$repo_root/scripts/generate-proto.sh"

"$cargo_bin" fmt \
    --manifest-path "$repo_root/Cargo.toml" \
    --all \
    -- \
    --check
"$cargo_bin" clippy \
    --manifest-path "$repo_root/Cargo.toml" \
    --workspace \
    --all-targets \
    -- \
    -D warnings
"$cargo_bin" test \
    --manifest-path "$repo_root/Cargo.toml" \
    --workspace

core_library="$("$repo_root/scripts/build-rust-core.sh" | tail -n 1)"

if [[ -n "${CROSSDESKTOP_ANDROID_NDK_HOME:-}" ]]; then
    "$repo_root/scripts/build-rust-core-android.sh"
fi

(
    cd "$repo_root/services/control-plane-java"
    ./gradlew test
)

(
    cd "$repo_root/apps/client_flutter"
    "$flutter_bin_dir/dart" format --output=none --set-exit-if-changed lib test
    "$flutter_bin_dir/dart" analyze build/generated/proto/dart
    "$flutter_bin_dir/flutter" analyze
    CROSSDESKTOP_CORE_LIBRARY="$core_library" "$flutter_bin_dir/flutter" test
    "$flutter_bin_dir/flutter" build macos --debug
    "$flutter_bin_dir/flutter" build ios --simulator --debug
    test -d "$repo_root/apps/client_flutter/build/ios/Debug-iphonesimulator/Runner.app"
    "$flutter_bin_dir/flutter" build apk --debug
)

printf 'CrossDesktopRemote baseline checks passed.\n'
