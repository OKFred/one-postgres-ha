#!/usr/bin/env bash
# Real isolated official-image initialization; never reads inventory or site credentials.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
mkdir -p "$ROOT/.local/data-tests"
WORK=$(mktemp -d "$ROOT/.local/data-tests/readiness.XXXXXXXX")
cluster="ha-ready-$RANDOM-$$"
restore_container="ha-restore-$cluster-$$"
READY_JOB=''
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$READY_JOB" ]]; then
    kill "$READY_JOB" >/dev/null 2>&1 || true
    wait "$READY_JOB" >/dev/null 2>&1 || true
  fi
  command docker rm -fv "$restore_container" >/dev/null 2>&1 || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$WORK/init"
chmod 755 "$WORK/init"
cat >"$WORK/init/hold.sh" <<'SH'
#!/usr/bin/env bash
printf 'temporary-server\n' >/phase/held
while [[ ! -f /phase/release ]]; do sleep 0.1; done
SH
chmod 644 "$WORK/init/hold.sh"

# Load the production start_restore function without running the data CLI.
awk '/^start_restore\(\) \{/ {copy=1} copy {print} copy && /^\}$/ {exit}' "$ROOT/scripts/data/data.sh" >"$WORK/start-restore.sh"
[[ -s "$WORK/start-restore.sh" ]]
source "$WORK/start-restore.sh"
die() {
  printf 'readiness: %s\n' "$*" >&2
  exit 1
}
# Globals consumed by the sourced production start_restore function.
# shellcheck disable=SC2034
image=$(sed -n 's/^POSTGRES_BASE_IMAGE=//p' "$ROOT/versions.lock")
# shellcheck disable=SC2034
work=$WORK
docker() {
  if [[ $1 == run ]]; then
    local args=("$@")
    command docker "${args[@]:0:${#args[@]}-1}" \
      --mount "type=bind,src=$WORK/init,dst=/docker-entrypoint-initdb.d,readonly" \
      --tmpfs /phase:rw,mode=1777 "${args[-1]}"
  else
    command docker "$@"
  fi
}
(
  trap - EXIT INT TERM
  start_restore
  touch "$WORK/final-ready"
) >"$WORK/readiness.log" 2>&1 &
READY_JOB=$!
temporary_ready=false
for ((i = 0; i < 120; i++)); do
  if docker exec "$restore_container" test -f /phase/held >/dev/null 2>&1; then
    temporary_ready=true
    break
  fi
  sleep 0.25
done
[[ "$temporary_ready" == true ]]
docker exec "$restore_container" pg_isready -U postgres >"$WORK/temporary-socket.txt"
if docker exec "$restore_container" pg_isready -h 127.0.0.1 -p 5432 -U postgres >"$WORK/temporary-tcp.txt"; then
  die 'temporary init server unexpectedly accepted TCP'
fi
sleep 2
[[ ! -f "$WORK/final-ready" ]] || die 'production readiness accepted the temporary init server'
docker exec -u 0 "$restore_container" touch /phase/release
wait "$READY_JOB"
READY_JOB=''
[[ -f "$WORK/final-ready" ]]
docker exec "$restore_container" pg_isready -h 127.0.0.1 -p 5432 -U postgres >"$WORK/final-tcp.txt"
[[ $(docker exec "$restore_container" psql -X -A -t -U postgres -d postgres -c 'SELECT 1') == 1 ]]
printf 'PASS: production restore readiness waits through socket-only initialization for final TCP service\n'
