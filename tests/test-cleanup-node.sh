#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
import json, pathlib, shutil, stat, subprocess, sys, yaml
root,work=map(pathlib.Path,sys.argv[1:])
tools=work/'tools'
tools.mkdir()
stub=tools/'fixture-command'
stub.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys,time
root=pathlib.Path(os.environ['HA_CLEANUP_FIXTURE'])
statefile=root/'state.json'
state=json.loads(statefile.read_text())
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
def save(action):
    statefile.write_text(json.dumps(state))
    with (root/'actions').open('a') as log: log.write(action+'\\n')
    if os.environ.get('HA_CLEANUP_EVENTS'):
        with open(os.environ['HA_CLEANUP_EVENTS'],'a') as log:
            log.write(json.dumps([time.monotonic_ns(),root.name,action])+'\\n')
if name=='findmnt':
    assert args==['--json','--list','--output','TARGET,SOURCE,FSTYPE,OPTIONS']
    print(json.dumps({'filesystems':state['mounts']}))
elif name=='docker':
    if args==['info','--format','{{.DockerRootDir}}']: print('/unrelated-docker-storage')
    elif args==['ps','--all','--quiet','--no-trunc']: print('\\n'.join(obj['Id'] for obj in state['containers']))
    elif args[:2]==['image','inspect']: print(json.dumps({'/var/lib/postgresql':{}}))
    elif args[:2]==['volume','inspect']: print(json.dumps([state['volumes'][args[2]]]))
    elif args[0]=='inspect' and args[1]=='--format':
        obj=next(obj for obj in state['containers'] if obj['Id']==args[-1])
        if args[2]=='{{.State.Running}}': print(str(obj['State']['Running']).lower())
        elif args[2]=='{{.State.ExitCode}}': print(obj['State']['ExitCode'])
        else: raise SystemExit('unexpected inspect format')
    elif args[0]=='inspect': print(json.dumps([obj for obj in state['containers'] if obj['Id'] in args[1:]]))
    elif args[0] in ['update','stop','rm']:
        obj=next(obj for obj in state['containers'] if obj['Id']==args[-1])
        service=(obj.get('Config',{}).get('Labels') or {}).get('com.docker.compose.service','foreign')
        assert service!='foreign'
        if args[0]=='stop':
            obj['State']['Running']=False
            obj['State']['ExitCode']=137 if state.get('force_kill') and service=='postgres' else 0
        elif args[0]=='rm':
            assert not obj['State']['Running']
            state['containers'].remove(obj)
        save(args[0]+' '+service)
    else: raise SystemExit('unexpected docker command')
elif name=='systemctl':
    if args[:2]==['is-active','--quiet']: raise SystemExit(0 if state['active'].get(args[-1],False) else 3)
    elif args[:3]==['show','--property=DropInPaths','--value']:
        gate=root/'etc/systemd/system'/(args[-1]+'.d')/'30-one-postgres-ha-firewall.conf'
        print(state.get('dropins',str(gate) if gate.exists() else ''))
    elif args[:2]==['disable','--now']:
        if args[-1]=='one-postgres-ha-firewall.service':
            assert not any((root/'etc/systemd/system'/(unit+'.d')/'30-one-postgres-ha-firewall.conf').exists()
                           for unit in ['docker.service','keepalived.service'])
            if state.get('firewall_gates'):
                assert (root/'actions').read_text().splitlines()[-1]=='daemon-reload'
        state['active'][args[-1]]=False
        save('disable '+args[-1])
    elif args==['daemon-reload']: save('daemon-reload')
    else: raise SystemExit('unexpected systemctl command')
