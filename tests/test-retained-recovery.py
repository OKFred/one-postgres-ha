"""Exercise controlled restart decisions through the real Ansible recovery plays."""
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

import yaml

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "sha256:" + "f" * 64
IDENTITY = "1234567890123456789"
TRANSACTION = "a" * 64

DOCKER = r'''#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['RECOVERY_FIXTURE'])
node=pathlib.Path.cwd().parent.name
args=sys.argv[1:]
if args[0]=='run':
    mount=args[args.index('--mount')+1]
    node=pathlib.Path(mount.split('src=',1)[1].split(',dst=',1)[0]).parent.parent.name
    state=json.loads((root/node/'state.json').read_text())
    assert '--read-only' in args and args[args.index('--network')+1]=='none'
    assert args[args.index('--entrypoint')+1]=='/usr/lib/postgresql/18/bin/pg_controldata'
    print('Database system identifier: '+state['system_identifier'])
    print('Database cluster state: '+state.get('control_state','shut down'))
elif args[:2]==['image','inspect']:
    print('sha256:'+'f'*64)
elif args[0]=='inspect':
    print('sha256:'+'f'*64+' fixture-config')
elif args[0]=='compose':
    statefile=root/node/'state.json'; state=json.loads(statefile.read_text())
    if 'up' in args:
        for member in ['core01','core02','core03','replica04']:
            receipt=json.loads((root/member/'deployment/.one-postgres-ha-retained.json').read_text())
            assert receipt['phase']=='resuming'
        state['running']=True; statefile.write_text(json.dumps(state))
        with (root/'actions').open('a') as log: log.write('start '+node+'\n')
    elif '--hash' in args: print('postgres fixture-config')
    elif 'config' in args: print(json.dumps({'services':{'postgres':{'image':'fixture:locked'}}}))
    elif 'ps' in args: print('a'*64 if state['running'] else '')
    else: raise SystemExit(96)
else: raise SystemExit(97)
'''

AUDIT = r'''#!/usr/bin/env bash
set -euo pipefail
python3 -B - "$PWD" "$@" <<'PY'
import json,os,pathlib,stat,sys
args=sys.argv[2:]
assert not os.environ['RECOVERY_FIXTURE'].endswith('/ordinary-no-receipt'), 'A normal installation must not run cleanup-only audits'
deployment=pathlib.Path(args[args.index('--deployment-root')+1])
node=deployment.parent.name
state=json.loads((deployment.parent/'state.json').read_text())
path=deployment/'.one-postgres-ha-retained.json'
receipt=None
if path.exists():
    info=path.lstat()
    assert stat.S_ISREG(info.st_mode) and info.st_uid==0 and info.st_nlink==1 and stat.S_IMODE(info.st_mode)==0o600
    receipt=json.loads(path.read_text())
    assert receipt['node']==node and receipt['deployment']==str(deployment)
    assert receipt['cluster']=='recovery-test' and receipt['data']==str(deployment.parent/'data')
containers=[]
if state['running']:
    containers=[dict(service='postgres',running=True,image=state.get('image','sha256:'+'f'*64))]
print(json.dumps(dict(retained_receipt=receipt,containers=containers)))
PY
'''


