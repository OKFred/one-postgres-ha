#!/usr/bin/env bash
# Requires Linux Docker, Bash, jq and flock. Never contacts inventory/site hosts.
set -Eeuo pipefail
umask 077
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
here="$repo/scripts/data"
bash "$here/test-readiness.sh"
prefix="ha-data-test-$RANDOM-$$"
network=$prefix
source_name="$prefix-source"
target_name="$prefix-target"
target_image=$(sed -n 's/^POSTGRES_BASE_IMAGE=//p' "$repo/versions.lock")
source_image=${PG17_TEST_IMAGE:-postgres:17.11-alpine@sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73}
root="$repo/.local/data-tests/$prefix"
mkdir -p -- "$root"
cleanup() {
  docker rm -fv -- "$source_name" "$target_name" >/dev/null 2>&1 || true
  docker network rm -- "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker network create "$network" >/dev/null
docker run -d --name "$source_name" --network "$network" --env POSTGRES_HOST_AUTH_METHOD=trust "$source_image" >/dev/null
docker run -d --name "$target_name" --network "$network" --env POSTGRES_HOST_AUTH_METHOD=trust \
  --mount "type=bind,src=$here/sql,dst=/sql,readonly" "$target_image" >/dev/null
for name in "$source_name" "$target_name"; do
  ready=false
  for ((i = 0; i < 60; i++)); do
    if docker exec "$name" pg_isready -h 127.0.0.1 -p 5432 -U postgres >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  [[ $ready = true ]]
done
for name in "$source_name" "$target_name"; do
  [[ $(docker exec "$name" psql -X -qAt -U postgres -c 'SHOW server_version_num;') =~ ^17[0-9]{4}$ ]] || {
    printf 'Integration fixtures must both run PostgreSQL17.\n' >&2; exit 1;
  }
done
fixture_password=$(openssl rand -hex 24)
docker exec -i "$source_name" psql -X -q --set ON_ERROR_STOP=1 -U postgres \
  --set "fixture_password=$fixture_password" <"$here/sql/compat-fixture.sql" >/dev/null
source_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$source_name")
target_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$target_name")
docker exec "$target_name" psql -X -qAt -U postgres -h "$source_ip" -d one_minihouse \
  --set ON_ERROR_STOP=1 --set required_roles=app_writer,app_viewer --file /sql/roles-list.sql >"$root/roles.list"
grep -qx app_parent "$root/roles.list"
if grep -q unrelated_other_database_role "$root/roles.list"; then
  echo 'unrelated role was selected' >&2
  exit 1
fi
docker exec "$target_name" psql -X -qAt -U postgres -h "$source_ip" -d one_minihouse \
  --set ON_ERROR_STOP=1 --set required_roles=app_writer,app_viewer --file /sql/roles.sql >"$root/roles.sql"
docker exec -i "$target_name" psql -X -qAt -U postgres --set ON_ERROR_STOP=1 <"$root/roles.sql" >/dev/null

# Hold a normal business connection, then terminate it as part of the freeze.
docker exec "$source_name" psql -X -qAt -U app_viewer -h 127.0.0.1 -d one_minihouse -c 'SELECT pg_sleep(60)' \
  >"$root/frozen-session.txt" 2>&1 &
business_pid=$!
sleep 1
printf "ALTER DATABASE one_minihouse CONNECTION LIMIT 0; SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='one_minihouse';\n" |
  docker exec -i "$source_name" psql -X -qAt -U postgres -d postgres --set ON_ERROR_STOP=1 >/dev/null
if wait "$business_pid"; then
  echo 'business connection survived freeze' >&2
  exit 1
fi
if docker exec "$source_name" psql -X -qAt -U app_writer -h 127.0.0.1 -d one_minihouse -c 'SELECT 1' >"$root/frozen-connect.txt" 2>&1; then
  echo 'business reconnect bypassed freeze' >&2
  exit 1
fi
[[ $(docker exec "$source_name" psql -X -qAt -U app_writer -h 127.0.0.1 -d unrelated_database -c 'SELECT 1') = 1 ]]

docker exec "$target_name" pg_dump -h "$source_ip" -U postgres -d one_minihouse -Fc -C -f /tmp/one_minihouse.dump
docker exec "$target_name" pg_restore -U postgres -d postgres -C --exit-on-error /tmp/one_minihouse.dump
docker exec "$target_name" psql -X -qAt -U postgres -h "$source_ip" -d one_minihouse \
  --set ON_ERROR_STOP=1 --file /sql/fingerprint.sql | sort >"$root/source.fingerprint"
docker exec "$target_name" psql -X -qAt -U postgres -d one_minihouse \
  --set ON_ERROR_STOP=1 --file /sql/fingerprint.sql | sort >"$root/target.fingerprint"
cmp "$root/source.fingerprint" "$root/target.fingerprint"
for endpoint in source target; do
  args=()
  [[ $endpoint != source ]] || args+=(--host "$source_ip")
  docker exec "$target_name" psql -X -qAt -U postgres "${args[@]}" -d one_minihouse \
    --set ON_ERROR_STOP=1 --set required_roles=app_writer,app_viewer,app_parent,grant_manager --file /sql/role-fingerprint.sql \
    >"$root/$endpoint.roles.fingerprint"
done
cmp "$root/source.roles.fingerprint" "$root/target.roles.fingerprint"
[[ $(docker exec "$target_name" psql -X -qAt -U postgres -c "SELECT count(*) FROM pg_roles WHERE rolname='unrelated_other_database_role'") = 0 ]]

printf '%s\n' "$fixture_password" >"$root/password"
jq -n --arg cluster "$prefix" --arg path "$root/backups" --arg image "$target_image" --arg target "$target_ip" \
  --arg source "$source_ip" --arg password "$root/password" \
  '{cluster_name:$cluster,directory:$path,postgres_image:$image,target:{host:$target,port:5432,user:"postgres",password_file:$password},
  migrations:{one_minihouse:{source:{host:$source,port:5432,user:"postgres",password_file:$password,database:"one_minihouse"},
  required_roles:["app_writer","app_viewer"]}}}' >"$root/config.json"
