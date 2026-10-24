#!/usr/bin/env python3
"""Exercise the actual remote discovery code without host or network access."""

from contextlib import ExitStack
import copy
import importlib.util
import json
from pathlib import Path
import stat
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("configure_probe_helper", ROOT / "scripts/configure.py")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


def disk(path, partition, *, rotational=False):
    return {"path": path, "type": "disk", "rota": rotational, "pkname": None,
            "children": [{"path": partition, "type": "part", "rota": rotational,
                          "pkname": path}]}


def mount(source, target, *, options="rw,relatime", filesystem="ext4"):
    return {"source": source, "target": target, "fstype": filesystem, "options": options}


class HostFixture:
    """Only the discovery commands below can execute inside the mocked host."""

    def __init__(self):
        self.addresses = [{"ifname": "eth0", "addr_info": [
            {"family": "inet", "local": "192.0.2.11", "prefixlen": 24},
            {"family": "inet6", "local": "fe80::11", "prefixlen": 64}]}]
        self.architecture = "aarch64"
        self.blocks = {"blockdevices": [disk("/dev/sda", "/dev/sda1")]}
        self.mounts = {"filesystems": [mount("/dev/sda1", "/mnt/ssd")]}
        self.connection = "192.0.2.5 49152 192.0.2.11 22"
        self.watchdog_exists = True
        self.watchdog_mode = stat.S_IFCHR | 0o660
        self.holder_status = 1
        self.runtime_watchdog = "0"
        self.compose_status = 0
        self.keepalived_candidate = "1:2.3.3-1"
        self.ping_available = True
        self.ping_status = 1
        self.containers = ""
        self.existing_paths = set()
        self.calls = []
        self.statvfs_calls = []

    def command(self, args, **kwargs):
        args = tuple(args)
        self.calls.append((args, kwargs))
        self.assert_process_options(kwargs)
        commands = {
            ("ip", "-j", "address", "show"): (0, json.dumps(self.addresses)),
            ("fuser", "/dev/watchdog"): (self.holder_status, ""),
            ("systemctl", "show", "--property=RuntimeWatchdogUSec", "--value"):
                (0, self.runtime_watchdog),
            ("docker", "compose", "version"): (self.compose_status, "Docker Compose version fixture"),
            ("apt-cache", "policy", "keepalived"):
                (0, "keepalived:\n  Installed: (none)\n  Candidate: " + self.keepalived_candidate + "\n"),
            ("lsblk", "--json", "--paths", "--tree", "--output", "PATH,TYPE,ROTA,PKNAME"):
                (0, json.dumps(self.blocks)),
            ("findmnt", "--json", "--list", "--output", "SOURCE,TARGET,FSTYPE,OPTIONS"):
                (0, json.dumps(self.mounts)),
            ("ping", "-n", "-c", "1", "-W", "1", "192.0.2.20"):
                (self.ping_status, ""),
            ("docker", "ps", "-a", "--filter", "label=com.docker.compose.project=one-postgres-ha",
             "--format", "{{.ID}}"):
                (0, self.containers),
        }
        if args not in commands:
            raise AssertionError("Unexpected or mutating discovery command: " + repr(args))
        status, output = commands[args]
        return SimpleNamespace(returncode=status, stdout=output, stderr="")

    @staticmethod
    def assert_process_options(kwargs):
        if (kwargs.get("capture_output") is not True or kwargs.get("text") is not True
                or kwargs.get("check") is not False or kwargs.get("timeout", 0) <= 0
                or kwargs.get("timeout", 0) > 30 or kwargs.get("shell", False)):
            raise AssertionError("Discovery subprocess is unbounded or invokes a shell")

    def read_text(self, path, *args, **kwargs):
        if path.as_posix() != "/etc/os-release":
            raise AssertionError("Unexpected discovery file read: " + path.as_posix())
        return 'ID=debian\nID_LIKE="debian"\nVERSION_ID="13"\n'

    def exists(self, path):
        if path.as_posix() != "/dev/watchdog":
            raise AssertionError("Unexpected discovery existence check: " + path.as_posix())
        return self.watchdog_exists

    def file_stat(self, path, *args, **kwargs):
        if path.as_posix() != "/dev/watchdog":
            raise AssertionError("Unexpected discovery stat: " + path.as_posix())
        return SimpleNamespace(st_mode=self.watchdog_mode)

    def statvfs(self, path):
        self.statvfs_calls.append(path)
        if path not in {entry["target"] for entry in self.mounts["filesystems"]}:
            raise AssertionError("Unexpected filesystem discovery: " + str(path))
        return SimpleNamespace(f_bavail=25 * 1024**2, f_frsize=1024)

    def lexists(self, path):
        return str(path).replace("\\", "/") in self.existing_paths

    def execute(self, *, connection=None):
        with ExitStack() as patches:
            patches.enter_context(mock.patch.object(HELPER.subprocess, "run", side_effect=self.command))
            patches.enter_context(mock.patch.object(HELPER.Path, "read_text", autospec=True,
                                                    side_effect=self.read_text))
            patches.enter_context(mock.patch.object(HELPER.Path, "exists", autospec=True,
                                                    side_effect=self.exists))
            patches.enter_context(mock.patch.object(HELPER.Path, "stat", autospec=True,
                                                    side_effect=self.file_stat))
            patches.enter_context(mock.patch.object(HELPER.os, "statvfs", create=True,
                                                    side_effect=self.statvfs))
            patches.enter_context(mock.patch.object(HELPER.os.path, "lexists", side_effect=self.lexists))
            patches.enter_context(mock.patch.object(HELPER.platform, "machine", return_value=self.architecture))
            patches.enter_context(mock.patch.object(HELPER.shutil, "which",
                                                    return_value="/usr/bin/ping" if self.ping_available else None))
            patches.enter_context(mock.patch.dict(HELPER.os.environ,
                                                  {"SSH_CONNECTION": self.connection}, clear=True))
            for name in ("write_text", "write_bytes", "mkdir", "chmod", "unlink"):
                patches.enter_context(mock.patch.object(HELPER.Path, name,
                                                        side_effect=AssertionError("Discovery wrote host files")))
            return HELPER.probe("192.0.2.11", "192.0.2.20", connection)


