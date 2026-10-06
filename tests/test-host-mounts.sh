#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
python3 - "$root" "$tmp" <<'PY'
import pathlib,re,sys
root,work=map(pathlib.Path,sys.argv[1:])
text=(root/'scripts/prepare-host.sh').read_text()
functions=[]
for name in ['check_mount_dependencies','install_mount_dependencies','verify_mount_dependencies']:
    match=re.search(r'^'+name+r'\(\) \{\n.*?^\}',text,re.M|re.S)
    assert match,name
    functions.append(match.group())
(work/'functions.sh').write_text('\n'.join(functions)+'\n')
branch=re.search(r'^if \[\[ "\$OWNED" == true \]\] && running_root=.*?^fi',text,re.M|re.S)
assert branch
(work/'already.sh').write_text(branch.group()+'\n')
PY
die() { printf '%s\n' "$1" >&2; exit 2; }
SSD="$tmp/ssd"
DOCKER_ROOT="$SSD/docker"
SYSTEMD_UNIT_ROOT="$tmp/systemd"
export OWNED=true
docker() { printf '%s\n' "$DOCKER_ROOT"; }
systemctl() {
  printf '%s\n' "$*" >>"$tmp/systemctl.log"
  case "$1" in
    daemon-reload) ;;
    show) local service=${*: -1}; printf '%s\n' "$SSD/${service%.service}" ;;
    *) die 'Unexpected service mutation in an already prepared host' ;;
  esac
}
source "$tmp/functions.sh"
check_mount_dependencies
(source "$tmp/already.sh")
for service in docker containerd; do
  grep -Fxq "RequiresMountsFor=$SSD/$service" "$SYSTEMD_UNIT_ROOT/$service.service.d/20-one-postgres-ha-ssd.conf"
done
[[ $(grep -c '^daemon-reload$' "$tmp/systemctl.log") == 1 ]]
(source "$tmp/already.sh")
[[ $(grep -c '^daemon-reload$' "$tmp/systemctl.log") == 1 ]]
cp "$root/ansible/roles/cluster/templates/firewall-dependency.conf.j2" "$SYSTEMD_UNIT_ROOT/docker.service.d/30-one-postgres-ha-firewall.conf"
check_mount_dependencies
(source "$tmp/already.sh")
[[ $(grep -c '^daemon-reload$' "$tmp/systemctl.log") == 1 ]]
grep -Fxq 'Requires=one-postgres-ha-firewall.service' "$SYSTEMD_UNIT_ROOT/docker.service.d/30-one-postgres-ha-firewall.conf"
printf 'After=foreign.service\n' >>"$SYSTEMD_UNIT_ROOT/docker.service.d/30-one-postgres-ha-firewall.conf"
if (check_mount_dependencies) >"$tmp/rejection.log" 2>&1; then die 'Modified firewall dependency was accepted'; fi
rm -- "$SYSTEMD_UNIT_ROOT/docker.service.d/30-one-postgres-ha-firewall.conf"
printf '[Unit]\n' >"$SYSTEMD_UNIT_ROOT/docker.service.d/unknown.conf"
if (check_mount_dependencies) >"$tmp/rejection.log" 2>&1; then die 'Unknown systemd drop-in was accepted'; fi
rm -- "$SYSTEMD_UNIT_ROOT/docker.service.d/unknown.conf"
printf 'RequiresMountsFor=/wrong\n' >>"$SYSTEMD_UNIT_ROOT/docker.service.d/20-one-postgres-ha-ssd.conf"
if (check_mount_dependencies) >"$tmp/rejection.log" 2>&1; then die 'Modified managed drop-in was accepted'; fi
echo 'PASS: prepared-host mount dependencies, idempotence, no restart and unknown-drop-in rejection'
