"""Keep unsupported PostgreSQL data outside the deployment write barrier."""
import copy
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]


def preflight_cases(work):
    tasks = yaml.safe_load((ROOT / "ansible/roles/cluster/tasks/preflight.yml").read_text())
    first = next(index for index, task in enumerate(tasks)
                 if task["name"] == "Inspect the PostgreSQL directory without following links")
    last = next(index for index, task in enumerate(tasks) if task["name"] == "Read available disk space")
    guard = tasks[first:last]
    assert len(guard) == 8
    allowed = {"ansible.builtin.stat", "ansible.builtin.assert", "ansible.builtin.slurp", "ansible.builtin.find"}
    assert all(len(set(task) & allowed) == 1 for task in guard)
    deploy = yaml.safe_load((ROOT / "ansible/deploy.yml").read_text())
    assert deploy[0]["ansible.builtin.import_playbook"] == "preflight.yml"
    assert next(index for index, play in enumerate(deploy) if play.get("vars", {}).get("cluster_action") == "prepare") > 0
    imported = yaml.safe_load((ROOT / "ansible/preflight.yml").read_text())[0]
    assert imported["hosts"] == "pg_nodes" and imported["any_errors_fatal"] is True
    env = dict(os.environ, ANSIBLE_CONFIG=str(ROOT / "ansible/ansible.cfg"),
               ANSIBLE_HOME=str(work / "ansible-home"), ANSIBLE_LOCAL_TEMP=str(work / "ansible-local"),
               ANSIBLE_REMOTE_TEMP=str(work / "ansible-remote"))
    cases = ["pg17", "empty", "absent", "old18-core", "old18-replica", "pg19", "linked-version",
             "linked-pgdata", "broken-version", "hardlinked-version", "wrong-owner", "missing-version",
             "empty-version", "multiline-version"]
    for name in cases:
        fixture = work / name
        fixture.mkdir()
        hosts = {}
        before = {}
        for node in ("core01", "core02", "core03", "replica04"):
            directory = fixture / node
            directory.mkdir()
            pgdata = directory / "postgres"
            if name != "absent":
                pgdata.mkdir()
            if name not in ("empty", "absent"):
                version = pgdata / "PG_VERSION"
                value = "17\n"
                if (name == "old18-core" and node == "core03") or (name == "old18-replica" and node == "replica04"):
                    value = "18\n"
                if name == "pg19" and node == "replica04":
                    value = "19\n"
                if name == "empty-version" and node == "replica04":
                    value = ""
                if name == "multiline-version" and node == "replica04":
                    value = "17\n18\n"
                version.write_text(value)
                os.chown(version, 999, 999)
                if name == "wrong-owner" and node == "replica04":
                    os.chown(version, 0, 0)
                if name in ("linked-version", "broken-version") and node == "replica04":
                    target = directory / "external-version"
                    version.rename(target)
                    if name == "broken-version":
                        target.unlink()
                    version.symlink_to(target)
                if name == "hardlinked-version" and node == "replica04":
                    os.link(version, directory / "external-version")
                if name == "linked-pgdata" and node == "replica04":
                    external = directory / "external-pgdata"
                    pgdata.rename(external)
                    pgdata.symlink_to(external)
                if name == "missing-version" and node == "replica04":
                    version.unlink()
                    (pgdata / "unknown-data").write_bytes(b"must be preserved")
            for path in directory.rglob("*"):
                if path.is_file() and not path.is_symlink():
                    before[str(path)] = path.read_bytes()
            hosts[node] = dict(ansible_connection="local", ansible_python_interpreter=sys.executable,
                               data_root=str(directory), postgres_uid=999)
        inventory = {"all": {"children": {"pg_nodes": {"hosts": hosts}}}}
        (fixture / "inventory.yml").write_text(yaml.safe_dump(inventory))
        plays = [dict(name="Run the production major guard on all nodes", hosts="pg_nodes", gather_facts=False,
                      any_errors_fatal=True, tasks=copy.deepcopy(guard)),
                 dict(name="Model a later deployment write only after all guards pass", hosts="pg_nodes", gather_facts=False,
                      any_errors_fatal=True, tasks=[{"name": "Write an isolated acceptance canary", "ansible.builtin.copy": {
                          "content": "safe to proceed\n", "dest": "{{ data_root }}/write-canary", "mode": "0600"}}])]
        (fixture / "play.yml").write_text(yaml.safe_dump(plays))
        result = subprocess.run(["ansible-playbook", "-i", str(fixture / "inventory.yml"), str(fixture / "play.yml")],
                                capture_output=True, text=True, env=env, timeout=120)
        accepted = name in ("pg17", "empty", "absent")
        if (result.returncode == 0) != accepted:
            print(result.stdout + result.stderr, file=sys.stderr)
            raise AssertionError("Wrong major guard result: " + name)
        for node in hosts:
            assert (fixture / node / "write-canary").exists() == accepted, name
        assert all(Path(path).read_bytes() == content for path, content in before.items()), name
        print("PASS: all-node read-only PostgreSQL 17 preflight " + name, flush=True)


