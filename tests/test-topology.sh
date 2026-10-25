#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# Execute production assertions and host selectors with local facts. These
# fixtures never call SSH, Docker, systemd, disks or a running PostgreSQL server.
python3 -B - "$ROOT" "$WORK" <<'PY'
import copy
import os
import pathlib
import subprocess
import sys

import jinja2
import yaml

root, work = map(pathlib.Path, sys.argv[1:])
defaults = yaml.safe_load((root / 'ansible/roles/cluster/defaults/main.yml').read_text())
deploy = yaml.safe_load((root / 'ansible/deploy.yml').read_text())
preflight = yaml.safe_load((root / 'ansible/roles/cluster/tasks/preflight.yml').read_text())
cleanup = yaml.safe_load((root / 'ansible/cleanup.yml').read_text())

def named(items, name):
    matches = [item for item in items if item.get('name') == name]
    assert len(matches) == 1, name
    return copy.deepcopy(matches[0])

def inventory(total, core_indices, **variables):
    hosts = {}
    for index in range(1, total + 1):
        name = f'node{index:02d}'
        hosts[name] = dict(ansible_connection='local', node_name=name,
                           node_ip=f'192.0.2.{index}', network_interface='eth0')
    core = [f'node{index:02d}' for index in core_indices]
    return dict(all=dict(vars={**defaults, 'cluster_name': 'topology-fixture',
                              'data_mount': '/mnt/fixture', 'data_root': '/mnt/fixture/pg',
                              'vip_address': '192.0.2.250', 'vip_prefix': 24,
                              'vip_router_id': 51, 'vip_reserved': True,
                              'admin_cidrs': ['192.0.2.0/24'], 'client_cidrs': ['192.0.2.0/24'],
                              **variables}, children=dict(pg_nodes=dict(hosts=hosts),
                              core_nodes=dict(hosts={name: {} for name in core}),
                              replica_nodes=dict(hosts={name: {} for name in hosts if name not in core}))))

def execute(name, private_inventory, plays, success=True, message=None):
    directory = work / name
    directory.mkdir()
    (directory / 'inventory.yml').write_text(yaml.safe_dump(private_inventory, sort_keys=False))
    (directory / 'play.yml').write_text(yaml.safe_dump(plays, sort_keys=False))
    result = subprocess.run(['ansible-playbook', '-i', str(directory / 'inventory.yml'),
                             str(directory / 'play.yml')], text=True, capture_output=True,
                            env={**os.environ, 'ANSIBLE_CONFIG': str(root / 'ansible/ansible.cfg')})
    (directory / 'result.log').write_text(result.stdout + result.stderr)
    if (result.returncode == 0) != success or (message and message not in result.stdout):
        raise AssertionError(f'{name}: unexpected production gate result\n{result.stdout}\n{result.stderr}')

gates = [named(preflight, 'Validate inventory invariants'),
         named(cleanup[0]['tasks'], 'Require the full cluster inventory and an explicit cleanup mode')]
cases = [(3, False, True), (5, False, True), (7, False, True),
         (4, False, False), (4, True, True), (6, False, False), (6, True, True),
         (8, False, False), (8, True, True), (2, True, False),
         (3, 'true', False), (8, 'true', False)]
for index, (count, confirmed, success) in enumerate(cases):
    tasks = [dict(name='Load isolated operating system facts', **{
        'ansible.builtin.set_fact': {'ansible_facts': {'system': 'Linux'}}})]
    for gate in gates:
        gate.update(ignore_errors=True, register='fixture_gate')
        tasks += [gate, dict(name='Check the production topology decision', **{
            'ansible.builtin.assert': {'that': f'fixture_gate is {"not failed" if success else "failed"}'}})]
    execute(f'cohort-{index}', inventory(count, range(1, count + 1),
                                      etcd_nonstandard_members_confirmed=confirmed),
            [dict(name='Exercise both production topology gates', hosts='pg_nodes',
                  gather_facts=False, tasks=tasks)])

early = named(deploy, 'Refuse unfinished joins and unsafe new members before changing any node')
core_prepare = named(deploy, 'Prepare the etcd and proxy cohort before inspecting DCS')
replica_prepare = named(deploy, 'Prepare approved replicas after the DCS initialization decision')
primary = named(deploy, 'Bootstrap exactly one PostgreSQL primary')
standbys = named(deploy, 'Build every initial standby after primary bootstrap')
dcs_index = next(index for index, play in enumerate(deploy) if play.get('vars', {}).get('cluster_action') == 'inspect-dcs')
assert deploy.index(core_prepare) < dcs_index < deploy.index(replica_prepare)
assert deploy.index(replica_prepare) < next(index for index, play in enumerate(deploy)
    if play.get('vars', {}).get('cluster_action') == 'inspect-retained')