def run_case(work, name, expected=True):
    fixture = work / name
    fixture.mkdir()
    nodes = ["core01", "core02", "core03", "replica04"]
    servers = []
    hosts = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            states = {node: json.loads((fixture / node / "state.json").read_text()) for node in nodes}
            if self.path == "/cluster":
                body = {"members": [{"name": node, "role": "leader" if node == "core02" else "replica"}
                                    for node in nodes if states[node]["running"]]}
                status = 200 if all(state["running"] for state in states.values()) else 503
            else:
                body = {}
                status = 200 if states[self.server.node]["running"] else 503
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())

        def log_message(self, *_args):
            pass

    for node in nodes:
        directory = fixture / node
        deployment = directory / "deployment"
        (deployment / "bin").mkdir(parents=True)
        (directory / "data/postgres/global").mkdir(parents=True)
        control = directory / "data/postgres/global/pg_control"
        control.write_bytes(b"fixture PostgreSQL control file")
        os.chown(control, 999, 999)
        control.chmod(0o600)
        shutil.copyfile(ROOT / "scripts/retained-state.py", deployment / "bin/retained-state.py")
        (deployment / "bin/cleanup-node.sh").write_text(AUDIT)
        receipt = dict(schema=1, cluster="recovery-test", node=node, project="one-postgres-ha",
                       deployment=str(deployment), data=str(directory / "data"), phase="stopped",
                       transaction=TRANSACTION, system_identifier=IDENTITY, image_id=IMAGE)
        state = dict(running=False, system_identifier=IDENTITY)
        if name == "ordinary-no-receipt":
            receipt = None
        elif name == "ordinary-completed":
            receipt["phase"] = "complete"
        elif name == "ordinary-upgrade":
            receipt["phase"] = "complete"
            state.update(running=True,image="sha256:"+"e"*64)
        elif name == "missing-replica" and node == "replica04":
            receipt = None
        elif name == "wrong-transaction" and node == "replica04":
            receipt["transaction"] = "b" * 64
        elif name == "wrong-control" and node == "replica04":
            state["system_identifier"] = "9999999999999999999"
        elif name == "wrong-dcs":
            pass
        elif name == "dirty-control" and node == "replica04":
            state["control_state"] = "in production"
        elif name == "partial-resume":
            receipt["phase"] = "resuming"
            state["running"] = node == "replica04"
        elif name == "partial-completion":
            receipt["phase"] = "resuming" if node == "replica04" else "complete"
            state["running"] = True
        elif name == "running-stopped" and node == "replica04":
            state["running"] = True
        if receipt is not None:
            path = deployment / ".one-postgres-ha-retained.json"
            path.write_text(json.dumps(receipt))
            path.chmod(0o644 if name == "unsafe-receipt" and node == "replica04" else 0o600)
        (directory / "state.json").write_text(json.dumps(state))
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.node = node
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        hosts[node] = dict(ansible_connection="local", ansible_python_interpreter=sys.executable,
                           node_name=node, node_ip="127.0.0.1", patroni_port=server.server_port,
                           deployment_root=str(deployment), data_root=str(directory / "data"), data_mount=str(directory),
                           pg_ha_desired_image=dict(stdout=IMAGE), pg_ha_patroni_template=dict(changed=True),
                           pg_ha_new_cluster=False,
                           pg_ha_initialize_key=dict(stdout="9999999999999999999" if name == "wrong-dcs" else IDENTITY))
    (fixture / "bin").mkdir()
    docker = fixture / "bin/docker"
    docker.write_text(DOCKER)
    docker.chmod(0o700)
    all_vars = dict(cluster_name="recovery-test", watchdog_device="/dev/fixture", watchdog_gid=999,
                    compose_project_name="one-postgres-ha")
    inventory = {"all": {"vars": all_vars, "children": {"pg_nodes": {"children": {
        "core_nodes": {"hosts": {node: hosts[node] for node in nodes[:3]}},
        "replica_nodes": {"hosts": {nodes[3]: hosts[nodes[3]]}},
    }}}}}
    (fixture / "inventory.yml").write_text(yaml.safe_dump(inventory))
    deploy = yaml.safe_load((ROOT / "ansible/deploy.yml").read_text())
    start = next(index for index, play in enumerate(deploy)
                 if play["name"] == "Inspect retained-data receipts on every PostgreSQL member")
    end = next(index for index, play in enumerate(deploy)
               if play["name"] == "Bootstrap exactly one PostgreSQL primary")
    plays = copy.deepcopy(deploy[start:end])
    env = dict(os.environ, RECOVERY_FIXTURE=str(fixture),
               PATH=str(fixture / "bin") + ":" + os.environ["PATH"],
               ANSIBLE_CONFIG=str(ROOT / "ansible/ansible.cfg"), ANSIBLE_ROLES_PATH=str(ROOT / "ansible/roles"),
               ANSIBLE_HOME=str(work / "ansible-home"), ANSIBLE_LOCAL_TEMP=str(work / "ansible-local"),
               ANSIBLE_REMOTE_TEMP=str(work / "ansible-remote"))
    for play in plays:
        play["environment"] = {"RECOVERY_FIXTURE": str(fixture), "PATH": env["PATH"]}
    plays.append(dict(name="Check recovered identity requires no rolling recreate", hosts="pg_nodes", gather_facts=False,
                      tasks=[{"name": "Assert consumed config matches running image", "ansible.builtin.assert": {
                          "that": ["not pg_ha_pg_recreate"]},
                              "when": "hostvars[groups.core_nodes[0]].pg_ha_retained_restore_required"}]))
    complete = next(play for play in deploy if play.get("name") == "Complete controlled recovery receipts only after full verification")
    plays.append(copy.deepcopy(complete))
    plays[-1]["environment"] = {"RECOVERY_FIXTURE": str(fixture), "PATH": env["PATH"]}
    (fixture / "play.yml").write_text(yaml.safe_dump(plays))
    try:
        result = subprocess.run(["ansible-playbook", "-i", str(fixture / "inventory.yml"), str(fixture / "play.yml")],
                                capture_output=True, text=True, env=env, timeout=180)
        (fixture / "ansible.log").write_text(result.stdout + result.stderr)
        if (result.returncode == 0) != expected:
            print(result.stdout[-12000:] + result.stderr, file=sys.stderr)
            raise AssertionError(name + " produced the wrong Ansible exit status")
        actions = (fixture / "actions").read_text().splitlines() if (fixture / "actions").exists() else []
        if expected and name not in ("ordinary-no-receipt", "ordinary-completed", "ordinary-upgrade"):
            assert sorted(actions) == ["start " + node for node in sorted(nodes)]
            for node in nodes:
                receipt = json.loads((fixture / node / "deployment/.one-postgres-ha-retained.json").read_text())
                assert receipt["phase"] == "complete" and receipt["system_identifier"] == IDENTITY
        else:
            assert actions == [], name + " unexpectedly started PostgreSQL"
        print("PASS: protected retained-data recovery " + name, flush=True)
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="ha-retained-recovery-") as temporary:
        work = Path(temporary)
        for scenario in ("normal", "partial-resume", "partial-completion", "ordinary-no-receipt", "ordinary-completed", "ordinary-upgrade"):
            run_case(work, scenario)
        for scenario in ("missing-replica", "wrong-transaction", "wrong-control", "wrong-dcs", "dirty-control", "running-stopped", "unsafe-receipt"):
            run_case(work, scenario, expected=False)
