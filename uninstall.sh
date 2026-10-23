#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  printf '%s\n' 'Usage: bash uninstall.sh [--inventory FILE] [--plan|--apply] [--keep-data|--purge-data] [--confirm TOKEN]' \
    'Default: --plan --keep-data. Apply requires an explicit data level and the displayed confirmation.' \
    '--keep-data retains PostgreSQL/etcd data and node configuration for reinstall.' \
    '--purge-data deletes this cluster data; controller .local, disks and unrelated services are retained.'
}
mode=''
level=''
confirmation=''
inventory=${HA_INVENTORY:-$ROOT/.local/inventory.yml}
inventory_seen=false
while (($#)); do
  case "$1" in
    --inventory)
      [[ $# -ge 2 && -n $2 && $inventory_seen == false ]] || die '--inventory requires one file'
      inventory=$2; inventory_seen=true; shift ;;
    --plan|--apply)
      [[ -z $mode ]] || die 'Choose --plan or --apply once'; mode=$1 ;;
    --keep-data|--purge-data)
      [[ -z $level ]] || die 'Choose --keep-data or --purge-data once'; level=$1 ;;
    --confirm)
      [[ $# -ge 2 && -n $2 && -z $confirmation ]] || die '--confirm requires one token'
      confirmation=$2; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die 'Unexpected uninstallation argument' ;;
  esac
  shift
done
mode=${mode:---plan}
[[ $mode != --apply || -n $level ]] || die '--apply requires explicit --keep-data or --purge-data'
[[ -z $confirmation || $mode == --apply ]] || die '--confirm requires --apply'
level=${level:---keep-data}
args=(--inventory "$inventory" cleanup "$mode" "$level")
[[ -z $confirmation ]] || args+=(--confirm "$confirmation")
exec bash "$ROOT/ops.sh" "${args[@]}"
