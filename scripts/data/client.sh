#!/usr/bin/env bash
# Client changes are deliberately specific: no eval, arbitrary hooks or generated shell.
set -Eeuo pipefail
umask 077
die() {
  printf 'client: %s\n' "$*" >&2
  exit 1
}
safe_path() { [[ $1 =~ ^/[A-Za-z0-9_./-]+$ && $1 != / && ! -L $1 ]] || die 'use an absolute non-symlink path without spaces'; }
safe_host() { [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]] || die 'invalid endpoint host'; }
operation=${1:-}
shift || true
case $operation in
  queue-backup)
    [[ $# = 2 ]] || die 'queue-backup QUEUE STATE_DIRECTORY'
    queue=$1 state=$2
    safe_path "$queue"
    safe_path "$state"
    [[ -f $queue ]] || die 'ingestor queue is missing'
    mkdir -p -- "$state"
    [[ ! -e $state/inbox.sqlite ]] || die 'queue backup already exists; inspect the previous migration state'
    sqlite3 -batch "$queue" ".timeout 30000" ".backup '$state/inbox.sqlite'"
    [[ $(sqlite3 -batch "$state/inbox.sqlite" 'PRAGMA integrity_check;') = ok ]] || die 'queue backup integrity failed'
    failed=$(sqlite3 -readonly "$queue" "SELECT count(*) FROM delivery_job WHERE target_id='local' AND status='failed';")
    jq -n --argjson failed "$failed" --argjson cutoff "$(date -u +%s000)" \
      '{failed_before:$failed,cutoff_ms:$cutoff}' >"$state/queue-before.json"
    ;;
  ingestor-switch | ingestor-check)
    [[ $# = 3 ]] || die 'ingestor-switch CONFIG OLD_HOST NEW_HOST'
    file=$1 old=$2 new=$3
    safe_path "$file"
    safe_host "$old"
    safe_host "$new"
    [[ -f $file ]] || die 'ingestor config missing'
    jq -e --arg old "$old" '[.targets[] | select(.id=="local")] | length==1 and .[0].host==$old and .[0].port==5432' "$file" >/dev/null ||
      die 'local target must match the expected PG17 endpoint on port5432'
    [[ ! -e $file.pg-ha-before ]] || die 'ingestor configuration backup exists; inspect previous switch'
    [[ $operation != ingestor-check ]] || exit 0
    cp -p -- "$file" "$file.pg-ha-before"
    temp=$(mktemp "${file}.pg-ha.XXXXXX")
    trap 'rm -f -- "${temp:-}"' EXIT
    jq --arg host "$new" '(.targets[] | select(.id=="local") | .host)=$host' "$file" >"$temp"
    # Compare normalized content after masking the single intended field.
    cmp -s <(jq -S '(.targets[]|select(.id=="local")|.host)="MASKED"' "$file") \
      <(jq -S '(.targets[]|select(.id=="local")|.host)="MASKED"' "$temp") || die 'unexpected configuration change'
    chown --reference="$file" "$temp"
    chmod --reference="$file" "$temp"
    mv -f -- "$temp" "$file"
    ;;
  queue-cutoff)
    [[ $# = 1 ]] || die 'queue-cutoff STATE_DIRECTORY'
    state=$1
    safe_path "$state"
    jq --argjson cutoff "$(date -u +%s000)" '.cutoff_ms=$cutoff' "$state/queue-before.json" >"$state/queue-before.tmp"
    mv -f -- "$state/queue-before.tmp" "$state/queue-before.json"
    ;;
  queue-verify)
    [[ $# = 3 ]] || die 'queue-verify QUEUE HEALTH STATE_DIRECTORY'
    queue=$1 health=$2 state=$3
    safe_path "$queue"
    safe_path "$health"
    safe_path "$state"
    before=$(jq -er '.failed_before' "$state/queue-before.json")
    cutoff=$(jq -er '.cutoff_ms' "$state/queue-before.json")
    ok=false
    for ((i = 0; i < 120; i++)); do
      failed=$(sqlite3 -readonly "$queue" "SELECT count(*) FROM delivery_job WHERE target_id='local' AND status='failed';")
      [[ $failed -le $before ]] || die 'permanent local delivery failures increased'
      pending=$(sqlite3 -readonly "$queue" "SELECT count(*) FROM delivery_job WHERE target_id='local' AND status='pending' AND create_time_utc<=$cutoff;")
      recent=$(sqlite3 -readonly "$queue" "SELECT count(*) FROM delivery_job WHERE target_id='local' AND status='done' AND outcome IS DISTINCT FROM 'expired' AND update_time_utc>=$cutoff;")
      if [[ $pending = 0 && $recent -gt 0 ]] && jq -e --argjson now "$(date -u +%s)" \
        '.targets.local.error==null and .mqtt_connected==true and .subscribed==true and .intake_paused==false and ($now-(.heartbeat_time_utc|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601))<60' "$health" >/dev/null 2>&1; then
        ok=true
        break
      fi
      sleep 5
    done
    [[ $ok = true ]] || die 'local backlog or actual post-switch delivery did not recover; repair the target PostgreSQL17 deployment'
    ;;
  nexus-switch | nexus-check)
    [[ $# = 4 ]] || die 'nexus-switch PROPERTIES KEY OLD_HOST NEW_HOST'
    file=$1 key=$2 old=$3 new=$4
    safe_path "$file"
    safe_host "$old"
    safe_host "$new"
    [[ $key =~ ^[a-zA-Z][a-zA-Z0-9_.]+$ && -f $file ]] || die 'invalid JDBC property file/key'
    [[ ! -e $file.pg-ha-before ]] || die 'JDBC configuration backup exists; inspect previous switch'
    prefix="$key=jdbc:postgresql://$old:5432/"
    replacement="$key=jdbc:postgresql://$new:5432/"
    temp=$(mktemp "${file}.pg-ha.XXXXXX")
    changed=0
    trap 'rm -f -- "${temp:-}"' EXIT
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line = "$prefix"* ]]; then
        printf '%s%s\n' "$replacement" "${line#"$prefix"}"
        ((changed += 1))
      else printf '%s\n' "$line"; fi
    done <"$file" >"$temp"
    [[ $changed = 1 ]] || die 'expected exactly one literal JDBC URL on port5432; escaped/multiline properties need explicit review'
    [[ $operation != nexus-check ]] || exit 0
    cp -p -- "$file" "$file.pg-ha-before"
    chown --reference="$file" "$temp"
    chmod --reference="$file" "$temp"
    mv -f -- "$temp" "$file"
    ;;
  grafana-switch | grafana-check)
    [[ $# = 5 ]] || die 'grafana-switch URL UID TOKEN_FILE OLD_HOST NEW_HOST'
    url=${1%/}
    uid=$2 token=$3 old=$4 new=$5
    [[ $url =~ ^https?://[A-Za-z0-9_.:-]+$ && $uid =~ ^[A-Za-z0-9_-]+$ ]] || die 'invalid Grafana URL or UID'
    safe_path "$token"
    safe_host "$old"
    safe_host "$new"
    [[ -f $token ]] || die 'Grafana API token is missing'
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    value=$(cat -- "$token")
    [[ $value != *$'\n'* && -n $value ]] || die 'invalid token'
    printf 'Authorization: Bearer %s\n' "$value" >"$work/header"
    curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
      --header "@$work/header" "$url/api/datasources/uid/$uid" >"$work/before.json"
    jq -e --arg uid "$uid" --arg old "$old:5432" '.uid==$uid and .type=="grafana-postgresql-datasource" and .url==$old' "$work/before.json" >/dev/null ||
      die 'Grafana datasource must match the existing UID and old endpoint'
    [[ $operation != grafana-check ]] || exit 0
    jq --arg host "$new:5432" '.url=$host | del(.id,.orgId,.version,.typeLogoUrl,.readOnly)' "$work/before.json" >"$work/update.json"
    curl --fail --silent --show-error --connect-timeout 10 --max-time 60 --request PUT \
      --header "@$work/header" --header 'Content-Type: application/json' --data-binary "@$work/update.json" \
      "$url/api/datasources/uid/$uid" >"$work/result.json"
    curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
      --header "@$work/header" "$url/api/datasources/uid/$uid" >"$work/after.json"
    jq -e --arg uid "$uid" --arg host "$new:5432" '.uid==$uid and .url==$host' "$work/after.json" >/dev/null || die 'Grafana readback failed'
    cmp -s <(jq -S 'del(.url,.version)' "$work/before.json") <(jq -S 'del(.url,.version)' "$work/after.json") ||
      die 'Grafana properties changed beyond the endpoint; investigate before proceeding'
    curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
      --header "@$work/header" "$url/api/datasources/uid/$uid/health" >"$work/health.json"
    jq -e '.status=="OK"' "$work/health.json" >/dev/null || die 'Grafana datasource health check failed'
    ;;
  *) die 'unsupported client operation' ;;
esac
