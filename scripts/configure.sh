#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
HELPER="$ROOT/scripts/configure.py"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
if [[ "${1:-}" == --help && $# -eq 1 ]]; then
  printf '%s\n' 'Usage: bash ops.sh configure' \
    'Prepare at least three ARM64 or AMD64 PostgreSQL nodes interactively; more nodes are optional.' \
    'Review etcd voters; default is the largest odd count up to seven. Overrides require confirmation.' \
    'All nodes must use the same architecture; discovery selects the inventory value.' \
    'No deployment, disk changes, database passwords or certificates are created.' \
    'Existing inventory, known_hosts, controller.env or secrets are never overwritten.'
  exit 0
fi
[[ $# -eq 0 ]] || die 'configure accepts only --help'
for tool in python3 ssh ssh-keyscan ssh-keygen; do
  command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
python3 "$HELPER" fresh "$ROOT"
STAGE=$(mktemp -d "$ROOT/.local/configure.XXXXXXXX")
cleanup() { rm -rf -- "$STAGE"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
prompt() {
  local message=$1 default=${2:-}
  printf '%s' "$message" >&2
  [[ -z "$default" ]] || printf ' [%s]' "$default" >&2
  printf ': ' >&2
  IFS= read -r ANSWER || die 'Configuration cancelled'
  [[ -n "$ANSWER" ]] || ANSWER=$default
}
nodes=()
add_address() {
  local ip existing
  ip=$(python3 "$HELPER" ipv4 "$ANSWER")
  for existing in "${nodes[@]}"; do [[ $ip != "$existing" ]] || die 'Node addresses must be different'; done
  nodes+=("$ip")
}
for number in 1 2 3; do
  prompt "$(printf 'Node %02d IPv4' "$number")"
  add_address
done
number=4
while true; do
  prompt "$(printf 'Node %02d IPv4 (optional; blank to finish) -- 可选节点，留空结束' "$number")"
  if [[ -z $ANSWER ]]; then
    while true; do
      prompt 'Stop adding nodes? (yes/no) -- 是否停止添加节点？' no
      case "${ANSWER,,}" in
        y|yes) finished=true; break ;;
        n|no) finished=false; break ;;
        *) printf 'Enter yes or no -- 请输入 yes 或 no。\n' >&2 ;;
      esac
    done
    [[ $finished != true ]] || break
    continue
  fi
  add_address
  number=$((number + 1))
done

voters_default=$(python3 "$HELPER" voters-default "${#nodes[@]}")
while true; do
  printf '\nEntered PostgreSQL nodes -- 已填写的 PostgreSQL 节点：\n' >&2
  for index in "${!nodes[@]}"; do printf '  %02d  %s\n' "$((index + 1))" "${nodes[$index]}" >&2; done
  prompt 'Etcd voting node numbers (spaces/commas) -- etcd 仲裁节点编号（空格或逗号分隔）' "$voters_default"
  voters=$(python3 "$HELPER" voters "${#nodes[@]}" "$ANSWER")
  read -r -a voter_numbers <<<"$voters"
  voter_count=${#voter_numbers[@]}
  quorum=$((voter_count / 2 + 1))
  tolerance=$((voter_count - quorum))
  printf 'Etcd voters -- 仲裁节点：%s\nQuorum -- 最少存活：%s；Failure tolerance -- 可容忍成员故障：%s\n' \
    "$voters" "$quorum" "$tolerance" >&2
  printf 'Selected core nodes also provide HAProxy and the VIP -- 选中的核心节点同时提供代理与 VIP。\n' >&2
  nonstandard=false
  if ((voter_count % 2 == 0 || voter_count > 7)); then
    nonstandard=true
    printf 'Recommended etcd voter counts are 3, 5 or 7 -- 推荐 3、5 或 7 台仲裁；当前选择需要额外确认。\n' >&2
  fi
  prompt 'Use these etcd voting nodes? (yes/no) -- 是否采用上述仲裁节点？' yes
  case "${ANSWER,,}" in
    y|yes) ;;
    n|no) voters_default=$voters; continue ;;
    *) die 'Etcd membership confirmation must be yes or no' ;;
  esac
  if [[ $nonstandard == true ]]; then
    prompt 'Type FORCE-ETCD to accept this nonstandard voting group -- 输入 FORCE-ETCD 确认采用非推荐数量'
    [[ $ANSWER == FORCE-ETCD ]] || die 'Nonstandard etcd membership was not confirmed'
    printf 'FORCE-ETCD\n' >"$STAGE/etcd-force-confirmation"
  fi
  printf '%s\n' "$voters" >"$STAGE/core-node-indices"
  break
done
prompt 'VIP IPv4'
vip=$(python3 "$HELPER" ipv4 "$ANSWER")
for ip in "${nodes[@]}"; do [[ $vip != "$ip" ]] || die 'Node addresses and VIP must be different'; done
prompt 'SSH user (non-root requires passwordless sudo)' root
user=$(python3 "$HELPER" user "$ANSWER")
printf '\nCompare these fingerprints with ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on each node console.\n' >&2
for ip in "${nodes[@]}"; do
  ssh-keyscan -T 5 -t ed25519 "$ip" >"$STAGE/key-$ip" 2>/dev/null || die "Cannot obtain SSH key from $ip"
  awk -v host="$ip" 'NF != 3 || $1 != host || $2 != "ssh-ed25519" {exit 1} END {if (NR != 1) exit 1}' "$STAGE/key-$ip" \
    || die "Unexpected SSH key response from $ip"
  printf '%s: ' "$ip" >&2
  ssh-keygen -lf "$STAGE/key-$ip" >&2 || die "Invalid SSH public key from $ip"
  cat "$STAGE/key-$ip" >>"$STAGE/known_hosts"
