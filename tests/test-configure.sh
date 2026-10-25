#!/usr/bin/env bash
set -Eeuo pipefail
# These are offline SSH/wizard fixtures; live source probing is tested separately.
export HA_DOWNLOAD_SOURCE=official
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/host-key"

# These tools never open a network connection. Cryptographic fingerprint parsing
# still uses the real ssh-keygen against a valid key generated for this test.
cat >"$WORK/bin/ssh-keyscan" <<'MOCK'
#!/usr/bin/env python3
import ipaddress, json, os, pathlib, sys
host = next(value for value in sys.argv[1:] if value.startswith('192.0.2.'))
ipaddress.ip_address(host)
with open(os.environ['FIXTURE_CALLS'], 'a') as log:
    log.write(json.dumps({'tool': 'ssh-keyscan', 'argv': sys.argv[1:]}) + '\n')
if os.environ.get('FIXTURE_SCAN_FAIL') == host:
    sys.exit(1)
if os.environ.get('FIXTURE_SCAN_BAD') == host:
    print(host, 'ssh-ed25519', 'invalid-public-key')
    sys.exit(0)
key = pathlib.Path(os.environ['FIXTURE_HOST_KEY'] + '.pub').read_text().split()
print(host, key[0], key[1])
MOCK
cat >"$WORK/bin/ssh" <<'MOCK'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
host = next(value.rsplit('@', 1)[-1] for value in args
            if value.rsplit('@', 1)[-1].startswith('192.0.2.'))
helper = sys.stdin.read()
with open(os.environ['FIXTURE_CALLS'], 'a') as log:
    log.write(json.dumps({'tool': 'ssh', 'argv': args, 'helper': helper}) + '\n')
if os.environ.get('FIXTURE_SSH_FAIL') == host:
    sys.exit(255)
if os.environ.get('FIXTURE_PROBE_MODE') == 'malformed':
    print('unexpected login banner')
    sys.exit(0)
probe = dict(node_ip=host, architecture='aarch64', os_id='debian', os_like='',
             controller_ip='192.0.2.5', interface='eth0', prefix=24,
             network='192.0.2.0/24', keepalived_version='1:2.3.3-1',
             docker_compose=True, watchdog=True, systemd_watchdog_usec=0,
             deployment_exists=False, vip_in_use=False,
             mounts=[dict(target='/mnt/ssd', fstype='ext4', source='/dev/sda1',
                          rw=True, local=True, ssd=True,
                          available_bytes=50000000000, data_exists=False)])
mode = os.environ.get('FIXTURE_PROBE_MODE', '')
if mode == 'wrong-types':
    probe['mounts'] = [None]
elif mode == 'amd64':
    probe['architecture'] = 'x86_64'
elif mode == 'mixed-architecture' and host == '192.0.2.13':
    probe['architecture'] = 'x86_64'
elif mode == 'unknown-architecture':
    probe['architecture'] = 'riscv64'
elif mode == 'occupied-vip':
    probe['vip_in_use'] = True
elif mode == 'missing-watchdog':
    probe['watchdog'] = False
elif mode == 'readonly-mount':
    probe['mounts'][0]['rw'] = False
elif mode == 'existing-data':
    probe['mounts'][0]['data_exists'] = True
elif mode == 'insufficient-space':
    probe['mounts'][0]['available_bytes'] = 1000
elif mode == 'existing-deployment':
    probe['deployment_exists'] = True
elif mode == 'missing-compose':
    probe['docker_compose'] = False
elif mode == 'inconsistent-version' and host == '192.0.2.13':
    probe['keepalived_version'] = '1:2.2.8-1'
elif mode == 'different-controller' and host == '192.0.2.13':
    probe['controller_ip'] = '192.0.2.6'
elif host == '192.0.2.14':
    if mode == 'extra-mixed-architecture':
        probe['architecture'] = 'x86_64'
    elif mode == 'extra-unknown-architecture':
        probe['architecture'] = 'riscv64'
    elif mode == 'extra-missing-watchdog':
        probe['watchdog'] = False
    elif mode == 'extra-existing-data':
        probe['mounts'][0]['data_exists'] = True
print(json.dumps(probe))
MOCK
cat >"$WORK/bin/sshpass" <<'MOCK'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['FIXTURE_CALLS'], 'a') as log:
    log.write(json.dumps({'tool': 'sshpass', 'argv': args}) + '\n')
