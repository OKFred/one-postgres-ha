#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(uname -s) == Linux ]] || { echo 'Gitleaks bootstrap requires Linux' >&2; exit 1; }
VERSION=8.30.1
case $(uname -m) in
  x86_64)
    ASSET=gitleaks_${VERSION}_linux_x64.tar.gz
    SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    ;;
  aarch64 | arm64)
    ASSET=gitleaks_${VERSION}_linux_arm64.tar.gz
    SHA256=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
    ;;
  *) echo 'Unsupported Gitleaks architecture' >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 \
  "https://github.com/gitleaks/gitleaks/releases/download/v$VERSION/$ASSET" --output "$work/$ASSET"
printf '%s  %s\n' "$SHA256" "$work/$ASSET" | sha256sum --check --status
tar -xzf "$work/$ASSET" -C "$work" gitleaks
binary_dir=${HA_CI_BIN_DIR:-$HOME/.local/bin}
install -d -m 0755 "$binary_dir"
install -m 0755 "$work/gitleaks" "$binary_dir/gitleaks"
[[ $("$binary_dir/gitleaks" version) == "$VERSION" ]]
printf 'PASS: verified official Gitleaks %s\n' "$VERSION"
