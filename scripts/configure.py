#!/usr/bin/env python3
"""Read-only host discovery and private inventory rendering for configure.sh."""

import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys


def fail(message):
    raise ValueError(message)


def ipv4(value):
    address = ipaddress.IPv4Address(value)
    if address.is_unspecified or address.is_multicast or address.is_loopback:
        fail("Use a unicast IPv4 address reachable from the controller")
    return str(address)


def username(value):
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", value):
        fail("Invalid SSH username")
    return value


def default_voters(count):
    if count < 3:
        fail("At least three PostgreSQL nodes are required")
    size = min(count, 7)
    if size % 2 == 0:
        size -= 1
    return list(range(1, size + 1))


def voter_indices(count, value):
    parts = re.split(r"[\s,]+", value.strip())
    if not parts or any(not re.fullmatch(r"0*[1-9][0-9]*", part) for part in parts):
        fail("Etcd voters must be node numbers separated by spaces or commas")
    selected = [int(part) for part in parts]
    if len(selected) < 3 or len(set(selected)) != len(selected):
        fail("Choose at least three distinct etcd voting nodes")
    if any(number > count for number in selected):
        fail("An etcd voter refers to a node that was not entered")
    return sorted(selected)


def image(value, local=False):
    registry = r"[a-z0-9][a-z0-9.:_-]*/[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[a-f0-9]{64}"
    registry_host = value.split("/", 1)[0]
    if re.fullmatch(registry, value) and ("." in registry_host or ":" in registry_host or registry_host == "localhost"):
        return value
    if local and re.fullmatch(r"one-postgres-ha-tools:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", value):
        return value
    fail("Use an immutable registry image with @sha256: followed by 64 lowercase hex digits")


def run(args, accepted=(0,)):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30, check=False)
    if result.returncode not in accepted:
        fail("Host discovery failed: " + args[0])
    return result.stdout.strip()


def probe(node_ip, vip, ssh_connection=None):
    node_ip, vip = ipv4(node_ip), ipv4(vip)
    os_release = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            os_release[key] = value.strip('"')
    addresses = json.loads(run(["ip", "-j", "address", "show"]))
    matches = [(item["ifname"], entry) for item in addresses for entry in item.get("addr_info", [])
               if entry.get("family") == "inet" and entry.get("local") == node_ip]
    if len(matches) != 1:
        fail("Node IPv4 must belong to exactly one interface")
    interface, address = matches[0]
    network = ipaddress.IPv4Network(f"{node_ip}/{address['prefixlen']}", strict=False)
    connection = (ssh_connection or os.environ.get("SSH_CONNECTION", "")).split()
    if len(connection) != 4:
        fail("SSH_CONNECTION is unavailable; controller source cannot be established")
    controller = ipv4(connection[0])
    watchdog = Path("/dev/watchdog")
    watchdog_ok = watchdog.exists() and stat.S_ISCHR(watchdog.stat().st_mode)
    if watchdog_ok:
        holder = subprocess.run(["fuser", "/dev/watchdog"], capture_output=True, text=True,
                                timeout=10, check=False)
        if holder.returncode not in (0, 1):
            fail("Cannot check watchdog ownership")
        watchdog_ok = holder.returncode == 1
    watchdog_time = run(["systemctl", "show", "--property=RuntimeWatchdogUSec", "--value"])
    if watchdog_time != "0":
        fail("Disable the systemd runtime watchdog before configuring this cluster")
    compose = subprocess.run(["docker", "compose", "version"], capture_output=True,
                             text=True, timeout=30, check=False).returncode == 0
    policy = run(["apt-cache", "policy", "keepalived"])
    candidate = re.search(r"^\s*Candidate:\s+(\S+)\s*$", policy, re.MULTILINE)
    if not candidate or candidate[1] == "(none)":
        fail("No Keepalived package candidate; refresh package metadata before configuring")
    blocks = json.loads(run(["lsblk", "--json", "--paths", "--tree", "--output", "PATH,TYPE,ROTA,PKNAME"]))
    devices = {}

    def visit(items, parent=None):
        for item in items:
            entry = devices.setdefault(item["path"], {"types": set(), "rotations": set(), "parents": set()})
            entry["types"].add(item.get("type"))
            entry["rotations"].add(item.get("rota"))
            if parent:
                entry["parents"].add(parent)
            visit(item.get("children", []), item["path"])

    visit(blocks["blockdevices"])

    def is_ssd(source):
        def ancestry(path, seen):
            entry = devices.get(path)
            if not entry or path in seen or len(entry["types"]) != 1:
                return False
            if entry["types"] == {"disk"}:
                return not entry["parents"] and entry["rotations"] == {False} and not Path(path).name.startswith("mmc")
            return bool(entry["parents"]) and all(ancestry(parent, seen | {path}) for parent in entry["parents"])

        # RAID/LVM can appear below several disks in lsblk's tree. Every physical
        # ancestor must qualify; missing or cyclic ancestry cannot establish SSD storage.
        return ancestry(source.split("[", 1)[0], set())

    found = json.loads(run(["findmnt", "--json", "--list", "--output", "SOURCE,TARGET,FSTYPE,OPTIONS"]))
    mounts = []
    for mount in found["filesystems"]:
        target, source, filesystem = mount["target"], mount["source"], mount["fstype"]
        if target == "/" or not source.startswith("/dev/") or filesystem not in ("ext4", "xfs", "btrfs"):
            continue
        free = os.statvfs(target)
        mounts.append({"target": target, "source": source, "fstype": filesystem,
                       "rw": "rw" in mount["options"].split(","), "local": True,
                       "ssd": is_ssd(source), "available_bytes": free.f_bavail * free.f_frsize,
                       "data_exists": os.path.lexists(str(Path(target) / "one-postgres-ha"))})
    vip_local = any(entry.get("local") == vip for item in addresses for entry in item.get("addr_info", []))
    ping_reply = False
    if shutil.which("ping"):
        ping = subprocess.run(["ping", "-n", "-c", "1", "-W", "1", vip], capture_output=True,
                              text=True, timeout=5, check=False)
        if ping.returncode not in (0, 1):
            fail("Cannot check VIP reachability")
        ping_reply = ping.returncode == 0
    containers = run(["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=one-postgres-ha",
                      "--format", "{{.ID}}"])
    return {"node_ip": node_ip, "architecture": platform.machine(), "os_id": os_release.get("ID", ""),
            "os_like": os_release.get("ID_LIKE", ""), "controller_ip": controller, "interface": interface,
            "prefix": address["prefixlen"], "network": str(network), "keepalived_version": candidate[1],
            "docker_compose": compose, "watchdog": watchdog_ok, "systemd_watchdog_usec": 0,
            "deployment_exists": os.path.lexists("/opt/one-postgres-ha") or bool(containers),
            "vip_in_use": vip_local or ping_reply, "mounts": mounts}