if args[0] == '-f':
    password = pathlib.Path(args[1]).read_text().rstrip('\n')
    command = args[2:]
elif args[0] == '-d':
    password = os.read(int(args[1]), 4096).decode().rstrip('\n')
    command = args[2:]
else:
    sys.exit('Fixture only accepts password files or descriptors')
if password != os.environ['FIXTURE_PASSWORD']:
    sys.exit('Fixture password mismatch (value withheld)')
os.execvp(command[0], command)
MOCK
chmod +x "$WORK/bin/"{ssh-keyscan,ssh,sshpass}
export PATH="$WORK/bin:$PATH" FIXTURE_HOST_KEY="$WORK/host-key"
export FIXTURE_PASSWORD='isolated fixture password'
case_number=0

new_case() {
  case_number=$((case_number + 1))
  CASE="$WORK/case-$case_number"
  PROJECT="$CASE/project"
  mkdir -p "$PROJECT/scripts" "$PROJECT/ansible"
  cp "$ROOT/scripts/"configure.{sh,py} "$PROJECT/scripts/"
  cp "$ROOT/ops.sh" "$PROJECT/"
  cp "$ROOT/ansible/inventory.example.yml" "$PROJECT/ansible/"
  export FIXTURE_CALLS="$CASE/calls.jsonl"
  : >"$FIXTURE_CALLS"
  unset FIXTURE_SCAN_FAIL FIXTURE_SCAN_BAD FIXTURE_SSH_FAIL FIXTURE_PROBE_MODE
  unset HA_CONFIGURE_KEY_PATH HA_CONFIGURE_KEY_HOST_PATH HA_CONFIGURE_TOOLS_IMAGE
  unset HA_INVENTORY HA_TOOLS_IMAGE HA_SSH_KEY
}

write_inputs() {
  local number count=${NODE_COUNT:-3}
  printf '%s\n' 192.0.2.11 "${NODE_TWO:-192.0.2.12}" 192.0.2.13 >"$CASE/input"
  if [[ ${OPTIONAL_NODE_INPUTS+x} ]]; then
    printf '%s' "$OPTIONAL_NODE_INPUTS" >>"$CASE/input"
  else
    for ((number=4; number<=count; number++)); do
      if ((number == 4)); then
        printf '%s\n' "${NODE_FOUR:-192.0.2.14}" >>"$CASE/input"
      else
        printf '192.0.2.%s\n' "$((number + 10))" >>"$CASE/input"
      fi
    done
    printf '\nyes\n' >>"$CASE/input"
  fi
  if [[ ${ETCD_INPUTS+x} ]]; then
    printf '%s' "$ETCD_INPUTS" >>"$CASE/input"
  else
    printf '%s\n' "${ETCD_SELECTION:-}" "${ETCD_CONFIRM:-}" >>"$CASE/input"
    if [[ ${FORCE_ETCD+x} ]]; then printf '%s\n' "$FORCE_ETCD" >>"$CASE/input"; fi
  fi
  printf '%s\n' "${VIP:-192.0.2.20}" '' "${TRUST:-VERIFY}" >>"$CASE/input"
  if [[ -z ${HA_CONFIGURE_KEY_PATH:-} ]]; then
    printf '%s\n' "$FIXTURE_PASSWORD" "${PASSWORD_CONFIRM:-$FIXTURE_PASSWORD}" >>"$CASE/input"
  fi
  printf '%s\n' "${SSD_PATH:-}" "${RESERVATION:-RESERVED}" "${CLIENT_CIDR:-}" \
    "${POSTGRES_IMAGE:-}" "${TOOLS_IMAGE:-}" "${SAVE:-SAVE}" >>"$CASE/input"
}

run_wizard() {
  bash "$PROJECT/scripts/configure.sh" <"$CASE/input" >"$CASE/output" 2>&1
}

expect_success() {
  run_wizard || { cat "$CASE/output" >&2; exit 1; }
}

assert_no_tool_call() {
  if grep -Fq "\"tool\": \"$1\"" "$FIXTURE_CALLS"; then
    printf 'Unexpected %s call before configuration was accepted\n' "$1" >&2
    exit 1
  fi
}

