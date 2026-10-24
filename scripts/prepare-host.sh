#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/versions.lock"
die() { printf 'prepare-host: %s\n' "$1" >&2; exit 2; }
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf 'Usage: bash scripts/prepare-host.sh SSD_MOUNT [--plan|--apply]\nDefault: read-only plan. Debian 13 AMD64 or ARM64; never partitions or formats disks.\n'
  exit 0
fi
[[ $# -ge 1 && $# -le 2 ]] || die 'Expected an explicit SSD mount path and optional --plan or --apply'
MODE=${2:---plan}
[[ "$MODE" == --plan || "$MODE" == --apply ]] || die 'Expected --plan or --apply'
[[ -r /etc/os-release ]] || die 'Run this script on the target Debian host'
source /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 && ${VERSION_CODENAME:-} == trixie ]] || die 'Only Debian 13 Trixie is supported'
ARCHITECTURE=$(dpkg --print-architecture)
case "$ARCHITECTURE" in
  amd64 | arm64) ;;
  *) die 'Only AMD64 and ARM64 host packages are supported' ;;
esac
for tool in findmnt lsblk realpath systemctl; do command -v "$tool" >/dev/null || die "Missing $tool"; done
SSD=$(realpath -e -- "$1")
[[ "$SSD" != / && "$SSD" =~ ^/[a-zA-Z0-9_/-]+$ ]] || die 'Use an absolute SSD mount path with simple directory names'
findmnt --mountpoint "$SSD" >/dev/null || die 'The supplied directory is not a filesystem mount point'
DEVICE=$(findmnt -nr -o SOURCE --mountpoint "$SSD")
DEVICE=${DEVICE%%\[*}
[[ -b "$DEVICE" ]] || die 'The mount must be backed by a local block device'
FSTYPE=$(findmnt -nr -o FSTYPE --mountpoint "$SSD")
case "$FSTYPE" in ext4 | xfs | btrfs) ;; *) die 'Use an existing ext4, XFS or Btrfs SSD filesystem' ;; esac
[[ $(findmnt -nr -o OPTIONS --mountpoint "$SSD") =~ (^|,)rw(,|$) ]] || die 'The SSD filesystem is read-only'
rotation=$(lsblk -sn -o ROTA "$DEVICE")
[[ -n "$rotation" && -z $(grep -v '^[[:space:]]*0[[:space:]]*$' <<<"$rotation") ]] || die 'The backing device does not report SSD/non-rotational storage'
device_names=$(lsblk -sn -o KNAME "$DEVICE")
! grep -Eq '^[[:space:]]*mmcblk' <<<"$device_names" || die 'MMC/eMMC storage is not an SSD target'

