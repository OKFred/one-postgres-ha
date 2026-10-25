#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INVENTORY="${HA_INVENTORY:-$ROOT/.local/inventory.yml}"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'USAGE'
Usage: bash ops.sh [--inventory FILE] COMMAND [ARGUMENTS]
  configure | preflight | plan | deploy | status | verify | secrets | tools | check
  backup | restore-test | switchover | rollback [one_minihouse|nexus]
  migrate-plan|migrate-apply [one_minihouse|nexus]
  add-node NODE [--plan]
  install [--plan|--apply]
  uninstall [--plan|--apply] [--keep-data|--purge-data] [--confirm TOKEN]
  package
  sources [auto|official|ustc|tuna|--show]

Inventory defaults to .local/inventory.yml. Windows: run through WSL.
preflight/plan read the site; secrets prepares local credentials, never resets them.
configure interactively creates fresh private configuration; it never deploys services.
deploy prepares hosts and starts the cluster; it does not migrate business databases.
install runs secrets, plan, deploy, status and verify under one lock.
Use install.sh/uninstall.sh for the shared interactive entrypoints.
uninstall defaults to a keep-data preview.
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
CLEANUP_LEVEL=purge-data
CONFIRMATION=DELETE-ONE-POSTGRES-HA
case "$COMMAND" in
  help|-h|--help) usage; exit 0 ;;
  sources) exec bash "$ROOT/scripts/download-sources.sh" "$@" ;;
  uninstall) exec bash "$ROOT/uninstall.sh" --inventory "$INVENTORY" "$@" ;;
  configure)
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
      [[ $# -eq 1 ]] || die 'Unexpected arguments'
      exec bash "$ROOT/scripts/configure.sh" --help
    fi
    [[ $# -eq 0 ]] || die 'configure accepts no arguments'
    [[ "$INVENTORY" == "$ROOT/.local/inventory.yml" ]] || die 'configure writes only .local/inventory.yml; do not specify another inventory'
    [[ -t 0 && -t 1 ]] || die 'configure requires an interactive terminal; Windows: use WSL'
    ;;
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
    # Internal backend for uninstall.sh; operators use the common root entry.
    cleanup_mode='' cleanup_level_seen=false
    while (($#)); do
      case "$1" in
        --plan|--apply)
          [[ -z $cleanup_mode ]] || die 'Choose --plan or --apply once'; cleanup_mode=$1 ;;
        --keep-data|--purge-data)
          [[ $cleanup_level_seen == false ]] || die 'Choose --keep-data or --purge-data once'
          cleanup_level_seen=true; CLEANUP_LEVEL=${1#--} ;;
        --confirm)
          [[ $# -ge 2 && -n $2 && -z $CLEANUP_CONFIRM ]] || die '--confirm requires one token'
          CLEANUP_CONFIRM=$2; shift ;;
        *) die 'cleanup accepts --plan|--apply, --keep-data|--purge-data and --confirm TOKEN' ;;
      esac
      shift
    done
    if [[ $CLEANUP_LEVEL == keep-data ]]; then CONFIRMATION=UNINSTALL-ONE-POSTGRES-HA; fi
    if [[ ${cleanup_mode:---plan} == --apply ]]; then
      CLEANUP_APPLY=true
      if [[ -n $CLEANUP_CONFIRM ]]; then
        [[ $CLEANUP_CONFIRM == "$CONFIRMATION" ]] || die 'Incorrect cleanup confirmation'
      else
        [[ -t 0 ]] || die "Non-interactive cleanup requires --confirm $CONFIRMATION"
      fi
    else
      [[ -z $CLEANUP_CONFIRM ]] || die '--confirm requires --apply'
      READ_ONLY=true
    fi
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
# Parse the wizard's private settings as data, never execute a shell config file.
[[ ! -L "$ROOT/.local" ]] || die 'Private directory must not be a symlink'
CONTROLLER_ENV="$ROOT/.local/controller.env"
if [[ -e "$CONTROLLER_ENV" || -L "$CONTROLLER_ENV" ]]; then
  [[ -f "$CONTROLLER_ENV" && ! -L "$CONTROLLER_ENV" ]] || die 'Invalid .local/controller.env'
  declare -A CONTROLLER_SEEN=()
  while IFS= read -r setting || [[ -n "$setting" ]]; do
    [[ -n "$setting" && "$setting" != \#* ]] || continue
    [[ "$setting" != *$'\r'* && "$setting" == *=* ]] || die 'Invalid controller setting'
    key=${setting%%=*}
    value=${setting#*=}
    [[ "$key" == HA_TOOLS_IMAGE || "$key" == HA_SSH_KEY ]] || die 'Unknown controller setting'
    [[ -z ${CONTROLLER_SEEN[$key]:-} ]] || die 'Duplicate controller setting'
    CONTROLLER_SEEN[$key]=1
    case "$key" in
      HA_TOOLS_IMAGE)
        [[ "$value" =~ ^[a-z0-9][a-z0-9_.-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$ ||
           "$value" =~ ^[a-z0-9][a-z0-9.:_-]*/[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[a-f0-9]{64}$ ]] || die 'Invalid saved tools image'
        if [[ "$value" == */* ]]; then
          registry=${value%%/*}
          [[ "$registry" == *.* || "$registry" == *:* || "$registry" == localhost ]] || die 'Saved tools image requires a registry hostname'
        fi
        HA_TOOLS_IMAGE=${HA_TOOLS_IMAGE:-$value}
        ;;
      HA_SSH_KEY)
        [[ "$value" == /* && "$value" != *$'\t'* && "$value" != *,* ]] || die 'Saved HA_SSH_KEY must be an absolute path without tabs or commas'
        HA_SSH_KEY=${HA_SSH_KEY:-$value}
        ;;
      *) die 'Unknown controller setting' ;;
    esac
  done <"$CONTROLLER_ENV"
fi
TOOLS_IMAGE="${HA_TOOLS_IMAGE:-one-postgres-ha-tools:pg17.11}"
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
if [[ "$COMMAND" != tools && "$COMMAND" != check && "$COMMAND" != configure ]]; then
  [[ -f "$INVENTORY" ]] || die "Missing inventory: $INVENTORY; copy ansible/inventory.example.yml to .local/inventory.yml"
  INVENTORY="$(cd -- "$(dirname -- "$INVENTORY")" && pwd -P)/$(basename -- "$INVENTORY")"
fi
if [[ "$COMMAND" == install || "$COMMAND" == cleanup ]]; then
  [[ -s "$ROOT/.local/known_hosts" ]] || die 'Missing .local/known_hosts; verify each SSH host fingerprint before installation or cleanup'
fi
# Resolve download settings before the first tool build. Explicit environment
# overrides are transient; the sources command and auto detection save a choice.
source_request=${HA_DOWNLOAD_SOURCE:-}
if [[ -z $source_request ]]; then
  if [[ -e "$ROOT/.local/download-source" || -L "$ROOT/.local/download-source" ]]; then
    source_request=saved
  elif [[ ($COMMAND == configure || $COMMAND == tools) && ! -e $INVENTORY && -t 0 && -t 1 ]]; then
    source_request=auto
  else
    source_request=official
  fi
fi
case "$source_request" in
  official|ustc|tuna) HA_DOWNLOAD_SOURCE=$source_request ;;
  auto|saved) HA_DOWNLOAD_SOURCE=$(bash "$ROOT/scripts/download-sources.sh" --resolve "$source_request") ;;
  *) die 'HA_DOWNLOAD_SOURCE must be auto, official, ustc or tuna' ;;
esac
export HA_DOWNLOAD_SOURCE
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
    docker build --pull=false --build-arg "DOWNLOAD_SOURCE=$HA_DOWNLOAD_SOURCE" \
      -f "$ROOT/images/tools/Dockerfile" -t "$TOOLS_IMAGE" "$ROOT"
  fi
fi
[[ "$COMMAND" != tools ]] || exit 0
RUN=(docker run --rm --init --read-only --tmpfs '/tmp:rw,exec,nosuid,size=256m'
  --mount "type=bind,src=$ROOT,dst=/workspace"
  --workdir /workspace
  -e ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
  -e ANSIBLE_HOME=/tmp/ansible-home
  -e "HA_DOWNLOAD_SOURCE=$HA_DOWNLOAD_SOURCE"
  -e ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg)
if [[ "$COMMAND" == configure ]]; then
  RUN+=(--interactive --tty -e "HA_CONFIGURE_TOOLS_IMAGE=$TOOLS_IMAGE")
  exec 7<&0
fi
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
  if [[ "$COMMAND" == configure ]]; then
    # Background shell commands otherwise lose stdin; preserve the user's TTY.
    "${RUN[@]}" "$@" <&7 &
  else
    "${RUN[@]}" "$@" &
  fi
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
if [[ "$COMMAND" != configure ]]; then
  RUN+=(--mount "type=bind,src=$INVENTORY,dst=/inventory.yml,readonly")
fi
if [[ -f "$ROOT/.local/known_hosts" ]]; then
  RUN+=(--mount "type=bind,src=$ROOT/.local/known_hosts,dst=/tmp/known_hosts,readonly"
    -e 'ANSIBLE_SSH_ARGS=-C -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/known_hosts')
fi
if [[ -n "${HA_SSH_KEY:-}" ]]; then
  [[ -f "$HA_SSH_KEY" ]] || die 'HA_SSH_KEY must point to a private key file'
  RUN+=(--mount "type=bind,src=$HA_SSH_KEY,dst=/ssh-key,readonly"
    -e ANSIBLE_PRIVATE_KEY_FILE=/ssh-key)
  if [[ "$COMMAND" == configure ]]; then
    RUN+=(-e HA_CONFIGURE_KEY_PATH=/ssh-key -e "HA_CONFIGURE_KEY_HOST_PATH=$HA_SSH_KEY")
  fi
fi
run_playbook() {
  run_tool "$TOOLS_IMAGE" ansible-playbook -i /inventory.yml "$1" \
    -e project_root=/workspace -e private_dir=/workspace/.local "${@:2}"
}
if [[ "$COMMAND" == configure ]]; then
  run_tool "$TOOLS_IMAGE" bash scripts/configure.sh
elif [[ "$COMMAND" == install ]]; then
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
  run_playbook "$PLAYBOOK" -e ha_cleanup_apply=false -e "ha_cleanup_level=$CLEANUP_LEVEL"
  if [[ "$CLEANUP_APPLY" == true ]]; then
    if [[ -z "$CLEANUP_CONFIRM" ]]; then
      if [[ $CLEANUP_LEVEL == purge-data ]]; then
        printf 'All displayed PostgreSQL/etcd data will be permanently deleted.\n' >&2
      else
        printf 'Remove this cluster runtime; retain PostgreSQL/etcd data and node configuration.\n' >&2
      fi
      printf 'Type %s to continue: ' "$CONFIRMATION" >&2
      IFS= read -r CLEANUP_CONFIRM || die 'Cleanup confirmation was not provided'
      [[ "$CLEANUP_CONFIRM" == "$CONFIRMATION" ]] || die 'Cleanup cancelled: confirmation did not match'
    fi
    run_playbook "$PLAYBOOK" -e ha_cleanup_apply=true -e "ha_cleanup_level=$CLEANUP_LEVEL"
    printf 'CLEANUP_COMPLETE: level=%s; controller configuration and credentials retained.\n' "$CLEANUP_LEVEL"
  else
    printf 'CLEANUP_PLAN_COMPLETE: no services or data changed. Apply with --apply after reviewing the displayed scope.\n'
  fi
elif [[ "$COMMAND" == secrets ]]; then
  run_tool "$TOOLS_IMAGE" bash scripts/bootstrap-secrets.sh /inventory.yml /workspace/.local/secrets
else
  run_playbook "$PLAYBOOK" "${EXTRA[@]}"
fi