assert_membership() {
  python3 - "$PROJECT" "$FIXTURE_CALLS" "$CASE/output" "$FIXTURE_PASSWORD" "$1" "$2" "$3" <<'PY'
import json, pathlib, sys, yaml
root, calls, output = map(pathlib.Path, sys.argv[1:4])
password, count, core_indices, forced = sys.argv[4], int(sys.argv[5]), sys.argv[6], sys.argv[7] == 'true'
expected_core = {f'armbian-{int(index):02d}' for index in core_indices.split(',')}
expected_names = {f'armbian-{index:02d}' for index in range(1, count + 1)}
expected_ips = {f'192.0.2.{index + 10}' for index in range(1, count + 1)}
private = root / '.local'
inventory = yaml.safe_load((private / 'inventory.yml').read_text())
groups = inventory['all']['children']['pg_nodes']['children']
core, replicas = groups['core_nodes']['hosts'], groups['replica_nodes']['hosts'] or {}
assert set(core) == expected_core, (set(core), expected_core)
assert set(replicas) == expected_names - expected_core, (set(replicas), expected_names - expected_core)
assert not set(core) & set(replicas)
nodes = dict(core, **replicas)
assert len(nodes) == count
assert {node['node_ip'] for node in nodes.values()} == expected_ips
for index in range(1, count + 1):
    name = f'armbian-{index:02d}'
    assert nodes[name]['node_name'] == name
    assert nodes[name]['ansible_host'] == f'192.0.2.{index + 10}'
    assert nodes[name]['data_mount'] == '/mnt/ssd'
    assert nodes[name]['data_root'] == '/mnt/ssd/one-postgres-ha'
assert inventory['all']['vars'].get('etcd_nonstandard_members_confirmed', False) is forced
assert {line.split()[0] for line in (private / 'known_hosts').read_text().splitlines()} == expected_ips
records = [json.loads(line) for line in calls.read_text().splitlines()]
assert len([record for record in records if record['tool'] == 'ssh']) == count
assert len([record for record in records if record['tool'] == 'ssh-keyscan']) == count
assert output.read_text().count('SHA256:') == count
quorum = len(expected_core) // 2 + 1
assert f'Quorum -- 最少存活：{quorum}' in output.read_text()
assert f'Failure tolerance -- 可容忍成员故障：{len(expected_core) - quorum}' in output.read_text()
assert password not in output.read_text() and password not in calls.read_text()
assert not list(private.glob('configure.*'))
PY
}

expect_failure() {
  local result=0
  run_wizard || result=$?
  [[ $result == 2 ]] || {
    printf 'Expected configure exit 2, got %s\n' "$result" >&2
    cat "$CASE/output" >&2
    exit 1
  }
  for path in inventory.yml known_hosts controller.env secrets/ssh-password; do
    [[ ! -e "$PROJECT/.local/$path" ]] || {
      printf 'Failed configuration published %s\n' "$path" >&2
      exit 1
    }
  done
  python3 - "$PROJECT" "$FIXTURE_PASSWORD" "$CASE/output" "$FIXTURE_CALLS" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
password = sys.argv[2].encode()
for path in root.rglob('*'):
    if path.is_file():
        assert password not in path.read_bytes(), 'Failed configuration retained a password'
assert not list(root.glob('.local/configure.*')), 'Failed configuration retained staged inputs'
for name in sys.argv[3:]:
    assert password not in pathlib.Path(name).read_bytes(), 'A failure report leaked the password'
PY
}

new_case
TRUST=NO write_inputs
expect_failure
assert_no_tool_call ssh
assert_no_tool_call sshpass

# Bad addresses are rejected before host trust or SSH authentication.
for invalid in duplicate malformed vip-on-node; do
  new_case
  case "$invalid" in
    duplicate) NODE_TWO=192.0.2.11 write_inputs ;;
    malformed) NODE_TWO=999.0.2.12 write_inputs ;;
    vip-on-node) VIP=192.0.2.11 write_inputs ;;
  esac
  expect_failure
  [[ ! -s "$FIXTURE_CALLS" ]]
done

# Optional addresses obey the same validation and cannot collide with the VIP.
for invalid in duplicate-extra malformed-extra vip-on-extra; do
  new_case
  case "$invalid" in
    duplicate-extra) NODE_COUNT=4 NODE_FOUR=192.0.2.13 write_inputs ;;
    malformed-extra) NODE_COUNT=4 NODE_FOUR=999.0.2.14 write_inputs ;;
    vip-on-extra) NODE_COUNT=4 VIP=192.0.2.14 write_inputs ;;
  esac
  expect_failure
  [[ ! -s "$FIXTURE_CALLS" ]]
done

