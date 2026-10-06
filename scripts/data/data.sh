#!/usr/bin/env bash
# Runs on the independent backup host. Configuration and SQL output are private.
set -Eeuo pipefail
umask 077
export LC_ALL=C
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config=${HA_DATA_CONFIG:-$here/config.json}
die() {
  printf 'data: %s\n' "$*" >&2
  exit 1
}
need() { command -v "$1" >/dev/null || die "missing command: $1"; }
for tool in jq docker flock sha256sum date readlink sync mktemp find sort; do need "$tool"; done
operation=${1:-}
case $operation in
  prepare-directory | backup | restore-test | migrate-plan | migrate-apply | migrate-precheck | write-started | complete | verify-readonly | rollback) ;;
  *) die 'usage: data.sh prepare-directory|backup|restore-test|migrate-plan DB|migrate-apply DB|rollback DB' ;;
esac
[[ -f $config && ! -L $config ]] || die 'config.json is required and must not be a symlink'
jq -e 'type=="object"' "$config" >/dev/null || die 'invalid data config'
get() { jq -er "$1" "$config"; }
cluster=$(get '.cluster_name')
[[ $cluster =~ ^[a-z][a-z0-9_-]{0,62}$ ]] || die 'invalid cluster_name'
root=$(get '.directory')
root=${root%/}
[[ $root =~ ^/[A-Za-z0-9_./-]+$ && $root = "$(readlink -m -- "$root")" ]] ||
  die 'backup directory must be an absolute canonical path without symlinks'
case $root in
  / | /tmp | /var | /srv | /mnt | /opt | /root | /home | /usr | /etc | /run | /var/lib) die 'backup directory must be dedicated' ;;
esac
[[ ! -e $root || -d $root ]] || die 'backup directory is not a directory'
image=$(get '.postgres_image')
[[ $image =~ @sha256:[0-9a-f]{64}$ ]] || die 'postgres_image must be digest pinned'
mkdir -p -- "$root"
owner_file="$root/.one-postgres-ha-data.json"
directory_initialized=false
if [[ ! -e $owner_file && ! -L $owner_file ]]; then
  [[ -z $(find "$root" -mindepth 1 -maxdepth 1 -print -quit) ]] ||
    die 'backup directory is nonempty and unowned; preserve it and configure a new empty dedicated backup path'
  # noclobber prevents a second cluster from replacing the ownership claim.
  (set -o noclobber
    jq -n --arg cluster "$cluster" '{tool:"one-postgres-ha",schema_version:1,cluster_name:$cluster,system_identifier:null}' >"$owner_file"
  ) || die 'could not claim backup directory; inspect its ownership marker'
  sync -f "$owner_file"
  directory_initialized=true
fi
[[ -f $owner_file && ! -L $owner_file ]] || die 'backup ownership marker must be a regular file'
jq -e --arg cluster "$cluster" '
  type=="object" and has("system_identifier") and .tool=="one-postgres-ha" and .schema_version==1 and .cluster_name==$cluster
  and (.system_identifier==null or (.system_identifier | type=="string" and test("^[0-9]{1,20}$")))
' "$owner_file" >/dev/null || die 'backup directory belongs to another cluster or has an invalid ownership marker'
for directory in state migrations secrets; do
  [[ ! -L $root/$directory && (! -e $root/$directory || -d $root/$directory) ]] || die 'unsafe data subdirectory'
done
mkdir -p -- "$root/state" "$root/migrations" "$root/secrets"
chmod 700 -- "$root" "$root/state" "$root/migrations" "$root/secrets"
if [[ $operation = prepare-directory ]]; then
  if [[ $directory_initialized = true ]]; then printf 'data directory initialized\n'; else printf 'data directory ownership verified\n'; fi
  exit 0
