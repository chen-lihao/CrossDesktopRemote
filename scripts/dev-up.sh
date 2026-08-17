#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
compose_file="$repo_root/infra/deploy/compose.dev.yaml"

if ! command -v docker >/dev/null 2>&1; then
    printf 'docker is required. See docs/工程搭建.md.\n' >&2
    exit 2
fi

docker info >/dev/null
docker compose -f "$compose_file" config --quiet
docker compose -f "$compose_file" up -d --wait
docker compose -f "$compose_file" ps