# Bad voter selections and incomplete override confirmation fail before SSH.
for selection in '1 2' '1 2 2' '1 2 6' '0 1 2' '1 two 3' '1;2;3'; do
  new_case
  NODE_COUNT=5 ETCD_SELECTION="$selection" write_inputs
  expect_failure
  [[ ! -s "$FIXTURE_CALLS" ]]
done
for token in '' FORCE force-etcd; do
  new_case
  NODE_COUNT=4 ETCD_SELECTION='1 2 3 4' FORCE_ETCD="$token" write_inputs
  expect_failure
  [[ ! -s "$FIXTURE_CALLS" ]]
done

new_case
export FIXTURE_SCAN_FAIL=192.0.2.12
write_inputs
expect_failure
assert_no_tool_call ssh

new_case
export FIXTURE_SCAN_BAD=192.0.2.12
write_inputs
expect_failure
assert_no_tool_call ssh

new_case
PASSWORD_CONFIRM='different fixture password' write_inputs
expect_failure
assert_no_tool_call ssh

new_case
export FIXTURE_SSH_FAIL=192.0.2.13
write_inputs
expect_failure

for failure in scan ssh; do
  new_case
  if [[ $failure == scan ]]; then
    export FIXTURE_SCAN_FAIL=192.0.2.14
  else
    export FIXTURE_SSH_FAIL=192.0.2.14
  fi
  NODE_COUNT=4 write_inputs
  expect_failure
done

# An incomplete or unsuitable inspection must never publish a deployable input.
for mode in malformed wrong-types mixed-architecture unknown-architecture occupied-vip missing-watchdog readonly-mount existing-data insufficient-space existing-deployment missing-compose inconsistent-version different-controller; do
  new_case
  export FIXTURE_PROBE_MODE="$mode"
  write_inputs
  expect_failure
  case "$mode" in
    mixed-architecture) grep -Fq 'mixed ARM64 and AMD64 clusters are unsupported' "$CASE/output" ;;
    unknown-architecture) grep -Fq 'Initial setup requires ARM64 (aarch64) or AMD64 (x86_64) nodes' "$CASE/output" ;;
  esac
done

for mode in extra-mixed-architecture extra-unknown-architecture extra-missing-watchdog extra-existing-data; do
  new_case
  export FIXTURE_PROBE_MODE="$mode"
  NODE_COUNT=4 write_inputs
  expect_failure
done

for rejection in unsafe-path reservation unsafe-client unsigned-image cancelled; do
  new_case
  case "$rejection" in
    unsafe-path) SSD_PATH=/mnt/ssd/../../etc write_inputs ;;
    reservation) RESERVATION=NO write_inputs ;;
    unsafe-client) CLIENT_CIDR=0.0.0.0/0 write_inputs ;;
    unsigned-image) POSTGRES_IMAGE=example.invalid/postgres:latest write_inputs ;;
    cancelled) SAVE=NO write_inputs ;;
  esac
  expect_failure
done

new_case
write_inputs
run_wizard || {
  cat "$CASE/output" >&2
  exit 1
}
python3 - "$PROJECT" "$FIXTURE_CALLS" "$CASE/output" "$FIXTURE_PASSWORD" <<'PY'
import json, pathlib, stat, sys, yaml
root, calls, output = map(pathlib.Path, sys.argv[1:4])
password = sys.argv[4]
private = root / '.local'
inventory = yaml.safe_load((private / 'inventory.yml').read_text())
variables = inventory['all']['vars']
nodes = inventory['all']['children']['pg_nodes']['children']['core_nodes']['hosts']
assert len(nodes) == 3
assert {item['node_ip'] for item in nodes.values()} == {'192.0.2.11', '192.0.2.12', '192.0.2.13'}
assert all(item['data_mount'] == '/mnt/ssd' and item['network_interface'] == 'eth0' for item in nodes.values())
assert all(item['data_root'] == '/mnt/ssd/one-postgres-ha' for item in nodes.values())
assert variables['ansible_user'] == 'root' and variables['ansible_become'] is False
assert variables['vip_address'] == '192.0.2.20' and variables['vip_reserved'] is True
assert variables['keepalived_package_version'] == '1:2.3.3-1'
assert variables['admin_cidrs'] == ['192.0.2.5/32']
assert variables['client_cidrs'] == ['192.0.2.0/24']
assert variables['postgres_image_mode'] == 'source'
assert variables['expected_architecture'] == 'aarch64'
assert 'Architecture: aarch64' in output.read_text()
assert variables['backup_target']['enabled'] is False
assert "private_dir + '/secrets/ssh-password'" in variables['ansible_password']
assert (private / 'secrets/ssh-password').read_text().rstrip('\n') == password
for name in ('inventory.yml', 'known_hosts', 'controller.env', 'secrets/ssh-password'):
    assert stat.S_IMODE((private / name).stat().st_mode) == 0o600, name