DOCKER_ROOT="$SSD/docker"
CONTAINERD_ROOT="$SSD/containerd"
STATE=/etc/one-postgres-ha-host.state
DOCKER_CONFIG=/etc/docker/daemon.json
CONTAINERD_CONFIG=/etc/containerd/config.toml
REPO=/etc/apt/sources.list.d/docker.sources
KEY=/etc/apt/keyrings/docker.asc
MARKER=$(printf 'one-postgres-ha-host-v1\n%s\n%s' "$DOCKER_ROOT" "$CONTAINERD_ROOT")
DOCKER_JSON=$(printf '{"data-root":"%s","log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' "$DOCKER_ROOT")
CONTAINERD_TOML=$(printf 'version = 3\nroot = "%s"\nstate = "/run/containerd"' "$CONTAINERD_ROOT")
REPO_TEXT=$(printf 'Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: trixie\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc' "$ARCHITECTURE")
SYSTEMD_UNIT_ROOT=/etc/systemd/system
check_mount_dependencies() {
  local service directory file root expected entry firewall_expected
  firewall_expected=$'# Managed by one-postgres-ha.\n[Unit]\nRequires=one-postgres-ha-firewall.service\nAfter=one-postgres-ha-firewall.service'
  for service in docker containerd; do
    directory="$SYSTEMD_UNIT_ROOT/$service.service.d"
    file="$directory/20-one-postgres-ha-ssd.conf"
    root="$SSD/$service"
    expected=$(printf '# Managed by one-postgres-ha.\n[Unit]\nRequiresMountsFor=%s' "$root")
    [[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] || die 'Refusing a systemd drop-in directory symlink or non-directory'
    for entry in "$directory"/*.conf; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      [[ -f "$entry" && ! -L "$entry" ]] || die 'An unknown Docker/containerd systemd drop-in requires manual review'
      if [[ "$entry" == "$file" && $(<"$entry") == "$expected" ]]; then
        continue
      fi
      [[ "$service" == docker && "$entry" == "$directory/30-one-postgres-ha-firewall.conf" && $(<"$entry") == "$firewall_expected" ]] || die 'An unknown Docker/containerd systemd drop-in requires manual review'
    done
  done
}
install_mount_dependencies() {
  local service directory file root expected temporary changed=false
  for service in docker containerd; do
    directory="$SYSTEMD_UNIT_ROOT/$service.service.d"
    file="$directory/20-one-postgres-ha-ssd.conf"
    root="$SSD/$service"
    expected=$(printf '# Managed by one-postgres-ha.\n[Unit]\nRequiresMountsFor=%s' "$root")
    if [[ ! -f "$file" ]]; then
      install -d -m 0755 "$directory"
      temporary=$(mktemp "$directory/.one-postgres-ha-mount.XXXXXXXX")
      printf '%s\n' "$expected" >"$temporary"
      chmod 0644 "$temporary"
      mv -T -- "$temporary" "$file"
      changed=true
    fi
  done
  [[ "$changed" != true ]] || systemctl daemon-reload
}
verify_mount_dependencies() {
  local service mounts
  for service in docker containerd; do
    mounts=$(systemctl show --property=RequiresMountsFor --value "$service.service")
    [[ " $mounts " == *" $SSD/$service "* ]] || die 'The Docker/containerd SSD mount dependency was not loaded'
  done
}
check_mount_dependencies
OWNED=false
if [[ -e "$STATE" ]]; then
  [[ ! -L "$STATE" && $(<"$STATE") == "$MARKER" ]] || die 'The preparation marker belongs to another path or installation'
  OWNED=true
fi
for directory in /etc/docker /etc/containerd /etc/apt/keyrings; do
  [[ ! -L "$directory" ]] || die 'Refusing a configuration directory symlink'
done
for config in "$DOCKER_CONFIG" "$CONTAINERD_CONFIG" "$REPO" "$KEY"; do
  [[ ! -L "$config" ]] || die 'Refusing a configuration symlink'
  [[ ! -e "$config" || "$OWNED" == true ]] || die 'Existing unmanaged Docker/containerd configuration requires manual review'
done
[[ ! -e /etc/apt/sources.list.d/docker.list ]] || die 'An existing Docker apt source requires manual review'
if [[ "$OWNED" == true ]]; then
  [[ ! -e "$DOCKER_CONFIG" || $(<"$DOCKER_CONFIG") == "$DOCKER_JSON" ]] || die 'Docker configuration differs from the managed configuration'
  [[ ! -e "$CONTAINERD_CONFIG" || $(<"$CONTAINERD_CONFIG") == "$CONTAINERD_TOML" ]] || die 'containerd configuration differs from the managed configuration'
  [[ ! -e "$REPO" || $(<"$REPO") == "$REPO_TEXT" ]] || die 'Docker apt configuration differs from the managed configuration'
else
  ! command -v docker >/dev/null || die 'Existing Docker installations are not migrated automatically'
  ! command -v containerd >/dev/null || die 'Existing containerd installations are not migrated automatically'
fi
for directory in /var/lib/docker /var/lib/containerd "$DOCKER_ROOT" "$CONTAINERD_ROOT"; do
  [[ ! -L "$directory" ]] || die 'Refusing a Docker/containerd data symlink'
  [[ ! -e "$directory" || -d "$directory" ]] || die 'The data path already exists as a non-directory'
  if [[ -d "$directory" && -n $(find "$directory" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    [[ "$OWNED" == true && "$directory" == "$SSD/"* ]] || die 'Existing Docker/containerd data is never migrated or overwritten automatically'
  fi
done
for package in docker.io docker-compose docker-buildx podman-docker containerd runc; do
  [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true) != installed ]] || die "Conflicting package $package needs manual review"
done
PACKAGES=("docker-ce=$HOST_DOCKER_ENGINE_DEBIAN13" "docker-ce-cli=$HOST_DOCKER_ENGINE_DEBIAN13"
  "containerd.io=$HOST_CONTAINERD_DEBIAN13" "docker-buildx-plugin=$HOST_BUILDX_DEBIAN13" "docker-compose-plugin=$HOST_COMPOSE_DEBIAN13")
for spec in "${PACKAGES[@]}"; do
  installed=$(dpkg-query -W -f='${Version}' "${spec%%=*}" 2>/dev/null || true)
  [[ -z "$installed" || "$installed" == "${spec#*=}" ]] || die 'Existing Docker package versions differ; upgrades and downgrades require manual review'
done
printf 'Host package architecture: %s\nDocker data root: %s\ncontainerd data root: %s\nPinned packages: %s\n' "$ARCHITECTURE" "$DOCKER_ROOT" "$CONTAINERD_ROOT" "${PACKAGES[*]}"
[[ "$MODE" == --apply ]] || { printf 'PLAN_ONLY: no files, services, network or disks changed.\n'; exit 0; }
[[ $(id -u) == 0 ]] || die '--apply requires root'
if [[ "$OWNED" == true ]] && running_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null); then
  [[ "$running_root" == "$DOCKER_ROOT" ]] || die 'Running Docker uses an unexpected data root; stop for manual review'
  install_mount_dependencies
  verify_mount_dependencies
  printf 'ALREADY_PREPARED: managed Docker is running on the SSD.\n'; exit 0
fi

# Prevent package post-install scripts from starting either daemon on the eMMC.
systemctl mask docker.service docker.socket containerd.service
install -d -m 0755 /etc/docker /etc/containerd /etc/apt/keyrings
install -d -m 0711 "$DOCKER_ROOT" "$CONTAINERD_ROOT"
printf '%s\n' "$MARKER" >"$STATE"
printf '%s\n' "$DOCKER_JSON" >"$DOCKER_CONFIG"
printf '%s\n' "$CONTAINERD_TOML" >"$CONTAINERD_CONFIG"
chmod 0600 "$STATE" "$DOCKER_CONFIG" "$CONTAINERD_CONFIG"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg python3 iproute2 psmisc iptables
key_file=$(mktemp)
trap 'rm -f -- "$key_file"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/debian/gpg -o "$key_file"
key_details=$(gpg --batch --show-keys --with-colons "$key_file")
fingerprint=$(awk -F: '$1=="fpr" {print $10; exit}' <<<"$key_details")
[[ "$fingerprint" == "$HOST_DOCKER_GPG_FINGERPRINT" ]] || die 'Docker apt signing key fingerprint does not match the pinned key'
install -m 0644 "$key_file" "$KEY"
printf '%s\n' "$REPO_TEXT" >"$REPO"
chmod 0644 "$REPO"
apt-get update
apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends "${PACKAGES[@]}"
[[ $(<"$DOCKER_CONFIG") == "$DOCKER_JSON" && $(<"$CONTAINERD_CONFIG") == "$CONTAINERD_TOML" ]] || die 'The package installation replaced a managed configuration; daemons remain masked'
install_mount_dependencies
systemctl unmask containerd.service docker.service docker.socket
verify_mount_dependencies
systemctl enable --now containerd.service docker.service
[[ $(docker info --format '{{.DockerRootDir}}') == "$DOCKER_ROOT" ]] || die 'Docker did not use the required SSD data root'
containerd_config=$(containerd config dump)
grep -Fxq "root = '$CONTAINERD_ROOT'" <<<"$containerd_config" || grep -Fxq "root = \"$CONTAINERD_ROOT\"" <<<"$containerd_config" || die 'containerd root verification failed'
docker compose version
printf 'HOST_PREPARED: Docker and containerd use the SSD; watchdog and disk layout unchanged.\n'
