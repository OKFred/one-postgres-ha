#!/usr/bin/env python3
"""Occasional native acceptance helper; explicit mutations require --apply."""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
import urllib.request

STATE = Path('/run/one-postgres-ha-native')

def run(argv, check=True):
    result = subprocess.run(argv, text=True, capture_output=True, timeout=30)
    if check and result.returncode:
        raise RuntimeError('command failed: ' + ' '.join(argv[:3]))
    return result

def compose(args):
    return ['docker', 'compose', '--project-directory', args.deployment_root,
            '--env-file', args.deployment_root + '/.env']

def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()

def proc_identity(pid):
    base = Path('/proc') / str(pid)
    command = (base / 'cmdline').read_bytes()
    fields = (base / 'stat').read_text().rsplit(')', 1)[1].split()
    return {'pid': pid, 'boot_id': boot_id(), 'starttime': fields[19],
            'cmdline_sha256': hashlib.sha256(command).hexdigest(),
            'is_patroni': b'/opt/patroni/bin/patroni' in command,
            'cgroup': (base / 'cgroup').read_text()}

def watchdog_fds(pid, device):
    matches = []
    for fd in (Path('/proc') / str(pid) / 'fd').iterdir():
        try:
            item = fd.stat()
        except (OSError, FileNotFoundError):
            continue
        if stat.S_ISCHR(item.st_mode) and item.st_rdev == device.st_rdev:
            matches.append(int(fd.name))
    return matches

