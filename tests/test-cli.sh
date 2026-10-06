#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project/.local"
cp "$root/ops.sh" "$tmp/project/ops.sh"
echo 'all: {}' >"$tmp/project/.local/inventory.yml"
cat >"$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" != run ]] || printf '%s\0' "$@" >"$MOCK_LOG"
if [[ ${MOCK_DAEMON_FAILURE:-false} == true && ( $1 == stop || $1 == container ) ]]; then
  exit 125
fi
case "$1 ${2:-}" in
  'container inspect') printf '%s\n' "${MOCK_CONTROLLER_RUNNING:-false}" ;;
  'container ls') exit 0 ;;
esac
if [[ ${MOCK_DELAY:-false} == true ]]; then
  case "$1" in
    run)
      while [[ $# -gt 0 ]]; do
        if [[ $1 == --cidfile ]]; then printf '%064d' 1 >"$2"; break; fi
        shift
      done
      touch "$MOCK_STARTED"
      exec sleep 30
      ;;
    stop) touch "$MOCK_STOPPED" ;;
  esac
fi
MOCK
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/arguments"
expect_failure() {
  if bash "$tmp/project/ops.sh" "$@" >"$tmp/out" 2>&1; then
    echo "Expected rejection: $*" >&2; exit 1
  fi
}
expect_failure add-node 'node;touch-bad'
expect_failure add-node node04 --apply
expect_failure migrate-apply postgres
expect_failure --inventory
bash "$tmp/project/ops.sh" add-node node04 --plan
mapfile -d '' args <"$tmp/arguments"
printf '%s\n' "${args[@]}" | grep -Fxq 'add_node_plan=true'
printf '%s\n' "${args[@]}" | grep -Fxq 'ansible/add-node.yml'
exec 8>"$tmp/project/.local/operations.lock"
flock -n 8
expect_failure deploy
expect_failure migrate-plan
bash "$tmp/project/ops.sh" status
flock -u 8
bash "$tmp/project/ops.sh" migrate-apply nexus
mapfile -d '' args <"$tmp/arguments"
printf '%s\n' "${args[@]}" | grep -Fxq 'ha_data_database=nexus'
export MOCK_DELAY=true MOCK_STARTED="$tmp/started" MOCK_STOPPED="$tmp/stopped"
bash "$tmp/project/ops.sh" deploy &
operation_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ ! -f "$MOCK_STARTED" ]] || break
  sleep 0.02
done
[[ -f "$MOCK_STARTED" ]]
if flock -n 8; then echo 'Operation failed to hold its lock' >&2; exit 1; fi
kill -TERM "$operation_pid"
result=0
wait "$operation_pid" || result=$?
[[ $result == 143 && -f "$MOCK_STOPPED" ]]
flock -n 8
flock -u 8

# Losing access to the daemon must preserve evidence and block another writer.
rm -f -- "$MOCK_STARTED" "$MOCK_STOPPED"
export MOCK_DAEMON_FAILURE=true
bash "$tmp/project/ops.sh" deploy >"$tmp/uncertain.out" 2>&1 &
operation_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ ! -f "$MOCK_STARTED" ]] || break
  sleep 0.02
done
[[ -f "$MOCK_STARTED" ]]
kill -TERM "$operation_pid"
result=0
wait "$operation_pid" || result=$?
[[ $result == 143 ]]
mapfile -t records < <(find "$tmp/project/.local" -name container.cid -type f)
[[ ${#records[@]} == 1 && -s ${records[0]} ]]
expect_failure deploy
[[ -s ${records[0]} ]]
export MOCK_DAEMON_FAILURE=false MOCK_CONTROLLER_RUNNING=true
expect_failure deploy
[[ -s ${records[0]} ]]
export MOCK_DELAY=false MOCK_CONTROLLER_RUNNING=false
bash "$tmp/project/ops.sh" deploy
[[ ! -e ${records[0]} ]]
echo 'PASS: CLI validation, routing, exclusion, SIGTERM cleanup and uncertain-controller guard'