export HA_DATA_CONFIG="$root/config.json"
bash "$here/data.sh" backup
bash "$here/data.sh" restore-test
latest=$(cat "$root/backups/state/latest-backup")
jq -e '.passed==true and .isolated==true' "$latest/restore-test.json" >/dev/null

# A restored migration is conservatively marked before unlocking the target.
mkdir -p "$root/backups/migrations/rollback-fixture"
printf '%s\n' -1 >"$root/backups/migrations/rollback-fixture/original-connection-limit"
jq -n --arg work "$root/backups/migrations/rollback-fixture" \
  '{phase:"frozen",database:"one_minihouse",work:$work}' >"$root/backups/state/one_minihouse.json"
bash "$here/data.sh" rollback one_minihouse
[[ $(docker exec "$source_name" psql -X -qAt -U app_writer -h 127.0.0.1 -d one_minihouse -c 'SELECT 1') = 1 ]]
jq '.phase="restored"' "$root/backups/state/one_minihouse.json" >"$root/state.tmp"
mv "$root/state.tmp" "$root/backups/state/one_minihouse.json"
bash "$here/data.sh" write-started one_minihouse
[[ $(docker exec "$target_name" psql -X -qAt -U app_viewer -h 127.0.0.1 -d one_minihouse -c 'SELECT count(*) FROM iot.visible') = 2 ]]
docker exec "$source_name" psql -X -qAt -U postgres -c 'ALTER DATABASE one_minihouse CONNECTION LIMIT 0'
if bash "$here/data.sh" rollback one_minihouse >"$root/refused-rollback.txt" 2>&1; then
  echo 'unsafe post-write rollback was allowed' >&2
  exit 1
fi
[[ $(docker exec "$source_name" psql -X -qAt -U postgres -c "SELECT datconnlimit FROM pg_database WHERE datname='one_minihouse'") = 0 ]]
jq -n --arg at "$(date -u +%FT%TZ)" \
  --arg source_image "$source_image" --arg target_image "$target_image" \
  --arg script_sha256 "$(sha256sum "$here/data.sh" | cut -d' ' -f1)" \
  '{passed:true,pg17_to17:true,selected_roles:true,password_hashes:true,memberships:true,acl_rls_sequences:true,
  freeze:true,other_database_unaffected:true,backup_restore:true,stale_rollback_refused:true,completed_at:$at,
  source_image:$source_image,target_image:$target_image,script_sha256:$script_sha256}' >"$root/result.json"
printf 'DATA_INTEGRATION_PASSED: %s\n' "$root/result.json"
