#!/usr/bin/env bash
set -euo pipefail

required_tools=(git java docker cmake)
generation_tools=(flutter dart rustc cargo protoc buf protoc-gen-dart cargo-ndk)
missing_required=0
missing_generation=0

check_tool() {
    local tool="$1"
    local kind="$2"
    local resolved=""

    if command -v "$tool" >/dev/null 2>&1; then
        resolved="$(command -v "$tool")"
    elif [[ "$tool" == "flutter" || "$tool" == "dart" ]]; then
        if [[ -n "${CROSSDESKTOP_FLUTTER_BIN:-}" && -x "${CROSSDESKTOP_FLUTTER_BIN}/$tool" ]]; then
            resolved="${CROSSDESKTOP_FLUTTER_BIN}/$tool"
        elif [[ -x "/Volumes/zhiti-1T/Library/flutter/bin/$tool" ]]; then
            resolved="/Volumes/zhiti-1T/Library/flutter/bin/$tool"
        fi
    elif [[ "$tool" == "rustc" || "$tool" == "cargo" || "$tool" == "cargo-ndk" ]]; then
        if [[ -x "$HOME/.cargo/bin/$tool" ]]; then
            resolved="$HOME/.cargo/bin/$tool"
        fi
    elif [[ "$tool" == "protoc-gen-dart" && -x "$HOME/.pub-cache/bin/protoc-gen-dart" ]]; then
        resolved="$HOME/.pub-cache/bin/protoc-gen-dart"
    fi

    if [[ -n "$resolved" ]]; then
        printf '[ok] %-16s %s\n' "$tool" "$resolved"
        return
    fi

    printf '[missing] %-16s %s\n' "$tool" "$kind"
    if [[ "$kind" == "required" ]]; then
        missing_required=1
    else
        missing_generation=1
    fi
}

for tool in "${required_tools[@]}"; do
    check_tool "$tool" required
done

for tool in "${generation_tools[@]}"; do
    check_tool "$tool" generator
done

if (( missing_generation != 0 )); then
    printf '\nSome framework generators are missing. See docs/工程搭建.md.\n'
fi

exit "$missing_required"
