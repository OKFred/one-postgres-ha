#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
PGDATA_TEST="$WORK/pgdata"
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -f "$PGDATA_TEST/postmaster.pid" ]]; then
    runuser -u postgres -- pg_ctl -D "$PGDATA_TEST" -m immediate -w stop >"$WORK/stop.log" 2>&1 || true
  fi
  rm -rf -- "$WORK"
  exit "$result"
}
trap cleanup EXIT
chmod 755 "$WORK"
mkdir "$PGDATA_TEST" "$WORK/socket"
chown postgres:postgres "$PGDATA_TEST" "$WORK/socket"
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib, sys, yaml
root, work = map(pathlib.Path, sys.argv[1:])
play = [dict(name='Render the real production Patroni template', hosts='armbian-01',
    connection='local', become=False, gather_facts=False,
    vars={'ansible_python_interpreter':'{{ ansible_playbook_python }}'},
    vars_files=[str(root/'ansible/roles/cluster/defaults/main.yml')],
    tasks=[dict(name='Render production config without site inventory',
        **{'ansible.builtin.template':{'src':str(root/'ansible/roles/cluster/templates/patroni.yml.j2'),
                                     'dest':str(work/'patroni.yml'),'mode':'0644'}})])]
(work/'render.yml').write_text(yaml.safe_dump(play))
PY
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg"
ansible-playbook -i "$ROOT/ansible/inventory.example.yml" "$WORK/render.yml"
python3 - "$WORK" <<'PY'
import pathlib, sys, yaml
work = pathlib.Path(sys.argv[1])
hba = yaml.safe_load((work/'patroni.yml').read_text())['postgresql']['pg_hba']
loopback = 'host replication replicator 127.0.0.1/32 scram-sha-256'
assert hba.count(loopback) == 1
assert not any(line.startswith('local replication ') for line in hba)
assert not any(line.startswith('host replication ') and '0.0.0.0/0' in line for line in hba)
(work/'pg_hba.conf').write_text('\n'.join(hba)+'\n')
(work/'missing-loopback.conf').write_text('\n'.join(line for line in hba if line != loopback)+'\n')
PY
runuser -u postgres -- initdb -D "$PGDATA_TEST" --auth-local=trust --auth-host=scram-sha-256 >"$WORK/init.log"
runuser -u postgres -- pg_ctl -D "$PGDATA_TEST" -l "$PGDATA_TEST/server.log" \
  -o "-h 127.0.0.1 -p 5433 -k $WORK/socket -c shared_buffers=16MB" -w start >"$WORK/start.log"
psql -h "$WORK/socket" -p 5433 -U postgres -d postgres -X -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE replicator REPLICATION LOGIN PASSWORD 'fixture-replication-password';" >"$WORK/create-role.log"
cp "$WORK/missing-loopback.conf" "$PGDATA_TEST/pg_hba.conf"
chown postgres:postgres "$PGDATA_TEST/pg_hba.conf"
runuser -u postgres -- pg_ctl -D "$PGDATA_TEST" reload >/dev/null
sleep 0.2
if PGPASSWORD=fixture-replication-password psql -X -A -t \
  -d 'host=127.0.0.1 port=5433 user=replicator replication=true connect_timeout=3' \
  -c IDENTIFY_SYSTEM >"$WORK/denied.log" 2>&1; then
  echo 'The fixture without a loopback replication rule unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'no pg_hba.conf entry for replication connection' "$WORK/denied.log"
cp "$WORK/pg_hba.conf" "$PGDATA_TEST/pg_hba.conf"
chown postgres:postgres "$PGDATA_TEST/pg_hba.conf"
runuser -u postgres -- pg_ctl -D "$PGDATA_TEST" reload >/dev/null
sleep 0.2
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib, subprocess, sys, yaml
root, work = map(pathlib.Path, sys.argv[1:])
tasks = yaml.safe_load((root/'ansible/roles/cluster/tasks/read-local-replication.yml').read_text())
command = tasks[0]['ansible.builtin.command']
assert command['argv'][:8] == ['docker','compose','--env-file','.env','exec','-T','postgres','/usr/local/bin/patroni-entrypoint']
command['argv'] = command['argv'][8:]
tasks[0]['environment'] = {'PATRONI_REPLICATION_PASSWORD':'fixture-replication-password'}
identity = subprocess.check_output(['pg_controldata',str(work/'pgdata')],text=True)
systemid = next(line.split(':',1)[1].strip() for line in identity.splitlines()
                if line.startswith('Database system identifier:'))
play = [dict(name='Execute the production local replication invariant against an isolated PostgreSQL',
    hosts='localhost', connection='local', gather_facts=False,
    vars={'postgres_port':5433,'deployment_root':str(work),'pg_ha_sql':{'system_identifier':systemid}},tasks=tasks)]
(work/'verify.yml').write_text(yaml.safe_dump(play))
PY
ansible-playbook -i localhost, "$WORK/verify.yml"
if PGPASSWORD=fixture-replication-password psql -X -A -t -h 127.0.0.1 -p 5433 -U replicator -d postgres \
  -c 'SELECT 1' >"$WORK/regular-denied.log" 2>&1; then
  echo 'The loopback replication rule also granted regular SQL access' >&2
  exit 1
fi
grep -Eq 'no pg_hba.conf entry|pg_hba.conf rejects connection' "$WORK/regular-denied.log"
printf 'PASS: production HBA authenticates local physical replication without granting regular SQL access\n'