def secure_directory(path):
    if path.is_symlink() or not path.is_dir():
        fail("Private paths must be real directories")
    if path.resolve() != path.absolute():
        fail("Private directories must not traverse symbolic links")


def check_fresh(root):
    private = root / ".local"
    if not private.exists() and not private.is_symlink():
        private.mkdir(mode=0o700)
    secure_directory(private)
    for name in ("inventory.yml", "known_hosts", "controller.env"):
        if os.path.lexists(str(private / name)):
            fail("Existing configuration found; configure refuses to overwrite " + name)
    secrets = private / "secrets"
    if os.path.lexists(str(secrets)):
        secure_directory(secrets)
        if any(secrets.iterdir()):
            fail("Existing secrets found; preserve their matching inventory")
    return private


def collect(stage, vip, user, ips):
    ips = [ipv4(value) for value in ips]
    vip = ipv4(vip)
    if len(ips) < 3 or len(set(ips + [vip])) != len(ips) + 1:
        fail("At least three distinct node addresses and a different VIP are required")
    selection = (stage / "core-node-indices").read_text()
    core_indices = voter_indices(len(ips), selection)
    nonstandard = len(core_indices) % 2 == 0 or len(core_indices) > 7
    confirmation = stage / "etcd-force-confirmation"
    if nonstandard and (not confirmation.is_file() or confirmation.read_text() != "FORCE-ETCD\n"):
        fail("An even or larger-than-seven etcd voting group requires explicit FORCE-ETCD confirmation")
    discoveries = []
    for index, expected in enumerate(ips, 1):
        entry = json.loads((stage / f"node{index}.json").read_text())
        string_fields = ("node_ip", "architecture", "os_id", "os_like", "controller_ip", "interface", "network", "keepalived_version")
        bool_fields = ("docker_compose", "watchdog", "deployment_exists", "vip_in_use")
        if not isinstance(entry, dict) or any(type(entry.get(field)) is not str for field in string_fields) or any(type(entry.get(field)) is not bool for field in bool_fields) or type(entry.get("prefix")) is not int or type(entry.get("systemd_watchdog_usec")) is not int or not isinstance(entry.get("mounts"), list):
            fail("Invalid probe JSON structure")
        for mount in entry["mounts"]:
            if not isinstance(mount, dict) or any(type(mount.get(field)) is not str for field in ("target", "source", "fstype")) or any(type(mount.get(field)) is not bool for field in ("rw", "local", "ssd", "data_exists")) or type(mount.get("available_bytes")) is not int:
                fail("Invalid probe mount structure")
        if entry.get("node_ip") != expected:
            fail("Probe address mismatch")
        if entry.get("architecture") not in ("aarch64", "x86_64"):
            fail("Initial setup requires ARM64 (aarch64) or AMD64 (x86_64) nodes")
        if "debian" not in [entry.get("os_id"), *entry.get("os_like", "").split()] and entry.get("os_id") != "armbian":
            fail("Initial setup requires Debian based Linux nodes")
        if entry.get("docker_compose") is not True or entry.get("watchdog") is not True or entry.get("systemd_watchdog_usec") != 0:
            fail("Docker Compose or an unused hardware watchdog is unavailable")
        if entry.get("deployment_exists") is not False or entry.get("vip_in_use") is not False:
            fail("Existing deployment or occupied VIP; this wizard only prepares an empty cluster")
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,32}", entry.get("interface", "")):
            fail("Invalid detected network interface")
        net = ipaddress.IPv4Network(entry["network"], strict=True)
        if entry.get("prefix") != net.prefixlen or ipaddress.IPv4Address(vip) not in net or ipaddress.IPv4Address(expected) not in net:
            fail("Nodes and VIP must share the detected subnet")
        if any(ipaddress.IPv4Address(value) in (net.network_address, net.broadcast_address) for value in (vip, expected)):
            fail("Nodes and VIP cannot use the subnet or broadcast address")
        ipv4(entry["controller_ip"])
        if not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", entry.get("keepalived_version", "")):
            fail("Invalid Keepalived package version")
        discoveries.append(entry)
    if len({entry["architecture"] for entry in discoveries}) != 1:
        fail("All nodes must use the same architecture; mixed ARM64 and AMD64 clusters are unsupported")
    for field in ("prefix", "network", "controller_ip", "keepalived_version"):
        if len({entry[field] for entry in discoveries}) != 1:
            fail("Nodes disagree on " + field + "; configure manually")
    common = None
    for entry in discoveries:
        usable = set()
        for mount in entry.get("mounts", []):
            target = mount.get("target", "")
            if not re.fullmatch(r"/[A-Za-z0-9_./-]+", target) or ".." in Path(target).parts or target in ("/", "/boot", "/usr", "/var", "/home", "/etc", "/tmp"):
                continue
            if all(mount.get(field) is True for field in ("rw", "local", "ssd")) and mount.get("data_exists") is False and mount.get("fstype") in ("ext4", "xfs", "btrfs") and type(mount.get("available_bytes")) is int and mount["available_bytes"] >= 20 * 1024**3:
                usable.add(target)
        common = usable if common is None else common & usable
    if not common:
        fail("No common writable local SSD mount with at least 20 GiB free and no cluster data")
    metadata = {"nodes": discoveries, "mounts": sorted(common), "vip": vip, "user": user,
                "core_indices": core_indices, "etcd_nonstandard_members_confirmed": nonstandard}
    (stage / "metadata.json").write_text(json.dumps(metadata))
    print("Detected node architecture:", discoveries[0]["architecture"], file=sys.stderr)
    print("Detected network:", discoveries[0]["network"], file=sys.stderr)
    print("Controller management address:", discoveries[0]["controller_ip"], file=sys.stderr)
    print("Keepalived package:", discoveries[0]["keepalived_version"], file=sys.stderr)
    print("Common qualifying SSD mounts:", ", ".join(sorted(common)), file=sys.stderr)


