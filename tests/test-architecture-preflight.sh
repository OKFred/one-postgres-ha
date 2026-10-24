#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# Run the production Ansible assertions with isolated host facts. No SSH,
# Docker, device access or service changes are needed for this gate.
python3 - "$ROOT" "$WORK" <<'PY'
import copy
import pathlib
import sys
import yaml

root, work = map(pathlib.Path, sys.argv[1:])
tasks = yaml.safe_load((root / 'ansible/roles/cluster/tasks/preflight.yml').read_text())
selected = [task for task in tasks if task['name'] == 'Require supported uniform node architecture']
assert len(selected) == 1
defaults = yaml.safe_load((root / 'ansible/roles/cluster/defaults/main.yml').read_text())
assert defaults['expected_architecture'] == 'aarch64'
fact_fixture = dict(name='Load isolated per-node architecture facts',
                    **{'ansible.builtin.set_fact': {'ansible_facts': '{{ fixture_facts }}'}})
play = [dict(name='Exercise the production architecture gate', hosts='pg_nodes',
             gather_facts=False, tasks=[fact_fixture] + selected)]
(work / 'play.yml').write_text(yaml.safe_dump(play))

cases = [
    ('arm64-production', 'aarch64', ['aarch64'] * 3, True),
    ('amd64-production', 'x86_64', ['x86_64'] * 3, True),
    ('arm64-default', defaults['expected_architecture'], ['aarch64'] * 3, True),
    ('amd64-with-replica', 'x86_64', ['x86_64'] * 4, True),
    ('mixed-nodes', 'aarch64', ['aarch64', 'x86_64', 'aarch64'], False),
    ('mismatched-expectation', 'aarch64', ['x86_64'] * 3, False),
    ('unsupported', 'riscv64', ['riscv64'] * 3, False),
    ('mixed-overrides', None, ['aarch64', 'x86_64', 'aarch64'], False),
    ('mixed-replica', 'x86_64', ['x86_64'] * 3 + ['aarch64'], False),
    ('missing-peer-fact', 'x86_64', ['x86_64', 'x86_64', None], False),
    ('test-mode-unsupported', 'riscv64', ['riscv64'] * 3, False),
]
for name, expected, facts, success in cases:
    hosts = {}
    for index, architecture in enumerate(facts, 1):
        host = dict(ansible_connection='local', fixture_facts={})
        if architecture is not None:
            host['fixture_facts']['architecture'] = architecture
        if expected is None:
            host['expected_architecture'] = architecture
        hosts[f'node{index}'] = host
    variables = dict(deployment_environment='test' if name.startswith('test-mode-') else 'production')
    if expected is not None:
        variables['expected_architecture'] = expected
    inventory = dict(all=dict(vars=variables, children=dict(pg_nodes=dict(hosts=hosts))))
    (work / f'{name}.yml').write_text(yaml.safe_dump(copy.deepcopy(inventory)))
    with (work / 'cases').open('a') as stream:
        stream.write(f'{name} {str(success).lower()}\n')
PY

while read -r name expected; do
  result=0
  ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" ansible-playbook \
    -i "$WORK/$name.yml" "$WORK/play.yml" >"$WORK/$name.log" 2>&1 || result=$?
  if [[ $expected == true ]]; then
    if [[ $result != 0 ]]; then
      cat "$WORK/$name.log" >&2
      printf 'Supported architecture was rejected: %s\n' "$name" >&2
      exit 1
    fi
  else
    if [[ $result == 0 ]]; then
      printf 'Invalid architecture was accepted: %s\n' "$name" >&2
      exit 1
    fi
    grep -Fq 'Require supported uniform node architecture' "$WORK/$name.log"
    grep -Fq 'fatal: [node' "$WORK/$name.log"
  fi
done <"$WORK/cases"
printf 'PASS: production architecture gate accepts homogeneous AMD64/ARM64 and rejects mixed, unknown or missing host facts (11 cases)\n'
