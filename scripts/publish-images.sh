#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'USAGE'
Usage: bash scripts/publish-images.sh REGISTRY/NAMESPACE [--plan|--push] [--builder NAME]
Preview by default. --push publishes linux/amd64 and linux/arm64 from committed HEAD.
Docker must already be logged in. Existing destination tags are never overwritten.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
PREFIX=$1
shift
[[ $PREFIX =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?/[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]] || die 'Use a registry host and namespace, without scheme, credentials, tag or digest'
MODE=plan
MODE_SET=false
BUILDER=()
while (($#)); do
  case "$1" in
    --plan|--push)
      [[ $MODE_SET == false ]] || die 'Choose --plan or --push once'
      MODE=${1#--}; MODE_SET=true; shift ;;
    --builder)
      [[ $# -ge 2 && ${#BUILDER[@]} == 0 && $2 =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die '--builder requires one valid builder name'
      BUILDER=(--builder "$2"); shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
command -v git >/dev/null || die 'Git is required'
COMMIT=$(git -C "$ROOT" rev-parse --verify HEAD)
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || die 'Expected a Git SHA-1 source commit'
POSTGRES_VERSION=''; PATRONI_VERSION=''; POSTGRES_BASE_IMAGE=''
while IFS='=' read -r key value; do
  case "$key" in
    POSTGRES_VERSION) POSTGRES_VERSION=$value ;;
    PATRONI_VERSION) PATRONI_VERSION=$value ;;
    POSTGRES_BASE_IMAGE) POSTGRES_BASE_IMAGE=$value ;;
  esac
done < <(git -C "$ROOT" show "$COMMIT:versions.lock")
[[ $POSTGRES_VERSION =~ ^[0-9]+\.[0-9]+$ && $PATRONI_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid committed runtime versions'
[[ $POSTGRES_BASE_IMAGE =~ ^postgres:[a-zA-Z0-9_.-]+@sha256:[0-9a-f]{64}$ ]] || die 'Committed PostgreSQL base must be digest pinned'
[[ $POSTGRES_BASE_IMAGE == "postgres:$POSTGRES_VERSION-bookworm@sha256:"* ]] || die 'Committed PostgreSQL base tag must match POSTGRES_VERSION and the bookworm variant'
REV=${COMMIT:0:12}
PG_IMAGE="$PREFIX/one-postgres-ha:pg$POSTGRES_VERSION-patroni$PATRONI_VERSION-$REV"
TOOLS_IMAGE="$PREFIX/one-postgres-ha-tools:pg$POSTGRES_VERSION-$REV"
PLATFORMS=linux/amd64,linux/arm64
DOWNLOAD_SOURCE=${HA_DOWNLOAD_SOURCE:-}
if [[ -z $DOWNLOAD_SOURCE ]]; then
  DOWNLOAD_SOURCE=official
  if [[ -e "$ROOT/.local/download-source" || -L "$ROOT/.local/download-source" ]]; then
    DOWNLOAD_SOURCE=$(bash "$ROOT/scripts/download-sources.sh" --resolve saved)
  fi
fi
case "$DOWNLOAD_SOURCE" in auto|official|ustc|tuna) ;; *) die 'HA_DOWNLOAD_SOURCE must be auto, official, ustc or tuna' ;; esac
printf 'source_commit=%s\nplatforms=%s\npostgres=%s\ntools=%s\nmode=%s\ndownload_source=%s\n' \
  "$COMMIT" "$PLATFORMS" "$PG_IMAGE" "$TOOLS_IMAGE" "$MODE" "$DOWNLOAD_SOURCE"
if [[ $MODE == plan ]]; then
  printf 'Only committed image files will be published. Run with --push after Docker login.\n'
  exit 0
fi
for tool in docker tar flock; do command -v "$tool" >/dev/null || die "$tool is required"; done
docker buildx version >/dev/null
mkdir -p "$ROOT/.local/publish"
exec 9>"$ROOT/.local/publish/publish.lock"
flock -n 9 || die 'Another image publication is running'
REPORT=$(mktemp -d "$ROOT/.local/publish/$REV.XXXXXXXX")
CONTEXT="$REPORT/context"
cleanup() { rm -rf -- "$CONTEXT"; }
trap cleanup EXIT
printf '%s\n' "$COMMIT" >"$REPORT/source-commit"
check_absent() {
  local image=$1 log=$2
  if docker buildx imagetools inspect "$image" >"$log" 2>&1; then
    die "Destination tag already exists: $image"
  fi
  # Do not treat authentication, network or server errors as a missing tag.
  if ! grep -Eqi '(^|[[:space:]:])(MANIFEST_UNKNOWN|manifest unknown)([[:space:]:]|$)' "$log" \
    && ! grep -Fxq "ERROR: $image: not found" "$log"; then
    die "Cannot establish that the destination is absent; review $log"
  fi
}
check_absent "$PG_IMAGE" "$REPORT/postgres-inspect.log"
check_absent "$TOOLS_IMAGE" "$REPORT/tools-inspect.log"
if [[ $DOWNLOAD_SOURCE == auto ]]; then
  DOWNLOAD_SOURCE=$(bash "$ROOT/scripts/download-sources.sh" --resolve auto)
fi
printf '%s\n' "$DOWNLOAD_SOURCE" >"$REPORT/download-source"
mkdir "$CONTEXT"
# Narrow, committed contexts cannot include .local, .git or untracked credentials.
git -C "$ROOT" archive "$COMMIT" -- images/postgres images/tools .dockerignore | tar -xf - -C "$CONTEXT"
COMMON=(--platform "$PLATFORMS" --push --provenance=false --sbom=false
  --label "org.opencontainers.image.revision=$COMMIT"
  --label 'org.opencontainers.image.source=https://github.com/OKFred/one-postgres-ha')
docker buildx build "${BUILDER[@]}" "${COMMON[@]}" \
  --label "org.opencontainers.image.version=${PG_IMAGE##*:}" \
  --build-arg "POSTGRES_BASE_IMAGE=$POSTGRES_BASE_IMAGE" \
  --build-arg "DOWNLOAD_SOURCE=$DOWNLOAD_SOURCE" \
  --file "$CONTEXT/images/postgres/Dockerfile" --tag "$PG_IMAGE" \
  --metadata-file "$REPORT/postgres.json" "$CONTEXT/images/postgres"
docker buildx build "${BUILDER[@]}" "${COMMON[@]}" \
  --label "org.opencontainers.image.version=${TOOLS_IMAGE##*:}" \
  --build-arg "POSTGRES_BASE=$POSTGRES_BASE_IMAGE" \
  --build-arg "DOWNLOAD_SOURCE=$DOWNLOAD_SOURCE" \
  --file "$CONTEXT/images/tools/Dockerfile" --tag "$TOOLS_IMAGE" \
  --metadata-file "$REPORT/tools.json" "$CONTEXT"
digest_from_metadata() {
  local metadata
  metadata=$(cat "$1")
  [[ $metadata =~ \"containerimage.digest\"[[:space:]]*:[[:space:]]*\"(sha256:[0-9a-f]{64})\" ]] || die "Missing image index digest: $1"
  printf '%s' "${BASH_REMATCH[1]}"
}
PG_REF="${PG_IMAGE%:*}@$(digest_from_metadata "$REPORT/postgres.json")"
TOOLS_REF="${TOOLS_IMAGE%:*}@$(digest_from_metadata "$REPORT/tools.json")"
printf 'postgres_image_mode: prebuilt\npostgres_ha_image: %s\n' "$PG_REF" >"$REPORT/inventory-images.yml"
printf 'HA_TOOLS_IMAGE=%s\n' "$TOOLS_REF" >"$REPORT/tools.env"
printf 'PUBLISH_COMPLETE\npostgres_ha_image=%s\nHA_TOOLS_IMAGE=%s\nmetadata=%s\n' "$PG_REF" "$TOOLS_REF" "$REPORT"
