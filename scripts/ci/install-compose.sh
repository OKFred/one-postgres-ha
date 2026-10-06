#!/usr/bin/env bash
set -Eeuo pipefail
# CI installs a fixed user-scoped plugin; host deployment uses its pinned APT package.
[[ $(uname -s) == Linux ]] || { echo 'CI Compose bootstrap requires Linux' >&2; exit 1; }
VERSION=5.6.0
case $(uname -m) in
  x86_64)
    ASSET=docker-compose-linux-x86_64
    SHA256=40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a
    ;;
  aarch64 | arm64)
    ASSET=docker-compose-linux-aarch64
    SHA256=733ec76717ceb59052a9609b9dadfb523b2df8eab57a54212872d10a58078ea2
    ;;
  *) echo 'Unsupported CI Compose architecture' >&2; exit 1 ;;
esac
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 \
  "https://github.com/docker/compose/releases/download/v$VERSION/$ASSET" --output "$WORK/$ASSET"
printf '%s  %s\n' "$SHA256" "$WORK/$ASSET" | sha256sum --check --status
PLUGIN_DIR="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
install -d -m 0755 "$PLUGIN_DIR"
install -m 0755 "$WORK/$ASSET" "$PLUGIN_DIR/docker-compose"
[[ $("$PLUGIN_DIR/docker-compose" version --short) == "$VERSION" ]]
printf 'PASS: installed official Compose %s (%s), SHA256=%s\n' "$VERSION" "$ASSET" "$SHA256"