for path in (private, private / 'secrets'):
    assert stat.S_IMODE(path.stat().st_mode) == 0o700
known = (private / 'known_hosts').read_text().splitlines()
assert {line.split()[0] for line in known} == {'192.0.2.11', '192.0.2.12', '192.0.2.13'}
assert password not in output.read_text() and password not in calls.read_text()
assert output.read_text().count('SHA256:') == 3, 'Host fingerprints were not displayed'
records = [json.loads(line) for line in calls.read_text().splitlines()]
probes = [item for item in records if item['tool'] == 'ssh']
assert len(probes) == 3
for item in probes:
    args = item['argv']
    assert any('StrictHostKeyChecking=yes' in arg for arg in args)
    assert any('UserKnownHostsFile=' in arg for arg in args)
    assert '--probe' in ' '.join(args)
    assert password not in ' '.join(args) and password not in item['helper']
assert len(list((private / 'secrets').iterdir())) == 1, 'Wizard generated database credentials or certificates'
assert not list(private.glob('configure.*'))
PY
find "$PROJECT/.local" -type f -exec sha256sum {} + | sort >"$CASE/before"
: >"$FIXTURE_CALLS"
result=0
run_wizard || result=$?
[[ $result == 2 && ! -s "$FIXTURE_CALLS" ]]
find "$PROJECT/.local" -type f -exec sha256sum {} + | sort >"$CASE/after"
cmp "$CASE/before" "$CASE/after"

# A full AMD64 cluster is detected from the remote probes, including while the
# controller and fixture remain unchanged. No architecture prompt is needed.
new_case
export FIXTURE_PROBE_MODE=amd64
write_inputs
run_wizard || {
  cat "$CASE/output" >&2
  exit 1
}
python3 - "$PROJECT" "$CASE/output" <<'PY'
import pathlib, sys, yaml
private = pathlib.Path(sys.argv[1]) / '.local'
variables = yaml.safe_load((private / 'inventory.yml').read_text())['all']['vars']
assert variables['expected_architecture'] == 'x86_64'
assert variables['deployment_environment'] == 'production'
assert 'Architecture: x86_64' in pathlib.Path(sys.argv[2]).read_text()
assert (private / 'secrets/ssh-password').is_file()
assert not list(private.glob('configure.*'))
PY

# Adding replicas preserves the recommended odd voter count up to seven. Every
# address still receives the same trust check and read-only remote inspection.
for count in 4 5 6 8 10; do
  new_case
  NODE_COUNT="$count" VIP=192.0.2.200 write_inputs
  expect_success
  case "$count" in
    4) members=1,2,3 ;;
    5|6) members=1,2,3,4,5 ;;
    8|10) members=1,2,3,4,5,6,7 ;;
  esac
  assert_membership "$count" "$members" false
done

# Operators can choose a different three-node voting cohort. Commas, spaces and
# reordered input are normalized without dropping any PostgreSQL replicas.
new_case
NODE_COUNT=5 ETCD_SELECTION='05, 02, 03' write_inputs
expect_success
assert_membership 5 2,3,5 false

# An even cohort and a cohort larger than seven both require the exact override.
for count in 4 8; do
  new_case
  if [[ $count == 4 ]]; then members='1 2 3 4'; else members='1 2 3 4 5 6 7 8'; fi
  NODE_COUNT="$count" ETCD_SELECTION="$members" FORCE_ETCD=FORCE-ETCD write_inputs
  expect_success
  assert_membership "$count" "${members// /,}" true
done

# A blank optional address does not stop collection without explicit consent.
# Both 'no' and the blank/default response resume the very same node index.
for decline in no ''; do
  new_case
  printf -v optional '\n%s\n192.0.2.14\n\nyes\n' "$decline"
  OPTIONAL_NODE_INPUTS="$optional" write_inputs
  expect_success
  assert_membership 4 1,2,3 false
done

new_case
OPTIONAL_NODE_INPUTS=$'\ny\n' write_inputs
expect_success
assert_membership 3 1,2,3 false

