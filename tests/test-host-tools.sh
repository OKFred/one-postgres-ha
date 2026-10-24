#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib, sys, yaml
root, work = map(pathlib.Path, sys.argv[1:])
tasks = yaml.safe_load((root / 'ansible/roles/cluster/tasks/preflight.yml').read_text())
selected = [t for t in tasks if t['name'] == 'Check the required tools']
assert len(selected) == 1
(work / 'check.sh').write_text(selected[0]['ansible.builtin.shell'])
PY
mkdir -p "$WORK/bin"
for tool in docker ss fuser openssl iptables ip6tables flock curl systemctl udevadm iptables-restore ip6tables-restore timeout; do
  printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/$tool"
  chmod +x "$WORK/bin/$tool"
done
PATH="$WORK/bin" /bin/bash "$WORK/check.sh"
for tool in docker fuser iptables udevadm iptables-restore ip6tables-restore timeout; do
  mv "$WORK/bin/$tool" "$WORK/$tool"
  if PATH="$WORK/bin" /bin/bash "$WORK/check.sh" >"$WORK/output" 2>&1; then
    printf 'Missing host tool was not rejected: %s\n' "$tool" >&2
    exit 1
  fi
  grep -Fq "Missing required tool: $tool" "$WORK/output"
  mv "$WORK/$tool" "$WORK/bin/$tool"
done
echo 'PASS: host preflight rejects every missing tool, including one before available commands'
