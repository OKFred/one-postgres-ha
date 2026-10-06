#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib,sys,yaml
root,work=map(pathlib.Path,sys.argv[1:])
tasks=yaml.safe_load((root/'ansible/roles/cluster/tasks/start-proxy.yml').read_text())
selected=[task for task in tasks if 'ansible.builtin.command' in task]
assert len(selected)==4
fake=work/'docker'
fake.write_text('''#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\\n' "$*" >>docker.log
case "$*" in
  'compose --env-file .env ps --quiet haproxy')
    if [[ -f started ]]; then cat after; else cat before; fi ;;
  'compose --env-file .env up -d --no-build haproxy') touch started ;;
  'compose --env-file .env kill --signal SIGUSR2 haproxy') : ;;
  *) echo 'Unexpected fake Docker command' >&2; exit 2 ;;
esac
''')
fake.chmod(0o755)
for task in selected:
    task['ansible.builtin.command']['argv'][0]=str(fake)
inventory=dict(all=dict(hosts={}))
for name,before,after in [('initial','','new-proxy'),('same','same-proxy','same-proxy'),('replaced','old-proxy','new-proxy')]:
    directory=work/name
    directory.mkdir()
    (directory/'before').write_text(before+'\n')
    (directory/'after').write_text(after+'\n')
    inventory['all']['hosts'][name]=dict(ansible_connection='local',
        ansible_python_interpreter='{{ ansible_playbook_python }}',
        deployment_root=str(directory),pg_ha_haproxy_template=dict(changed=True))
(work/'inventory.yml').write_text(yaml.safe_dump(inventory))
(work/'play.yml').write_text(yaml.safe_dump([dict(name='Exercise real proxy reconciliation guards',
    hosts='all',gather_facts=False,tasks=selected)]))
PY
ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" ansible-playbook -i "$WORK/inventory.yml" "$WORK/play.yml"
for scenario in initial same replaced; do
  count=$(grep -c -- 'kill --signal SIGUSR2 haproxy' "$WORK/$scenario/docker.log" || true)
  expected=0
  [[ "$scenario" != same ]] || expected=1
  [[ "$count" == "$expected" ]]
done
printf 'PASS: initial and replaced proxies avoid reload; an existing same-ID proxy reloads changed configuration\n'
