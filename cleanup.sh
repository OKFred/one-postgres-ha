#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf 'Usage: bash cleanup.sh [--inventory FILE] [--plan|--apply [--confirm DELETE-ONE-POSTGRES-HA]]\nDefault: preview. Apply permanently removes this cluster from all inventory pg_nodes, including PostgreSQL/etcd data. Controller inputs, disks and Docker storage are retained.\n'
  exit 0
fi
ARGS=()
if [[ ${1:-} == --inventory ]]; then
  [[ $# -ge 2 ]] || {
    echo '--inventory requires a file' >&2
    exit 2
  }
  ARGS=(--inventory "$2")
  shift 2
fi
exec bash "$ROOT/ops.sh" "${ARGS[@]}" cleanup "$@"
