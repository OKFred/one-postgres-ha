#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d /run/one-postgres-ha-firewall-test.XXXXXXXX)
trap 'rm -rf -- "$WORK"' EXIT

if [[ ${1:-} == --native ]]; then
  [[ $# == 1 && $(id -u) == 0 ]] || exit 2
  systemctl is-system-running --quiet
  PREFIX="one-pg-ha-firewall-test-$(date +%s)-$$"
  FIREWALL="$PREFIX-firewall.service"
  DOCKER="$PREFIX-docker.service"
  KEEPALIVED="$PREFIX-keepalived.service"
  UNIT_ROOT=/run/systemd/system
  cleanup_native() {
    local result=$?
    trap - EXIT
    systemctl stop "$DOCKER" "$KEEPALIVED" "$FIREWALL" >/dev/null 2>&1 || true
    rm -f -- "$UNIT_ROOT/$DOCKER" "$UNIT_ROOT/$KEEPALIVED" "$UNIT_ROOT/$FIREWALL"
    for service in "$DOCKER" "$KEEPALIVED"; do
      rm -f -- "$UNIT_ROOT/$service.d/30-one-postgres-ha-firewall.conf"
      rmdir -- "$UNIT_ROOT/$service.d" 2>/dev/null || true
    done
    systemctl daemon-reload
    systemctl reset-failed "$DOCKER" "$KEEPALIVED" "$FIREWALL" >/dev/null 2>&1 || true
    rm -rf -- "$WORK"
    exit "$result"
  }
  trap cleanup_native EXIT
  mkdir -p "$WORK/deploy/bin"
  cat >"$WORK/deploy/bin/firewall.sh" <<EOF
#!/bin/sh
test ! -e '$WORK/deny' || exit 1
printf 'applied\n' >>'$WORK/applications'
EOF
  chmod 0755 "$WORK/deploy/bin/firewall.sh"
  sed -e "s|{{ deployment_root }}|$WORK/deploy|g" \
    -e "s|docker.service keepalived.service|$DOCKER $KEEPALIVED|g" \
    "$ROOT/ansible/roles/cluster/templates/firewall.service.j2" >"$UNIT_ROOT/$FIREWALL"
  for service in "$DOCKER" "$KEEPALIVED"; do
    mkdir -p "$UNIT_ROOT/$service.d"
    sed "s|one-postgres-ha-firewall.service|$FIREWALL|g" \
      "$ROOT/ansible/roles/cluster/templates/firewall-dependency.conf.j2" \
      >"$UNIT_ROOT/$service.d/30-one-postgres-ha-firewall.conf"
    cat >"$UNIT_ROOT/$service" <<EOF
[Unit]
Description=Isolated firewall startup test
[Service]
Type=oneshot
ExecStart=/usr/bin/touch $WORK/$service-started
ExecStop=/usr/bin/touch $WORK/$service-stopped
RemainAfterExit=yes
EOF
  done
  systemctl daemon-reload
  touch "$WORK/deny"
  if systemctl start "$DOCKER" "$KEEPALIVED" >"$WORK/failure.log" 2>&1; then
    echo 'A dependent service started despite firewall failure' >&2
    exit 1
  fi
  for service in "$DOCKER" "$KEEPALIVED"; do
    if systemctl is-active --quiet "$service"; then
      echo 'A dependent service remained active after firewall failure' >&2
      exit 1
    fi
    [[ ! -e "$WORK/$service-started" ]]
  done
  rm -- "$WORK/deny"
  systemctl reset-failed "$FIREWALL"
  systemctl start "$DOCKER" "$KEEPALIVED"
  systemctl reload "$FIREWALL"
  for service in "$DOCKER" "$KEEPALIVED"; do
    systemctl is-active --quiet "$service"
    [[ -e "$WORK/$service-started" && ! -e "$WORK/$service-stopped" ]]
    rm -- "$UNIT_ROOT/$service.d/30-one-postgres-ha-firewall.conf"
  done
  [[ $(wc -l <"$WORK/applications") == 2 ]]
  systemctl daemon-reload
  systemctl stop "$FIREWALL"
  for service in "$DOCKER" "$KEEPALIVED"; do
    systemctl is-active --quiet "$service"
    [[ ! -e "$WORK/$service-stopped" ]]
  done
  rm -- "$UNIT_ROOT/$FIREWALL"
  systemctl daemon-reload
  systemctl stop "$DOCKER" "$KEEPALIVED"
  systemctl start "$DOCKER" "$KEEPALIVED"
  printf 'PASS: real systemd blocks dependent startup on firewall failure, reload keeps services active, and removing gates permits restart\n'
  exit 0
fi
[[ $# == 0 ]] || exit 2
TOOLS=$(mktemp -d /tmp/one-postgres-ha-firewall-tools.XXXXXXXX)
trap 'rm -rf -- "$WORK" "$TOOLS"' EXIT

python3 - "$ROOT" "$WORK" "$TOOLS" <<'PY'
import copy, json, pathlib, sys, yaml
root, work, tools = map(pathlib.Path, sys.argv[1:])
role = work/'roles/firewall_fixture'
(role/'tasks').mkdir(parents=True)
(role/'templates').symlink_to(root/'ansible/roles/cluster/templates')
tasks = yaml.safe_load((root/'ansible/roles/cluster/tasks/firewall.yml').read_text())
for task in tasks:
    for module in ['ansible.builtin.file', 'ansible.builtin.template']:
        if module in task:
            for key in ['path', 'dest']:
                if key in task[module]:
                    task[module][key] = task[module][key].replace('/etc/systemd/system', '{{ fixture_system }}/systemd/system')
    if task['name'] == 'Refuse replacement of unowned firewall units or dependency files':
        argv = task['ansible.builtin.command']['argv']
        argv[2] = argv[2].replace("root = pathlib.Path('/etc/systemd/system')", 'root = pathlib.Path(sys.argv[5])')
        argv.append('{{ fixture_system }}/systemd/system')
(role/'tasks/firewall.yml').write_text(yaml.safe_dump(tasks, sort_keys=False))
prepare = yaml.safe_load((root/'ansible/roles/cluster/tasks/prepare.yml').read_text())
selected = []
for task in prepare:
    if task['name'] == 'Read the installed Keepalived status and version without refreshing APT':
        task = copy.deepcopy(task)
        command = task['ansible.builtin.command']
        assert command['argv'] == ['dpkg-query', '--show', '--showformat=${db:Status-Status}\\n${Version}', 'keepalived']
        assert command['expand_argument_vars'] is False and task['check_mode'] is False
        command['argv'][0] = str(tools/'query-keepalived')
        selected.append(task)
    elif task['name'] == 'Install the pinned Keepalived package':
        task = copy.deepcopy(task)
        package = task.pop('ansible.builtin.apt')
        assert package['state'] == 'present' and package['update_cache'] is True
        task['ansible.builtin.command'] = dict(argv=[str(tools/'install-keepalived'),
            package['name'], str(package['policy_rc_d'])])
        task['changed_when'] = "pg_ha_keepalived_package.stdout == 'installed'"
        selected.append(task)
    elif task['name'] == 'Install and apply the firewall startup gate':
        selected.append(copy.deepcopy(task))
assert len(selected) == 3
(role/'tasks/prepare-core.yml').write_text(yaml.safe_dump(selected, sort_keys=False))
(role/'tasks/main.yml').write_text(yaml.safe_dump([
    dict(name='Exercise the actual preparation sequence for a core node',
         **{'ansible.builtin.include_tasks': 'prepare-core.yml'},
         when='fixture_prepare | default(false) and not fixture_firewall_only | default(false)'),
    dict(name='Exercise the standalone firewall tasks',
         **{'ansible.builtin.include_tasks': 'firewall.yml'},
         when='not fixture_prepare | default(false) or fixture_firewall_only | default(false)')], sort_keys=False))
query = tools/'query-keepalived'
query.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['HA_FIREWALL_FIXTURE'])
state = json.loads((root/'state.json').read_text())
assert sys.argv[1:] == ['--show', '--showformat=${db:Status-Status}\\\\n${Version}', 'keepalived']
with (root/'calls').open('a') as calls:
    calls.write('query keepalived\\n')
if state.get('query_failure'): raise SystemExit(2)
if not state['keepalived_installed']: raise SystemExit(1)
print(state.get('keepalived_status', 'installed'))
print(state.get('keepalived_version', '1:2.3.3-1'))
''')
query.chmod(0o755)
installer = tools/'install-keepalived'
installer.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['HA_FIREWALL_FIXTURE'])
statefile = root/'state.json'
state = json.loads(statefile.read_text())
assert sys.argv[1:] == ['keepalived=1:2.3.3-1', '101'], 'Package installation must suppress automatic startup'
changed = (not state['keepalived_installed'] or state.get('keepalived_status', 'installed') != 'installed'
           or state.get('keepalived_version', '1:2.3.3-1') != '1:2.3.3-1')
with (root/'calls').open('a') as calls:
    calls.write('package keepalived policy_rc_d=101 changed='+str(changed).lower()+'\\n')
state.update(keepalived_installed=True, keepalived_status='installed', keepalived_version='1:2.3.3-1')
statefile.write_text(json.dumps(state))
print('installed' if changed else 'present')
''')
installer.chmod(0o755)
stub = tools/'systemctl'
stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['HA_FIREWALL_FIXTURE'])
statefile = root/'state.json'
state = json.loads(statefile.read_text())
args = sys.argv[1:]
with (root/'calls').open('a') as calls:
    calls.write(' '.join(args)+'\\n')
if args == ['daemon-reload']:
    state['keepalived_loaded'] = state['keepalived_installed']
elif args[:1] == ['show'] and len(args) == 2:
    assert args[1] == 'one-postgres-ha-firewall'
    print('LoadState=loaded\\nActiveState='+('active' if state['active'] else 'inactive'))
elif args[:1] == ['is-enabled']:
    assert args[1] == 'one-postgres-ha-firewall'
    print('enabled' if state['enabled'] else 'disabled')
    raise SystemExit(0 if state['enabled'] else 1)
elif args[:1] == ['enable']:
    assert args[1] == 'one-postgres-ha-firewall'
    state['enabled'] = True
elif args[:1] in [['start'], ['reload']]:
    assert args[1] == 'one-postgres-ha-firewall'
    if state.get('fail_apply'):
        raise SystemExit('The fixture firewall failed to load')
    state['active'] = True
elif args[:3] == ['show', '--property=Requires', '--property=After']:
    service = args[3]
    assert service in ['docker.service', 'keepalived.service']
    gate = root/'etc/systemd/system'/(service+'.d')/'30-one-postgres-ha-firewall.conf'
    assert gate.exists()
    loaded = service != 'keepalived.service' or state['keepalived_loaded']
    print('Requires='+('one-postgres-ha-firewall.service' if loaded and not state.get('reset_dependencies') else ''))
    print('After='+('network-online.target one-postgres-ha-firewall.service' if loaded else ''))
else:
    raise SystemExit('Unexpected service command: '+' '.join(args))
statefile.write_text(json.dumps(state))
''')
stub.chmod(0o755)
cases = ['core', 'replica', 'legacy', 'bad_unit', 'bad_gate', 'linked_gate', 'linked_directory',
         'apply_failure', 'reset_dependencies', 'fresh_core', 'retry_core',
         'installed_core', 'different_version_core', 'unpacked_core', 'query_failure_core']
core_hosts, replica_hosts = {}, {}
dependency = (root/'ansible/roles/cluster/templates/firewall-dependency.conf.j2').read_text()
for index, name in enumerate(cases):
    scenario = work/name
    deployment = scenario/'deployment'
    system = scenario/'etc'
    for directory in [deployment/'bin', system/'systemd/system/docker.service.d']:
        directory.mkdir(parents=True)
    (system/'systemd/system/docker.service.d/20-one-postgres-ha-ssd.conf').write_text('[Unit]\nRequiresMountsFor=/srv/ssd/docker\n')
    (system/'systemd/system/docker.service.d/unrelated.conf').write_text('[Service]\nNice=5\n')
    unit = system/'systemd/system/one-postgres-ha-firewall.service'
    gate = system/'systemd/system/docker.service.d/30-one-postgres-ha-firewall.conf'
    if name == 'legacy':
        rendered = (root/'ansible/roles/cluster/templates/firewall.service.j2').read_text().replace('{{ deployment_root }}', str(deployment))
        unit.write_text(rendered.replace('ExecReload='+str(deployment)+'/bin/firewall.sh\n', ''))
    if name == 'bad_unit': unit.write_text('[Service]\nExecStart=/bin/true\n')
    if name == 'bad_gate': gate.write_text('[Unit]\nRequires=foreign.service\n')
    if name == 'linked_gate':
        (scenario/'foreign.conf').write_text(dependency)
        gate.symlink_to(scenario/'foreign.conf')
    if name == 'linked_directory':
        (scenario/'foreign').mkdir()
        (system/'systemd/system/keepalived.service.d').symlink_to(scenario/'foreign')
    (scenario/'state.json').write_text(json.dumps(dict(active=name == 'legacy', enabled=name == 'legacy',
        fail_apply=name == 'apply_failure', reset_dependencies=name == 'reset_dependencies',
        keepalived_installed=name != 'fresh_core', keepalived_loaded=name != 'fresh_core',
        keepalived_version='1:2.3.2-1' if name == 'different_version_core' else '1:2.3.3-1',
        keepalived_status='unpacked' if name == 'unpacked_core' else 'installed',
        query_failure=name == 'query_failure_core')))
    values = dict(ansible_connection='local', ansible_python_interpreter=sys.executable,
        deployment_root=str(deployment), fixture_system=str(system), fixture_dir=str(scenario), node_ip='192.0.2.'+str(index+10),
        fixture_prepare=name in ['fresh_core', 'retry_core', 'installed_core', 'different_version_core',
                                'unpacked_core', 'query_failure_core', 'replica'],
        keepalived_package_version='1:2.3.3-1')
    (replica_hosts if name == 'replica' else core_hosts)[name] = values
inventory = dict(all=dict(children=dict(core_nodes=dict(hosts=core_hosts),
    pg_nodes=dict(children=dict(core_nodes={}, replica_nodes=dict(hosts=replica_hosts))))))
(work/'inventory.yml').write_text(yaml.safe_dump(inventory))
play = dict(name='Exercise actual firewall startup gate tasks', hosts='all', gather_facts=False,
    environment=dict(PATH=str(tools)+':{{ lookup("ansible.builtin.env", "PATH") }}', HA_FIREWALL_FIXTURE='{{ fixture_dir }}'),
    vars=dict(admin_cidrs=['192.0.2.0/24'], client_cidrs=['198.51.100.0/24']), roles=['firewall_fixture'])
(work/'play.yml').write_text(yaml.safe_dump([play], sort_keys=False))
PY

run_case() {
  ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" ansible-playbook -i "$WORK/inventory.yml" "$WORK/play.yml" --limit "$1" "${@:2}"
}
for scenario in bad_unit bad_gate linked_gate linked_directory; do
  if run_case "$scenario" >"$WORK/$scenario/result.log" 2>&1; then
    echo "Unowned firewall configuration was accepted: $scenario" >&2
    exit 1
  fi
  grep -Eq 'unknown|linked' "$WORK/$scenario/result.log" || { cat "$WORK/$scenario/result.log" >&2; exit 1; }
  [[ ! -e "$WORK/$scenario/calls" && ! -e "$WORK/$scenario/deployment/bin/firewall.sh" ]]
done
if ! run_case retry_core -e '{"fixture_firewall_only":true}' >"$WORK/retry_core/partial.log"; then
  cat "$WORK/retry_core/partial.log" >&2
  exit 1
fi
python3 - "$WORK/retry_core" <<'PY'
import json, pathlib, sys
scenario = pathlib.Path(sys.argv[1])
statefile = scenario/'state.json'
state = json.loads(statefile.read_text())
state.update(keepalived_installed=False, keepalived_loaded=False)
statefile.write_text(json.dumps(state))
(scenario/'calls').write_text('')
PY
for scenario in core replica legacy fresh_core retry_core installed_core different_version_core unpacked_core; do
  if ! run_case "$scenario" >"$WORK/$scenario/result.log"; then cat "$WORK/$scenario/result.log" >&2; exit 1; fi
  if ! run_case "$scenario" >"$WORK/$scenario/repeat.log"; then cat "$WORK/$scenario/repeat.log" >&2; exit 1; fi
  grep -q 'changed=0' "$WORK/$scenario/repeat.log"
done
for scenario in apply_failure reset_dependencies query_failure_core; do
  if run_case "$scenario" >"$WORK/$scenario/result.log" 2>&1; then
    echo "A failed firewall gate was accepted: $scenario" >&2
    exit 1
  fi
done
python3 - "$WORK" <<'PY'
import pathlib, sys
work = pathlib.Path(sys.argv[1])
for name in ['core', 'replica', 'legacy', 'fresh_core', 'retry_core',
             'installed_core', 'different_version_core', 'unpacked_core']:
    scenario = work/name
    calls = (scenario/'calls').read_text().splitlines()
    action = 'reload' if name == 'legacy' else 'start'
    if name != 'retry_core':
        assert calls.index('daemon-reload') < calls.index(action+' one-postgres-ha-firewall')
    assert not any(line.startswith(('restart ', 'stop ')) for line in calls)
    assert calls.count(action+' one-postgres-ha-firewall') == (0 if name == 'retry_core' else 1)
    assert (scenario/'etc/systemd/system/docker.service.d/20-one-postgres-ha-ssd.conf').read_text() == '[Unit]\nRequiresMountsFor=/srv/ssd/docker\n'
    assert (scenario/'etc/systemd/system/docker.service.d/unrelated.conf').read_text() == '[Service]\nNice=5\n'
    assert (scenario/'etc/systemd/system/keepalived.service.d/30-one-postgres-ha-firewall.conf').exists() == (name != 'replica')
    if name in ['fresh_core', 'retry_core']:
        assert calls.index('package keepalived policy_rc_d=101 changed=true') < calls.index('daemon-reload')
        assert calls.count('daemon-reload') == 1, 'Repeated preparation must not reload unchanged service units'
        assert calls.count('query keepalived') == 2
        assert len([line for line in calls if line.startswith('package keepalived')]) == 1
    if name == 'installed_core':
        assert calls.count('query keepalived') == 2
        assert not any(line.startswith('package keepalived') for line in calls), 'An installed pin must not refresh APT'
    if name in ['different_version_core', 'unpacked_core']:
        assert calls.count('query keepalived') == 2
        assert len([line for line in calls if line.startswith('package keepalived')]) == 1
        assert calls.index('package keepalived policy_rc_d=101 changed=true') < calls.index('daemon-reload')
    if name == 'replica':
        assert not any(line.startswith(('query ', 'package ')) for line in calls)
assert (work/'query_failure_core/calls').read_text().splitlines() == ['query keepalived']
assert not (work/'query_failure_core/deployment/bin/firewall.sh').exists()
assert 'fixture firewall failed' in (work/'apply_failure/result.log').read_text()
assert 'does not require the startup firewall' in (work/'reset_dependencies/result.log').read_text()
PY
printf 'PASS: firewall gates preserve existing drop-ins, migrate legacy units without restart, reject unowned paths, and verify loaded dependencies\n'
printf 'PASS: fresh core preparation installs the stopped Keepalived unit before checking its gate; partial retries reload new units; repeated preparation avoids restarts\n'
printf 'PASS: the exact installed Keepalived pin avoids APT; missing, different and unpacked versions install; query errors fail closed and replicas skip package work\n'