assert deploy.index(primary) < deploy.index(standbys) and standbys['serial'] == 1
start_tasks = yaml.safe_load((root / 'ansible/roles/cluster/tasks/start-postgres.yml').read_text())
start_when = named(start_tasks, 'Start this initial PostgreSQL member')['when']
for name, count, cores, new_dcs, pg_data, markers, pending, success, message in [
    ('fresh-four', 4, [1, 2, 3], True, [], [], [], True, None),
    ('fresh-five', 5, [1, 2, 3], True, [], [], [], True, None),
    ('fresh-five-voters', 5, [1, 2, 3, 4, 5], True, [], [], [], True, None),
    ('fresh-subset', 7, [2, 4, 5, 6, 7], True, [], [], [], True, None),
    ('fresh-retry', 5, [1, 2, 3], True, [], [1, 2, 3], [], True, None),
    ('existing-new-replica', 4, [1, 2, 3], False, [1], [1, 2, 3], [], False,
     'An initialized cluster cannot enroll a fresh replica through deploy'),
    ('existing-empty-dcs', 4, [1, 2, 3], False, [], [1, 2, 3], [], False,
     'Deploy does not enroll new replicas into an initialized DCS'),
    ('existing-owned-replicas', 5, [1, 2, 3], False, [1, 2, 3, 4, 5], [1, 2, 3, 4, 5], [], True, None),
    ('pending-core', 4, [1, 2, 3], True, [], [], [1], False, 'A replica addition is pending'),
    ('pending-extra', 4, [1, 2, 3], True, [], [], [4], False, 'A replica addition is pending'),
]:
    private_inventory = inventory(count, cores)
    hosts = private_inventory['all']['children']['pg_nodes']['hosts']
    for index, host in enumerate(hosts.values(), 1):
        host.update(pg_ha_marker={'stat': {'exists': index in markers}},
                    pg_ha_pg_version_stat={'stat': {'exists': index in pg_data}},
                    pg_ha_pending_marker={'stat': {'exists': index in pending}})
    prepare_fact = dict(name='Record production preparation target', **{
        'ansible.builtin.set_fact': {'fixture_prepared': True}})
    start_fact = dict(name='Record production initial startup target', when=start_when, **{
        'ansible.builtin.set_fact': {'fixture_started': True}})
    plays = [early, dict(name=core_prepare['name'], hosts=core_prepare['hosts'], gather_facts=False,
                        tasks=[prepare_fact]),
             dict(name='Load authoritative DCS decision fixture', hosts='core_nodes[0]',
                  gather_facts=False, tasks=[dict(name='Set DCS fixture', **{
                      'ansible.builtin.set_fact': {'pg_ha_new_cluster': new_dcs}})]),
             dict(name=replica_prepare['name'], hosts=replica_prepare['hosts'], gather_facts=False,
                  pre_tasks=replica_prepare['pre_tasks'], tasks=[prepare_fact]),
             dict(name=primary['name'], hosts=primary['hosts'], gather_facts=False, tasks=[start_fact]),
             dict(name=standbys['name'], hosts=standbys['hosts'], serial=standbys['serial'],
                  gather_facts=False, tasks=[start_fact]),
             dict(name='Verify complete preparation and initial startup membership', hosts='pg_nodes',
                  gather_facts=False, tasks=[dict(name='Check member fixture', **{
                      'ansible.builtin.assert': {'that': ['fixture_prepared | default(false) | bool',
                           f'fixture_started | default(false) | bool == {str(new_dcs).lower()}']}})])]
    execute(name, private_inventory, plays, success, message)

environment = jinja2.Environment(undefined=jinja2.StrictUndefined)
environment.filters.update(bool=bool, ternary=lambda value, yes, no: yes if value else no)
templates = root / 'ansible/roles/cluster/templates'
for count, core_count in [(4, 3), (5, 3), (5, 5), (4, 4), (20, 7), (20, 20)]:
    private_inventory = inventory(count, range(1, core_count + 1))['all']
    hostvars = private_inventory['children']['pg_nodes']['hosts']
    groups = {name: list(group['hosts']) for name, group in private_inventory['children'].items()}
    for member in groups['pg_nodes']:
        variables = {**private_inventory['vars'], **hostvars[member], 'groups': groups,
                     'hostvars': hostvars, 'inventory_hostname': member}
        patroni = yaml.safe_load(environment.from_string((templates / 'patroni.yml.j2').read_text()).render(variables))
        bootstrap = patroni['bootstrap']['dcs']
        assert bootstrap['synchronous_mode_strict'] and bootstrap['synchronous_node_count'] == 1
        assert bootstrap['postgresql']['parameters']['max_wal_senders'] == max(16, count + 2)
        assert bootstrap['postgresql']['parameters']['max_replication_slots'] == max(16, count + 1)
        assert 'max_wal_senders' not in patroni['postgresql']['parameters']
        assert 'max_replication_slots' not in patroni['postgresql']['parameters']
        assert len(patroni['etcd3']['hosts']) == core_count
        assert not patroni['tags']['nofailover'] and not patroni['tags']['nosync']
        haproxy = environment.from_string((templates / 'haproxy.cfg.j2').read_text()).render(variables)
        assert haproxy.count(' check port ') == count
        if member in groups['core_nodes']:
            etcd = yaml.safe_load(environment.from_string((templates / 'etcd.yml.j2').read_text()).render(variables))
            assert len(etcd['initial-cluster'].split(',')) == core_count
            keepalived = environment.from_string((templates / 'keepalived.conf.j2').read_text()).render(variables)
            priority = next(int(line.split()[1]) for line in keepalived.splitlines() if line.strip().startswith('priority '))
            assert 1 <= priority <= 255
print('PASS: production topology gates (12), initial deployment guards/selectors (10), and variable-cohort templates')
PY