class ProbeTests(unittest.TestCase):
    def test_reports_each_host_architecture_without_using_controller_architecture(self):
        for architecture in ("aarch64", "x86_64", "riscv64"):
            with self.subTest(architecture=architecture):
                host = HostFixture()
                host.architecture = architecture
                self.assertEqual(host.execute()["architecture"], architecture)

    def test_partition_on_ssd_reports_network_source_and_available_space(self):
        host = HostFixture()
        result = host.execute()
        self.assertEqual((result["interface"], result["network"], result["prefix"]),
                         ("eth0", "192.0.2.0/24", 24))
        self.assertEqual(result["controller_ip"], "192.0.2.5")
        self.assertEqual(result["keepalived_version"], "1:2.3.3-1")
        self.assertTrue(result["watchdog"])
        self.assertTrue(result["mounts"][0]["ssd"])
        self.assertEqual(result["mounts"][0]["available_bytes"], 25 * 1024**3)
        self.assertFalse(result["deployment_exists"])
        self.assertFalse(result["vip_in_use"])

    def test_explicit_ssh_source_survives_sudo_environment_removal(self):
        host = HostFixture()
        host.connection = ""
        result = host.execute(connection="198.51.100.5 49153 192.0.2.11 22")
        self.assertEqual(result["controller_ip"], "198.51.100.5")

    def test_missing_ssh_source_fails_before_storage_or_docker_inspection(self):
        host = HostFixture()
        host.connection = ""
        with self.assertRaisesRegex(ValueError, "SSH_CONNECTION"):
            host.execute()
        self.assertEqual([args[0] for args, _ in host.calls], ["ip"])

    def test_node_address_must_identify_one_interface(self):
        host = HostFixture()
        host.addresses.append(copy.deepcopy(host.addresses[0]))
        host.addresses[1]["ifname"] = "eth1"
        with self.assertRaisesRegex(ValueError, "exactly one interface"):
            host.execute()

    def test_nested_lvm_on_ssd_is_recognized(self):
        host = HostFixture()
        parent = disk("/dev/nvme0n1", "/dev/nvme0n1p2")
        parent["children"][0]["children"] = [{"path": "/dev/mapper/vg-data", "type": "lvm",
                                                "rota": False, "pkname": "/dev/nvme0n1p2"}]
        host.blocks = {"blockdevices": [parent]}
        host.mounts = {"filesystems": [mount("/dev/mapper/vg-data", "/mnt/ssd")]}
        self.assertTrue(host.execute()["mounts"][0]["ssd"])

    def test_mmc_is_rejected_even_when_nonrotational(self):
        host = HostFixture()
        host.blocks = {"blockdevices": [disk("/dev/mmcblk0", "/dev/mmcblk0p1")]}
        host.mounts = {"filesystems": [mount("/dev/mmcblk0p1", "/mnt/emmc")]}
        self.assertFalse(host.execute()["mounts"][0]["ssd"])

    def test_mixed_raid_backing_cannot_be_qualified_by_last_ssd_parent(self):
        host = HostFixture()
        for first_path, first_partition, rotational in (
                ("/dev/sdb", "/dev/sdb1", True),
                ("/dev/mmcblk0", "/dev/mmcblk0p1", False)):
            with self.subTest(backing=first_path):
                members = [disk(first_path, first_partition, rotational=rotational),
                           disk("/dev/sda", "/dev/sda1")]
                for member in members:
                    partition = member["children"][0]
                    partition["children"] = [{"path": "/dev/md0", "type": "raid1", "rota": False,
                                               "pkname": partition["path"]}]
                host.blocks = {"blockdevices": members}
                host.mounts = {"filesystems": [mount("/dev/md0", "/mnt/ssd")]}
                self.assertFalse(host.execute()["mounts"][0]["ssd"],
                                 "Every backing disk must be a non-MMC SSD")

    def test_only_supported_local_mounts_are_inspected(self):
        host = HostFixture()
        host.mounts = {"filesystems": [
            mount("/dev/sda1", "/"), mount("server:/share", "/mnt/network", filesystem="nfs"),
            mount("/dev/sda1", "/mnt/unsupported", filesystem="vfat"),
            mount("/dev/sda1[/subvolume]", "/mnt/ssd", filesystem="btrfs"),
            mount("/dev/sda1", "/mnt/readonly", options="ro,relatime")]}
        result = host.execute()
        self.assertEqual(host.statvfs_calls, ["/mnt/ssd", "/mnt/readonly"])
        self.assertTrue(result["mounts"][0]["ssd"])
        self.assertFalse(result["mounts"][1]["rw"])

    def test_unknown_block_source_is_not_assumed_to_be_ssd(self):
        host = HostFixture()
        host.mounts = {"filesystems": [mount("/dev/mapper/unknown", "/mnt/ssd")]}
        self.assertFalse(host.execute()["mounts"][0]["ssd"])

    def test_existing_data_and_container_state_are_retained_in_discovery(self):
        host = HostFixture()
        host.existing_paths.add("/mnt/ssd/one-postgres-ha")
        host.containers = "fixture-id"
        result = host.execute()
        self.assertTrue(result["mounts"][0]["data_exists"])
        self.assertTrue(result["deployment_exists"])

    def test_watchdog_holder_prevents_empty_cluster_qualification(self):
        host = HostFixture()
        host.holder_status = 0
        self.assertFalse(host.execute()["watchdog"])

    def test_watchdog_owner_query_error_fails_closed(self):
        host = HostFixture()
        host.holder_status = 2
        with self.assertRaisesRegex(ValueError, "watchdog ownership"):
            host.execute()

    def test_missing_or_regular_watchdog_is_never_opened_or_queried(self):
        for missing in (True, False):
            with self.subTest(missing=missing):
                host = HostFixture()
                host.watchdog_exists = not missing
                host.watchdog_mode = stat.S_IFREG | 0o660
                self.assertFalse(host.execute()["watchdog"])
                self.assertFalse(any(args[0] == "fuser" for args, _ in host.calls))

    def test_active_systemd_runtime_watchdog_fails_closed(self):
        host = HostFixture()
        host.runtime_watchdog = "30s"
        with self.assertRaisesRegex(ValueError, "systemd runtime watchdog"):
            host.execute()

    def test_missing_ping_does_not_skip_local_vip_occupancy_detection(self):
        host = HostFixture()
        host.ping_available = False
        host.addresses[0]["addr_info"].append(
            {"family": "inet", "local": "192.0.2.20", "prefixlen": 24})
        self.assertTrue(host.execute()["vip_in_use"])
        self.assertFalse(any(args[0] == "ping" for args, _ in host.calls))

    def test_ping_response_marks_vip_occupied_and_ping_error_fails(self):
        host = HostFixture()
        host.ping_status = 0
        self.assertTrue(host.execute()["vip_in_use"])
        host.ping_status = 2
        with self.assertRaisesRegex(ValueError, "VIP reachability"):
            host.execute()

    def test_missing_compose_and_package_candidate_are_not_success(self):
        host = HostFixture()
        host.compose_status = 1
        self.assertFalse(host.execute()["docker_compose"])
        host.keepalived_candidate = "(none)"
        with self.assertRaisesRegex(ValueError, "Keepalived package candidate"):
            host.execute()

    def test_probe_executes_bounded_readonly_argv_without_a_shell(self):
        host = HostFixture()
        host.execute()
        self.assertGreater(len(host.calls), 5)
        self.assertEqual({args[0] for args, _ in host.calls},
                         {"ip", "fuser", "systemctl", "docker", "apt-cache", "lsblk", "findmnt", "ping"})
        for _, kwargs in host.calls:
            self.assertFalse(kwargs.get("shell", False))


if __name__ == "__main__":
    unittest.main(verbosity=2)
