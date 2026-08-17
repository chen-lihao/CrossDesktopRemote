#!/usr/bin/env bash
set -euo pipefail

for tool in curl unzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '%s is required to generate the Spring Boot project.\n' "$tool" >&2
        exit 2
    fi
done

repo_root="$(git rev-parse --show-toplevel)"
target="$repo_root/services/control-plane-java"
spring_boot_version="${CROSSDESKTOP_SPRING_BOOT_VERSION:-4.1.0}"

if [[ -f "$target/build.gradle" ]]; then
    printf 'Spring Boot project already exists at %s\n' "$target"
    exit 0
fi

bootstrap_tmp="$(mktemp -d)"

mkdir -p "$target"
curl --fail --location --get 'https://start.spring.io/starter.zip' \
    --data-urlencode 'type=gradle-project' \
    --data-urlencode 'language=java' \
    --data-urlencode "bootVersion=$spring_boot_version" \
    --data-urlencode 'groupId=com.crossdesktopremote' \
    --data-urlencode 'artifactId=control-plane-java' \
    --data-urlencode 'name=control-plane-java' \
    --data-urlencode 'description=CrossDesktopRemote control plane' \
    --data-urlencode 'packageName=com.crossdesktopremote.controlplane' \
    --data-urlencode 'packaging=jar' \
    --data-urlencode 'javaVersion=17' \
    --data-urlencode 'dependencies=web,websocket,validation,security,actuator,data-jpa,data-redis,postgresql,flyway' \
    --output "$bootstrap_tmp/control-plane-java.zip"

unzip -q "$bootstrap_tmp/control-plane-java.zip" -d "$target"
chmod +x "$target/gradlew"
"$target/gradlew" -p "$target" tasks
printf 'Initializr archive retained at %s for manual cleanup.\n' "$bootstrap_tmp/control-plane-java.zip"
