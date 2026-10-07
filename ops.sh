#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INVENTORY="${HA_INVENTORY:-$ROOT/.local/inventory.yml}"
TOOLS_IMAGE="${HA_TOOLS_IMAGE:-one-postgres-ha-tools:0.1.0}"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'USAGE'
Usage: bash ops.sh [--inventory FILE] COMMAND [ARGUMENTS]
  preflight | plan | deploy | status | verify | secrets | tools | check
  backup | restore-test | switchover | rollback [one_minihouse|nexus]
  migrate-plan|migrate-apply [one_minihouse|nexus]
  add-node NODE [--plan]
  install [--plan|--apply]
  cleanup [--plan|--apply [--confirm DELETE-ONE-POSTGRES-HA]]
  package

Inventory defaults to .local/inventory.yml. Windows: run through WSL.
preflight/plan read the site; secrets prepares local credentials, never resets them.
deploy prepares hosts and starts the cluster; it does not migrate business databases.
install runs secrets, plan, deploy, status and verify under one lock.
cleanup previews by default; applying deletes this cluster's PostgreSQL/etcd data.
USAGE
}
if [[ "${1:-}" == --inventory ]]; then
  [[ $# -ge 3 ]] || die '--inventory requires a file and command'
  INVENTORY="$2"; shift 2
fi
COMMAND="${1:-help}"
[[ $# -eq 0 ]] || shift
EXTRA=()
PLAYBOOK=''
READ_ONLY=false
INSTALL_APPLY=true
CLEANUP_APPLY=false
CLEANUP_CONFIRM=''
CONFIRMATION=DELETE-ONE-POSTGRES-HA
case "$COMMAND" in
  help|-h|--help) usage; exit 0 ;;
  tools|check|secrets|package) [[ $# -eq 0 ]] || die 'Unexpected arguments' ;;
  preflight|plan|status|verify|deploy|switchover)
    [[ $# -eq 0 ]] || die 'Unexpected arguments'
    PLAYBOOK="ansible/$COMMAND.yml"
    case "$COMMAND" in preflight|plan|status) READ_ONLY=true ;; esac
    ;;
  install)
    [[ $# -le 1 ]] || die 'install accepts only --plan or --apply'
    case "${1:---apply}" in
      --plan) INSTALL_APPLY=false ;;
      --apply) ;;
      *) die 'install accepts only --plan or --apply' ;;
    esac
    ;;
  cleanup)
    case "${1:---plan}" in
      --plan) [[ $# -le 1 ]] || die '--plan accepts no confirmation'; READ_ONLY=true ;;
      --apply)
        CLEANUP_APPLY=true
        if [[ $# -eq 3 && "$2" == --confirm ]]; then
          [[ "$3" == "$CONFIRMATION" ]] || die 'Incorrect cleanup confirmation'
          CLEANUP_CONFIRM=$3
        else
          [[ $# -eq 1 ]] || die 'cleanup --apply accepts only --confirm DELETE-ONE-POSTGRES-HA'
          [[ -t 0 ]] || die 'Non-interactive cleanup requires --confirm DELETE-ONE-POSTGRES-HA'
        fi
        ;;
      *) die 'cleanup accepts --plan or --apply [--confirm DELETE-ONE-POSTGRES-HA]' ;;
    esac
    PLAYBOOK=ansible/cleanup.yml
    ;;
  add-node)
    [[ $# -ge 1 && $# -le 2 ]] || die 'add-node requires NODE [--plan]'
    [[ "$1" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] || die 'Invalid node name'
    EXTRA+=(-e "add_node=$1")
    if [[ $# -eq 2 ]]; then
      [[ "$2" == --plan ]] || die 'Only --plan is supported'
      EXTRA+=(-e 'add_node_plan=true'); READ_ONLY=true
    fi
    PLAYBOOK=ansible/add-node.yml
    ;;
  backup|restore-test|migrate-plan|migrate-apply|rollback)
    [[ $# -le 1 ]] || die 'Unexpected arguments'
    DATABASE="${1:-one_minihouse}"
    [[ "$DATABASE" == one_minihouse || "$DATABASE" == nexus ]] || die 'Unsupported database'
    PLAYBOOK=ansible/data/main.yml
    EXTRA+=(-e "ha_data_operation=$COMMAND" -e "ha_data_database=$DATABASE")
    ;;
  *) die "Unknown command: $COMMAND" ;;
esac
if [[ "$COMMAND" == package ]]; then
  command -v git >/dev/null || die 'git is required'
  git -C "$ROOT" diff --quiet HEAD || die 'Commit tracked changes before packaging'
  [[ -z "$(git -C "$ROOT" ls-files --others --exclude-standard)" ]] || die 'Commit new files before packaging'
  mkdir -p "$ROOT/.local/dist"
  REV="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
  ARCHIVE="$ROOT/.local/dist/one-postgres-ha-$REV.tar.gz"
  git -C "$ROOT" archive --format=tar.gz --prefix=one-postgres-ha/ HEAD >"$ARCHIVE"
  (cd "$ROOT/.local/dist" && sha256sum "$(basename -- "$ARCHIVE")") >"$ARCHIVE.sha256"
  printf 'Deployment bundle: %s\n' "$ARCHIVE"; exit 0
fi
command -v docker >/dev/null || die 'Docker CLI is required; enable Docker Desktop WSL integration on Windows'
if [[ "$COMMAND" != tools && "$COMMAND" != check ]]; then
  [[ -f "$INVENTORY" ]] || die "Missing inventory: $INVENTORY; copy ansible/inventory.example.yml to .local/inventory.yml"
  INVENTORY="$(cd -- "$(dirname -- "$INVENTORY")" && pwd -P)/$(basename -- "$INVENTORY")"
fi
if [[ "$COMMAND" == install || "$COMMAND" == cleanup ]]; then
  [[ -s "$ROOT/.local/known_hosts" ]] || die 'Missing .local/known_hosts; verify each SSH host fingerprint before installation or cleanup'
fi
mkdir -p "$ROOT/.local"
controller_state() {
  local cid=$1 state containers
  if state=$(docker container inspect --format '{{.State.Running}}' "$cid" 2>/dev/null); then
    case "$state" in
      true) printf 'running'; return 0 ;;
      false) printf 'stopped'; return 0 ;;
      *) return 1 ;;
    esac
  fi
  # A failed inspect alone cannot distinguish removal from a daemon outage.
  if containers=$(docker container ls --all --quiet --no-trunc --filter "id=$cid" 2>/dev/null) && [[ -z "$containers" ]]; then
    printf 'removed'; return 0
  fi
  return 1
}
check_previous_controllers() {
  local file cid state
  for file in "$ROOT"/.local/tool.*/container.cid; do
    [[ -f "$file" ]] || continue
    cid=$(cat "$file")
    [[ "$cid" =~ ^[0-9a-f]{64}$ ]] || die "Unresolved controller record: $file"
    if ! state=$(controller_state "$cid"); then
      die "Cannot confirm the previous controller stopped; retained record: $file"
    fi
    [[ "$state" != running ]] || die "Previous controller is still running: $cid; retained record: $file"
    rm -f -- "$file"
    rmdir -- "$(dirname -- "$file")" 2>/dev/null || true
  done
}
if [[ "$READ_ONLY" != true ]]; then
  command -v flock >/dev/null || die 'flock is required'
  exec 9>"$ROOT/.local/operations.lock"
  flock -n 9 || die 'Another operation is running'
  check_previous_controllers
fi
TOOLS_REGISTRY="${TOOLS_IMAGE%%/*}"
TOOLS_PREBUILT=false
if [[ "$TOOLS_IMAGE" == */* && ( "$TOOLS_REGISTRY" == *.* || "$TOOLS_REGISTRY" == *:* || "$TOOLS_REGISTRY" == localhost ) ]]; then
  TOOLS_PREBUILT=true
  [[ "$TOOLS_IMAGE" =~ ^[a-z0-9][a-z0-9.:_-]*/[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[a-f0-9]{64}$ ]] \
    || die 'Registry HA_TOOLS_IMAGE must use a sha256 digest, without credentials or whitespace'
fi
if [[ "$COMMAND" == tools ]] || ! docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1; then
  if [[ "$TOOLS_PREBUILT" == true ]]; then
    docker pull "$TOOLS_IMAGE"
  else
    docker build --pull=false -f "$ROOT/images/tools/Dockerfile" -t "$TOOLS_IMAGE" "$ROOT"
  fi
fi
[[ "$COMMAND" != tools ]] || exit 0
RUN=(docker run --rm --init --read-only --tmpfs '/tmp:rw,exec,nosuid,size=256m'
  --mount "type=bind,src=$ROOT,dst=/workspace"
  --workdir /workspace
  -e ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
  -e ANSIBLE_HOME=/tmp/ansible-home
  -e ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg)
if [[ "$COMMAND" == check ]]; then
  # Systemd fixtures use a private, root-owned directory under /run.
  RUN+=(--tmpfs '/run:rw,noexec,nosuid,size=16m')
fi
TOOL_PID=''
TOOL_DIR=$(mktemp -d "$ROOT/.local/tool.XXXXXXXX")
TOOL_CID="$TOOL_DIR/container.cid"
RUN+=(--cidfile "$TOOL_CID")
cleanup_tool() {
  local result=$? cid state preserved=false
  trap - EXIT TERM INT
  if [[ -n "$TOOL_PID" ]]; then
    # Stop the client first so it cannot issue a late ContainerStart. Docker's
    # signal proxy can keep a TERM'd client alive; stop the container below.
    kill -KILL "$TOOL_PID" 2>/dev/null || true
    wait "$TOOL_PID" 2>/dev/null || true
  fi
  if [[ -s "$TOOL_CID" ]]; then
    cid=$(cat "$TOOL_CID")
    if [[ "$cid" =~ ^[0-9a-f]{64}$ ]]; then
      docker stop --time 30 "$cid" >/dev/null 2>&1 || true
      if ! state=$(controller_state "$cid") || [[ "$state" == running ]]; then
        preserved=true
      fi
    else
      preserved=true
    fi
  fi
  if [[ "$preserved" == true ]]; then
    printf 'ERROR: Controller shutdown could not be confirmed; retained record: %s\n' "$TOOL_CID" >&2
    [[ "$result" != 0 ]] || result=70
  else
    rm -f -- "$TOOL_CID"
    rm -f -- "$TOOL_DIR/inventory.yml"
    rmdir -- "$TOOL_DIR" 2>/dev/null || true
  fi
  exit "$result"
}
trap cleanup_tool EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
run_tool() {
  local result=0 cid state
  # A multi-stage operation reuses the controller path, never a live container.
  if [[ -e "$TOOL_CID" ]]; then
    cid=$(cat "$TOOL_CID")
    [[ "$cid" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid controller record between stages'
    state=$(controller_state "$cid") || die 'Cannot confirm controller shutdown between stages'
    [[ "$state" != running ]] || die 'Previous controller is still running between stages'
    rm -f -- "$TOOL_CID"
  fi
  "${RUN[@]}" "$@" &
  TOOL_PID=$!
  wait "$TOOL_PID" || result=$?
  TOOL_PID=''
  return "$result"
}
if [[ "$COMMAND" == check ]]; then
  run_tool "$TOOLS_IMAGE" bash tests/check.sh; exit 0
fi
if [[ "$COMMAND" == install || "$COMMAND" == cleanup ]]; then
  # Preview, confirmation and execution must use the same private host list.
  cp -- "$INVENTORY" "$TOOL_DIR/inventory.yml"
  chmod 0600 "$TOOL_DIR/inventory.yml"
  INVENTORY="$TOOL_DIR/inventory.yml"
fi
RUN+=(--mount "type=bind,src=$INVENTORY,dst=/inventory.yml,readonly")
if [[ -f "$ROOT/.local/known_hosts" ]]; then
  RUN+=(--mount "type=bind,src=$ROOT/.local/known_hosts,dst=/tmp/known_hosts,readonly"
    -e 'ANSIBLE_SSH_ARGS=-C -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/known_hosts')
fi
if [[ -n "${HA_SSH_KEY:-}" ]]; then
  [[ -f "$HA_SSH_KEY" ]] || die 'HA_SSH_KEY must point to a private key file'
  RUN+=(--mount "type=bind,src=$HA_SSH_KEY,dst=/ssh-key,readonly"
    -e ANSIBLE_PRIVATE_KEY_FILE=/ssh-key)
fi
run_playbook() {
  run_tool "$TOOLS_IMAGE" ansible-playbook -i /inventory.yml "$1" \
    -e project_root=/workspace -e private_dir=/workspace/.local "${@:2}"
}
if [[ "$COMMAND" == install ]]; then
  if [[ "$INSTALL_APPLY" == true ]]; then
    run_tool "$TOOLS_IMAGE" bash scripts/bootstrap-secrets.sh /inventory.yml /workspace/.local/secrets
  fi
  # plan and deploy both include the remote preflight checks.
  run_playbook ansible/plan.yml
  if [[ "$INSTALL_APPLY" == true ]]; then
    run_playbook ansible/deploy.yml
    run_playbook ansible/status.yml
    run_playbook ansible/verify.yml
    printf 'INSTALL_COMPLETE: cluster deployed and verified; no business databases migrated.\n'
  else
    printf 'INSTALL_PLAN_COMPLETE: no credentials or remote services changed.\n'
  fi
elif [[ "$COMMAND" == cleanup ]]; then
  run_playbook "$PLAYBOOK" -e ha_cleanup_apply=false
  if [[ "$CLEANUP_APPLY" == true ]]; then
    if [[ -z "$CLEANUP_CONFIRM" ]]; then
      printf 'All displayed PostgreSQL/etcd data will be permanently deleted.\nType %s to continue: ' "$CONFIRMATION" >&2
      IFS= read -r CLEANUP_CONFIRM || die 'Cleanup confirmation was not provided'
      [[ "$CLEANUP_CONFIRM" == "$CONFIRMATION" ]] || die 'Cleanup cancelled: confirmation did not match'
    fi
    run_playbook "$PLAYBOOK" -e ha_cleanup_apply=true
    printf 'CLEANUP_COMPLETE: cluster removed; controller configuration and credentials retained.\n'
  else
    printf 'CLEANUP_PLAN_COMPLETE: no services or data changed. Apply with --apply after reviewing the displayed scope.\n'
  fi
elif [[ "$COMMAND" == secrets ]]; then
  run_tool "$TOOLS_IMAGE" bash scripts/bootstrap-secrets.sh /inventory.yml /workspace/.local/secrets
else
  run_playbook "$PLAYBOOK" "${EXTRA[@]}"
fi