elif name in ['iptables','ip6tables']:
    assert args[:2]==['--wait','5']
    args=args[2:]
    rules=state['rules'][name]
    if args==['-S']: print('\\n'.join(rules))
    elif args==['-S','ONE_PG_HA']:
        raise SystemExit(0 if '-N ONE_PG_HA' in rules else 1)
    elif args[0] in ['-C','-D']:
        rule='-A '+' '.join(args[1:])
        rule=rule.replace('-p 112','-p vrrp')
        if rule not in rules: raise SystemExit(1)
        if args[0]=='-D': rules.remove(rule); save(name+' delete own jump')
    elif args==['-F','ONE_PG_HA']:
        state['rules'][name]=[rule for rule in rules if not rule.startswith('-A ONE_PG_HA ')]
        save(name+' flush own chain')
    elif args==['-X','ONE_PG_HA']:
        assert not any(rule.endswith('-j ONE_PG_HA') for rule in rules)
        rules.remove('-N ONE_PG_HA'); save(name+' remove own chain')
    else: raise SystemExit('unexpected firewall command')
elif name=='udevadm':
    assert args==['control','--reload']; save('udev reload')
else: raise SystemExit('unexpected fixture command')
''')
stub.chmod(0o755)
for name in ['docker','findmnt','systemctl','iptables','ip6tables','udevadm']: (tools/name).symlink_to(stub)
cases=['good','bad_marker','linked_root','nested_mount','foreign_bind','foreign_alias','foreign_root','foreign_volume','extra_volume',
       'duplicate_bind','bad_permissions','bad_udev','wrong_watchdog','short_identity','forced_stop','image_volume','partial_missing','empty',
       'core01','core02','core03','legacy','bad_firewall_unit','bad_dependency','linked_dependency','linked_dependency_directory']
for case in cases:
    scenario=work/case
    scenario.mkdir()
    deployment=scenario/'deployment'
    mount=scenario/'ssd'
    data=mount/'cluster'
    system=scenario/'etc'
    node=case if case in ['core01','core02','core03'] else 'core01'
    if case=='short_identity': node='p1'
    node_ip='192.0.2.'+str(10+int(node[-1]))
    project='0_ha' if case=='short_identity' else 'one-postgres-ha'
    for directory in [deployment/'config',deployment/'secrets',deployment/'bin',deployment/'images',data/'postgres',data/'etcd',
                      system/'systemd/system',system/'keepalived',system/'udev/rules.d',scenario/'locks',scenario/'external']:
        directory.mkdir(parents=True,exist_ok=True)
    for marker in [deployment/'.one-postgres-ha-cluster',data/'.one-postgres-ha-cluster']:
        marker.write_text('cleanup-test\n'); marker.chmod(0o600)
    env={'COMPOSE_PROJECT_NAME':project,'COMPOSE_PROFILES':'core','NODE_NAME':node,'NODE_IP':node_ip,
         'CONFIG_DIR':str(deployment/'config'),'SECRETS_DIR':str(deployment/'secrets'),
         'PG_DATA_DIR':str(data/'postgres'),'ETCD_DATA_DIR':str(data/'etcd'),
         'WATCHDOG_DEVICE':str(scenario/'watchdog'),'WATCHDOG_GID':'999'}
    (deployment/'.env').write_text(''.join(key+'='+value+'\n' for key,value in env.items()))
    (deployment/'.env').chmod(0o600)
    (deployment/'docker-compose.yml').write_text('services: {}\n')
    (deployment/'config/patroni.yml').write_text('scope: cleanup-test\nname: '+node+'\n')
    (deployment/'config/etcd.yml').write_text('name: '+node+'\ninitial-cluster-token: cleanup-test\n')
    pg_version=data/'postgres/PG_VERSION'
    pg_version.write_text('18\n'); pg_version.chmod(0o600)
    subprocess.check_call(['chown','999:999',str(pg_version)])
    (scenario/'external/preserved').write_text('external data stays\n')
    (data/'postgres/external-link').symlink_to(scenario/'external')
    for directory in [mount/'docker',mount/'containerd',scenario/'.local']:
        directory.mkdir(); (directory/'preserved').write_text('not cleanup data\n')
    firewall=(root/'ansible/roles/cluster/templates/firewall.service.j2').read_text().replace('{{ deployment_root }}',str(deployment))
    (system/'systemd/system/one-postgres-ha-firewall.service').write_text(firewall)
    for service in ['docker.service','keepalived.service']:
        directory=system/'systemd/system'/(service+'.d')
        directory.mkdir()
        if case!='legacy':
            (directory/'30-one-postgres-ha-firewall.conf').write_text((root/'ansible/roles/cluster/templates/firewall-dependency.conf.j2').read_text())
    docker_dropins=system/'systemd/system/docker.service.d'
    (docker_dropins/'20-one-postgres-ha-ssd.conf').write_text('[Unit]\nRequiresMountsFor=/srv/ssd/docker\n')
    (docker_dropins/'unrelated.conf').write_text('[Service]\nNice=5\n')
    if case=='legacy':
        (system/'systemd/system/one-postgres-ha-firewall.service').write_text(firewall.replace('ExecReload='+str(deployment)+'/bin/firewall.sh\n',''))
    (deployment/'bin/firewall.sh').write_text('# Only the dedicated chains are replaced.\n')
    (system/'keepalived/keepalived.conf').write_text('# Managed by one-postgres-ha.\nglobal_defs {\n router_id '+node+'\n}\nvrrp_script ready {\n script "'+str(deployment)+'/bin/check-proxy.sh"\n}\nvrrp_instance POSTGRES_HA {\n}\n')
    (system/'udev/rules.d/70-one-postgres-ha-watchdog.rules').write_text('SUBSYSTEM=="watchdog", KERNEL=="watchdog*", GROUP="999", MODE="0660"\nSUBSYSTEM=="misc", KERNEL=="watchdog", GROUP="999", MODE="0660"\n')
    watchdog=scenario/'watchdog'
    subprocess.check_call(['mknod',str(watchdog),'c','240','0'])
    containers=[]
    for service,cid in [('postgres','a'*64),('etcd','b'*64),('haproxy','c'*64)]:
        sources={str(deployment/'config'):'/etc/one-postgres-ha'}
        if service!='haproxy': sources[str(deployment/'secrets')]='/run/secrets'
        if service=='postgres': sources[str(data/'postgres')]='/var/lib/postgresql/data'
        if service=='etcd': sources[str(data/'etcd')]='/etcd-data'
        labels={'com.docker.compose.project':project,'com.docker.compose.service':service,
                'com.docker.compose.project.working_dir':str(deployment),'com.docker.compose.project.config_files':str(deployment/'docker-compose.yml'),
                'com.docker.compose.oneoff':'False'}
        containers.append({'Id':cid,'Image':'fixture-image','Config':{'Labels':labels},'Mounts':[{'Type':'bind','Source':source,'Destination':target} for source,target in sources.items()],
                           'State':{'Running':True,'ExitCode':0}})
    foreign={'Id':'d'*64,'Config':{'Labels':{}},'Mounts':[],'State':{'Running':True,'ExitCode':0}}
    containers.append(foreign)
    jump='-A INPUT -p tcp -m multiport --dports 5432,5433,8008,2379,2380 -j ONE_PG_HA'
    rules=['-N ONE_PG_HA','-A OTHER -j ACCEPT',jump,'-A ONE_PG_HA -j DROP']
    state={'containers':containers,'volumes':{},'active':{'keepalived.service':True,'one-postgres-ha-firewall.service':True},'firewall_gates':case!='legacy',
           'mounts':[{'target':str(mount),'source':'/dev/fixture','fstype':'ext4','options':'rw'}],
           'rules':{'iptables':rules+['-A INPUT -p vrrp -j ONE_PG_HA'],'ip6tables':list(rules)}}
    if case=='bad_marker': (data/'.one-postgres-ha-cluster').write_text('different-cluster\n')
    if case=='linked_root': data.rename(mount/'original'); data.symlink_to(scenario/'external')
    if case=='nested_mount': state['mounts'].append({'target':str(data/'postgres/mount'),'source':'/dev/other','fstype':'ext4','options':'rw'})
    if case=='foreign_bind': foreign['Mounts']=[{'Type':'bind','Source':str(data),'Destination':'/foreign'}]
    if case=='foreign_root': foreign['Mounts']=[{'Type':'bind','Source':'/','Destination':'/foreign'}]
    if case=='foreign_alias':
        (scenario/'foreign-alias').symlink_to(data)
        foreign['Mounts']=[{'Type':'bind','Source':str(scenario/'foreign-alias'),'Destination':'/foreign'}]
    if case=='foreign_volume':
        foreign['Mounts']=[{'Type':'volume','Name':'external','Source':'/unrelated-docker-storage/volume','Destination':'/foreign'}]
        state['volumes']['external']={'Driver':'local','Options':{'type':'none','o':'bind','device':str(data)}}
    if case=='extra_volume': containers[0]['Mounts'].append({'Type':'volume','Name':'extra','Source':'/unrelated-docker-storage/extra','Destination':'/var/lib/postgresql/data/extra'})
    if case=='duplicate_bind': containers[0]['Mounts'].append(containers[0]['Mounts'][0].copy())
    if case=='bad_permissions': data.chmod(0o777)
    if case=='bad_udev': (system/'udev/rules.d/70-one-postgres-ha-watchdog.rules').write_text('unmanaged device rule\n')
    if case=='bad_firewall_unit': (system/'systemd/system/one-postgres-ha-firewall.service').write_text('[Service]\nExecStart=/bin/true\n')
    if case=='bad_dependency': (docker_dropins/'30-one-postgres-ha-firewall.conf').write_text('[Unit]\nRequires=foreign.service\n')
    if case=='linked_dependency':
        (docker_dropins/'30-one-postgres-ha-firewall.conf').unlink()
        (docker_dropins/'30-one-postgres-ha-firewall.conf').symlink_to(scenario/'external/preserved')
    if case=='linked_dependency_directory':
        shutil.rmtree(docker_dropins)
        docker_dropins.symlink_to(scenario/'external')
    if case=='wrong_watchdog': (deployment/'.env').write_text((deployment/'.env').read_text().replace('WATCHDOG_GID=999','WATCHDOG_GID=1234'))
    if case=='forced_stop': state['force_kill']=True
    if case=='image_volume':
        name='e'*64
        containers[0]['Mounts'].append({'Type':'volume','Name':name,'Source':'/unrelated-docker-storage/anonymous','Destination':'/var/lib/postgresql'})
        state['volumes'][name]={'Driver':'local','Options':None}
    if case=='partial_missing': shutil.rmtree(deployment)
    if case=='empty':
        shutil.rmtree(deployment); shutil.rmtree(data)
        shutil.rmtree(system); system.mkdir()
        state['containers']=[foreign]; state['active']={}; state['rules']={'iptables':['-A OTHER -j ACCEPT'],'ip6tables':[]}
    (scenario/'state.json').write_text(json.dumps(state))
    script=(root/'scripts/cleanup-node.sh').read_text()
    assert script.count('SYSTEM_ROOT=/etc')==1 and script.count('LOCK_ROOT=/run/lock')==1
    script=script.replace('SYSTEM_ROOT=/etc','SYSTEM_ROOT='+str(system)).replace('LOCK_ROOT=/run/lock','LOCK_ROOT='+str(scenario/'locks'))
    (scenario/'cleanup.sh').write_text(script)
    argv=['--deployment-root',str(deployment),'--data-root',str(data),'--data-mount',str(mount),'--cluster-name','cleanup-test',
          '--node-name',node,'--node-ip',node_ip,'--compose-project',project,'--core','--watchdog-device',str(watchdog)]
    (scenario/'argv.json').write_text(json.dumps(argv))
(work/'cases').write_text('\n'.join(cases)+'\n')
PY
export PATH="$WORK/tools:$PATH"
run_case() {
  local case=$1 phase=$2
  shift 2
  HA_CLEANUP_FIXTURE="$WORK/$case" python3 - "$WORK/$case" "$phase" "$@" <<'PY'
import json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
raise SystemExit(subprocess.call(['bash',str(root/'cleanup.sh'),sys.argv[2],*json.loads((root/'argv.json').read_text()),*sys.argv[3:]]))
PY
}
for case in bad_marker linked_root nested_mount foreign_bind foreign_alias foreign_root foreign_volume extra_volume duplicate_bind bad_permissions bad_udev wrong_watchdog partial_missing bad_firewall_unit bad_dependency linked_dependency linked_dependency_directory; do
  if run_case "$case" audit >"$WORK/$case/result.log" 2>&1; then
    echo "Unsafe cleanup audit accepted: $case" >&2
    exit 1
  fi
  grep -q 'audit refused' "$WORK/$case/result.log"
  [[ ! -e "$WORK/$case/actions" ]]
  printf 'PASS: cleanup rejects %s before mutation\n' "$case"
done
for case in good image_volume short_identity legacy empty; do
  run_case "$case" audit >"$WORK/$case/preview.json"
  [[ ! -e "$WORK/$case/actions" ]]
  if run_case "$case" remove >"$WORK/$case/missing-apply.log" 2>&1; then
    echo 'Cleanup ran without explicit --apply' >&2
    exit 1
  fi
  [[ ! -e "$WORK/$case/actions" ]]
  for phase in stop-ingress stop-postgres stop-etcd remove; do run_case "$case" "$phase" --apply >/dev/null; done
  [[ ! -e "$WORK/$case/deployment" && ! -e "$WORK/$case/ssd/cluster" ]]
  [[ -f "$WORK/$case/external/preserved" && -f "$WORK/$case/.local/preserved" ]]
  [[ -f "$WORK/$case/ssd/docker/preserved" && -f "$WORK/$case/ssd/containerd/preserved" ]]
  run_case "$case" audit >/dev/null
  run_case "$case" remove --apply >/dev/null
  python3 - "$WORK/$case" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
state=json.loads((root/'state.json').read_text())
assert len(state['containers'])==1 and state['containers'][0]['Id']=='d'*64
assert state['containers'][0]['State']['Running']
assert '-A OTHER -j ACCEPT' in state['rules']['iptables']
assert not (root/'etc/keepalived/keepalived.conf').exists()
assert not (root/'etc/udev/rules.d/70-one-postgres-ha-watchdog.rules').exists()
for service in ['docker.service','keepalived.service']:
    assert not (root/'etc/systemd/system'/(service+'.d')/'30-one-postgres-ha-firewall.conf').exists()
if root.name!='empty':
    assert (root/'etc/systemd/system/docker.service.d/20-one-postgres-ha-ssd.conf').read_text()=='[Unit]\nRequiresMountsFor=/srv/ssd/docker\n'
    assert (root/'etc/systemd/system/docker.service.d/unrelated.conf').read_text()=='[Service]\nNice=5\n'
PY
  printf 'PASS: cleanup %s deletes only owned data and is repeatable\n' "$case"
done
if run_case forced_stop stop-postgres --apply >"$WORK/forced_stop/stop.log" 2>&1; then
  echo 'Forced PostgreSQL kill was accepted' >&2
  exit 1
fi
grep -q 'SIGKILL' "$WORK/forced_stop/stop.log"
if run_case forced_stop stop-etcd --apply >"$WORK/forced_stop/etcd.log" 2>&1; then
  echo 'DCS stopped after forced PG kill' >&2
  exit 1
fi
[[ -f "$WORK/forced_stop/ssd/cluster/.one-postgres-ha-cluster" ]]
! grep -q 'stop etcd' "$WORK/forced_stop/actions"
printf 'PASS: SIGKILL blocks DCS shutdown and preserves data\n'

# Run the actual playbook with local host boundaries, real files and fake host tools.
# Only the fixture backend's /etc and lock roots and controller copy paths differ.
python3 - "$ROOT" "$WORK" <<'PY'
import copy,json,pathlib,sys,yaml
root,work=map(pathlib.Path,sys.argv[1:])
plays=yaml.safe_load((root/'ansible/cleanup.yml').read_text())
arguments=next(copy.deepcopy(task) for task in plays[0]['tasks'] if task['name']=='Build the fixed cleanup arguments from the private inventory')
fallback=next(copy.deepcopy(task) for task in plays[0]['tasks'] if task['name']=='Load fallback values without overriding private inventory')
fallback['ansible.builtin.include_vars']['file']=str(root/'ansible/roles/cluster/defaults/main.yml')
checks={'name':'Require inventory values to win and fallback values to stay available',
        'ansible.builtin.assert':{'that':[
            'ha_cleanup_arguments[1] == expected_deployment',
            'ha_cleanup_arguments[13] == expected_project',
            'ha_cleanup_arguments[15] == expected_watchdog',
            'ha_cleanup_arguments[17] | string == expected_gid | string']}}
defaults={'node_name':'defaults','node_ip':'192.0.2.20','data_mount':'/srv/fixture-ssd','data_root':'/srv/fixture-ssd/cluster',
          'expected_deployment':'/opt/one-postgres-ha','expected_project':'one-postgres-ha',
          'expected_watchdog':'/dev/watchdog','expected_gid':'999'}
custom=dict(defaults,node_name='custom',deployment_root='/srv/custom-ha',compose_project_name='custom-project',
            watchdog_device='/dev/custom-watchdog',watchdog_gid=1234,expected_deployment='/srv/custom-ha',
            expected_project='custom-project',expected_watchdog='/dev/custom-watchdog',expected_gid='1234')
all_vars={'ansible_connection':'local','ansible_python_interpreter':sys.executable,'cluster_name':'cleanup-test'}
inventory={'all':{'vars':all_vars,'children':{'core_nodes':{'hosts':{'defaults':defaults,'custom':custom}}}}}
(work/'precedence-inventory.yml').write_text(yaml.safe_dump(inventory))
(work/'precedence.yml').write_text(yaml.safe_dump([{'name':'Check cleanup inventory precedence','hosts':'core_nodes',
                                                  'gather_facts':False,'tasks':[fallback,arguments,checks]}]))
nodes={}
for index in range(1,4):
    node='core0'+str(index); fixture=work/node
    nodes[node]={'node_name':node,'node_ip':'192.0.2.'+str(10+index),'deployment_root':str(fixture/'deployment'),
                 'data_root':str(fixture/'ssd/cluster'),'data_mount':str(fixture/'ssd'),
                 'watchdog_device':str(fixture/'watchdog'),'fixture_root':str(fixture)}
inventory={'all':{'vars':dict(all_vars,project_root=str(root)),
                  'children':{'pg_nodes':{'children':{'core_nodes':{'hosts':nodes}}}}}}
(work/'cluster-inventory.yml').write_text(yaml.safe_dump(inventory))
for play in plays:
    play['environment']={'PATH':str(work/'tools')+':'+__import__('os').environ['PATH'],
                         'HA_CLEANUP_FIXTURE':'{{ fixture_root }}','HA_CLEANUP_EVENTS':str(work/'events.jsonl')}
    for task in play['tasks']:
        if 'ansible.builtin.include_vars' in task:
            task['ansible.builtin.include_vars']['file']=str(root/'ansible/roles/cluster/defaults/main.yml')
        if 'ansible.builtin.tempfile' in task:
            task['ansible.builtin.tempfile']['path']='{{ fixture_root }}/temps'
        if 'ansible.builtin.copy' in task:
            task['ansible.builtin.copy']['src']='{{ fixture_root }}/cleanup.sh'
for node in nodes:
    (work/node/'temps').mkdir()
(work/'cluster-cleanup.yml').write_text(yaml.safe_dump(plays))
PY
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg"
export ANSIBLE_HOME="$WORK/ansible-home"
export ANSIBLE_LOCAL_TEMP="$WORK/ansible-local"
export ANSIBLE_REMOTE_TEMP="$WORK/ansible-remote"
export ANSIBLE_SSH_CONTROL_PATH_DIR="$WORK/ansible-cp"
run_ansible() {
  local log=$1
  shift
  if ! ansible-playbook "$@" >"$WORK/$log.log" 2>&1; then
    tail -n 60 "$WORK/$log.log" >&2
    return 1
  fi
}
run_ansible precedence -i "$WORK/precedence-inventory.yml" "$WORK/precedence.yml"
printf 'PASS: actual Ansible preserves custom inventory and uses named fallback defaults\n'
printf 'different-cluster\n' >"$WORK/core03/ssd/cluster/.one-postgres-ha-cluster"
if ansible-playbook -i "$WORK/cluster-inventory.yml" "$WORK/cluster-cleanup.yml" -e ha_cleanup_apply=true >"$WORK/barrier.log" 2>&1; then
  echo 'Cluster cleanup continued despite one failed ownership audit' >&2
  exit 1
fi
grep -q 'audit refused' "$WORK/barrier.log"
for node in core01 core02 core03; do [[ ! -e "$WORK/$node/actions" ]]; done
[[ ! -e "$WORK/events.jsonl" ]]
printf 'PASS: one failed node audit blocks every node before ingress or data mutation\n'
printf 'cleanup-test\n' >"$WORK/core03/ssd/cluster/.one-postgres-ha-cluster"
if ansible-playbook -i "$WORK/cluster-inventory.yml" "$WORK/cluster-cleanup.yml" --limit core01 -e ha_cleanup_apply=true >"$WORK/limit.log" 2>&1; then
  echo 'Partial inventory cleanup was accepted' >&2
  exit 1
fi
grep -q 'Cleanup must audit every pg_nodes host' "$WORK/limit.log"
python3 - "$WORK" <<'PY'
import json,pathlib,sys
work=pathlib.Path(sys.argv[1])
baseline={node:sorted(path.name for path in (work/node/'temps').iterdir()) for node in ['core01','core02','core03']}
(work/'failed-audit-temps.json').write_text(json.dumps(baseline))
PY
run_ansible preview -i "$WORK/cluster-inventory.yml" "$WORK/cluster-cleanup.yml"
for node in core01 core02 core03; do
  [[ ! -e "$WORK/$node/actions" && -d "$WORK/$node/deployment" && -d "$WORK/$node/ssd/cluster" ]]
done
grep -q 'delete_paths' "$WORK/preview.log"
grep -q "$WORK/core01/deployment" "$WORK/preview.log"
printf 'PASS: actual cluster preview shows deletion paths and changes no service or data\n'
run_ansible apply -i "$WORK/cluster-inventory.yml" "$WORK/cluster-cleanup.yml" -e ha_cleanup_apply=true
python3 - "$WORK" <<'PY'
import json,pathlib,sys
work=pathlib.Path(sys.argv[1])
events=[json.loads(line) for line in (work/'events.jsonl').read_text().splitlines()]
baseline=json.loads((work/'failed-audit-temps.json').read_text())
ingress=[event[0] for event in events if event[2] in ['stop haproxy','disable keepalived.service']]
postgres=[event[0] for event in events if event[2]=='stop postgres']
etcd=[event[0] for event in events if event[2]=='stop etcd']
removals=[event[0] for event in events if event[2].startswith('rm ')]
assert len(ingress)==6 and len(postgres)==3 and len(etcd)==3 and len(removals)==9
assert max(ingress)<min(postgres) and max(postgres)<min(etcd) and max(etcd)<min(removals)
for node in ['core01','core02','core03']:
    fixture=work/node
    assert not (fixture/'deployment').exists() and not (fixture/'ssd/cluster').exists()
    assert (fixture/'external/preserved').is_file() and (fixture/'.local/preserved').is_file()
    assert (fixture/'ssd/docker/preserved').is_file() and (fixture/'ssd/containerd/preserved').is_file()
    assert sorted(path.name for path in (fixture/'temps').iterdir())==baseline[node]
PY
printf 'PASS: actual Ansible applies global ingress, PG, DCS and deletion barriers\n'
