#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# This laboratory has no host ports and explicitly disables watchdog. It never uses site inventory.
source "$ROOT/config/versions.env"
IMAGE=${HA_TEST_IMAGE:-$POSTGRES_HA_IMAGE}
PLATFORM_ARGS=()
if [[ -n ${HA_TEST_PLATFORM:-} ]]; then
  case "$HA_TEST_PLATFORM" in linux/amd64 | linux/arm64) ;; *) echo 'Unsupported test platform' >&2; exit 2 ;; esac
  PLATFORM_ARGS=(--platform "$HA_TEST_PLATFORM")
fi
PREFIX="ha-it-$(date +%s)-$$"
NETWORK="$PREFIX-network"
WORK="$ROOT/.local/integration/$PREFIX"
mkdir -p "$WORK/secrets" "$WORK/config"
# These directories are mount roots for different container UIDs; WORK remains private.
chmod 755 "$WORK/secrets" "$WORK/config"
for command_name in docker openssl; do command -v "$command_name" >/dev/null || { echo "Missing $command_name" >&2; exit 2; }; done

# Git Bash supports the same script as Linux; keep container paths unchanged for docker.exe.
docker() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command docker "$@"; }
openssl() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command openssl "$@"; }
host_path() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
CONFIG=$(host_path "$WORK/config")
SECRETS=$(host_path "$WORK/secrets")
CONTAINERS=()
VOLUMES=()
cleanup() {
  local result=$?
  trap - EXIT
  if ((result != 0)); then
    for container in "${CONTAINERS[@]}"; do
      docker logs "$container" >"$WORK/$container.log" 2>&1 || true
      diagnostic=$(docker inspect --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' "$container" 2>&1 || true)
      diagnostic+=$'\n'$(tail -c 8192 "$WORK/$container.log" | tail -n 25)
      for credential_file in "$WORK"/secrets/*-password; do
        [[ -f "$credential_file" ]] || continue
        password=$(<"$credential_file")
        [[ -z "$password" ]] || diagnostic=${diagnostic//"$password"/[REDACTED]}
      done
      printf 'Diagnostic %s:\n%s\n' "$container" "${diagnostic:0:8192}" >&2
    done
    printf 'Integration failed; local evidence: %s\n' "$WORK" >&2
  fi
  for container in "${CONTAINERS[@]}"; do docker rm -fv "$container" >/dev/null 2>&1 || true; done
  for volume in "${VOLUMES[@]}"; do docker volume rm "$volume" >/dev/null 2>&1 || true; done
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
note() { printf 'PASS: %s\n' "$1"; }
retry() {
  local attempt
  for ((attempt = 0; attempt < 120; attempt++)); do if "$@"; then return 0; fi; sleep 2; done
  printf 'Timed out: %s\n' "$1" >&2; return 1
}
sql() { docker exec -i "$1" /usr/local/bin/pg-admin psql -X -q -A -t -v ON_ERROR_STOP=1 -d postgres "${@:2}"; }
primary() {
  local number candidate count=0 selected=''
  for number in 1 2 3 4; do
    candidate="$PREFIX-pg$number"
    if docker exec "$candidate" curl -fsS --max-time 2 http://127.0.0.1:8008/primary >/dev/null 2>&1; then selected=$candidate; count=$((count + 1)); fi
  done
  [[ $count == 1 ]] && printf '%s\n' "$selected"
}
cluster_ready() {
  local leader
  leader=$(primary) || return 1
  [[ $(sql "$leader" -c "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND sync_state='sync';" 2>/dev/null) == 1 ]] || return 1
  [[ $(sql "$leader" -c "SELECT count(*) FROM pg_stat_replication WHERE state='streaming';" 2>/dev/null) -ge 2 ]]
}
replica_ready() { docker exec "$PREFIX-pg$1" curl -fsS --max-time 2 http://127.0.0.1:8008/replica >/dev/null 2>&1; }
failover_candidate_ready() {
  local candidate sync_state
  candidate=$(sql "$LEADER" -c "SELECT application_name FROM pg_stat_replication WHERE state='streaming' AND sync_state='sync' LIMIT 1;" 2>/dev/null) || return 1
  [[ "$candidate" =~ ^pg[1-4]$ && "$READY_REPLAY_LSN" =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || return 1
  sync_state=$(docker exec "$PREFIX-etcd1" /usr/local/bin/etcdctl --endpoints="https://$PREFIX-etcd1:2379" \
    --cacert=/run/secrets/ca.crt --cert=/run/secrets/etcd.crt --key=/run/secrets/etcd.key \
    get "/one-postgres-ha-integration/$PREFIX/sync" --print-value-only 2>/dev/null) || return 1
  grep -Eq "\"leader\"[[:space:]]*:[[:space:]]*\"${LEADER##*-}\"" <<<"$sync_state" || return 1
  grep -Eq "\"sync_standby\"[[:space:]]*:[[:space:]]*\"$candidate\"" <<<"$sync_state" || return 1
  [[ $(sql "$PREFIX-$candidate" -c "SELECT pg_last_wal_replay_lsn() >= '$READY_REPLAY_LSN'::pg_lsn;" 2>/dev/null) == t ]] || return 1
  SYNC_READY_MEMBER=$candidate
  printf '%s\n' "$sync_state" >"$WORK/failover-sync-state.json"
}
create_volume() {
  local volume=$1 owner=$2
  docker volume create "$volume" >/dev/null
  VOLUMES+=("$volume")
  docker run --rm "${PLATFORM_ARGS[@]}" --user 0 --entrypoint chown --mount "type=volume,src=$volume,dst=/data" "$IMAGE" "$owner:$owner" /data
}

for credential in postgres-password replication-password rewind-password patroni-api-password reader-password; do openssl rand -hex 24 | tr -d '\r' >"$WORK/secrets/$credential"; done
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -subj /CN=ha-integration-ca \
  -keyout "$SECRETS/ca.key" -out "$SECRETS/ca.crt" >"$WORK/openssl.log" 2>&1
cat >"$WORK/secrets/extensions" <<EOF
subjectAltName=DNS:$PREFIX-etcd1,DNS:$PREFIX-etcd2,DNS:$PREFIX-etcd3,IP:127.0.0.1
extendedKeyUsage=serverAuth,clientAuth
keyUsage=digitalSignature,keyEncipherment
EOF
openssl req -new -newkey rsa:2048 -nodes -subj /CN=ha-integration-member \
  -keyout "$SECRETS/etcd.key" -out "$SECRETS/member.csr" >>"$WORK/openssl.log" 2>&1
openssl x509 -req -sha256 -days 2 -in "$SECRETS/member.csr" -CA "$SECRETS/ca.crt" \
  -CAkey "$SECRETS/ca.key" -CAcreateserial -extfile "$SECRETS/extensions" \
  -out "$SECRETS/etcd.crt" >>"$WORK/openssl.log" 2>&1
cp "$WORK/secrets/etcd.crt" "$WORK/secrets/patroni.crt"
cp "$WORK/secrets/etcd.key" "$WORK/secrets/patroni.key"
chmod 644 "$WORK/secrets/"{ca.crt,etcd.crt,etcd.key,patroni.crt,patroni.key,*-password}
docker image inspect "$IMAGE" >/dev/null
docker network create --internal "$NETWORK" >/dev/null

for number in 1 2 3; do
  cat >"$WORK/config/etcd$number.yml" <<EOF
name: etcd$number
data-dir: /etcd-data
listen-client-urls: https://0.0.0.0:2379
advertise-client-urls: https://$PREFIX-etcd$number:2379
listen-peer-urls: https://0.0.0.0:2380
initial-advertise-peer-urls: https://$PREFIX-etcd$number:2380
initial-cluster: etcd1=https://$PREFIX-etcd1:2380,etcd2=https://$PREFIX-etcd2:2380,etcd3=https://$PREFIX-etcd3:2380
initial-cluster-state: new
initial-cluster-token: $PREFIX
client-transport-security:
  cert-file: /run/secrets/etcd.crt
  key-file: /run/secrets/etcd.key
  client-cert-auth: true
  trusted-ca-file: /run/secrets/ca.crt
peer-transport-security:
  cert-file: /run/secrets/etcd.crt
  key-file: /run/secrets/etcd.key
  client-cert-auth: true
  trusted-ca-file: /run/secrets/ca.crt
quota-backend-bytes: 67108864
log-level: warn
EOF
  chmod 644 "$WORK/config/etcd$number.yml"
  create_volume "$PREFIX-etcd$number-data" 65532
  CONTAINERS+=("$PREFIX-etcd$number")
  docker run -d "${PLATFORM_ARGS[@]}" --name "$PREFIX-etcd$number" --network "$NETWORK" --user 65532:65532 \
    --read-only --cap-drop ALL --security-opt no-new-privileges --memory 256m --cpus 0.5 \
    --mount "type=volume,src=$PREFIX-etcd$number-data,dst=/etcd-data" \
    --mount "type=bind,src=$CONFIG,dst=/config,readonly" --mount "type=bind,src=$SECRETS,dst=/run/secrets,readonly" \
    --entrypoint /usr/local/bin/etcd "$ETCD_IMAGE" --config-file="/config/etcd$number.yml" >/dev/null
done
etcd_ready() {
  docker exec "$PREFIX-etcd1" /usr/local/bin/etcdctl --endpoints="https://$PREFIX-etcd1:2379,https://$PREFIX-etcd2:2379,https://$PREFIX-etcd3:2379" \
    --cacert=/run/secrets/ca.crt --cert=/run/secrets/etcd.crt --key=/run/secrets/etcd.key endpoint health >/dev/null 2>&1
}
retry etcd_ready
note 'three-member etcd quorum with client and peer TLS'
if docker exec "$PREFIX-etcd1" /usr/local/bin/etcdctl --endpoints="https://$PREFIX-etcd1:2379" --cacert=/run/secrets/ca.crt --dial-timeout=2s --command-timeout=3s endpoint health >/dev/null 2>&1; then echo 'etcd accepted an unauthenticated client' >&2; exit 1; fi
note 'etcd rejects clients without a certificate'

write_pg_config() {
  local number=$1 nofailover=$2 sync_priority=${3:-1}
  cat >"$WORK/config/pg$number.yml" <<EOF
scope: $PREFIX
namespace: /one-postgres-ha-integration/
name: pg$number
restapi:
  listen: 0.0.0.0:8008
  connect_address: $PREFIX-pg$number:8008
  authentication:
    username: admin
ctl:
  authentication:
    username: admin
etcd3:
  hosts: $PREFIX-etcd1:2379,$PREFIX-etcd2:2379,$PREFIX-etcd3:2379
  protocol: https
  cacert: /run/secrets/ca.crt
  cert: /run/secrets/patroni.crt
  key: /run/secrets/patroni.key
bootstrap:
  dcs:
    ttl: 20
    loop_wait: 3
    retry_timeout: 3
    check_timeline: true
    synchronous_mode: true
    synchronous_mode_strict: true
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        shared_buffers: 256MB
        work_mem: 4MB
        maintenance_work_mem: 64MB
        max_connections: 100
        synchronous_commit: "on"
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        max_slot_wal_keep_size: 2GB
  initdb:
    - data-checksums
    - auth-local: scram-sha-256
    - auth-host: scram-sha-256
postgresql:
  listen: 0.0.0.0:5433
  connect_address: $PREFIX-pg$number:5433
  data_dir: /var/lib/postgresql/data
  pgpass: /run/patroni/pgpass
  authentication:
    superuser: {username: postgres}
    replication: {username: replicator}
    rewind: {username: rewind_user}
  parameters:
    unix_socket_directories: /run/postgresql
  pg_hba:
    - local all all scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256
    - host replication replicator 0.0.0.0/0 scram-sha-256
  use_pg_rewind: true
  remove_data_directory_on_rewind_failure: false
  remove_data_directory_on_diverged_timelines: false
watchdog:
  mode: "off" # Explicitly a Docker-only test; production is required.
tags:
  nofailover: $nofailover
  nosync: $nofailover
  sync_priority: $sync_priority
EOF
  chmod 644 "$WORK/config/pg$number.yml"
}
start_pg() {
  local number=$1
  create_volume "$PREFIX-pg$number-data" 999
  CONTAINERS+=("$PREFIX-pg$number")
  docker run -d "${PLATFORM_ARGS[@]}" --init --name "$PREFIX-pg$number" --network "$NETWORK" --user 999:999 \
    --read-only --cap-drop ALL --security-opt no-new-privileges --memory 1536m --cpus 2 --shm-size 256m \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m,uid=999,gid=999,mode=1770 \
    --tmpfs /run/postgresql:rw,noexec,nosuid,size=16m,uid=999,gid=999,mode=0770 \
    --tmpfs /run/patroni:rw,noexec,nosuid,size=16m,uid=999,gid=999,mode=0700 \
    --mount "type=volume,src=$PREFIX-pg$number-data,dst=/var/lib/postgresql/data" \
    --mount "type=bind,src=$CONFIG,dst=/config,readonly" --mount "type=bind,src=$SECRETS,dst=/run/secrets,readonly" \
    -e "PATRONI_CONFIG_FILE=/config/pg$number.yml" "$IMAGE" patroni "/config/pg$number.yml" >/dev/null
}
for number in 1 2 3; do write_pg_config "$number" false; start_pg "$number"; done
retry cluster_ready
LEADER=$(primary)
[[ $(sql "$LEADER" -c 'SHOW data_checksums;') == on ]]
[[ $(docker exec "$LEADER" id -u) == 999 ]]
note 'one primary, two streaming replicas, strict synchronous commit, checksums and uid 999'
reader_password=$(<"$WORK/secrets/reader-password")
sql "$LEADER" <<EOF
CREATE EXTENSION pg_trgm;
CREATE TABLE ha_test(id integer PRIMARY KEY, value text NOT NULL);
INSERT INTO ha_test VALUES (1, 'confirmed-before-switchover');
CREATE ROLE integration_reader LOGIN PASSWORD '$reader_password';
GRANT SELECT ON ha_test TO integration_reader;
EOF
docker exec "$LEADER" bash -c 'PGPASSWORD=$(</run/secrets/reader-password); export PGPASSWORD; psql -h127.0.0.1 -p5433 -Uintegration_reader -dpostgres -XAt -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM ha_test;"' >"$WORK/reader-result"
[[ $(<"$WORK/reader-result") == 1 ]]
if docker exec "$LEADER" bash -c 'PGPASSWORD=$(</run/secrets/reader-password); export PGPASSWORD; psql -h127.0.0.1 -p5433 -Uintegration_reader -dpostgres -XAt -v ON_ERROR_STOP=1 -c "INSERT INTO ha_test VALUES(99, '\''forbidden'\'');"' >"$WORK/reader-denied" 2>&1; then echo 'Readonly role wrote data' >&2; exit 1; fi
grep -q 'permission denied' "$WORK/reader-denied"
note 'actual password-authenticated readonly role can read and cannot write'

write_proxy() {
  local maximum=$1 number
  cat >"$WORK/config/haproxy.cfg" <<EOF
global
  log stdout format raw local0
  maxconn 300
defaults
  mode tcp
  timeout connect 5s
  timeout client 30m
  timeout server 30m
  timeout check 3s
frontend postgres_write
  bind :5432
  default_backend postgres_primary
backend postgres_primary
  option httpchk GET /primary
  http-check expect status 200
  default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
EOF
  for ((number = 1; number <= maximum; number++)); do printf '  server pg%s %s-pg%s:5433 check port 8008\n' "$number" "$PREFIX" "$number" >>"$WORK/config/haproxy.cfg"; done
  chmod 644 "$WORK/config/haproxy.cfg"
}
write_proxy 3
CONTAINERS+=("$PREFIX-haproxy")
docker run -d "${PLATFORM_ARGS[@]}" --name "$PREFIX-haproxy" --network "$NETWORK" --user 99:99 --read-only \
  --cap-drop ALL --security-opt no-new-privileges --memory 64m --cpus 0.25 \
  --mount "type=bind,src=$CONFIG,dst=/config,readonly" "$HAPROXY_IMAGE" haproxy -W -db -f /config/haproxy.cfg >/dev/null
proxy_ready() { [[ $(sql "$LEADER" -h "$PREFIX-haproxy" -p5432 -c 'SELECT pg_is_in_recovery();' 2>/dev/null) == f ]]; }
retry proxy_ready
READY_REPLAY_LSN=$(sql "$LEADER" -c 'SELECT pg_current_wal_lsn();')
retry failover_candidate_ready
SYNC=$SYNC_READY_MEMBER
docker exec "$LEADER" /usr/local/bin/patroni-entrypoint patronictl -c "/config/${LEADER##*-}.yml" \
  switchover --leader "${LEADER##*-}" --candidate "$SYNC" --force >/dev/null
new_primary() { local now; now=$(primary) && [[ $now != "$LEADER" ]]; }
retry new_primary
LEADER=$(primary)
retry cluster_ready
retry proxy_ready
sql "$LEADER" -h "$PREFIX-haproxy" -p5432 -c "INSERT INTO ha_test VALUES (2, 'confirmed-after-switchover');" >/dev/null
note 'controlled synchronous switchover and HAProxy routes to the new primary'

REPLICAS=()
for number in 1 2 3; do [[ "$PREFIX-pg$number" == "$LEADER" ]] || REPLICAS+=("$PREFIX-pg$number"); done
docker stop -t 30 "${REPLICAS[@]}" >/dev/null
strict_waiting() { [[ $(sql "$LEADER" -c "SELECT count(*) FROM pg_stat_activity WHERE wait_event='SyncRep';" 2>/dev/null) -ge 1 ]]; }
docker exec "$LEADER" timeout 60 /usr/local/bin/pg-admin psql -X -q -v ON_ERROR_STOP=1 -dpostgres \
  -c "INSERT INTO ha_test VALUES (3, 'confirmed-after-sync-recovery');" >"$WORK/blocked-write" 2>&1 &
BLOCKED_PID=$!
retry strict_waiting
kill -0 "$BLOCKED_PID"
note 'strict synchronous write waits when both replicas are unavailable'
docker start "${REPLICAS[@]}" >/dev/null
wait "$BLOCKED_PID"
retry cluster_ready
note 'waiting write completes after synchronous replica recovery'

# PostgreSQL can acknowledge the recovered standby before Patroni publishes /sync.
READY_REPLAY_LSN=$(sql "$LEADER" -c 'SELECT pg_current_wal_lsn();')
retry failover_candidate_ready
note 'recovered synchronous standby is recorded in DCS and has replayed confirmed WAL'
OLD_PRIMARY=$LEADER
docker kill "$OLD_PRIMARY" >/dev/null
failover_ready() { local now; now=$(primary) && [[ $now != "$OLD_PRIMARY" ]]; }
retry failover_ready
LEADER=$(primary)
[[ $(sql "$LEADER" -c 'SELECT count(*) FROM ha_test;') == 3 ]]
retry proxy_ready
sql "$LEADER" -h "$PREFIX-haproxy" -p5432 -c "INSERT INTO ha_test VALUES (4, 'confirmed-after-primary-failure');" >/dev/null
docker start "$OLD_PRIMARY" >/dev/null
retry cluster_ready
note 'primary SIGKILL failover preserves confirmed data; previous primary rejoins'
docker stop -t 10 "$PREFIX-etcd1" >/dev/null
sql "$LEADER" -c "INSERT INTO ha_test VALUES (5, 'confirmed-with-etcd-member-offline');" >/dev/null
docker start "$PREFIX-etcd1" >/dev/null
retry etcd_ready
note 'one etcd member failure preserves database writes'

write_pg_config 4 true
start_pg 4
retry replica_ready 4
new_replica_has_data() { [[ $(sql "$PREFIX-pg4" -c 'SELECT count(*) FROM ha_test;' 2>/dev/null) == 5 ]]; }
retry new_replica_has_data
docker exec "$PREFIX-pg4" curl -fsS http://127.0.0.1:8008/patroni >"$WORK/new-node-quarantined.json"
grep -Eq '"nofailover"[[:space:]]*:[[:space:]]*true' "$WORK/new-node-quarantined.json"
grep -Eq '"nosync"[[:space:]]*:[[:space:]]*true' "$WORK/new-node-quarantined.json"
write_proxy 4
docker kill --signal SIGUSR2 "$PREFIX-haproxy" >/dev/null
retry proxy_ready
# Prefer this node as sync standby only in the laboratory to exercise promotion through the proxy.
write_pg_config 4 false 10
docker kill --signal HUP "$PREFIX-pg4" >/dev/null
note 'fourth replica joins online; proxy reload happens before promotion eligibility'
new_node_is_sync() { [[ $(sql "$LEADER" -c "SELECT application_name FROM pg_stat_replication WHERE sync_state='sync' LIMIT 1;" 2>/dev/null) == pg4 ]]; }
retry new_node_is_sync
READY_REPLAY_LSN=$(sql "$LEADER" -c 'SELECT pg_current_wal_lsn();')
retry failover_candidate_ready
[[ "$SYNC_READY_MEMBER" == pg4 ]]
docker exec "$LEADER" /usr/local/bin/patroni-entrypoint patronictl -c "/config/${LEADER##*-}.yml" \
  switchover --leader "${LEADER##*-}" --candidate pg4 --force >/dev/null
fourth_is_primary() { [[ $(primary) == "$PREFIX-pg4" ]]; }
retry fourth_is_primary
LEADER=$(primary)
retry cluster_ready
retry proxy_ready
sql "$LEADER" -h "$PREFIX-haproxy" -p5432 -c "INSERT INTO ha_test VALUES (6, 'confirmed-after-new-node-promotion');" >/dev/null
note 'new node can become synchronous primary and remains reachable through the proxy'
for container in "${CONTAINERS[@]}"; do
  docker logs "$container" >"$WORK/$container.log" 2>&1
  while IFS= read -r password_file; do
    password=$(<"$password_file")
    if grep -Fq -- "$password" "$WORK/$container.log"; then echo 'Credential found in service logs' >&2; exit 1; fi
  done < <(find "$WORK/secrets" -name '*-password' -type f)
  [[ $(docker inspect --format '{{.State.OOMKilled}}' "$container") == false ]]
done
docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' "${CONTAINERS[@]}" >"$WORK/resources.txt"
note 'no test credential appears in logs; no OOM under configured limits'
printf 'integration=passed\nplatform=%s\nwatchdog=disabled-for-test\nvrRP=not-tested\n' "$(docker image inspect --format '{{.Architecture}}' "$IMAGE")" >"$WORK/result.txt"
printf 'PASS: integration complete. Evidence: %s\n' "$WORK"