# Declining the proposed membership returns to selection before host inspection.
new_case
NODE_COUNT=5 ETCD_INPUTS=$'\nno\n2,3,5\nyes\n' write_inputs
expect_success
assert_membership 5 2,3,5 false

# Reject linked private state without altering the directory it points to.
new_case
mkdir "$CASE/external"
printf 'unrelated private state\n' >"$CASE/external/marker"
ln -s "$CASE/external" "$PROJECT/.local"
write_inputs
expect_failure
[[ ! -s "$FIXTURE_CALLS" ]]
cmp "$CASE/external/marker" <(printf 'unrelated private state\n')

# Key authentication never creates a password file and retains the host-side path.
new_case
cp "$WORK/host-key" "$CASE/client-key"
export HA_CONFIGURE_KEY_PATH="$CASE/client-key" HA_CONFIGURE_KEY_HOST_PATH=/home/deploy/.ssh/fixture-key
export HA_CONFIGURE_TOOLS_IMAGE='example.invalid/tools@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
write_inputs
run_wizard || {
  cat "$CASE/output" >&2
  exit 1
}
python3 - "$PROJECT" "$FIXTURE_CALLS" <<'PY'
import json, pathlib, sys, yaml
private = pathlib.Path(sys.argv[1]) / '.local'
variables = yaml.safe_load((private / 'inventory.yml').read_text())['all']['vars']
assert not (private / 'secrets/ssh-password').exists()
assert 'ansible_password' not in variables
assert '/home/deploy/.ssh/fixture-key' in (private / 'controller.env').read_text()
assert not any(json.loads(line)['tool'] == 'sshpass' for line in pathlib.Path(sys.argv[2]).read_text().splitlines())
PY

# The public entry point requires a terminal rather than silently consuming
# piped credentials. Existing CLI fixture tests cover other operation routing.
new_case
if bash "$PROJECT/ops.sh" configure </dev/null >"$CASE/output" 2>&1; then
  echo 'Non-terminal configure was accepted' >&2
  exit 1
fi
[[ ! -s "$FIXTURE_CALLS" && ! -e "$PROJECT/.local/inventory.yml" ]]

# Exercise the public routing under a real pseudo-terminal. Docker is mocked,
# including the interactive child, so stdin cannot accidentally become /dev/null
# when ops.sh starts the controller client in the background.
cat >"$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 ${2:-}" in
  'image inspect') exit 0 ;;
  'container inspect') printf 'false\n'; exit 0 ;;
  'container ls') exit 0 ;;
esac
[[ $1 == run ]] || exit 0
[[ -t 0 && -t 1 ]] || { echo 'Interactive controller lost its terminal' >&2; exit 1; }
printf '%s\0' "$@" >"$FIXTURE_DOCKER_ARGS"
while (($#)); do
  if [[ $1 == --cidfile ]]; then printf '%064d' 1 >"$2"; break; fi
  shift
done
if flock -n "$FIXTURE_PROJECT/.local/operations.lock" true; then
  echo 'Configure did not hold the shared operations lock' >&2; exit 1
fi
IFS= read -rt 5 answer
[[ $answer == CONFIGURE-STDIN-FIXTURE ]] || exit 1
printf 'INTERACTIVE_INPUT_FORWARDED\n'
MOCK
chmod +x "$WORK/bin/docker"
export FIXTURE_DOCKER_ARGS="$CASE/docker-args" FIXTURE_PROJECT="$PROJECT"
printf 'CONFIGURE-STDIN-FIXTURE\n' | script -qec "bash $PROJECT/ops.sh configure" /dev/null >"$CASE/tty-output" 2>&1
grep -Fq INTERACTIVE_INPUT_FORWARDED "$CASE/tty-output"
python3 - "$FIXTURE_DOCKER_ARGS" "$PROJECT" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().decode().split('\0')[:-1]
assert '--interactive' in args and '--tty' in args
assert '--read-only' in args
assert args[-3:] == ['one-postgres-ha-tools:pg17.11', 'bash', 'scripts/configure.sh']
assert not any('dst=/inventory.yml' in arg for arg in args)
root = pathlib.Path(sys.argv[2])
assert not list(root.glob('.local/tool.*')), 'Finished controller retained its lifecycle directory'
assert not (root / '.local/inventory.yml').exists(), 'Routing created an inventory without running the wizard'
PY

echo 'PASS: configure optional nodes, recommended/forced etcd voters, ARM64/AMD64 detection, trust gating, atomic output, secret handling and no-overwrite'
