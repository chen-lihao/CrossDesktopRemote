#!/usr/bin/env bash
set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
    printf 'Flutter SDK is not installed. Follow docs/工程搭建.md, then rerun this script.\n' >&2
    exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
target="$repo_root/apps/client_flutter"

if [[ -f "$target/pubspec.yaml" ]]; then
    printf 'Flutter project already exists at %s\n' "$target"
    exit 0
fi

mkdir -p "$target"
(
    cd "$target"
    flutter create \
        --empty \
        --org com.crossdesktopremote \
        --project-name cross_desktop_remote \
        --platforms android,ios,linux,macos,windows \
        --android-language kotlin \
        --ios-language swift \
        .
)

(
    cd "$target"
    flutter --version
    flutter analyze
    flutter test
)
