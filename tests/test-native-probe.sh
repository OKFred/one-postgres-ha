#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
import ast, importlib.util, json, pathlib, subprocess, sys, types, unittest.mock
root, work = map(pathlib.Path, sys.argv[1:])
helper = root / 'tests/native-probe.py'
ast.parse(helper.read_text())
spec = importlib.util.spec_from_file_location('native_probe', helper)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
proof = {'pid': 9, 'boot_id': 'old', 'starttime': '111',
         'cmdline_sha256': 'abc', 'container_id': 'fixture'}
args = types.SimpleNamespace(apply=False, proof=str(work/'proof.json'),
    deployment_root='/not-a-production-path', cluster_name='fixture',
    watchdog_device='/not-a-device', run_id='123456abcdef')
(work/'proof.json').write_text(json.dumps(proof))
with unittest.mock.patch.object(probe, 'inspect_owner') as inspect:
    try:
        probe.write_proof(args)
    except RuntimeError as error:
        assert 'requires root and --apply' in str(error)
    else:
        raise AssertionError('proof mutation was allowed without --apply')
    inspect.assert_not_called()
with unittest.mock.patch.object(probe, 'boot_id', return_value='new'), \
     unittest.mock.patch.object(probe, 'inspect_owner') as inspect:
    assert probe.matching_owner(args, proof) == (False, 'new_boot_no_signal')
    inspect.assert_not_called()
with unittest.mock.patch.object(probe, 'boot_id', return_value='old'), \
     unittest.mock.patch.object(probe, 'inspect_owner', return_value={**proof, 'starttime': '222'}):
    assert not probe.matching_owner(args, proof)[0]
with unittest.mock.patch.object(probe, 'require_apply'), \
     unittest.mock.patch.object(probe, 'matching_owner', return_value=(False, 'new_boot_no_signal')), \
     unittest.mock.patch.object(probe.os, 'pidfd_open') as pid_open, \
     unittest.mock.patch.object(probe.signal, 'pidfd_send_signal') as send:
    assert not probe.watchdog_signal(args, False)['signal_sent']
    pid_open.assert_not_called()
    send.assert_not_called()
with unittest.mock.patch.object(probe, 'require_apply'), \
     unittest.mock.patch.object(probe, 'matching_owner', return_value=(True, '')), \
     unittest.mock.patch.object(probe.os, 'pidfd_open', return_value=42), \
     unittest.mock.patch.object(probe.os, 'close') as close, \
     unittest.mock.patch.object(probe.signal, 'pidfd_send_signal') as send:
    assert probe.watchdog_signal(args, False)['signal_sent']
    send.assert_called_once_with(42, probe.signal.SIGCONT)
    close.assert_called_once_with(42)
with unittest.mock.patch.object(probe, 'require_apply'), \
     unittest.mock.patch.object(probe, 'matching_owner', return_value=(True, '')), \
     unittest.mock.patch.object(probe.os, 'pidfd_open', return_value=42), \
     unittest.mock.patch.object(probe.os, 'close') as close, \
     unittest.mock.patch.object(probe.signal, 'pidfd_send_signal') as send, \
     unittest.mock.patch.object(probe.urllib.request, 'urlopen') as request, \
     unittest.mock.patch.object(probe, 'run', side_effect=RuntimeError('timer failed')):
    request.return_value.__enter__.return_value.status = 200
    try:
        probe.watchdog_signal(args, True)
    except RuntimeError as error:
        assert str(error) == 'timer failed'
    else:
        raise AssertionError('pause was allowed before recovery timer creation')
    send.assert_not_called()
    close.assert_called_once_with(42)
