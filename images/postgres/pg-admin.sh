#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
case ${1:-} in
  psql | pg_dump | pg_restore | pg_dumpall) ;;
  *) printf 'pg-admin: expected psql, pg_dump, pg_restore or pg_dumpall\n' >&2; exit 2 ;;
esac
secret=/run/secrets/postgres-password
[[ -r "$secret" && -s "$secret" ]] || { printf 'pg-admin: missing PostgreSQL credential file\n' >&2; exit 1; }
PGPASSWORD=$(<"$secret")
export PGPASSWORD
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5433}" PGUSER="${PGUSER:-postgres}"
exec "$@"
