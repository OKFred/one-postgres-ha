#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/private"
printf 'isolated-test-password\n' >"$tmp/private/ssh-password"
python3 - "$root" "$tmp" <<'PY'
import pathlib,sys,yaml
root,work=map(pathlib.Path,sys.argv[1:])
inventory=yaml.safe_load((root/'ansible/inventory.example.yml').read_text())
inventory['all']['vars'].update(ansible_user='root',ansible_become=True,
    private_dir=str(work/'private'),
    ansible_password="{{ lookup('ansible.builtin.file', private_dir + '/ssh-password') }}")
(work/'inventory.yml').write_text(yaml.safe_dump(inventory))
tasks=yaml.safe_load((root/'ansible/roles/cluster/tasks/preflight.yml').read_text())
names={'Check private input files on the controller','Require complete private inputs',
       'Verify the node TLS chains on the controller','Verify the etcd certificate IP addresses'}
selected=[task for task in tasks if task.get('name') in names]
assert len(selected)==4
plays=[dict(name='Execute production controller checks with remote authentication vars',
    hosts='pg_nodes',gather_facts=False,become=True,tasks=selected)]
local_play=yaml.safe_load((root/'ansible/data/main.yml').read_text())[0]
local_play['name']='Exercise the data entry local connection with an actual module'
local_play['tasks']=[dict(name='Read a harmless controller file',
    **{'ansible.builtin.stat':dict(path=str(work/'private/secrets/ca.crt'))},
    register='controller_probe'),dict(name='Require successful local module execution',
    **{'ansible.builtin.assert':dict(that='controller_probe.stat.exists')})]
plays.append(local_play)
(work/'local.yml').write_text(yaml.safe_dump(plays))
probe={'ansible_connection':'ssh','ansible_host':'127.0.0.1','ansible_port':22,
       'ansible_user':'root','ansible_become':False,
       'ansible_ssh_common_args':'-o BatchMode=yes -o IdentityFile=/dev/null'}
(work/'ssh.yml').write_text(yaml.safe_dump({'all':{'hosts':{'controller_ssh_probe':probe}}}))
PY
bash "$root/scripts/bootstrap-secrets.sh" "$tmp/inventory.yml" "$tmp/private/secrets" >/dev/null
ANSIBLE_CONFIG="$root/ansible/ansible.cfg" ansible-playbook -i "$tmp/inventory.yml" "$tmp/local.yml"
echo 'PASS: private input/TLS delegation and data local modules use writable controller temp'

# This tools container has no SSH server; only probe its own loopback address.
if ANSIBLE_CONFIG="$root/ansible/ansible.cfg" ansible -i "$tmp/ssh.yml" controller_ssh_probe \
  -m ansible.builtin.command -a /bin/true --timeout 3 -vvv >"$tmp/ssh.log" 2>&1; then
  echo 'The isolated loopback SSH probe unexpectedly succeeded' >&2; exit 1
fi
grep -Fq 'Connection refused' "$tmp/ssh.log"
grep -Fq '/tmp/ansible-cp/' "$tmp/ssh.log"
! grep -Fq '/root/.ansible/cp' "$tmp/ssh.log"
[[ -d /tmp/ansible-cp ]]
echo 'PASS: SSH control path stays in writable /tmp before loopback connection refusal'