done
prompt 'After independently checking every fingerprint, type VERIFY'
[[ "$ANSWER" == VERIFY ]] || die 'SSH trust verification was not confirmed'
SSH=(ssh -T -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$STAGE/known_hosts"
  -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ConnectionAttempts=1
  -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o LogLevel=ERROR)
key_host=''
if [[ -n "${HA_CONFIGURE_KEY_PATH:-}" ]]; then
  [[ -f "$HA_CONFIGURE_KEY_PATH" && -s "$HA_CONFIGURE_KEY_PATH" && ! -L "$HA_CONFIGURE_KEY_PATH" ]] || die 'SSH key must be a nonempty regular file'
  key_host=${HA_CONFIGURE_KEY_HOST_PATH:-}
  [[ -n "$key_host" ]] || die 'SSH key host path is required for persistence'
  SSH+=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$HA_CONFIGURE_KEY_PATH")
else
  command -v sshpass >/dev/null || die 'sshpass is required for SSH password authentication'
  unset password confirmation
  printf 'Shared SSH password (input hidden): ' >&2
  IFS= read -rs password || die 'Configuration cancelled'
  printf '\nConfirm SSH password: ' >&2
  IFS= read -rs confirmation || die 'Configuration cancelled'
  printf '\n' >&2
  [[ -n "$password" && "$password" == "$confirmation" ]] || die 'SSH passwords are empty or differ'
  printf '%s\n' "$password" >"$STAGE/ssh-password"
  unset password confirmation
  SSH=(sshpass -f "$STAGE/ssh-password" "${SSH[@]}" -o BatchMode=no
    -o 'PreferredAuthentications=password,keyboard-interactive' -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1)
fi
printf '\nInspecting nodes through authenticated SSH (read-only).\n' >&2
for index in "${!nodes[@]}"; do
  ip=${nodes[$index]}
  if [[ "$user" == root ]]; then
    remote="python3 - --probe $ip $vip"
  else
    # Pass SSH source metadata without requiring sudo to preserve environment variables.
    remote="sudo -n python3 - --probe $ip $vip \"\$SSH_CONNECTION\""
  fi
  "${SSH[@]}" "$user@$ip" "$remote" <"$HELPER" >"$STAGE/node$((index + 1)).json" \
    || die "Read-only probe failed on $ip; nothing was saved"
done
python3 "$HELPER" collect "$STAGE" "$vip" "$user" "${nodes[@]}"
architecture=$(python3 "$HELPER" field "$STAGE" architecture)
mount_default=$(python3 "$HELPER" field "$STAGE" mount_default)
prompt 'Shared SSD mount' "$mount_default"
mount=$ANSWER
printf 'Verify that %s is unused and reserved outside the DHCP allocation range. A failed ping alone does not prove this.\n' "$vip" >&2
prompt 'Type RESERVED after checking the VIP reservation'
[[ "$ANSWER" == RESERVED ]] || die 'VIP reservation was not confirmed'
network=$(python3 "$HELPER" field "$STAGE" network)
prompt 'Client IPv4 CIDR' "$network"
cidr=$ANSWER
prompt 'PostgreSQL image (empty builds from pinned source; otherwise registry@sha256:digest)'
postgres=$ANSWER
prompt 'Tools image (project local tag or registry@sha256:digest)' "${HA_CONFIGURE_TOOLS_IMAGE:-one-postgres-ha-tools:pg17.11}"
tools=$ANSWER
python3 "$HELPER" render "$STAGE" "$mount" "$cidr" "$postgres" "$tools" "$key_host"
printf '\nConfiguration summary -- 配置摘要：\n  PostgreSQL nodes -- 节点总数：%s\n' "${#nodes[@]}" >&2
for index in "${!nodes[@]}"; do
  role='PG replica -- PG 副本'
  if [[ " $voters " == *" $((index + 1)) "* ]]; then role='etcd/core -- 仲裁与入口核心'; fi
  printf '  %02d  %s  %s\n' "$((index + 1))" "${nodes[$index]}" "$role" >&2
done
printf '  Etcd voters: %s; quorum: %s; tolerated failures: %s\n  Architecture: %s\n  VIP: %s\n  SSD: %s\n  SSH user: %s\n  Clients: %s\n  PostgreSQL image: %s\n  Tools image: %s\n  Backups: disabled\n' \
  "$voters" "$quorum" "$tolerance" "$architecture" "$vip" "$mount" "$user" "$cidr" "${postgres:-build from pinned source}" "$tools" >&2
prompt 'Type SAVE to write new private configuration'
[[ "$ANSWER" == SAVE ]] || die 'Configuration cancelled; nothing was saved'
python3 "$HELPER" publish "$ROOT" "$STAGE"
printf 'CONFIGURE_COMPLETE: private configuration saved in .local/.\nNext: bash install.sh.\n'