def entrypoint_cases(work):
    fixture = work / "entrypoint"
    fixture.mkdir()
    private = fixture / "secrets"
    private.mkdir()
    for name in ("postgres-password", "replication-password", "rewind-password", "patroni-api-password"):
        (private / name).write_text("fixture-only-secret\n")
    runtime = fixture / "runtime"
    runtime.mkdir()
    configuration = fixture / "patroni.yml"
    configuration.write_text("scope: fixture\n")
    binary = fixture / "bin"
    binary.mkdir()
    (binary / "id").write_text("#!/bin/sh\nprintf '999\\n'\n")
    (binary / "id").chmod(0o700)
    (binary / "patroni").write_text("#!/bin/sh\nprintf 'started\\n' >\"$MAJOR_GUARD_STARTED\"\n")
    (binary / "patroni").chmod(0o700)
    text = (ROOT / "images/postgres/entrypoint.sh").read_text()
    text = text.replace("/run/secrets/", str(private) + "/").replace("/run/patroni", str(runtime)).replace("/run/postgresql", str(runtime))
    (fixture / "entrypoint.sh").write_text(text)
    for name, value, accepted in (("17", "17\n", True), ("18", "18\n", False), ("19", "19\n", False),
                                  ("16", "16\n", False), ("minor", "17.11\n", False),
                                  ("empty", None, True), ("linked", "17\n", False)):
        data = fixture / name
        data.mkdir()
        if value is not None:
            (data / "PG_VERSION").write_text(value)
        if name == "linked":
            (data / "PG_VERSION").rename(data / "outside-version")
            (data / "PG_VERSION").symlink_to(data / "outside-version")
        started = fixture / (name + ".started")
        env = dict(os.environ, PATH=str(binary) + ":" + os.environ["PATH"], PGDATA=str(data),
                   PATRONI_CONFIG_FILE=str(configuration), MAJOR_GUARD_STARTED=str(started))
        result = subprocess.run(["bash", str(fixture / "entrypoint.sh"), "patroni"], capture_output=True, text=True, env=env)
        assert (result.returncode == 0) == accepted and started.exists() == accepted, (name, result.stderr)
    assert "bin_dir: /usr/lib/postgresql/17/bin" in (ROOT / "ansible/roles/cluster/templates/patroni.yml.j2").read_text()
    assert "bin_dir: /usr/lib/postgresql/17/bin" in (ROOT / "config/patroni.example.yml").read_text()
    invariants = next(task for task in yaml.safe_load((ROOT / "ansible/roles/cluster/tasks/verify.yml").read_text())
                      if task["name"] == "Validate this member's invariants")["ansible.builtin.assert"]["that"]
    assert "pg_ha_sql.server_version_num | int >= 170000" in invariants
    assert "pg_ha_sql.server_version_num | int < 180000" in invariants
    print("PASS: runtime accepts PG17 and fresh storage; rejects other majors and linked metadata", flush=True)


