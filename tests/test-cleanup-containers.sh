#!/usr/bin/env bash
# Real Docker/Compose/storage; host services, SSD metadata and watchdog are fixtures.
set -Eeuo pipefail
docker() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command docker "$@"; }
host_path() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
die() {
  printf 'cleanup-containers: %s\n' "$*" >&2
  exit 1
}

if [[ ${1:-} != --inside ]]; then
  [[ $# == 0 ]] || die 'This test takes no arguments'
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  [[ -f "$ROOT/scripts/cleanup-node.sh" ]] || die 'The cleanup backend is missing'
  ENDPOINT=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}' "$(docker context show)")}
  case "$ENDPOINT" in unix://* | npipe://*) ;; *) die 'Use a local Docker daemon; remote contexts are refused' ;; esac
  [[ $(docker info --format '{{.OSType}}') == linux ]] || die 'Linux containers are required'
  RUNID="ha-cleanup-$(date +%s)-$$"
  VOLUME="$RUNID-storage"
  CANARY_VOLUME="$RUNID-canary-volume"
  CONTROLLER="$RUNID-controller"
  RUN_IMAGE="$RUNID-tools"
  LEGACY_IMAGE="$RUNID-legacy-postgres"
  TOOLS_IMAGE=${HA_TOOLS_IMAGE:-one-postgres-ha-tools:pg17.11}
  mkdir -p "$ROOT/.local/reports"
  WORK=$(mktemp -d "$ROOT/.local/cleanup-containers.XXXXXXXX")
  cleanup() {
    local result=$? cid name image
    trap - EXIT
    docker cp "$CONTROLLER:$LAB/postgres-volumes.list" "$(host_path "$WORK/postgres-volumes.list")" >/dev/null 2>&1 || true
    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      docker rm -fv "$cid" >/dev/null 2>&1 || true
    done < <(docker ps --all --quiet --filter "label=ha.cleanup.fixture=$RUNID" 2>/dev/null)
    docker network rm "$RUNID-default" >/dev/null 2>&1 || true
    for name in "$CANARY_VOLUME" "$VOLUME"; do docker volume rm "$name" >/dev/null 2>&1 || true; done
    if [[ -f "$WORK/postgres-volumes.list" ]]; then
      while IFS= read -r name; do
        [[ "$name" =~ ^[0-9a-f]{64}$ ]] || continue
        docker volume rm "$name" >/dev/null 2>&1 || true
      done < <(sort -u "$WORK/postgres-volumes.list")
    fi
    for image in "$RUN_IMAGE" "$LEGACY_IMAGE"; do docker image rm "$image" >/dev/null 2>&1 || true; done
    exit "$result"
  }
  LAB=/not-created
  trap cleanup EXIT
  docker image inspect "$TOOLS_IMAGE" >/dev/null || die 'Build the tools image first: bash ops.sh tools'
  PG_IMAGE=$(sed -n 's/^POSTGRES_BASE_IMAGE=//p' "$ROOT/versions.lock")
  ETCD_IMAGE=$(sed -n 's/^ETCD_IMAGE=//p' "$ROOT/versions.lock")
  HAPROXY_IMAGE=$(sed -n 's/^HAPROXY_IMAGE=//p' "$ROOT/versions.lock")
  for image in "$PG_IMAGE" "$ETCD_IMAGE" "$HAPROXY_IMAGE"; do
    docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >"$WORK/pull.log" 2>&1
  done
  docker image inspect --format '{{json .Config.Volumes}}' "$PG_IMAGE" | python3 -c 'import json,sys; assert json.load(sys.stdin)=={"/var/lib/postgresql/data":{}}, "PG17 must declare its PGDATA volume, not a parent volume"'
  # A separate image models the legacy inherited parent-volume exception.
  # The real PG17 baseline above must not acquire that volume merely to pass cleanup.
  cat >"$WORK/LegacyPostgres.Dockerfile" <<'DOCKERFILE'
ARG PG_IMAGE
FROM ${PG_IMAGE}
VOLUME ["/var/lib/postgresql"]
DOCKERFILE
  if ! docker build --build-arg "PG_IMAGE=$PG_IMAGE" --file "$(host_path "$WORK/LegacyPostgres.Dockerfile")" \
    -t "$LEGACY_IMAGE" "$(host_path "$WORK")" >"$WORK/legacy-build.log" 2>&1; then
    tail -n 40 "$WORK/legacy-build.log"
    die 'Isolated legacy-volume fixture build failed'
  fi
  cp "$ROOT/scripts/ci/install-compose.sh" "$WORK/install-compose.sh"
  cat >"$WORK/Dockerfile" <<'DOCKERFILE'
ARG TOOLS_IMAGE=one-postgres-ha-tools:pg17.11
FROM docker:29.7.2-cli@sha256:3f4743208d2338c934d7b8bcfbe1bb54c0b2355c510ad5e0f31c0c4a54bd704e AS cli
FROM ${TOOLS_IMAGE}
COPY --from=cli /usr/local/bin/docker /usr/local/bin/docker
COPY install-compose.sh /tmp/install-compose.sh
RUN bash /tmp/install-compose.sh && rm /tmp/install-compose.sh
DOCKERFILE
  if ! docker build --build-arg "TOOLS_IMAGE=$TOOLS_IMAGE" -t "$RUN_IMAGE" "$(host_path "$WORK")" >"$WORK/build.log" 2>&1; then
    tail -n 40 "$WORK/build.log"
    die 'Isolated Docker CLI tooling build failed'
  fi
  docker volume create --label "ha.cleanup.fixture=$RUNID" "$VOLUME" >/dev/null
  docker volume create --label "ha.cleanup.fixture=$RUNID" "$CANARY_VOLUME" >/dev/null
  LAB=$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME")
  [[ "$LAB" == /* && "$LAB" != / && "$LAB" == */"$VOLUME"/_data ]] || die 'Unexpected fixture volume mountpoint'
  CONTROLLER_ID=$(docker run -d --name "$CONTROLLER" --label "ha.cleanup.fixture=$RUNID" \
    --network none --read-only --cap-drop ALL --cap-add MKNOD --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --tmpfs /tmp:rw,exec,nosuid,size=64m --tmpfs /run/lock:rw,nosuid,size=1m \
    --mount "type=volume,src=$VOLUME,dst=$LAB" \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
    -e LAB="$LAB" -e PROJECT="$RUNID" -e CANARY_VOLUME="$CANARY_VOLUME" \
    -e PG_IMAGE="$PG_IMAGE" -e LEGACY_PG_IMAGE="$LEGACY_IMAGE" -e ETCD_IMAGE="$ETCD_IMAGE" -e HAPROXY_IMAGE="$HAPROXY_IMAGE" \
    "$RUN_IMAGE" sleep 900)
  docker cp "$(host_path "$ROOT/scripts/cleanup-node.sh")" "$CONTROLLER:$LAB/original-helper.sh"
  docker cp "$(host_path "${BASH_SOURCE[0]}")" "$CONTROLLER:$LAB/test.sh"
  result=0
  docker exec -e CONTROLLER_ID="$CONTROLLER_ID" "$CONTROLLER" bash "$LAB/test.sh" --inside 2>&1 | tee "$WORK/runner.log" || result=$?
  docker cp "$CONTROLLER:$LAB/report.json" "$(host_path "$ROOT/.local/reports/$RUNID.json")" >/dev/null 2>&1 || true
  exit "$result"
fi

[[ $# == 1 && $(id -u) == 0 && "$PROJECT" =~ ^ha-cleanup-[0-9]+-[0-9]+$ && "$CONTROLLER_ID" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid isolated controller'
DEPLOY="$LAB/node/deploy"
DATA="$LAB/node/data"
SYSTEM="$LAB/host/etc"
NODE=lab01
CLUSTER=$PROJECT
CANARY="$PROJECT-canary"
FOREIGN="$PROJECT-foreign"
WATCHDOG="$LAB/watchdog-fixture"
mkdir -p "$LAB/bin" "$LAB/host/lock" "$SYSTEM/udev/rules.d" "$LAB/canary"
printf 'unrelated-data\n' >"$LAB/canary/proof"
mknod "$WATCHDOG" c 240 201
REAL_DOCKER=$(type -P docker)
export REAL_DOCKER LAB CONTROLLER_ID
cat >"$LAB/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'info --format {{.DockerRootDir}}' ]]; then
  printf '/simulated-host/docker\n'
elif [[ "$*" == 'ps --all --quiet --no-trunc' ]]; then
  # The controller represents the SSH host, not another project mounting its disk.
  "$REAL_DOCKER" "$@" | awk -v controller="$CONTROLLER_ID" '$0 != controller'
else
  exec "$REAL_DOCKER" "$@"
fi
MOCK
cat >"$LAB/bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == '--json --list --output TARGET,SOURCE,FSTYPE,OPTIONS' ]] || exit 90
printf '{"filesystems":[{"target":"%s","source":"/dev/fixture-ssd","fstype":"ext4","options":"rw"}]}\n' "$LAB"
MOCK
cat >"$LAB/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  'is-active --quiet one-postgres-ha-firewall.service'|'is-active --quiet keepalived.service') exit 3 ;;
  'show --property=DropInPaths --value one-postgres-ha-firewall.service') exit 0 ;;
  daemon-reload) printf 'daemon-reload\n' >>"$LAB/host-calls.log" ;;
  *) exit 90 ;;