def render(stage, mount, cidr, postgres, tools, key_host):
    import yaml  # Remote probes deliberately need only the Python standard library.

    metadata = json.loads((stage / "metadata.json").read_text())
    if mount not in metadata["mounts"]:
        fail("SSD mount was not qualified on all nodes")
    client_network = ipaddress.IPv4Network(cidr, strict=True)
    client = str(client_network)
    if client == "0.0.0.0/0" or any(client_network.overlaps(ipaddress.IPv4Network(block)) for block in ("127.0.0.0/8", "224.0.0.0/4")):
        fail("Client access must use a restricted network")
    image(tools, local=True)
    if postgres:
        image(postgres)
    if key_host and (not key_host.startswith("/") or any(c in key_host for c in ",\t\r\n\x00")):
        fail("SSH key host path must be absolute and contain no commas or control characters")
    nodes = metadata["nodes"]
    variables = {"ansible_user": metadata["user"], "ansible_become": metadata["user"] != "root",
                 "cluster_name": "one-postgres-ha", "deployment_root": "/opt/one-postgres-ha",
                 "deployment_environment": "production", "expected_architecture": nodes[0]["architecture"],
                 "postgres_image_mode": "prebuilt" if postgres else "source", "postgres_ha_image": postgres,
                 "vip_address": metadata["vip"], "vip_prefix": nodes[0]["prefix"], "vip_router_id": 51,
                 "vip_reserved": True, "keepalived_package_version": nodes[0]["keepalived_version"],
                 "etcd_nonstandard_members_confirmed": metadata["etcd_nonstandard_members_confirmed"],
                 "admin_cidrs": [nodes[0]["controller_ip"] + "/32"], "client_cidrs": [client],
                 "minimum_data_free_gib": 20, "backup_target": {"enabled": False}}
    if not key_host:
        variables["ansible_password"] = "{{ lookup('ansible.builtin.file', private_dir + '/secrets/ssh-password') }}"
    hosts = {}
    for index, node in enumerate(nodes, 1):
        name = f"armbian-{index:02d}"
        hosts[name] = {"ansible_host": node["node_ip"], "node_ip": node["node_ip"], "node_name": name,
                       "data_mount": mount, "data_root": mount.rstrip("/") + "/one-postgres-ha",
                       "network_interface": node["interface"]}
    core_names = {f"armbian-{index:02d}" for index in metadata["core_indices"]}
    inventory = {"all": {"vars": variables, "children": {"pg_nodes": {"children": {
        "core_nodes": {"hosts": {name: host for name, host in hosts.items() if name in core_names}},
        "replica_nodes": {"hosts": {name: host for name, host in hosts.items() if name not in core_names}}}}}}}
    (stage / "inventory.yml").write_text(yaml.safe_dump(inventory, sort_keys=False, allow_unicode=True))
    env = "HA_TOOLS_IMAGE=" + tools + "\n"
    if key_host:
        env += "HA_SSH_KEY=" + key_host + "\n"
    (stage / "controller.env").write_text(env)


