#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  printf '%s\n' 'Usage: bash install.sh [--inventory FILE] [--plan|--apply|--yes]' \
    'Default: configure if needed, then confirm INSTALL before installing.' \
    '--plan prepares missing local credentials and previews without changing target hosts.' \
    '--apply explicitly approves installation.' \
    '--yes is a compatibility alias for --apply; all configuration and SSH checks remain required.'
}
mode=''
inventory=${HA_INVENTORY:-$ROOT/.local/inventory.yml}
inventory_seen=false
while (($#)); do
  case "$1" in
    --inventory)
      [[ $# -ge 2 && -n $2 && $inventory_seen == false ]] || die '--inventory requires one file'
      inventory=$2; inventory_seen=true; shift ;;
    --plan|--apply|--yes)
      [[ -z $mode ]] || die 'Choose --plan, --apply or --yes once'
      mode=$1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die 'Unexpected installation argument' ;;
  esac
  shift
done
[[ ! -L $ROOT/.local && ! -L $inventory ]] || die 'Private configuration must not be a symlink'
if [[ ! -e $inventory ]]; then
  [[ $inventory == "$ROOT/.local/inventory.yml" && -t 0 && -t 1 ]] || die 'Run bash ops.sh configure first, or supply a prepared --inventory FILE'
  bash "$ROOT/ops.sh" configure
fi
[[ -f $inventory && -s $inventory ]] || die 'Missing or empty inventory; run bash ops.sh configure first'
if [[ -z $mode ]]; then
  [[ -t 0 && -t 1 ]] || die 'Installation requires interactive confirmation or explicit --apply'
  printf 'Install and verify the PostgreSQL cluster described by %s. Existing data and credentials are preserved.\n' "$inventory"
  read -r -p 'Type INSTALL to continue: ' answer
  [[ $answer == INSTALL ]] || die 'Installation cancelled; configuration was preserved'
fi
[[ $mode == --plan ]] || mode=--apply
exec bash "$ROOT/ops.sh" --inventory "$inventory" install "$mode"
