#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() {
  printf 'one-postgres-ha: %s\n' "$1" >&2
  exit 1
}

load_secret() {
  local variable=$1 path=$2 value size value_size last_byte
  [[ -f "$path" && -r "$path" ]] || fail "missing or unreadable credential file: $path"
  size=$(wc -c <"$path")
  ((size > 0 && size <= 4097)) || fail "credential file must contain 1-4096 bytes: $path"
  value=$(<"$path")
  value_size=$(printf '%s' "$value" | wc -c)
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "credential must be a single nonempty line: $path"
  ((value_size <= 4096)) || fail "credential exceeds 4096 bytes: $path"
  if ((size != value_size)); then
    last_byte=$(tail -c 1 "$path" | od -An -tu1)
    ((size == value_size + 1 && last_byte == 10)) || fail "credential has unsupported bytes or trailing lines: $path"
  fi
  export "$variable=$value"
}

[[ $(id -u) == 999 ]] || fail 'the process must run as PostgreSQL uid 999'
load_secret PATRONI_SUPERUSER_PASSWORD /run/secrets/postgres-password
load_secret PATRONI_REPLICATION_PASSWORD /run/secrets/replication-password
load_secret PATRONI_REWIND_PASSWORD /run/secrets/rewind-password
load_secret PATRONI_RESTAPI_PASSWORD /run/secrets/patroni-api-password
export PATRONI_CTL_PASSWORD="$PATRONI_RESTAPI_PASSWORD"
[[ -r "$PATRONI_CONFIG_FILE" ]] || fail 'Patroni configuration is missing or unreadable'

if [[ ${1:-} == patroni ]]; then
  [[ -d "$PGDATA" && -w "$PGDATA" ]] || fail 'PGDATA must be a prepared writable directory'
  if [[ -f "$PGDATA/PG_VERSION" ]]; then
    [[ $(<"$PGDATA/PG_VERSION") == 18 ]] || fail 'PGDATA belongs to another PostgreSQL major version'
  elif [[ -n $(find "$PGDATA" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    fail 'refusing an unrecognized nonempty PGDATA directory'
  fi
  [[ -w /run/patroni && -w /run/postgresql ]] || fail 'runtime tmpfs directories are not writable'
fi
exec "$@"
