#!/usr/bin/env python3
"""Validate and advance a controlled keep-data restart receipt."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


def execute(argv):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=90, check=False)
    if result.returncode != 0:
        raise RuntimeError("Retained-data inspection failed; no PostgreSQL start was attempted")
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("probe", "mark", "complete"))
    for name in ("deployment-root", "data-root", "data-mount", "cluster-name", "node-name", "node-ip",
                 "compose-project", "watchdog-device", "watchdog-gid", "image"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--core", action="store_true")
    parser.add_argument("--transaction")
    parser.add_argument("--system-identifier")
    args = parser.parse_args()
    if os.getuid() != 0 or not re.fullmatch(r"sha256:[0-9a-f]{64}", args.image):
        raise RuntimeError("Require root and the inspected immutable PostgreSQL image ID")
    deployment = Path(args.deployment_root)
    # Ordinary installations have no restart receipt. Do not impose uninstall
    # container/path restrictions or run one-off inspection containers on them.
    if args.operation == "probe" and not os.path.lexists(deployment / ".one-postgres-ha-retained.json"):
        print(json.dumps({"present": False}))
        return
    backend = deployment / "bin/cleanup-node.sh"
    audit_args = ["/bin/bash", str(backend), "audit"]
    for name in ("deployment_root", "data_root", "data_mount", "cluster_name", "node_name", "node_ip",
                 "compose_project", "watchdog_device", "watchdog_gid"):
        audit_args += ["--" + name.replace("_", "-"), getattr(args, name)]
    audit_args += ["--core" if args.core else "--replica"]
    audit = json.loads(execute(audit_args))
    receipt = audit["retained_receipt"]
    if receipt is None:
        if args.operation != "probe":
            raise RuntimeError("Missing retained-data receipt")
        print(json.dumps({"present": False}))
        return
    postgres = [item for item in audit["containers"] if item["service"] == "postgres"]
    running = bool(postgres and postgres[0]["running"])
    enforce_image = receipt["phase"] != "complete" or args.operation != "probe"
    if running and (receipt["phase"] == "stopped" or (enforce_image and postgres[0]["image"] != args.image)):
        raise RuntimeError("A stopped receipt has an active or unexpected PostgreSQL runtime")
    control = Path(args.data_root) / "postgres/global/pg_control"
    info = control.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != 999 or info.st_mode & 0o022:
        raise RuntimeError("Unsafe PostgreSQL control file")
    output = execute([
        "docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges", "--user", "999:999", "--env", "LC_ALL=C",
        "--mount", "type=bind,src=" + args.data_root + "/postgres,dst=/var/lib/postgresql/data,readonly",
        "--entrypoint", "/usr/lib/postgresql/17/bin/pg_controldata", args.image, "/var/lib/postgresql/data",
    ])
    identities = re.findall(r"^Database system identifier:\s+([1-9][0-9]{0,19})\s*$", output, re.M)
    if identities != [receipt["system_identifier"]]:
        raise RuntimeError("Stored PostgreSQL identity differs from its retained-data receipt")
    states = re.findall(r"^Database cluster state:\s+(.+?)\s*$", output, re.M)
    if receipt["phase"] == "stopped" and (len(states) != 1 or states[0] not in ("shut down", "shut down in recovery")):
        raise RuntimeError("Retained PostgreSQL did not complete a clean shutdown")
    if args.operation != "probe":
        if args.transaction != receipt["transaction"] or args.system_identifier != receipt["system_identifier"]:
            raise RuntimeError("Retained-data transaction or DCS identity differs")
        if args.operation == "complete" and not running:
            raise RuntimeError("Cannot complete retained recovery without the running member")
        receipt["phase"] = "resuming" if args.operation == "mark" else "complete"
        descriptor, temporary = tempfile.mkstemp(prefix=".retained-", dir=deployment)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(receipt, stream, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, deployment / ".one-postgres-ha-retained.json")
            directory_descriptor = os.open(deployment, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(json.dumps({"present": True, "phase": receipt["phase"], "transaction": receipt["transaction"],
                      "system_identifier": receipt["system_identifier"], "running": running}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired):
        print("retained-state: protected recovery inspection failed; preserve receipts and inspect the nodes", file=sys.stderr)
        raise SystemExit(2)
