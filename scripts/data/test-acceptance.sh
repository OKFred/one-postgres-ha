#!/usr/bin/env bash
# Exercise the production native evidence gate without Docker or live databases.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 -B - "$ROOT" <<'PY'
import copy
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

root = Path(sys.argv[1])
source = (root / "scripts/data/data.sh").read_text()
lines = source.splitlines(keepends=True)
start = next(index for index, line in enumerate(lines) if line.startswith("validate_acceptance() {"))
end = next(index for index in range(start + 1, len(lines)) if lines[index].strip() == "}")
production = "".join(lines[start:end + 1])

with tempfile.TemporaryDirectory(prefix="pg-native-evidence-") as temporary:
    fixture = Path(temporary)
    library = fixture / "gate.sh"
    library.write_text(production)
    script = fixture / "case.sh"
    script.write_text(r'''#!/usr/bin/env bash
set -Eeuo pipefail
source "$FIXTURE_LIBRARY"
die() { printf 'data: %s\n' "$*" >&2; exit 1; }
config=$FIXTURE_CONFIG
cluster=fixture
database=one_minihouse
control_id() { printf '1111111111111111111\n'; }
sql() {
  local query
  query=$(cat)
  printf '%s\n' "$query" >>"$FIXTURE_CALLS"
  case $query in
    "SELECT :'replay'::pg_lsn >= :'primary'::pg_lsn;") printf '%s\n' "${FIXTURE_REPLAY:-t}" ;;
    "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND sync_state IN ('sync','quorum');")
      printf '%s\n' "${FIXTURE_SYNC:-1}" ;;
    *) exit 97 ;;
  esac
}
validate_acceptance
''')
    config_path = fixture / "config.json"
    evidence_path = fixture / "acceptance.json"
    calls_path = fixture / "calls"
    stamp = lambda seconds=0: (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")
    modern = dict(cluster_name="fixture", system_identifier="1111111111111111111",
                  completed_at=stamp(), native=True, architecture="x86_64",
                  primary_failure=True, proxy_failure=True, etcd_failure=True,
                  network_isolation=True, watchdog=True, confirmed_transactions=True,
                  primary_lsn="0/10", replay_lsn="0/11")
    legacy = modern | {"arm64_native": True}
    del legacy["native"], legacy["architecture"]

    def run(name, accepted, evidence, architecture="x86_64", omit_architecture=False,
            expect_sql=None, raw_evidence=None, **extra):
        config = {"migrations": {"one_minihouse": {"acceptance_file": str(evidence_path)}}}
        if not omit_architecture:
            config["expected_architecture"] = architecture
        config_path.write_text(json.dumps(config))
        evidence_path.write_text(json.dumps(evidence) if raw_evidence is None else raw_evidence)
        calls_path.write_text("")
        env = os.environ | extra | {"FIXTURE_LIBRARY": str(library), "FIXTURE_CONFIG": str(config_path),
                                    "FIXTURE_CALLS": str(calls_path)}
        result = subprocess.run(["bash", str(script)], capture_output=True, text=True,
                                env=env, check=False, timeout=10)
        assert (result.returncode == 0) == accepted, (name, result.stderr)
        if expect_sql is not None:
            assert bool(calls_path.read_text()) == expect_sql, name
        print("PASS: native evidence " + name)

    run("AMD64 native", True, modern, expect_sql=True)
    run("ARM64 native", True, modern | {"architecture": "aarch64"}, architecture="aarch64")
    run("ARM64 legacy", True, legacy, architecture="aarch64")
    run("old ARM64 config", True, legacy, omit_architecture=True)
    run("ARM64 evidence cannot certify AMD64", False, legacy, expect_sql=False)
    run("wrong modern architecture", False, modern | {"architecture": "aarch64"}, expect_sql=False)
    run("AMD64 cannot use old ARM64 default", False, modern, omit_architecture=True, expect_sql=False)
    run("emulated evidence", False, modern | {"native": False}, expect_sql=False)
    run("legacy does not override native false", False, legacy | {"native": False}, architecture="aarch64", expect_sql=False)
    run("legacy does not override modern architecture", False, legacy | {"architecture": "x86_64"}, architecture="aarch64", expect_sql=False)
    run("architecture alias refused", False, modern | {"architecture": "amd64"}, expect_sql=False)
    run("invalid target", False, modern, architecture="amd64", expect_sql=False)
    run("null target", False, modern, architecture=None, expect_sql=False)
    run("malformed evidence", False, modern, raw_evidence="{bad json", expect_sql=False)
    run("foreign identity", False, modern | {"system_identifier": "2222222222222222222"}, expect_sql=False)
    run("foreign cluster", False, modern | {"cluster_name": "other"}, expect_sql=False)
    run("stale evidence", False, modern | {"completed_at": stamp(-90000)}, expect_sql=False)
    run("future evidence", False, modern | {"completed_at": stamp(60)}, expect_sql=False)
    run("missing watchdog", False, modern | {"watchdog": False}, expect_sql=False)
    run("malformed LSN", False, modern | {"replay_lsn": "invalid"}, expect_sql=False)
    run("lagged replay", False, modern, FIXTURE_REPLAY="f", expect_sql=True)
    run("no synchronous replica", False, modern, FIXTURE_SYNC="0", expect_sql=True)

    # Render the actual Ansible private config task, not a duplicate JSON template.
    tasks = yaml.safe_load((root / "ansible/data/prepare.yml").read_text())
    guard = copy.deepcopy(next(task for task in tasks if task["name"] == "Require one independent backup host"))
    writer = copy.deepcopy(next(task for task in tasks if task["name"] == "Write private data operation configuration"))
    env = os.environ | {"ANSIBLE_CONFIG": str(root / "ansible/ansible.cfg"),
                        "ANSIBLE_HOME": str(fixture / "ansible-home"),
                        "ANSIBLE_LOCAL_TEMP": str(fixture / "ansible-local"),
                        "ANSIBLE_REMOTE_TEMP": str(fixture / "ansible-remote")}
    for architecture in ("x86_64", "aarch64", None, "amd64"):
        deployment = fixture / (architecture or "legacy")
        (deployment / "data").mkdir(parents=True)
        variables = dict(cluster_name="fixture", deployment_root=str(deployment),
                         backup_target=dict(enabled=True, host="backup-01", path=str(fixture / "backups")),
                         data_postgres_image="postgres@sha256:" + "a" * 64, data_migrations={}, vip_address="192.0.2.50")
        if architecture is not None:
            variables["expected_architecture"] = architecture
        inventory = {"all": {"children": {
            "backup_server": {"hosts": {"backup-01": dict(ansible_connection="local", ansible_host="192.0.2.20",
                                                         ansible_python_interpreter=sys.executable)}},
            "pg_nodes": {"hosts": {"core-01": dict(ansible_host="192.0.2.11")}}}}}
        inventory_path = fixture / "inventory.yml"
        inventory_path.write_text(yaml.safe_dump(inventory))
        play = [dict(name="Render the production private data config", hosts="backup_server", gather_facts=False,
                     become=False, vars=variables, tasks=[guard, writer])]
        play_path = fixture / "play.yml"
        play_path.write_text(yaml.safe_dump(play))
        result = subprocess.run(["ansible-playbook", "-i", str(inventory_path), str(play_path)],
                                env=env, capture_output=True, text=True, timeout=45, check=False)
        expected = architecture != "amd64"
        assert (result.returncode == 0) == expected, result.stdout + result.stderr
        saved_path = deployment / "data/config.json"
        if expected:
            assert json.loads(saved_path.read_text())["expected_architecture"] == (architecture or "aarch64")
        else:
            assert not saved_path.exists()
        print("PASS: actual Ansible native config " + (architecture or "legacy default"))
PY