result = subprocess.run([sys.executable, str(helper), 'snapshot'], capture_output=True, text=True)
assert result.returncode == 2 and 'snapshot requires --data-mount' in result.stderr
for count in [3, 4, 5, 7, 8]:
    addresses = [f'192.0.2.{index}' for index in range(1, count + 1)]
    isolated = types.SimpleNamespace(**vars(args), addresses=addresses, chain=f'PGN_{count:012x}')
    def command(argv, check=True):
        return types.SimpleNamespace(returncode=1 if argv[:5] == ['iptables', '-w', '5', '-S', isolated.chain] else 0)
    with unittest.mock.patch.object(probe, 'require_apply'), \
         unittest.mock.patch.object(probe, 'STATE', work/'owned-dcs'), \
         unittest.mock.patch.object(probe, 'run', side_effect=command) as run:
        assert probe.dcs_isolate(isolated)['status'] == 'dcs_client_egress_isolated'
        commands = [call.args[0] for call in run.call_args_list]
        targets = [argv[6] for argv in commands if argv[:5] == ['iptables', '-w', '5', '-A', isolated.chain]]
        assert set(targets) == {address + '/32' for address in addresses + ['127.0.0.1']}
        assert commands.index(next(argv for argv in commands if argv[0] == 'systemd-run')) < commands.index(
            ['iptables', '-w', '5', '-N', isolated.chain])
for addresses in [[], ['192.0.2.1'] * 3, ['192.0.2.1', '192.0.2.2', '127.0.0.1'],
                  ['192.0.2.1', '192.0.2.2', '224.0.0.1']]:
    isolated = types.SimpleNamespace(**vars(args), addresses=addresses, chain='PGN_123456abcdef')
    with unittest.mock.patch.object(probe, 'require_apply'), unittest.mock.patch.object(probe, 'run') as run:
        try:
            probe.dcs_isolate(isolated)
        except RuntimeError as error:
            assert 'at least three distinct non-loopback' in str(error)
        else:
            raise AssertionError('invalid isolation endpoints were accepted')
        run.assert_not_called()
print('PASS: native helper syntax, explicit mutation, boot/PID and timer guards')
PY
yamllint -c "$ROOT/.yamllint.yml" "$ROOT/tests/native-vip.yml"
mkdir -p "$WORK/private/secrets"
printf '%s' fixture-secret >"$WORK/private/secrets/postgres-password"
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib, sys, yaml
root, work = map(pathlib.Path, sys.argv[1:])
play = yaml.safe_load((root/'tests/native-vip.yml').read_text())
play[0]['tasks'][1]['ansible.builtin.command']['argv'][0] = str(work/'fixture-psql')
script = work/'fixture-psql'
script.write_text('''#!/usr/bin/env python3
import os, sys
assert os.environ['PGPASSWORD'] == 'fixture-secret'
sql = sys.argv[sys.argv.index('-c')+1]
if sql != 'SELECT 1':
    assert "json_build_object('identity'," in sql
    assert "current_setting('data_checksums')" in sql
print('{"mock_client":"render_validated"}')
''')
script.chmod(0o755)
(work/'native-vip.yml').write_text(yaml.safe_dump(play))
PY
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg"
ansible-playbook -i localhost, "$WORK/native-vip.yml" --syntax-check \
  -e vip_address=192.0.2.50 -e private_dir="$WORK/private"
ansible-playbook -i localhost, "$WORK/native-vip.yml" \
  -e vip_address=192.0.2.50 -e private_dir="$WORK/private"
if ansible-playbook -i localhost, "$WORK/native-vip.yml" \
  -e vip_address=192.0.2.50 -e private_dir="$WORK/private" \
  -e '{"native_sql":"SELECT 1"}' >"$WORK/negative.log" 2>&1; then
  echo 'Supplied SQL was allowed without native_apply' >&2
  exit 1
fi
grep -q 'Supplied acceptance SQL requires native_apply=true' "$WORK/negative.log"
ansible-playbook -i localhost, "$WORK/native-vip.yml" \
  -e vip_address=192.0.2.50 -e private_dir="$WORK/private" \
  -e '{"native_apply":true,"native_sql":"SELECT 1"}'
printf 'PASS: real Ansible SQL rendering and explicit mutation opt-in\n'
