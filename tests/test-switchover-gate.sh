#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg"
python3 - "$ROOT" "$WORK" <<'PY'
import copy, json, os, pathlib, subprocess, sys, yaml
root, work = map(pathlib.Path, sys.argv[1:])
source = yaml.safe_load((root/'ansible/roles/cluster/tasks/switchover.yml').read_text())
names = ['Read current synchronous replica names',
         'Select a current synchronous replica unless an explicit candidate was supplied',
         'Validate the switchover target',
         'Wait until Patroni records the candidate as synchronous',
         'Confirm the original leader is still current',
         'Refresh SQL synchronous state immediately before the request',
         'Require the fixed candidate to remain synchronous in PostgreSQL',
         'Request the controlled switchover']
selected = [next(task for task in source if task['name']==name) for name in names]
assert selected[0]['until'] and selected[0]['retries']
assert '--consistency=l' in selected[3]['ansible.builtin.command']['argv']
assert selected[3]['until'] and selected[3]['retries']
refresh = next(i for i,task in enumerate(source)
               if task['name']=='Refresh the leader immediately before requesting a switchover')
request = next(i for i,task in enumerate(source) if task['name']==names[-1])
assert refresh < request and source[refresh]['ansible.builtin.include_tasks']=='read-cluster.yml'
inventory = {'all':{'children':{
    'core_nodes':{'hosts':{'localhost':{'ansible_connection':'local','node_ip':'127.0.0.1'}}},
    'pg_nodes':{'hosts':{'replica':{'ansible_connection':'local'},'localhost':{}}}}}}
(work/'inventory.yml').write_text(yaml.safe_dump(inventory))
ready = {'leader':'leader','sync_standby':'other,replica'}
cases = [
    ('pending-to-eligible', {'sql':[[],['replica'],['replica']], 'dcs':['',{'leader':'leader','sync_standby':''},ready]}, True),
    ('missing-key', {'sql':[['replica']], 'dcs':['']}, False),
    ('wrong-dcs-leader', {'sql':[['replica']], 'dcs':[{'leader':'different','sync_standby':'replica'}]}, False),
    ('substring-is-not-member', {'sql':[['replica']], 'dcs':[{'leader':'leader','sync_standby':'replica-extra'}]}, False),
    ('leader-changed-before-request', {'sql':[['replica']], 'dcs':[ready], 'current_leader':'different'}, False),
    ('lost-sql-sync-before-request', {'sql':[['replica'],[]], 'dcs':[ready]}, False),
    ('never-sql-sync', {'sql':[[]], 'dcs':[ready]}, False),
    ('dcs-query-failed', {'sql':[['replica']], 'dcs':[ready], 'dcs_rc':1}, False),
]
for name,fixture,allowed in cases:
    folder = work/name
    folder.mkdir()
    (folder/'fixture.json').write_text(json.dumps(fixture))
    docker = folder/'docker-fixture'
    docker.write_text('''#!/usr/bin/env python3
import json,pathlib,sys
folder=pathlib.Path(__file__).parent
fixture=json.loads((folder/'fixture.json').read_text())
if 'switchover' in sys.argv:
    (folder/'request').write_text('submitted')
    raise SystemExit(0)
kind='dcs' if '/usr/local/bin/etcdctl' in sys.argv else 'sql'
counter=folder/(kind+'-count')
number=int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(number+1))
sequence=fixture[kind]
value=sequence[min(number,len(sequence)-1)]
print(value if isinstance(value,str) else json.dumps(value))
raise SystemExit(fixture.get(kind+'_rc',0))
''')
    docker.chmod(0o755)
    tasks=copy.deepcopy(selected)
    for task in tasks:
        if 'ansible.builtin.command' in task:
            task['ansible.builtin.command']['argv'][0]=str(docker)
        if 'until' in task:
            task['delay']=0
            task['retries']=3 if allowed else 1
    tasks.insert(4,dict(name='Simulate the refreshed leader observation',
        **{'ansible.builtin.set_fact':{'pg_ha_leader_name':fixture.get('current_leader','leader')}}))
    play=[dict(name='Exercise the production switchover gate '+name,hosts='localhost',
        connection='local',gather_facts=False,
        vars={'deployment_root':str(folder),'cluster_name':'fixture',
              'pg_ha_leader_name':'leader','pg_ha_leader_host':'localhost','operation_timeout':6},tasks=tasks)]
    (folder/'play.yml').write_text(yaml.safe_dump(play))
    result=subprocess.run(['ansible-playbook','-i',str(work/'inventory.yml'),str(folder/'play.yml')],
                          text=True,capture_output=True,timeout=45,env=os.environ)
    (folder/'result.log').write_text(result.stdout+result.stderr)
    submitted=(folder/'request').exists()
    if (result.returncode==0)!=allowed or submitted!=allowed:
        raise AssertionError(name+': unexpected gate result\n'+result.stdout+result.stderr)
    if allowed:
        assert (folder/'dcs-count').read_text()=='3'
        assert (folder/'sql-count').read_text()=='3'
    print('PASS: '+name+' '+('submitted after eligibility' if allowed else 'rejected before request'))
PY
