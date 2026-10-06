#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib, sys, yaml
root, work = map(pathlib.Path, sys.argv[1:])
tasks = yaml.safe_load((root/'ansible/roles/cluster/tasks/preflight.yml').read_text())
names = {'Check peer routes and chosen source addresses',
         'Require the advertised source address and interface for every peer',
         'Require core nodes on the same directly attached network'}
selected = [task for task in tasks if task.get('name') in names]
assert len(selected) == 3
assert list(map(str, selected[0]['ansible.builtin.command']['argv'])) == ['ip','-j','-4','route','get','{{ hostvars[item].node_ip }}']
join = yaml.safe_load((root/'ansible/add-node.yml').read_text())
assert any(task.get('ansible.builtin.import_playbook') == 'preflight.yml' for task in join)
fake = work/'ip'
fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
work = pathlib.Path(os.environ['ROUTE_FIXTURE_DIR'])
args = sys.argv[1:]
if len(args) != 5 or args[:4] != ['-j','-4','route','get']:
    raise SystemExit('Unexpected route invocation')
with (work/'queries').open('a') as output:
    output.write(args[-1]+'\\n')
scenario = json.loads((work/'scenario.json').read_text())
if scenario['mode'] == 'query_failed':
    raise SystemExit('Fixture route lookup failed')
route = {'dst':args[-1], 'dev':'eth0', 'prefsrc':scenario['ip']}
if scenario['mode'] == 'wrong_source': route['prefsrc'] = '192.0.2.99'
if scenario['mode'] == 'wrong_dev': route['dev'] = 'eth1'
if scenario['mode'] == 'missing_source': route.pop('prefsrc')
if scenario['mode'] == 'src_fallback': route['src'] = route.pop('prefsrc')
if scenario['mode'] == 'gateway': route['gateway'] = '192.0.2.1'
print(json.dumps([route]))
''')
fake.chmod(0o755)
selected[0]['ansible.builtin.command']['argv'][0] = str(fake)
selected[0]['environment'] = {'ROUTE_FIXTURE_DIR':'{{ route_fixture_dir }}'}
inventory = {'all': {'children': {'pg_nodes': {'children': {
    'core_nodes': {'hosts': {}}, 'replica_nodes': {'hosts': {}}}}}}}
import json
cases = []
for is_core, modes in [(True,['good','wrong_source','wrong_dev','missing_source','query_failed','gateway']),
                       (False,['good','src_fallback','gateway','wrong_source','wrong_dev'])]:
    for mode in modes:
        name = ('core_' if is_core else 'replica_') + mode
        directory = work/name
        directory.mkdir()
        node = 'core01' if is_core else 'replica04'
        ip = '192.0.2.11' if is_core else '192.0.2.14'
        (directory/'scenario.json').write_text(json.dumps({'mode':mode, 'ip':ip}))
        group = 'core_nodes' if is_core else 'replica_nodes'
        case_inventory = yaml.safe_load(yaml.safe_dump(inventory))
        nodes = case_inventory['all']['children']['pg_nodes']['children']
        for number in range(1,4):
            nodes['core_nodes']['hosts']['core0'+str(number)] = {'node_ip':'192.0.2.1'+str(number)}
        nodes[group]['hosts'][node] = dict(ansible_connection='local',
            ansible_python_interpreter='{{ ansible_playbook_python }}',
            node_ip=ip, network_interface='eth0', route_fixture_dir=str(directory))
        (directory/'inventory.yml').write_text(yaml.safe_dump(case_inventory))
        (directory/'play.yml').write_text(yaml.safe_dump([dict(
            name='Execute production peer route gates', hosts=node, gather_facts=False, tasks=selected)]))
        expected = mode in ['good','src_fallback'] or mode == 'gateway' and not is_core
        peers = ['192.0.2.12','192.0.2.13'] if is_core else ['192.0.2.11','192.0.2.12','192.0.2.13']
        (directory/'expected-peers').write_text('\n'.join(peers)+'\n')
        cases.append((name,expected))
(work/'cases').write_text(''.join(name+' '+str(int(expected))+'\n' for name,expected in cases))
PY
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg"
while read -r scenario expected; do
  actual=0
  ansible-playbook -i "$WORK/$scenario/inventory.yml" "$WORK/$scenario/play.yml" >"$WORK/$scenario/result.log" 2>&1 || actual=$?
  if [[ "$expected" == 1 && "$actual" != 0 || "$expected" == 0 && "$actual" == 0 ]]; then
    cat "$WORK/$scenario/result.log" >&2
    echo "Unexpected peer-route outcome: $scenario" >&2
    exit 1
  fi
  if [[ "$actual" != 0 ]]; then
    grep -Eq 'Peer routing must use|Core nodes must share|Fixture route lookup failed' "$WORK/$scenario/result.log"
  fi
  sort "$WORK/$scenario/queries" >"$WORK/$scenario/actual-peers"
  cmp "$WORK/$scenario/expected-peers" "$WORK/$scenario/actual-peers"
  printf 'PASS: peer-route gate %s\n' "$scenario"
done <"$WORK/cases"