fi
[[ ! -L $root/state/data.lock && (! -e $root/state/data.lock || -f $root/state/data.lock) ]] || die 'unsafe data lock'
exec 9>"$root/state/data.lock"
flock -n 9 || die 'another data operation is running'
work=''
restore_container=''
snapshot_pid=''
cleanup() {
  if [[ -n $snapshot_pid ]]; then
    kill "$snapshot_pid" 2>/dev/null || true
    wait "$snapshot_pid" 2>/dev/null || true
  fi
  if [[ -n $restore_container ]]; then docker rm -fv -- "$restore_container" >/dev/null 2>&1 || true; fi
  local container
  while IFS= read -r container; do
    if [[ $container =~ ^[a-f0-9]+$ ]]; then docker rm -f -- "$container" >/dev/null 2>&1 || true; fi
  done < <(docker ps -aq --filter "label=ha.data.owner=$cluster-$$" 2>/dev/null || true)
  if [[ -n $work && -d $work ]]; then find "$work" -maxdepth 1 -type f -name '.pgpass-*' -delete; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

endpoint_json() {
  case $1 in
    target) jq -c '.target' "$config" ;;
    source) jq -ec --arg name "$database" '.migrations[$name].source' "$config" ;;
    readonly) jq -ec --arg name "$database" '.migrations[$name].readonly' "$config" ;;
    *) die 'invalid endpoint' ;;
  esac
}
client() {
  local endpoint=$1 command=$2
  shift 2
  local info host port user password_file password escaped user_escaped host_escaped pgpass
  info=$(endpoint_json "$endpoint")
  host=$(jq -er '.host' <<<"$info")
  port=$(jq -er '.port' <<<"$info")
  user=$(jq -er '.user' <<<"$info")
  password_file=$(jq -er '.password_file' <<<"$info")
  [[ $host =~ ^[A-Za-z0-9_.:-]+$ && $port =~ ^[0-9]+$ && $user =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die 'invalid SQL endpoint'
  [[ -f $password_file && ! -L $password_file ]] || die 'missing password file'
  password=$(cat -- "$password_file")
  [[ -n $password && $password != *$'\n'* && $password != *$'\r'* ]] || die 'password must be nonempty and contain no line breaks'
  escaped=${password//\\/\\\\}
  escaped=${escaped//:/\\:}
  user_escaped=${user//:/\\:}
  host_escaped=${host//:/\\:}
  pgpass="$work/.pgpass-$endpoint"
  printf '%s:%s:*:%s:%s\n' "$host_escaped" "$port" "$user_escaped" "$escaped" >"$pgpass"
  chmod 600 "$pgpass"
  docker run --rm -i --network host --user 0:0 --read-only --label "ha.data.owner=$cluster-$$" \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --volume "$root:/work" --volume "$here:/app:ro" \
    --env "PGPASSFILE=/work/${pgpass#"$root/"}" \
    --env "PGSSLMODE=$(jq -r '.sslmode // "prefer"' <<<"$info")" --env PGCONNECT_TIMEOUT=10 \
    --entrypoint "$command" "$image" --host "$host" --port "$port" --username "$user" "$@"
}
sql() {
  local endpoint=$1 db=$2
  shift 2
  client "$endpoint" psql -X -qAt --set ON_ERROR_STOP=1 --dbname "$db" "$@"
}
control_id() { printf 'SELECT system_identifier FROM pg_control_system();\n' | sql target postgres; }
write_json() {
  local file=$1 temporary
  [[ ! -L $file ]] || die 'refusing to replace a symlink with operation state'
  temporary=$(mktemp "$file.tmp.XXXXXXXX")
  cat >"$temporary"
  chmod 600 "$temporary"
  mv -fT -- "$temporary" "$file"
  # syncfs includes the rename/directory metadata before any PG18 write is enabled.
  sync -f "$file"
}
bind_backup_identity() {
  local id=$1 previous
  [[ $id =~ ^[0-9]{1,20}$ ]] || die 'invalid target system_identifier'
  previous=$(jq -er '.system_identifier // "unbound"' "$owner_file")
  [[ $previous = unbound || $previous = "$id" ]] || die 'backup directory belongs to another PostgreSQL instance; configure a new dedicated path'
  if [[ $previous = unbound ]]; then
    jq --arg id "$id" '.system_identifier=$id' "$owner_file" | write_json "$owner_file"
  fi
}
owned_backup() {
  local path=$1 id=$2 name
  name=${path#"$root/"}
  [[ $name =~ ^backup-20[0-9]{6}T[0-9]{6}-[0-9]+$ && -d $path && ! -L $path && $path = "$(readlink -f -- "$path")" ]] || return 1
  [[ -f $path/manifest.json && ! -L $path/manifest.json ]] || return 1
  jq -e --arg cluster "$cluster" --arg id "$id" '
    .complete==true and .cluster_name==$cluster and .system_identifier==$id
  ' "$path/manifest.json" >/dev/null 2>&1
}
retain_backups() {
  local id=$1 path n
  local -a complete=()
  while IFS= read -r -d '' path; do
    if owned_backup "$path" "$id"; then complete+=("$path"); fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'backup-20*' -print0 | sort -zr)
  for ((n = 14; n < ${#complete[@]}; n++)); do
    path=${complete[$n]}
    owned_backup "$path" "$id" || die 'backup ownership changed during retention'
    rm -rf -- "$path"
  done
}
new_work() {
  work="$root/$1"
  [[ ! -e $work ]] || die 'operation directory already exists'
  mkdir -- "$work"
}
safe_name() { [[ $1 =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,62}$ ]] || die "unsupported database/role name: $1"; }
state_file() { printf '%s/state/%s.json' "$root" "$database"; }
set_phase() {
  local phase=$1 file
  file=$(state_file)
  if [[ -f $file ]]; then
    jq --arg phase "$phase" --arg at "$(date -u +%FT%TZ)" '.phase=$phase | .updated_at=$at' "$file" | write_json "$file"
  else
    jq -n --arg phase "$phase" --arg db "$database" --arg work "$work" --arg cluster "$cluster" \
      --arg id "$(control_id)" --arg at "$(date -u +%FT%TZ)" \
      '{phase:$phase,database:$db,work:$work,cluster_name:$cluster,system_identifier:$id,created_at:$at,updated_at:$at}' | write_json "$file"
  fi
}
phase() { [[ -f $(state_file) ]] && jq -r '.phase' "$(state_file)" || printf 'new'; }
load_work() {
  work=$(jq -er '.work' "$(state_file)")
  [[ $work = "$root/migrations/"* && -d $work && ! -L $work ]] || die 'invalid migration state directory'
}

fingerprint() {
  local endpoint=$1 db=$2 output=$3 snapshot=${4:-}
  {
    if [[ -n $snapshot ]]; then printf "BEGIN ISOLATION LEVEL REPEATABLE READ; SET TRANSACTION SNAPSHOT '%s';\n" "$snapshot"; fi
    cat "$here/sql/fingerprint.sql"
    if [[ -n $snapshot ]]; then printf '\nCOMMIT;\n'; fi
  } | sql "$endpoint" "$db" | sort >"$output"
}
dump_database() {
  local endpoint=$1 db=$2 prefix=$3 snapshot snapshot_in snapshot_out
  # Keep an exported snapshot alive until both pg_dump and checks have completed.
  coproc SNAPSHOT { sql "$endpoint" "$db"; }
  # Bash creates this variable for the named coprocess.
  # shellcheck disable=SC2153
  snapshot_pid=$SNAPSHOT_PID
  snapshot_in=${SNAPSHOT[1]}
  snapshot_out=${SNAPSHOT[0]}
  printf 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SELECT pg_export_snapshot();\n' >&"$snapshot_in"
  read -r -t 60 snapshot <&"$snapshot_out" || die 'could not obtain export snapshot'
  [[ $snapshot =~ ^[A-Fa-f0-9-]+$ ]] || die 'invalid export snapshot'
  client "$endpoint" pg_dump --dbname "$db" --format custom --create --snapshot "$snapshot" \
    --file "/work/${prefix#"$root/"}.dump"
  fingerprint "$endpoint" "$db" "$prefix.fingerprint" "$snapshot"
  printf 'COMMIT;\n\\q\n' >&"$snapshot_in"
  wait "$snapshot_pid"
  snapshot_pid=''
}
reject_tablespaces() {
  local endpoint=$1 count
  count=$(printf "SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default','pg_global');\n" | sql "$endpoint" postgres)
  [[ $count = 0 ]] || die 'custom tablespaces require an explicit restore storage mapping; unsupported in this first release'
}
backup() {
  local state_file active_phase
  for state_file in "$root/state/"*.json; do
    [[ -f $state_file ]] || continue
    active_phase=$(jq -er '.phase' "$state_file")
    case $active_phase in
      freezing | frozen | restored | write-started) die 'an application migration is open; scheduled backup must wait until it completes or is rolled back' ;;
    esac
  done
  local id names db n=0 first_roles second_roles
  work="$root/state"
  id=$(control_id)
  bind_backup_identity "$id"
  rm -f -- "$work/.pgpass-target"
  new_work "backup-$(date -u +%Y%m%dT%H%M%S)-$$"
  reject_tablespaces target
  first_roles=$(printf "SELECT md5(string_agg(row_to_json(r)::text,'' ORDER BY rolname)) FROM pg_authid r;\n" | sql target postgres)
  client target pg_dumpall --database postgres --roles-only --file "/work/${work#"$root/"}/roles.sql"
  names=$(printf "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname;\n" | sql target postgres)
  [[ -n $names ]] || die 'no databases found'
  printf "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname;\n" | sql target postgres >"$work/roles.list"
  local role_csv
  role_csv=$(paste -sd, "$work/roles.list")
  sql target postgres --set "required_roles=$role_csv" --file /app/sql/role-fingerprint.sql >"$work/source.roles.fingerprint"
  while IFS= read -r db; do
    safe_name "$db"
    dump_database target "$db" "$work/$db"
    ((n += 1))
  done <<<"$names"
  second_roles=$(printf "SELECT md5(string_agg(row_to_json(r)::text,'' ORDER BY rolname)) FROM pg_authid r;\n" | sql target postgres)
  [[ $first_roles = "$second_roles" ]] || die 'roles changed during backup; backup left incomplete'
  (cd "$work" && sha256sum -- roles.sql roles.list ./*.dump ./*.fingerprint >SHA256SUMS)
  jq -n --arg cluster "$cluster" --arg id "$id" --arg at "$(date -u +%FT%TZ)" --argjson count "$n" \
    '{complete:true,cluster_name:$cluster,system_identifier:$id,created_at:$at,database_count:$count}' | write_json "$work/manifest.json"
  printf '%s\n' "$work" | write_json "$root/state/latest-backup"
  # Other clusters, old instance identities and incomplete backups remain intact.
  retain_backups "$id"
  printf 'backup complete: %s\n' "$work"
}
start_restore() {
  local restore_role=postgres
  restore_container="ha-restore-${cluster}-$$"
  # No published ports and no network: cannot be confused with the production cluster.
  docker run -d --name "$restore_container" --network none --memory 1536m --cpus 2 \
    --env "POSTGRES_USER=$restore_role" --env POSTGRES_HOST_AUTH_METHOD=trust \
    --volume "$work:/backup:ro" --tmpfs /var/run/postgresql:rw \
    "$image" >/dev/null
  local ready=false
  for ((i = 0; i < 60; i++)); do
    # The official entrypoint's temporary init server listens only on a Unix socket.
    if docker exec "$restore_container" pg_isready --host 127.0.0.1 --port 5432 --username "$restore_role" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  [[ $ready = true ]] || die 'isolated PostgreSQL did not become ready'
}
restore_sql() { docker exec -i "$restore_container" psql -X -qAt --username postgres --dbname "$1" --set ON_ERROR_STOP=1; }
isolated_restore() {
  local directory=$1 mode=${2:-archive} db file expected actual
  [[ $directory = "$root/"* && -d $directory && ! -L $directory ]] || die 'invalid restore directory'
  work=$directory
  (cd "$work" && sha256sum --check --status SHA256SUMS) || die 'backup checksum failed'
  start_restore
  # The bootstrap role OID must match production for GRANTED BY semantics.
  # Keep ALTER ROLE postgres (password/settings), skip only its duplicate CREATE.
  if [[ -f $work/roles.sql ]]; then sed '/^CREATE ROLE postgres;$/d' "$work/roles.sql" | restore_sql postgres; fi
  for file in "$work"/*.dump; do
    [[ -f $file ]] || die 'no dump archives found'
    db=$(basename -- "$file" .dump)
    safe_name "$db"
    docker exec "$restore_container" pg_restore --username postgres --dbname template1 \
      --clean --if-exists --create --exit-on-error "/backup/$db.dump"
    docker exec "$restore_container" pg_restore --list "/backup/$db.dump" >"$work/$db.toc"
    grep -E '^[0-9]+; [0-9]+ [0-9]+ SEQUENCE SET ' "$work/$db.toc" >"$work/$db.sequences.toc" || true
    {
      cat "$here/sql/verify-sequences.sql"
      docker exec "$restore_container" pg_restore --use-list "/backup/$db.sequences.toc" --file - "/backup/$db.dump" |
        sed 's/pg_catalog\.setval(/pg_temp.assert_sequence(/g'
    } | restore_sql "$db" >"$work/$db.sequence-archive-check.txt"
    actual="$work/$db.restored.fingerprint"
    restore_sql "$db" <"$here/sql/fingerprint.sql" | sort >"$actual"
    expected="$work/$db.fingerprint"
    if [[ $mode = frozen ]]; then
      cmp -s -- "$expected" "$actual" || die "logical/schema/ACL/RLS/sequence check failed for $db; inspect private fingerprints"
    else
      cmp -s <(grep -v '^sequence|' "$expected") <(grep -v '^sequence|' "$actual") ||
        die "logical/schema/ACL/RLS check failed for $db; inspect private fingerprints"
    fi
  done
  if [[ -f $work/roles.list && -f $work/source.roles.fingerprint ]]; then
    local role_csv
    role_csv=$(paste -sd, "$work/roles.list")
    docker exec -i "$restore_container" psql -X -qAt --username postgres --dbname postgres --set ON_ERROR_STOP=1 \
      --set "required_roles=$role_csv" <"$here/sql/role-fingerprint.sql" >"$work/restored.roles.fingerprint"
    cmp -s "$work/source.roles.fingerprint" "$work/restored.roles.fingerprint" || die 'restored role password/settings/membership verification failed'
  fi
  jq -n --arg cluster "$cluster" --arg id "$(control_id)" --arg at "$(date -u +%FT%TZ)" \
    --arg checksum "$(sha256sum "$work/SHA256SUMS" | cut -d' ' -f1)" --arg mode "$mode" \
    '{passed:true,cluster_name:$cluster,system_identifier:$id,completed_at:$at,checksum_manifest:$checksum,isolated:true,sequence_check:$mode}' |
    write_json "$work/restore-test.json"
  printf 'isolated restore passed: %s\n' "$work"
}
restore_test() {
  [[ -f $root/state/latest-backup && ! -L $root/state/latest-backup ]] || die 'run backup before restore-test; latest-backup must not be a symlink'
  local directory
  directory=$(cat "$root/state/latest-backup")
  owned_backup "$directory" "$(jq -er '.system_identifier' "$owner_file")" || die 'latest backup does not belong to this directory owner'
  isolated_restore "$directory"
}
validate_acceptance() {
  local file id now at
  file=$(jq -er --arg db "$database" '.migrations[$db].acceptance_file' "$config")
  [[ -f $file ]] || die 'missing native cluster failure acceptance JSON'
  id=$(control_id)
  now=$(date -u +%s)
  jq -e --arg cluster "$cluster" --arg id "$id" --argjson now "$now" '
    .cluster_name==$cluster and .system_identifier==$id and .arm64_native==true
    and .primary_failure==true and .proxy_failure==true and .etcd_failure==true
    and .network_isolation==true and .watchdog==true and .confirmed_transactions==true
    and (.completed_at | fromdateiso8601) <= $now
    and ($now-(.completed_at | fromdateiso8601)) <= 86400
    and (.replay_lsn | type=="string" and test("^[0-9A-F]+/[0-9A-F]+$"))
    and (.primary_lsn | type=="string" and test("^[0-9A-F]+/[0-9A-F]+$"))' "$file" >/dev/null ||
    die 'cluster acceptance is incomplete, stale, or belongs to another cluster'
  at=$(jq -er '.primary_lsn' "$file")
  local replay
  replay=$(jq -er '.replay_lsn' "$file")
  [[ $(printf "SELECT :'replay'::pg_lsn >= :'primary'::pg_lsn;\n" | sql target postgres --set "replay=$replay" --set "primary=$at") = t ]] ||
    die 'acceptance replay LSN is behind its confirmed primary LSN'
  local count
  count=$(printf "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND sync_state IN ('sync','quorum');\n" | sql target postgres)
  [[ $count =~ ^[0-9]+$ && $count -ge 1 ]] || die 'no healthy synchronous replica'
}
migration_checks() {
  safe_name "$database"
  [[ $database = one_minihouse || $database = nexus ]] || die 'unsupported migration database'
  local source_db roles role super
  source_db=$(jq -er --arg db "$database" '.migrations[$db].source.database' "$config")
  [[ $source_db = "$database" ]] || die 'source database must preserve its name'
  [[ $(printf 'SELECT rolname FROM pg_authid WHERE oid=10;\n' | sql source postgres) = postgres ]] ||
    die 'source bootstrap administrator must be postgres to preserve GRANTED BY semantics'
  roles=$(jq -er --arg db "$database" '.migrations[$db].required_roles | select(length>0) | join(",")' "$config")
  IFS=, read -ra role_array <<<"$roles"
  for role in "${role_array[@]}"; do
    safe_name "$role"
    [[ $role != postgres && $role != replicator && $role != rewind_user ]] || die 'business roles must not use cluster administrators'
  done
  local found
  found=$(printf "SELECT count(*) FROM pg_roles WHERE rolname=ANY(string_to_array(:'roles',','));\n" | sql source "$database" --set "roles=$roles")
  [[ $found = "${#role_array[@]}" ]] || die 'some required business roles are absent from the source'
  super=$(printf "SELECT count(*) FROM pg_roles WHERE rolname=ANY(string_to_array(:'roles',',')) AND (rolsuper OR rolreplication OR rolcreaterole);\n" |
    sql source "$database" --set "roles=$roles")
  [[ $super = 0 ]] || die 'business roles have administrative capabilities; connection-limit freeze would be insufficient'
  reject_tablespaces source
  [[ $(printf 'SHOW server_version_num;\n' | sql target postgres) =~ ^18[0-9]+$ ]] || die 'target must run PostgreSQL18'
  if [[ $database = one_minihouse ]]; then
    [[ $(printf 'SHOW server_version_num;\n' | sql source postgres) =~ ^17[0-9]+$ ]] || die 'one_minihouse source must run PostgreSQL17'
  fi
  if [[ $database = nexus ]]; then
    local other_databases
    other_databases=$(printf "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres','nexus');\n" | sql source postgres)
    [[ $other_databases = 0 ]] || die 'Nexus source is not a dedicated instance; stopping its PostgreSQL service would affect other databases'
    local stable
    stable=$(jq -er '.migrations.nexus.stable_minihouse_file' "$config")
    [[ -f $stable ]] || die 'Nexus requires oneMiniHouse stable observation evidence'
    jq -e --arg cluster "$cluster" --arg id "$(control_id)" --argjson now "$(date -u +%s)" '
      .cluster_name==$cluster and .system_identifier==$id and .database=="one_minihouse"
      and .pending_drained==true and .permanent_failures_increased==false and .grafana_readonly==true
      and .public_dashboard==true and .observation_hours>=24
      and ($now-(.completed_at|fromdateiso8601))>=0 and ($now-(.completed_at|fromdateiso8601))<=86400' "$stable" >/dev/null ||
      die 'oneMiniHouse 24-hour stable evidence is incomplete or stale'
    local state
    state="$root/state/one_minihouse.json"
    [[ -f $state && $(jq -r '.phase' "$state") = migrated ]] || die 'oneMiniHouse migration must be complete before Nexus'
    local since
    since=$(date -u -d "$(jq -r '.updated_at' "$state")" +%s)
    (($(date -u +%s) - since >= 86400)) || die 'oneMiniHouse has not completed 24 hours on this cluster'
  fi
}
export_migration() {
  local roles discovered existing
  roles=$(jq -er --arg db "$database" '.migrations[$db].required_roles | join(",")' "$config")
  sql source "$database" --set "required_roles=$roles" --file /app/sql/roles-list.sql >"$work/roles.list"
  while IFS= read -r discovered; do safe_name "$discovered"; done <"$work/roles.list"
  roles=$(paste -sd, "$work/roles.list")
  # Existing shared roles must match exactly; never overwrite an unrelated role.
  existing=$(printf "SELECT string_agg(rolname,',' ORDER BY rolname) FROM pg_roles WHERE rolname=ANY(string_to_array(:'roles',','));\n" |
    sql target postgres --set "roles=$roles")
  if [[ -n $existing ]]; then
    sql source "$database" --set "required_roles=$existing" --file /app/sql/role-fingerprint.sql >"$work/existing-source.roles"
    sql target postgres --set "required_roles=$existing" --file /app/sql/role-fingerprint.sql >"$work/existing-target.roles"
    cmp -s "$work/existing-source.roles" "$work/existing-target.roles" || die 'existing target roles differ; refusing to overwrite shared role attributes/passwords'
  fi
  sql source "$database" --set "required_roles=$roles" --file /app/sql/roles.sql >"$work/roles.sql"
  dump_database source "$database" "$work/$database"
  sql source "$database" --set "required_roles=$roles" --file /app/sql/role-fingerprint.sql >"$work/source.roles.fingerprint"
  (cd "$work" && sha256sum -- roles.sql roles.list ./*.dump ./*.fingerprint >SHA256SUMS)
}
migrate_plan() {
  # A rehearsal writes only a backup and an isolated temporary database.
  new_work "migrations/rehearsal-$database-$(date -u +%Y%m%dT%H%M%S)-$$"
  migration_checks
  export_migration
  isolated_restore "$work"
  printf '%s\n' "$work" | write_json "$root/state/rehearsal-$database"
  printf 'rehearsal complete; production endpoints unchanged\n'
}
validate_rehearsal() {
  local file directory
  file="$root/state/rehearsal-$database"
  [[ -f $file ]] || die 'migrate-plan must pass before migrate-apply'
  directory=$(cat "$file")
  [[ $directory = "$root/migrations/rehearsal-$database-"* && -f $directory/restore-test.json ]] || die 'invalid rehearsal state'
  (cd "$directory" && sha256sum --check --status SHA256SUMS) || die 'rehearsal backup changed'
  jq -e --arg cluster "$cluster" --arg id "$(control_id)" --argjson now "$(date -u +%s)" \
    --arg checksum "$(sha256sum "$directory/SHA256SUMS" | cut -d' ' -f1)" '
    .passed==true and .isolated==true and .cluster_name==$cluster and .system_identifier==$id
    and .checksum_manifest==$checksum and ($now-(.completed_at|fromdateiso8601))>=0
    and ($now-(.completed_at|fromdateiso8601))<=86400' "$directory/restore-test.json" >/dev/null ||
    die 'rehearsal evidence expired, failed, or belongs to another cluster'
}
migrate_apply() {
  [[ $(phase) = new || $(phase) = rolled-back ]] || die 'migration already started; inspect state instead of dumping again'
  new_work "migrations/final-$database-$(date -u +%Y%m%dT%H%M%S)-$$"
  migration_checks
  validate_acceptance
  validate_rehearsal
  local exists limit
  exists=$(printf "SELECT count(*) FROM pg_database WHERE datname=:'db';\n" | sql target postgres --set "db=$database")
  [[ $exists = 0 ]] || die 'target database already exists; refusing to replace it'
  limit=$(printf "SELECT datconnlimit FROM pg_database WHERE datname=:'db';\n" | sql source postgres --set "db=$database")
  [[ $limit =~ ^-?[0-9]+$ ]] || die 'source database does not exist'
  printf '%s\n' "$limit" >"$work/original-connection-limit"
  set_phase freezing
  printf "SELECT format('ALTER DATABASE %%I CONNECTION LIMIT 0', :'db') \\gexec\nSELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=:'db' AND pid<>pg_backend_pid();\n" |
    sql source postgres --set "db=$database" >/dev/null
  set_phase frozen
  export_migration
  # Final dump is also restored in isolation before touching the HA destination.
  isolated_restore "$work" frozen
  sql target postgres --file "/work/${work#"$root/"}/roles.sql" >/dev/null
  client target pg_restore --dbname postgres --create --exit-on-error "/work/${work#"$root/"}/$database.dump"
  fingerprint target "$database" "$work/$database.target.fingerprint"
  cmp -s "$work/$database.fingerprint" "$work/$database.target.fingerprint" || die 'target verification failed; source remains frozen'
  local roles
  roles=$(paste -sd, "$work/roles.list")
  sql target postgres --set "required_roles=$roles" --file /app/sql/role-fingerprint.sql >"$work/target.roles.fingerprint"
  cmp -s "$work/source.roles.fingerprint" "$work/target.roles.fingerprint" || die 'target role password/attribute verification failed'
  local lsn ok=false
  lsn=$(printf 'SELECT pg_current_wal_flush_lsn();\n' | sql target postgres)
  for ((i = 0; i < 60; i++)); do
    if [[ $(printf "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND replay_lsn>=:'lsn'::pg_lsn;\n" |
      sql target postgres --set "lsn=$lsn") -ge 1 ]]; then
      ok=true
      break
    fi
    sleep 2
  done
  [[ $ok = true ]] || die 'replica did not replay restored database; source remains frozen'
  set_phase restored
  printf 'restored and verified; source remains frozen until endpoint switch\n'
}
write_started() {
  [[ $(phase) = restored ]] || die 'endpoint switch requires restored state'
  load_work
  # Set first: a crash after this point must never authorize stale-PG17 rollback.
  set_phase write-started
  local limit
  limit=$(cat "$work/original-connection-limit")
  [[ $limit =~ ^-?[0-9]+$ ]] || die 'invalid original connection limit'
  printf "SELECT format('ALTER DATABASE %%I CONNECTION LIMIT %%s', :'db', :'lim') \\gexec\n" |
    sql target postgres --set "db=$database" --set "lim=$limit" >/dev/null
}
complete_migration() {
  [[ $(phase) = write-started ]] || die 'migration completion requires write-started state'
  load_work
  set_phase migrated
}
verify_readonly() {
  [[ $(phase) = write-started ]] || die 'read-only acceptance requires the endpoint switch stage'
  load_work
  local file
  file=$(jq -er --arg db "$database" '.migrations[$db].readonly.sql_file' "$config")
  [[ -f $file ]] || die 'read-only SQL regression file is missing'
  {
    printf 'BEGIN READ ONLY;\n'
    cat -- "$file"
    printf '\nCOMMIT;\n'
  } | sql readonly "$database" >"$work/readonly-regression.txt"
}
migrate_precheck() {
  work="$root/state"
  [[ $(phase) = new || $(phase) = rolled-back ]] || die 'migration already started; inspect durable state first'
  migration_checks
  validate_acceptance
  validate_rehearsal
  local exists
  exists=$(printf "SELECT count(*) FROM pg_database WHERE datname=:'db';\n" | sql target postgres --set "db=$database")
  [[ $exists = 0 ]] || die 'target database already exists; refusing to replace it'
}
rollback() {
  local current
  current=$(phase)
  case $current in
    write-started | migrated) die 'PG18 may have accepted writes. Stale-source rollback is prohibited; repair HA or restore a PG18 backup.' ;;
    freezing | frozen | restored) ;;
    *) die 'there is no pre-write migration to roll back' ;;
  esac
  load_work
  local limit
  limit=$(cat "$work/original-connection-limit")
  [[ $limit =~ ^-?[0-9]+$ ]] || die 'invalid original connection limit'
  printf "SELECT format('ALTER DATABASE %%I CONNECTION LIMIT %%s', :'db', :'lim') \\gexec\n" |
    sql source postgres --set "db=$database" --set "lim=$limit" >/dev/null
  set_phase rolled-back
  printf 'source connection limit restored; target database retained for investigation\n'
}

database=${2:-}
case $operation in
  backup) backup ;;
  restore-test) restore_test ;;
  migrate-plan | migrate-apply | migrate-precheck | write-started | complete | verify-readonly | rollback)
    safe_name "$database"
    case $operation in
      migrate-precheck) migrate_precheck ;;
      migrate-plan) migrate_plan ;; migrate-apply) migrate_apply ;; write-started) write_started ;;
      complete) complete_migration ;; verify-readonly) verify_readonly ;; rollback) rollback ;;
    esac
    ;;
  *) die 'usage: data.sh backup|restore-test|migrate-plan DB|migrate-apply DB|rollback DB' ;;
esac
