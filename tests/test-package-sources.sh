#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
# shellcheck source=../images/postgres/source-profiles.sh
source "$ROOT/images/postgres/source-profiles.sh"

make_root() {
  local directory=$1
  mkdir -p "$directory/etc/apt/sources.list.d" "$directory/etc/ssl/certs"
  cat >"$directory/etc/apt/sources.list.d/debian.sources" <<'SOURCES'
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: bookworm-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
  printf '%s\n' 'deb [ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main 17' \
    >"$directory/etc/apt/sources.list.d/pgdg.list"
}

apt-get() {
  printf '%s\n' "$*" >>"$FIXTURE_ROOT/apt-calls"
  # Missing CA uses HTTP only to bootstrap this signed Debian package.
  grep -Fxq "URIs: http://mirrors.ustc.edu.cn/debian" "$FIXTURE_ROOT/etc/apt/sources.list.d/debian.sources"
  [[ ! -e "$FIXTURE_ROOT/etc/apt/sources.list.d/pgdg.list" ]]
  [[ ${FAIL_BOOTSTRAP:-false} != true ]] || return 1
  case "$*" in
    update) ;;
    'install -y --no-install-recommends ca-certificates')
      printf 'fixture public CA bundle\n' >"$FIXTURE_ROOT/etc/ssl/certs/ca-certificates.crt" ;;
    *) return 9 ;;
  esac
}

for profile in official ustc tuna; do
  ha_source_urls "$profile"
  for url in "$HA_DEBIAN_URL" "$HA_DEBIAN_SECURITY_URL" "$HA_PYPI_URL" "$HA_DOCKER_CE_URL"; do
    [[ $url == https://* && $url != *@* && $url != *$'\n'* ]]
  done
  [[ $(bash "$ROOT/images/postgres/source-profiles.sh" --pip-url "$profile") == "$HA_PYPI_URL" ]]
done
if ha_source_urls '$(touch injected)' >/dev/null 2>&1; then exit 1; fi
if bash "$ROOT/images/postgres/source-profiles.sh" --pip-url official extra >/dev/null 2>&1; then exit 1; fi
# The public CLI cannot modify APT when run on an ordinary host.
if env PG_MAJOR=not-a-container bash "$ROOT/images/postgres/source-profiles.sh" --apply ustc >/dev/null 2>&1; then exit 1; fi
if env PG_MAJOR=17 bash "$ROOT/images/postgres/source-profiles.sh" --apply ustc >/dev/null 2>&1; then exit 1; fi

make_root "$WORK/official"
before=$(sha256sum "$WORK/official/etc/apt/sources.list.d/debian.sources")
ha_source_apply official "$WORK/official"
[[ $(sha256sum "$WORK/official/etc/apt/sources.list.d/debian.sources") == "$before" ]]
[[ -f "$WORK/official/etc/apt/sources.list.d/pgdg.list" && ! -e "$WORK/official/apt-calls" ]]

FIXTURE_ROOT="$WORK/bootstrap"
make_root "$FIXTURE_ROOT"
ha_source_apply ustc "$FIXTURE_ROOT"
[[ $(cat "$FIXTURE_ROOT/apt-calls") == $'update\ninstall -y --no-install-recommends ca-certificates' ]]
grep -Fxq 'URIs: https://mirrors.ustc.edu.cn/debian' "$FIXTURE_ROOT/etc/apt/sources.list.d/debian.sources"
grep -Fxq 'URIs: https://mirrors.ustc.edu.cn/debian-security' "$FIXTURE_ROOT/etc/apt/sources.list.d/debian.sources"
grep -Fxq 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' "$FIXTURE_ROOT/etc/apt/sources.list.d/debian.sources"
ha_source_apply tuna "$FIXTURE_ROOT"
grep -Fxq 'URIs: https://mirrors.tuna.tsinghua.edu.cn/debian' "$FIXTURE_ROOT/etc/apt/sources.list.d/debian.sources"
[[ $(wc -l <"$FIXTURE_ROOT/apt-calls") == 2 ]]

for scenario in foreign mixed_pgdg unsafe_trust unknown_key linked; do
  FIXTURE_ROOT="$WORK/$scenario"
  make_root "$FIXTURE_ROOT"
  sources="$FIXTURE_ROOT/etc/apt/sources.list.d"
  case "$scenario" in
    foreign) printf 'deb https://packages.example.invalid/debian stable main\n' >"$sources/foreign.list" ;;
    mixed_pgdg) printf 'deb https://packages.example.invalid/debian stable main\n' >>"$sources/pgdg.list" ;;
    unsafe_trust) printf 'Trusted: yes\n' >>"$sources/debian.sources" ;;
    unknown_key) sed -i 's|/usr/share/keyrings/debian-archive-keyring.gpg|/tmp/untrusted.gpg|' "$sources/debian.sources" ;;
    linked) mv "$sources/debian.sources" "$FIXTURE_ROOT/original"; ln -s "$FIXTURE_ROOT/original" "$sources/debian.sources" ;;
  esac
  before=$(cat "$sources/debian.sources")
  if ha_source_apply ustc "$FIXTURE_ROOT" >/dev/null 2>&1; then printf 'Unsafe source fixture accepted: %s\n' "$scenario" >&2; exit 1; fi
  [[ $(cat "$sources/debian.sources") == "$before" && ! -e "$FIXTURE_ROOT/apt-calls" ]]
  [[ -e "$sources/pgdg.list" ]]