esac
MOCK
cat >"$LAB/bin/iptables" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == '--wait 5 -S' ]] || exit 90
MOCK
cp "$LAB/bin/iptables" "$LAB/bin/ip6tables"
cat >"$LAB/bin/udevadm" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 'control --reload' ]] || exit 90
printf 'udev-reload\n' >>"$LAB/host-calls.log"
MOCK
chmod 755 "$LAB/bin/"*
export PATH="$LAB/bin:$PATH"
python3 - "$LAB/original-helper.sh" "$LAB/helper.sh" "$SYSTEM" "$LAB/host/lock" <<'PY'
import pathlib,sys
source,target,system,lock=sys.argv[1:]
text=pathlib.Path(source).read_text()
for old,new in [('SYSTEM_ROOT=/etc','SYSTEM_ROOT='+system),('LOCK_ROOT=/run/lock','LOCK_ROOT='+lock)]:
    assert text.count('\n'+old+'\n') == 1
    text=text.replace('\n'+old+'\n','\n'+new+'\n')
pathlib.Path(target).write_text(text)
PY
cleanup_node() {
  bash "$LAB/helper.sh" "$@" --deployment-root "$DEPLOY" --data-root "$DATA" --data-mount "$LAB" \
    --cluster-name "$CLUSTER" --node-name "$NODE" --node-ip 127.0.0.1 --compose-project "$PROJECT" \
    --watchdog-device "$WATCHDOG" --watchdog-gid 999 --core
}
compose() { docker compose --env-file "$DEPLOY/.env" --project-directory "$DEPLOY" -p "$PROJECT" -f "$DEPLOY/docker-compose.yml" "$@"; }
cid() { compose ps --all --quiet "$1"; }
running() { [[ $(docker inspect --format '{{.State.Running}}' "$1") == "$2" ]]; }
sql() { docker exec "$(cid postgres)" psql -X -A -t -U postgres -d postgres -c "$1"; }
etcd() { docker exec "$(cid etcd)" /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 "$@"; }
make_fixture() {
  local volume_layout=${1:-pg17}
  mkdir -p "$DEPLOY/config" "$DEPLOY/secrets" "$DATA/postgres" "$DATA/etcd"
  printf '%s\n' "$CLUSTER" >"$DEPLOY/.one-postgres-ha-cluster"
  printf '%s\n' "$CLUSTER" >"$DATA/.one-postgres-ha-cluster"
  printf 'fixture-only-password\n' >"$DEPLOY/secrets/postgres-password"
  printf 'scope: %s\nname: %s\n' "$CLUSTER" "$NODE" >"$DEPLOY/config/patroni.yml"
  printf 'SUBSYSTEM=="watchdog", KERNEL=="watchdog*", GROUP="999", MODE="0660"\nSUBSYSTEM=="misc", KERNEL=="watchdog", GROUP="999", MODE="0660"\n' >"$SYSTEM/udev/rules.d/70-one-postgres-ha-watchdog.rules"
  cat >"$DEPLOY/config/etcd.yml" <<EOF
name: $NODE
initial-cluster-token: $CLUSTER
data-dir: /etcd-data
listen-client-urls: http://127.0.0.1:2379
advertise-client-urls: http://127.0.0.1:2379
listen-peer-urls: http://127.0.0.1:2380
initial-advertise-peer-urls: http://127.0.0.1:2380
initial-cluster: $NODE=http://127.0.0.1:2380
EOF
  cat >"$DEPLOY/.env" <<EOF
COMPOSE_PROJECT_NAME=$PROJECT
NODE_NAME=$NODE
NODE_IP=127.0.0.1
COMPOSE_PROFILES=core
CONFIG_DIR=$DEPLOY/config
SECRETS_DIR=$DEPLOY/secrets
PG_DATA_DIR=$DATA/postgres
ETCD_DATA_DIR=$DATA/etcd
WATCHDOG_DEVICE=$WATCHDOG
WATCHDOG_GID=999
EOF
  cat >"$DEPLOY/docker-compose.yml" <<EOF
services:
  postgres:
    image: $PG_IMAGE
    user: "999:999"
    init: true
    restart: unless-stopped
    mem_limit: 256m
    labels: {ha.cleanup.fixture: "$PROJECT"}
    environment:
      PGDATA: /var/lib/postgresql/data
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres-password
    volumes:
      - $DEPLOY/config:/etc/one-postgres-ha:ro
      - $DEPLOY/secrets:/run/secrets:ro
      - $DATA/postgres:/var/lib/postgresql/data
  etcd:
    image: $ETCD_IMAGE
    user: "65532:65532"
    init: true
    restart: unless-stopped
    mem_limit: 128m
    labels: {ha.cleanup.fixture: "$PROJECT"}
    command: [/usr/local/bin/etcd, "--config-file=/etc/one-postgres-ha/etcd.yml"]
    volumes:
      - $DEPLOY/config:/etc/one-postgres-ha:ro
      - $DEPLOY/secrets:/run/secrets:ro
      - $DATA/etcd:/etcd-data
  haproxy:
    image: $HAPROXY_IMAGE
    init: true
    restart: unless-stopped
    mem_limit: 32m
    labels: {ha.cleanup.fixture: "$PROJECT"}
    entrypoint: [/bin/sleep, "600"]
    volumes: [$DEPLOY/config:/etc/one-postgres-ha:ro]
networks:
  default:
    name: $PROJECT-default
    internal: true
EOF
  chmod 644 "$DEPLOY/.env" "$DEPLOY/.one-postgres-ha-cluster" "$DATA/.one-postgres-ha-cluster" "$DEPLOY/config/"*
  chown 999:999 "$DATA/postgres" "$DEPLOY/secrets/postgres-password"
  chmod 700 "$DATA/postgres"
  chmod 600 "$DEPLOY/secrets/postgres-password"
  chown 65532:65532 "$DATA/etcd"
  chmod 700 "$DATA/etcd"
  compose up -d --no-build --pull never
  docker inspect "$(cid postgres)" | python3 -c 'import json,re,sys
mounts=json.load(sys.stdin)[0]["Mounts"]
volumes=[m for m in mounts if m["Type"]=="volume"]
binds=[m for m in mounts if m["Type"]=="bind" and m["Destination"]=="/var/lib/postgresql/data"]
assert len(binds)==1, "The PGDATA SSD bind must replace the PG17 image volume"
if sys.argv[1]=="pg17":
    assert not volumes, "PG17 with bound PGDATA must not create an anonymous volume"
else:
    assert sys.argv[1]=="legacy" and len(volumes)==1
    assert volumes[0]["Destination"]=="/var/lib/postgresql"
    assert re.fullmatch("[0-9a-f]{64}", volumes[0]["Name"])
    print(volumes[0]["Name"])
' "$volume_layout" >>"$LAB/postgres-volumes.list"
  local ready=false
  for ((attempt = 0; attempt < 120; attempt++)); do
    if docker exec "$(cid postgres)" pg_isready -h 127.0.0.1 -p 5432 -U postgres >/dev/null 2>&1 && etcd endpoint health >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 0.25
  done
  if [[ "$ready" != true ]]; then
    for service in postgres etcd; do docker logs --tail 30 "$(cid "$service")"; done
    die 'Isolated database initialization did not finish'
  fi
  printf 'owned-postgres-file\n' >"$DATA/postgres/cleanup-filesystem-proof"
  printf 'owned-etcd-file\n' >"$DATA/etcd/cleanup-filesystem-proof"
}
fingerprint() {
  # Running engines may checkpoint; fingerprint only immutable fixture inputs and canaries.
  {
    find "$DEPLOY" -type f -print0
    printf '%s\0' "$DATA/.one-postgres-ha-cluster" "$DATA/postgres/cleanup-filesystem-proof" "$DATA/etcd/cleanup-filesystem-proof"
  } | sort -z | xargs -0 sha256sum | sha256sum
}
stop_and_remove() {
  cleanup_node stop-ingress --apply
  running "$(cid haproxy)" false
  running "$(cid postgres)" true
  running "$(cid etcd)" true
  cleanup_node stop-postgres --apply
  running "$(cid postgres)" false
  running "$(cid etcd)" true
  cleanup_node stop-etcd --apply
  running "$(cid etcd)" false
  cleanup_node remove --apply
  [[ ! -e "$DEPLOY" && ! -e "$DATA" ]]
  [[ ! -e "$SYSTEM/udev/rules.d/70-one-postgres-ha-watchdog.rules" ]]
  [[ -z $(docker ps --all --quiet --filter "label=com.docker.compose.project=$PROJECT") ]]
  running "$CANARY" true
  [[ $(docker inspect --format '{{.Id}}' "$CANARY") == "$CANARY_ID" ]]
  [[ $(docker exec "$CANARY" cat /canary/proof) == unrelated-data ]]
  docker volume inspect "$CANARY_VOLUME" >/dev/null
  while IFS= read -r parent_volume; do docker volume inspect "$parent_volume" >/dev/null; done <"$LAB/postgres-volumes.list"
}
make_fixture
[[ ! -s "$LAB/postgres-volumes.list" ]]
[[ $(sql 'SHOW server_version_num') =~ ^17[0-9]{4}$ ]]
docker run -d --name "$CANARY" --label "ha.cleanup.fixture=$PROJECT" --network none --init \
  --mount "type=bind,src=$LAB/canary,dst=/canary,readonly" --mount "type=volume,src=$CANARY_VOLUME,dst=/canary-volume" \
  --entrypoint /bin/sleep "$HAPROXY_IMAGE" 600 >/dev/null
