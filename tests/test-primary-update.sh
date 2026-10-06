#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
python3 - "$root" <<'PY'
import pathlib, sys, yaml
tasks = pathlib.Path(sys.argv[1])/'ansible/roles/cluster/tasks'
replica = yaml.safe_load((tasks/'update-replica.yml').read_text())[0]
assert 'pg_ha_pg_recreate' in replica['when']
assert any('pg_ha_leader_host' in item for item in replica['when'])
replica_up = next(task for task in replica['block'] if task['name']=='Reconcile the replica container')
primary = yaml.safe_load((tasks/'update-primary.yml').read_text())
include = next(task for task in primary if 'ansible.builtin.include_tasks' in task)
assert 'pg_ha_update_primary_needed' in include['when']
old = yaml.safe_load((tasks/'update-primary-after-switch.yml').read_text())
old_up = next(task for task in old if task['name']=='Reconcile the old primary only after demotion')
for command in [replica_up, old_up]:
    assert '--force-recreate' in command['ansible.builtin.command']['argv']
initial = yaml.safe_load((tasks/'start-postgres.yml').read_text())
assert all('--force-recreate' not in task.get('ansible.builtin.command',{}).get('argv',[]) for task in initial)
PY
cat >"$tmp/inventory.yml" <<'YAML'
all:
  hosts:
    localhost:
      ansible_connection: local
      ansible_python_interpreter: "{{ ansible_playbook_python }}"
      pg_ha_pg_recreate: false
YAML
cat >"$tmp/skip.yml" <<'YAML'
- name: Initial deployment skips old-primary delegates without invented host defaults
  hosts: localhost
  gather_facts: false
  vars:
    pg_ha_new_cluster: true
  tasks:
    - name: Exercise the actual primary update entry
      ansible.builtin.include_role:
        name: cluster
        tasks_from: update-primary
    - name: Confirm no primary reconciliation is needed
      ansible.builtin.assert:
        that:
          - not pg_ha_update_primary_needed
          - pg_ha_previous_leader_host is undefined
- name: Unchanged existing deployment also skips undefined previous leader
  hosts: localhost
  gather_facts: false
  vars:
    pg_ha_new_cluster: false
    pg_ha_leader_host: localhost
  tasks:
    - name: Exercise the actual primary update entry
      ansible.builtin.include_role:
        name: cluster
        tasks_from: update-primary
    - name: Confirm no switchover or old-primary delegation happened
      ansible.builtin.assert:
        that:
          - not pg_ha_update_primary_needed
          - pg_ha_previous_leader_host is undefined
YAML
ANSIBLE_CONFIG="$root/ansible/ansible.cfg" ansible-playbook -i "$tmp/inventory.yml" "$tmp/skip.yml"
echo 'PASS: initial and unchanged deployments skip undefined old-primary delegates'
