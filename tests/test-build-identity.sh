#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"
docker() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command docker "$@"; }
host_path() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
mkdir -p "$ROOT/.local"
WORK=$(mktemp -d "$ROOT/.local/build-identity.XXXXXXXX")
PROJECT="ha-build-identity-$(date +%s)-$$"
compose() { docker compose -p "$PROJECT" -f "$(host_path "$WORK/compose.yml")" "$@"; }
cleanup() {
  local result=$?
  trap - EXIT
  compose down --volumes >/dev/null 2>&1 || true
  exit "$result"
}
trap cleanup EXIT

# Exercise the production build settings, then use an isolated harmless container.
IMAGE=$(docker compose config --images postgres)
[[ "$IMAGE" =~ ^[a-zA-Z0-9./:@_-]+$ ]]
docker compose build --print postgres >"$WORK/build.json"
grep -q 'type=provenance,disabled=true' "$WORK/build.json"
docker compose build postgres >"$WORK/first-build.log" 2>&1
FIRST_IMAGE=$(docker image inspect --format '{{.Id}}' "$IMAGE")
mkdir "$WORK/config"
chmod 755 "$WORK/config"
printf 'first\n' >"$WORK/config/marker"
chmod 644 "$WORK/config/marker"
cat >"$WORK/compose.yml" <<EOF
services:
  postgres:
    image: $IMAGE
    entrypoint: [/bin/sleep, "600"]
    init: true
    stop_grace_period: 1s
    network_mode: none
    user: "999:999"
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    mem_limit: 32m
    healthcheck:
      disable: true
    volumes:
      - type: bind
        source: $(host_path "$WORK/config")
        target: /etc/identity-fixture
        read_only: true
EOF
compose up -d --no-build --pull never >"$WORK/first-up.log" 2>&1
FIRST_CONTAINER=$(compose ps -q postgres)
FIRST_LABEL=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.image"}}' "$FIRST_CONTAINER")
[[ "$FIRST_LABEL" == "$FIRST_IMAGE" ]]

docker compose build postgres >"$WORK/second-build.log" 2>&1
SECOND_IMAGE=$(docker image inspect --format '{{.Id}}' "$IMAGE")
[[ "$SECOND_IMAGE" == "$FIRST_IMAGE" ]]
compose up -d --no-build --pull never >"$WORK/second-up.log" 2>&1
SECOND_CONTAINER=$(compose ps -q postgres)
SECOND_LABEL=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.image"}}' "$SECOND_CONTAINER")
[[ "$SECOND_CONTAINER" == "$FIRST_CONTAINER" && "$SECOND_LABEL" == "$SECOND_IMAGE" ]]
printf 'PASS: repeated cached production builds retain image identity and do not recreate the Compose container\n'

# Bind-file contents are outside Compose's hash; guarded configuration updates must recreate.
printf 'second\n' >"$WORK/config/marker"
compose up -d --no-build --pull never >"$WORK/config-up.log" 2>&1
[[ $(compose ps -q postgres) == "$SECOND_CONTAINER" ]]
[[ $(docker exec "$SECOND_CONTAINER" cat /etc/identity-fixture/marker) == second ]]
compose up -d --no-build --pull never --force-recreate >"$WORK/recreate-up.log" 2>&1
RECREATED_CONTAINER=$(compose ps -q postgres)
[[ -n "$RECREATED_CONTAINER" && "$RECREATED_CONTAINER" != "$SECOND_CONTAINER" ]]
[[ $(docker exec "$RECREATED_CONTAINER" cat /etc/identity-fixture/marker) == second ]]
printf 'PASS: changed bind contents retain the container until explicit force-recreate\n'
printf 'image=%s\ncontainer=%s\ncompose_image_label=%s\nrecreated_container=%s\n' "$SECOND_IMAGE" "$SECOND_CONTAINER" "$SECOND_LABEL" "$RECREATED_CONTAINER" >"$WORK/result.txt"