CANARY_ID=$(docker inspect --format '{{.Id}}' "$CANARY")
FIRST_CIDS=$(compose ps --all --quiet)
FIRST_PG_CID=$(cid postgres)
FIRST_ETCD_CID=$(cid etcd)
FIRST_PROXY_CID=$(cid haproxy)
FIRST_PG=$(sql 'SELECT system_identifier FROM pg_control_system()')
FIRST_ETCD=$(etcd endpoint status --write-out=json | python3 -c 'import json,sys; h=json.load(sys.stdin)[0]["Status"]["header"]; print(h["cluster_id"],h["member_id"])')
sql "CREATE TABLE cleanup_proof(value text); INSERT INTO cleanup_proof VALUES ('old');" >/dev/null
etcd put /cleanup-proof old >/dev/null
etcd put "/service/$CLUSTER/initialize" "$FIRST_PG" >/dev/null
FIRST_REVISION=$(etcd endpoint status --write-out=json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["Status"]["header"]["revision"])')
FIRST_POLICIES=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$FIRST_PG_CID" "$FIRST_ETCD_CID" "$FIRST_PROXY_CID")
BEFORE=$(fingerprint)
cleanup_node audit >"$LAB/preview.json"
cleanup_node audit >"$LAB/preview-repeat.json"
[[ $(fingerprint) == "$BEFORE" && $(compose ps --all --quiet) == "$FIRST_CIDS" ]]
[[ $(sql 'SELECT value FROM cleanup_proof') == old && $(etcd get /cleanup-proof --print-value-only) == old ]]
[[ $(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$FIRST_PG_CID" "$FIRST_ETCD_CID" "$FIRST_PROXY_CID") == "$FIRST_POLICIES" ]]
for service in postgres etcd haproxy; do running "$(cid "$service")" true; done
printf 'PASS: repeated preview preserves real Docker containers and database files\n'

# Every container is inspected except the exact controller standing in for the host.
docker run -d --name "$FOREIGN" --label "ha.cleanup.fixture=$PROJECT" --label "com.docker.compose.project=$PROJECT" \
  --label com.docker.compose.service=postgres --label com.docker.compose.oneoff=False \
  --label "com.docker.compose.project.working_dir=$LAB/outside" --label "com.docker.compose.project.config_files=$LAB/outside/compose.yml" \
  --mount "type=bind,src=$LAB/canary,dst=/canary,readonly" \
  --network none --init --entrypoint /bin/sleep "$HAPROXY_IMAGE" 600 >/dev/null
if cleanup_node audit >"$LAB/foreign.log" 2>&1; then die 'A same-project external container was adopted'; fi
running "$FOREIGN" true
for owned_cid in "$FIRST_PG_CID" "$FIRST_ETCD_CID" "$FIRST_PROXY_CID"; do running "$owned_cid" true; done
docker rm -f "$FOREIGN" >/dev/null
docker run -d --name "$FOREIGN" --label "ha.cleanup.fixture=$PROJECT" --network none --init \
  --mount "type=bind,src=$DATA,dst=/external,readonly" --entrypoint /bin/sleep "$HAPROXY_IMAGE" 600 >/dev/null
if cleanup_node audit >"$LAB/holder.log" 2>&1; then die 'An external holder of the data root was ignored'; fi
running "$FOREIGN" true
[[ $(fingerprint) == "$BEFORE" ]]
docker rm -f "$FOREIGN" >/dev/null
printf 'other-cluster\n' >"$DATA/.one-postgres-ha-cluster"
if cleanup_node audit >"$LAB/marker.log" 2>&1; then die 'A mismatched cluster marker was accepted'; fi
printf '%s\n' "$CLUSTER" >"$DATA/.one-postgres-ha-cluster"
printf 'PASS: mismatched ownership, same-project external containers and data holders are refused\n'

stop_and_remove
for phase in audit stop-ingress stop-postgres stop-etcd remove; do cleanup_node "$phase" --apply; done
printf 'PASS: PG17 binds PGDATA without anonymous volumes; cleanup preserves the unrelated canary volume\n'
make_fixture
SECOND_PG=$(sql 'SELECT system_identifier FROM pg_control_system()')
SECOND_ETCD=$(etcd endpoint status --write-out=json | python3 -c 'import json,sys; h=json.load(sys.stdin)[0]["Status"]["header"]; print(h["cluster_id"],h["member_id"])')
# etcd IDs hash peer URLs and token; identical bootstrap inputs may reuse IDs.
# https://github.com/etcd-io/etcd/blob/v3.6.15/server/etcdserver/api/membership/cluster.go#L76
SECOND_REVISION=$(etcd endpoint status --write-out=json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["Status"]["header"]["revision"])')
[[ "$FIRST_PG" != "$SECOND_PG" && "$SECOND_REVISION" == 1 && "$FIRST_REVISION" -ge 3 ]]
[[ -z $(sql "SELECT to_regclass('public.cleanup_proof')") && -z $(etcd get /cleanup-proof --print-value-only) ]]
[[ -z $(etcd get "/service/$CLUSTER/initialize" --print-value-only) ]]
etcd put "/service/$CLUSTER/initialize" "$SECOND_PG" >/dev/null
[[ $(etcd get "/service/$CLUSTER/initialize" --print-value-only) == "$SECOND_PG" ]]
SECOND_CIDS=$(compose ps --all --quiet)
compose up -d --no-build --pull never
[[ $(compose ps --all --quiet) == "$SECOND_CIDS" ]]
stop_and_remove
[[ ! -s "$LAB/postgres-volumes.list" ]]
PG_IMAGE=$LEGACY_PG_IMAGE
make_fixture legacy
[[ $(wc -l <"$LAB/postgres-volumes.list") == 1 ]]
cleanup_node audit >"$LAB/legacy-preview.json"
stop_and_remove
printf 'PASS: separate legacy inherited parent-volume fixture is audited and its anonymous volume is retained\n'
python3 - "$LAB/report.json" "$FIRST_PG" "$SECOND_PG" "$FIRST_ETCD" "$SECOND_ETCD" "$FIRST_REVISION" "$SECOND_REVISION" <<'PY'
import json,pathlib,sys
path,old_pg,new_pg,old_etcd,new_etcd,old_revision,new_revision=sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({'passed':True,'preview_preserved':True,'ordered_stops':True,
    'external_ownership_refused':True,'external_data_holder_refused':True,'canary_preserved':True,
    'pg17_default_anonymous_volumes':0,'pg17_data_volume_replaced_by_bind':True,
    'legacy_parent_volume_fixture_verified':True,'inherited_anonymous_parent_retained':True,
    'repeat_cleanup_noop':True,'repeat_compose_no_recreate':True,
    'old_pg_system_identifier':old_pg,'new_pg_system_identifier':new_pg,'old_etcd_identity':old_etcd,'new_etcd_identity':new_etcd,
    'old_etcd_revision':int(old_revision),'new_etcd_revision':int(new_revision),'etcd_ids_may_repeat_with_same_token_and_peer_urls':True,
    'old_sql_table_and_etcd_key_absent':True,'mocked_boundaries':['DockerRootDir','exact lab controller excluded from real ps',
    'SSD mount metadata','systemd','iptables','udev','unopened fake watchdog char device'],
    'excluded_acceptance':['Patroni HA','native host services','hardware watchdog','VIP']},indent=2)+'\n')
PY
printf 'PASS: cleanup/reinstall creates a new PostgreSQL identity and empty etcd; repeat startup preserves containers\n'