def image_contract_cases(work):
    source = yaml.safe_load((ROOT / "ansible/roles/cluster/tasks/prepare-image.yml").read_text())
    first = next(index for index, task in enumerate(source)
                 if task["name"] == "Read the actual configured PostgreSQL image reference")
    tasks = source[first:]
    assert len(tasks) == 4
    probe = tasks[-1]["ansible.builtin.command"]["argv"]
    assert probe[:5] == ["timeout", "--signal=TERM", "--kill-after=5", "30", "docker"]
    assert "--rm" in probe and "--read-only" in probe and "--pull=never" in probe
    assert "--mount" not in probe and "--volume" not in probe
    env = dict(os.environ, ANSIBLE_CONFIG=str(ROOT / "ansible/ansible.cfg"),
               ANSIBLE_HOME=str(work / "ansible-home"), ANSIBLE_LOCAL_TEMP=str(work / "ansible-local"),
               ANSIBLE_REMOTE_TEMP=str(work / "ansible-remote"))
    for name, accepted in (("pg17", True), ("pg18-binary", False), ("pg19-binary", False),
                           ("missing-pg17-binary", False), ("missing-helper", False), ("invalid-image-id", False)):
        fixture = work / ("image-" + name)
        fixture.mkdir()
        binary = fixture / "bin"
        binary.mkdir()
        image = fixture / "image"
        required = ("/usr/lib/postgresql/17/bin/postgres", "/usr/lib/postgresql/17/bin/pg_controldata",
                    "/usr/local/bin/patroni-entrypoint", "/usr/local/bin/patroni-healthcheck",
                    "/usr/local/bin/pg-admin", "/opt/patroni/bin/patroni")
        for executable in required:
            target = image / executable.lstrip("/")
            target.parent.mkdir(parents=True, exist_ok=True)
            version = "18.6" if name == "pg18-binary" else "19.1" if name == "pg19-binary" else "17.11"
            target.write_text("#!/bin/sh\nprintf '%s\\n' 'postgres (PostgreSQL) " + version + "'\n")
            target.chmod(0o700)
        if name == "missing-pg17-binary":
            (image / required[0].lstrip("/")).unlink()
        if name == "missing-helper":
            (image / required[-1].lstrip("/")).unlink()
        docker = binary / "docker"
        docker.write_text(r'''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
fixture=pathlib.Path(os.environ['MAJOR_IMAGE_FIXTURE'])
args=sys.argv[1:]
with (fixture/'calls.jsonl').open('a') as log: log.write(json.dumps(args)+'\n')
if args==['compose','--env-file','.env','config','--format','json']:
    print(json.dumps({'services':{'postgres':{'image':'registry.example.com/project/claimed-pg17@sha256:'+'a'*64}}}))
elif args[:4]==['image','inspect','--format','{{.Id}}']:
    print('not-an-immutable-id' if fixture.name=='image-invalid-image-id' else 'sha256:'+'f'*64)
elif args[0]=='run':
    assert '--rm' in args and '--read-only' in args and '--pull=never' in args
    assert args[args.index('--network')+1]=='none' and args[args.index('--user')+1]=='999:999'
    assert '--mount' not in args and '--volume' not in args
    assert args[args.index('--entrypoint')+1]=='/bin/sh' and args[-2]=='-ec'
    script=args[-1].replace('/usr/',str(fixture/'image/usr')+'/').replace('/opt/',str(fixture/'image/opt')+'/')
    raise SystemExit(subprocess.call(['/bin/sh','-ec',script]))
else:
    raise SystemExit('No service lifecycle operation is permitted by this image contract fixture')
''')
        docker.chmod(0o700)
        task_env = dict(MAJOR_IMAGE_FIXTURE=str(fixture), PATH=str(binary) + ":" + os.environ["PATH"])
        play = [dict(name="Validate the real image contract task before lifecycle writes", hosts="fixture", gather_facts=False,
                     any_errors_fatal=True, environment=task_env, vars=dict(deployment_root=str(fixture)), tasks=copy.deepcopy(tasks)),
                dict(name="Model permitted later service startup", hosts="fixture", gather_facts=False, any_errors_fatal=True,
                     tasks=[{"name": "Write an isolated startup canary", "ansible.builtin.copy": {
                         "content": "start permitted\n", "dest": str(fixture / "startup-canary"), "mode": "0600"}}])]
        inventory = {"all": {"hosts": {"fixture": {"ansible_connection": "local", "ansible_python_interpreter": sys.executable}}}}
        (fixture / "inventory.yml").write_text(yaml.safe_dump(inventory))
        (fixture / "play.yml").write_text(yaml.safe_dump(play))
        result = subprocess.run(["ansible-playbook", "-i", str(fixture / "inventory.yml"), str(fixture / "play.yml")],
                                capture_output=True, text=True, env=env, timeout=120)
        if (result.returncode == 0) != accepted:
            print(result.stdout + result.stderr, file=sys.stderr)
            raise AssertionError("Wrong immutable image contract result: " + name)
        assert (fixture / "startup-canary").exists() == accepted
        print("PASS: actual PostgreSQL image binary contract " + name, flush=True)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="ha-pg17-major-guard-") as temporary:
        work = Path(temporary)
        preflight_cases(work)
        entrypoint_cases(work)
        image_contract_cases(work)