def inspect_owner(args):
    device = Path(args.watchdog_device).stat()
    if not stat.S_ISCHR(device.st_mode):
        raise RuntimeError('watchdog is not a character device')
    container_ids = run(compose(args) + ['ps', '--quiet', 'postgres']).stdout.split()
    if len(container_ids) != 1:
        raise RuntimeError('expected exactly one PostgreSQL container')
    container = run(['docker', 'inspect', '--format', '{{.Id}}', container_ids[0]]).stdout.strip()
    owners = []
    for candidate in Path('/proc').iterdir():
        if not candidate.name.isdigit() or int(candidate.name) <= 1:
            continue
        try:
            identity = proc_identity(int(candidate.name))
            if not identity['is_patroni'] or container not in identity['cgroup']:
                continue
            fds = watchdog_fds(identity['pid'], device)
            if fds:
                identity.pop('cgroup')
                identity.update(container_id=container, watchdog_fds=fds,
                    watchdog_major=os.major(device.st_rdev), watchdog_minor=os.minor(device.st_rdev),
                    captured_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
                owners.append(identity)
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    if len(owners) != 1:
        raise RuntimeError('expected exactly one Patroni watchdog FD owner')
    return owners[0]

def require_apply(args):
    if not args.apply or os.geteuid() != 0:
        raise RuntimeError('mutation requires root and --apply')
    marker = Path(args.deployment_root) / '.one-postgres-ha-cluster'
    if not marker.is_file() or marker.read_text().strip() != args.cluster_name:
        raise RuntimeError('deployment ownership marker does not match')

def write_proof(args):
    require_apply(args)
    proof = inspect_owner(args)
    path = Path(args.proof)
    if path.exists():
        raise RuntimeError('refusing to overwrite an existing proof')
    with path.open('x') as handle:
        os.chmod(path, 0o600)
        json.dump(proof, handle)
    return proof

def matching_owner(args, proof):
    if boot_id() != proof['boot_id']:
        return False, 'new_boot_no_signal'
    try:
        current = inspect_owner(args)
    except (OSError, RuntimeError):
        return False, 'owner_missing_no_signal'
    keys = ['pid', 'boot_id', 'starttime', 'cmdline_sha256', 'container_id']
    return all(current[key] == proof[key] for key in keys), 'owner_changed_no_signal'

def watchdog_signal(args, stopping):
    require_apply(args)
    proof = json.loads(Path(args.proof).read_text())
    matches, reason = matching_owner(args, proof)
    if not matches:
        if stopping:
            raise RuntimeError(reason)
        return {'status': reason, 'signal_sent': False}
    pid_fd = os.pidfd_open(int(proof['pid']))
    try:
        if stopping:
            with urllib.request.urlopen('http://127.0.0.1:8008/primary', timeout=5) as response:
                if response.status != 200:
                    raise RuntimeError('the watchdog fault target is not the current primary')
            unit = 'pg-native-watchdog-' + args.run_id
            recovery = ['/usr/bin/python3', str(Path(__file__).resolve()), 'resume',
                '--deployment-root', args.deployment_root, '--cluster-name', args.cluster_name,
                '--watchdog-device', args.watchdog_device, '--proof', args.proof,
                '--run-id', args.run_id, '--apply']
            run(['systemd-run', '--unit=' + unit, '--on-active=90s', '--collect'] + recovery)
            run(['systemctl', 'is-active', '--quiet', unit + '.timer'])
        matches, reason = matching_owner(args, proof)
        if not matches:
            if stopping:
                raise RuntimeError(reason)
            return {'status': reason, 'signal_sent': False}
        signal.pidfd_send_signal(pid_fd, signal.SIGSTOP if stopping else signal.SIGCONT)
    finally:
        os.close(pid_fd)
    return {'status': 'paused' if stopping else 'resumed', 'pid': proof['pid'],
            'boot_id': proof['boot_id'], 'signal_sent': True,
            'controller_observed_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}

def dcs_cleanup(args):
    require_apply(args)
    path = STATE / (args.chain + '.json')
    if not path.exists():
        return {'status': 'no_owned_partition_record'}
    proof = json.loads(path.read_text())
    if proof.get('chain') != args.chain or proof.get('cluster') != args.cluster_name:
        raise RuntimeError('partition ownership record differs')
    jump = ['OUTPUT', '-p', 'tcp', '--dport', '2379', '-j', args.chain]
    for attempt in range(8):
        check = run(['iptables', '-w', '5', '-C'] + jump, check=False).returncode
        if check not in [0, 1]:
            raise RuntimeError('cannot inspect partition jump; record retained')
        if check == 1:
            break
        run(['iptables', '-w', '5', '-D'] + jump)
    else:
        raise RuntimeError('unexpected duplicate partition jumps; record retained')
    check = run(['iptables', '-w', '5', '-S', args.chain], check=False).returncode
    if check not in [0, 1]:
        raise RuntimeError('cannot inspect partition chain; record retained')
    if check == 0:
        run(['iptables', '-w', '5', '-F', args.chain])
        run(['iptables', '-w', '5', '-X', args.chain])
    path.unlink()
    return {'status': 'owned_dcs_client_rules_removed', 'chain': args.chain}

def dcs_isolate(args):
    require_apply(args)
    core_addresses = [ipaddress.IPv4Address(ip) for ip in args.addresses]
    if (len(set(core_addresses)) < 3 or len(set(core_addresses)) != len(core_addresses)
            or any(ip.is_loopback or ip.is_unspecified or ip.is_multicast for ip in core_addresses)):
        raise RuntimeError('provide at least three distinct non-loopback core IPv4 addresses')
    addresses = sorted({str(ip) for ip in core_addresses} | {'127.0.0.1'})
    chain_check = run(['iptables', '-w', '5', '-S', args.chain], check=False).returncode
    if chain_check not in [0, 1]:
        raise RuntimeError('cannot inspect partition chain; no rules changed')
    if chain_check == 0:
        raise RuntimeError('refusing to reuse an existing chain')
    STATE.mkdir(mode=0o700, exist_ok=True)
    record = STATE / (args.chain + '.json')
    with record.open('x') as handle:
        os.chmod(record, 0o600)
        json.dump({'chain': args.chain, 'cluster': args.cluster_name, 'addresses': addresses}, handle)
    unit = 'pg-native-dcs-' + args.run_id
    recovery = ['/usr/bin/python3', str(Path(__file__).resolve()), 'dcs-cleanup',
        '--deployment-root', args.deployment_root, '--cluster-name', args.cluster_name,
        '--chain', args.chain, '--run-id', args.run_id, '--apply']
    try:
        run(['systemd-run', '--unit=' + unit, '--on-active=90s', '--collect'] + recovery)
        run(['systemctl', 'is-active', '--quiet', unit + '.timer'])
        run(['iptables', '-w', '5', '-N', args.chain])
        for address in addresses:
            run(['iptables', '-w', '5', '-A', args.chain, '-d', address + '/32',
                 '-p', 'tcp', '--dport', '2379', '-j', 'REJECT', '--reject-with', 'tcp-reset'])
        run(['iptables', '-w', '5', '-I', 'OUTPUT', '1', '-p', 'tcp', '--dport', '2379', '-j', args.chain])
    except Exception:
        dcs_cleanup(args)
        raise
    return {'status': 'dcs_client_egress_isolated', 'chain': args.chain,
            'cleanup_timer': unit + '.timer', 'scope': 'core+loopback TCP2379 only'}

def snapshot(args):
    data = {'boot_id': boot_id(), 'utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'loadavg': Path('/proc/loadavg').read_text().strip(),
            'meminfo': {key: value.strip() for key, value in
                (line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
                if key in ['MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree']}}
    data['ssd_mount'] = json.loads(run(['findmnt', '-J', '--mountpoint', args.data_mount]).stdout)
    data['docker_root'] = run(['docker', 'info', '--format', '{{.DockerRootDir}}']).stdout.strip()
    data['mount_dependencies'] = run(['systemctl', 'show', 'docker.service', 'containerd.service',
        '--property=RequiresMountsFor', '--property=ActiveEnterTimestampMonotonic']).stdout.strip()
    unit = run(['systemd-escape', '-p', '--suffix=mount', args.data_mount]).stdout.strip()
    data['mount_activation'] = run(['systemctl', 'show', unit, '--property=ActiveEnterTimestampMonotonic']).stdout.strip()
    ids = run(compose(args) + ['ps', '--quiet']).stdout.split()
    data['containers'] = [json.loads(line) for line in run(['docker', 'stats', '--no-stream',
        '--format', '{{json .}}'] + ids).stdout.splitlines()] if ids else []
    with urllib.request.urlopen('http://127.0.0.1:8008/patroni', timeout=5) as response:
        data['patroni'] = json.load(response)
    if data['patroni'].get('role') in ['primary', 'master']:
        data['watchdog_owner'] = inspect_owner(args)
    else:
        data['watchdog_owner'] = {'status': 'not_armed_on_replica'}
    return data

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['snapshot', 'owner', 'proof', 'pause', 'resume', 'dcs-isolate', 'dcs-cleanup'])
    parser.add_argument('--deployment-root', default='/opt/one-postgres-ha')
    parser.add_argument('--cluster-name', default='one-postgres-ha')
    parser.add_argument('--watchdog-device', default='/dev/watchdog')
    parser.add_argument('--data-mount')
    parser.add_argument('--proof', default='/run/one-postgres-ha-native-watchdog.json')
    parser.add_argument('--run-id', default='')
    parser.add_argument('--chain', default='')
    parser.add_argument('--addresses', nargs='*', default=[])
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.action == 'snapshot' and not args.data_mount:
        parser.error('snapshot requires --data-mount from the private inventory')
    if args.apply and not re.fullmatch('[a-f0-9]{12}', args.run_id):
        parser.error('mutations require a unique 12-hex run-id')
    if args.action.startswith('dcs-') and not re.fullmatch('PGN_[a-f0-9]{12}', args.chain):
        parser.error('only a unique PGN_<12-hex> chain is accepted')
    actions = {'snapshot': lambda: snapshot(args), 'owner': lambda: inspect_owner(args),
        'proof': lambda: write_proof(args), 'pause': lambda: watchdog_signal(args, True),
        'resume': lambda: watchdog_signal(args, False), 'dcs-isolate': lambda: dcs_isolate(args),
        'dcs-cleanup': lambda: dcs_cleanup(args)}
    try:
        print(json.dumps(actions[args.action](), sort_keys=True))
    except Exception as error:
        print(json.dumps({'status': 'failed', 'reason': str(error)}))
        raise SystemExit(1)

if __name__ == '__main__':
    main()
