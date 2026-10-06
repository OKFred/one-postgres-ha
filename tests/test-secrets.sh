#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
bash "$root/scripts/bootstrap-secrets.sh" "$root/ansible/inventory.example.yml" "$tmp/secrets"
find "$tmp/secrets" -type f ! -name .lock -exec sha256sum {} + | sort >"$tmp/before"
bash "$root/scripts/bootstrap-secrets.sh" "$root/ansible/inventory.example.yml" "$tmp/secrets"
find "$tmp/secrets" -type f ! -name .lock -exec sha256sum {} + | sort >"$tmp/after"
cmp "$tmp/before" "$tmp/after"
truncate -s 0 "$tmp/secrets/postgres-password"
if bash "$root/scripts/bootstrap-secrets.sh" "$root/ansible/inventory.example.yml" "$tmp/secrets" >"$tmp/output" 2>&1; then
  echo 'Empty credentials were accepted' >&2; exit 1
fi
echo 'PASS: credential and certificate idempotence; corrupt credential rejection'