def publish(root, stage):
    def interrupted(_signum, _frame):
        raise InterruptedError("Configuration publication interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    private = check_fresh(root)
    names = ["known_hosts", "controller.env"]
    if (stage / "ssh-password").exists():
        names.append("secrets/ssh-password")
    names.append("inventory.yml")  # Publish the usable inventory only after its supporting files.
    created = []
    made_secrets = False
    try:
        if "secrets/ssh-password" in names:
            secrets = private / "secrets"
            if not secrets.exists():
                secrets.mkdir(mode=0o700)
                made_secrets = True
            secure_directory(secrets)
            secrets.chmod(0o700)
        for name in names:
            source = stage / Path(name).name
            target = private / name
            if source.is_symlink() or not source.is_file() or source.stat().st_nlink != 1:
                fail("Unsafe staged configuration")
            source.chmod(0o600)
            os.link(source, target, follow_symlinks=False)  # Refuses existing destinations.
            created.append((target, source.stat().st_ino))
    except BaseException:
        for target, inode in reversed(created):
            if target.is_file() and not target.is_symlink() and target.stat().st_ino == inode:
                target.unlink()
        if made_secrets:
            (private / "secrets").rmdir()
        raise


def main():
    command, *args = sys.argv[1:]
    if command == "--probe":
        print(json.dumps(probe(*args)))
    elif command == "ipv4":
        print(ipv4(*args))
    elif command == "user":
        print(username(*args))
    elif command == "voters-default":
        print(" ".join(map(str, default_voters(int(args[0])))))
    elif command == "voters":
        print(" ".join(map(str, voter_indices(int(args[0]), args[1]))))
    elif command == "fresh":
        check_fresh(Path(args[0]).absolute())
    elif command == "collect":
        collect(Path(args[0]), args[1], args[2], args[3:])
    elif command == "field":
        metadata = json.loads((Path(args[0]) / "metadata.json").read_text())
        if args[1] == "mount_default":
            print(metadata["mounts"][0] if len(metadata["mounts"]) == 1 else "")
        elif args[1] == "network":
            print(metadata["nodes"][0]["network"])
        elif args[1] == "architecture":
            print(metadata["nodes"][0]["architecture"])
    elif command == "render":
        render(Path(args[0]), *args[1:])
    elif command == "publish":
        publish(Path(args[0]).absolute(), Path(args[1]))
    else:
        fail("Unknown configure helper operation")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(2)
