#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d /tmp/ha-client-test.XXXXXX)
writer=''
cleanup() {
  if [[ -n $writer ]]; then
    kill "$writer" 2>/dev/null || true
    wait "$writer" 2>/dev/null || true
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
cat >"$work/ingestor.json" <<'JSON'
{"mqtt":{"clientId":"fixture-retained"},"queue":{"maxPending":100000},"targets":[{"id":"local","host":"192.0.2.206","port":5432,"database":"one_minihouse","user":"example_writer","passwordFile":"/fixture-secret"},{"id":"supabase","host":"cloud.example.com","port":5432,"database":"postgres"}]}
JSON
cp "$work/ingestor.json" "$work/before-check.json"
bash "$here/client.sh" ingestor-check "$work/ingestor.json" 192.0.2.206 192.0.2.20
cmp "$work/ingestor.json" "$work/before-check.json"
bash "$here/client.sh" ingestor-switch "$work/ingestor.json" 192.0.2.206 192.0.2.20
jq -e '.targets[0].host=="192.0.2.20" and .targets[1].host=="cloud.example.com" and .mqtt.clientId=="fixture-retained"' "$work/ingestor.json" >/dev/null
if bash "$here/client.sh" ingestor-switch "$work/ingestor.json" 192.0.2.206 192.0.2.20 >/dev/null 2>&1; then
  echo 'unexpected repeat endpoint rewrite' >&2
  exit 1
fi
cat >"$work/nexus.properties" <<'PROPERTIES'
jdbcUrl=jdbc:postgresql://nexus-postgres:5432/nexus?connectTimeout=10
username=example_user
maximumPoolSize=20
PROPERTIES
bash "$here/client.sh" nexus-check "$work/nexus.properties" jdbcUrl nexus-postgres 192.0.2.20
bash "$here/client.sh" nexus-switch "$work/nexus.properties" jdbcUrl nexus-postgres 192.0.2.20
grep -qx 'jdbcUrl=jdbc:postgresql://192.0.2.20:5432/nexus?connectTimeout=10' "$work/nexus.properties"
cmp <(tail -n +2 "$work/nexus.properties") <(tail -n +2 "$work/nexus.properties.pg-ha-before")

# Keep the writer open so its committed record remains in WAL, not a copied main file.
{
  printf "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE delivery_job(target_id TEXT,status TEXT,outcome TEXT,create_time_utc INTEGER,update_time_utc INTEGER); INSERT INTO delivery_job VALUES('local','pending',NULL,0,0);\n"
  sleep 30
} | sqlite3 -batch "$work/inbox.sqlite" >"$work/writer-output" &
writer=$!
ready=false
for ((i = 0; i < 10; i++)); do
  if [[ -s $work/inbox.sqlite-wal ]] && [[ $(sqlite3 -readonly "$work/inbox.sqlite" 'SELECT count(*) FROM delivery_job;' 2>/dev/null) = 1 ]]; then
    ready=true
    break
  fi
  sleep 1
done
[[ $ready = true ]]
bash "$here/client.sh" queue-backup "$work/inbox.sqlite" "$work/state"
[[ $(sqlite3 "$work/state/inbox.sqlite" 'SELECT count(*) FROM delivery_job;') = 1 ]]
bash "$here/client.sh" queue-cutoff "$work/state"
sqlite3 "$work/inbox.sqlite" "UPDATE delivery_job SET status='done',outcome='confirmed',update_time_utc=$(date -u +%s000);"
jq -n --arg at "$(date -u +%FT%T.000Z)" '{targets:{local:{error:null}},mqtt_connected:true,subscribed:true,intake_paused:false,heartbeat_time_utc:$at}' >"$work/health.json"
bash "$here/client.sh" queue-verify "$work/inbox.sqlite" "$work/health.json" "$work/state"
printf 'CLIENT_TEST_PASSED: host-only changes, retained settings and committed WAL backup\n'