done

FIXTURE_ROOT="$WORK/failure"
make_root "$FIXTURE_ROOT"
before=$(cat "$FIXTURE_ROOT/etc/apt/sources.list.d/debian.sources")
FAIL_BOOTSTRAP=true
if ha_source_apply ustc "$FIXTURE_ROOT" >/dev/null 2>&1; then exit 1; fi
[[ $(cat "$FIXTURE_ROOT/etc/apt/sources.list.d/debian.sources") == "$before" ]]
unset FAIL_BOOTSTRAP

# Supplying a fixture root alone cannot accidentally run the host APT command.
make_root "$WORK/no-stub"
if (unset -f apt-get; ha_source_apply ustc "$WORK/no-stub") >/dev/null 2>&1; then exit 1; fi
[[ -f "$WORK/no-stub/etc/apt/sources.list.d/pgdg.list" && ! -e "$WORK/no-stub/apt-calls" ]]

python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
pg = (root/'images/postgres/Dockerfile').read_text()
tools = (root/'images/tools/Dockerfile').read_text()
assert pg.count('ARG DOWNLOAD_SOURCE=official') == 2
assert pg.count('ha-source-profiles --apply "$DOWNLOAD_SOURCE"') == 2
assert pg.count('--require-hashes') == 2
assert '--no-build-isolation --require-hashes' in pg
assert tools.count('ARG DOWNLOAD_SOURCE=official') == 1
assert '--index-url "$(/usr/local/bin/ha-source-profiles --pip-url "$DOWNLOAD_SOURCE")"' in pg
assert '--index-url "$(/usr/local/bin/ha-source-profiles --pip-url "$DOWNLOAD_SOURCE")"' in tools
assert '!source-profiles.sh' in (root/'images/postgres/.dockerignore').read_text().splitlines()
assert 'DOWNLOAD_SOURCE: ${HA_DOWNLOAD_SOURCE:-official}' in (root/'docker-compose.yml').read_text()
for text in (pg, tools):
    assert '--trusted-host' not in text and '--allow-unauthenticated' not in text and '--extra-index-url' not in text
assert 'HA_DOWNLOAD_SOURCE={{ download_source }}' in (root/'ansible/roles/cluster/templates/node.env.j2').read_text()
PY
printf 'PASS: package source presets, signed CA bootstrap, HTTPS rendering, unknown-source guards and immutable dependency contracts\n'
