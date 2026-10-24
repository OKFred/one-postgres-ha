#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PROJECT="$WORK/project"
mkdir -p "$PROJECT/scripts" "$PROJECT/images/postgres" "$PROJECT/images/tools" "$WORK/bin"
cp "$ROOT/scripts/publish-images.sh" "$PROJECT/scripts/"
printf '.local\n.git\n' >"$PROJECT/.dockerignore"
printf '.local/\n' >"$PROJECT/.gitignore"
printf 'POSTGRES_VERSION=17.11\nPATRONI_VERSION=4.1.5\nPOSTGRES_BASE_IMAGE=postgres:17.11-bookworm@sha256:%064d\n' 1 >"$PROJECT/versions.lock"
printf 'FROM scratch\n# committed\n' >"$PROJECT/images/postgres/Dockerfile"
printf 'FROM scratch\n' >"$PROJECT/images/tools/Dockerfile"
git -C "$PROJECT" init -q
git -C "$PROJECT" add .
git -C "$PROJECT" -c user.name=Fixture -c user.email=fixture@example.com commit -qm fixture
mkdir -p "$PROJECT/.local/secrets"
printf 'private-fixture\n' >"$PROJECT/.local/secrets/password"
printf '# uncommitted\n' >>"$PROJECT/images/postgres/Dockerfile"
export PUBLISH_LOG="$WORK/docker.log"
cat >"$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$PUBLISH_LOG"
case "$1 ${2:-} ${3:-}" in
  'buildx version ') exit 0 ;;
  'buildx imagetools inspect')
    case "${PUBLISH_INSPECT:-absent}" in
      present) exit 0 ;;
      denied) printf 'ERROR: unexpected status: 401 Unauthorized\n' >&2; exit 1 ;;
      absent) printf 'ERROR: %s: not found\n' "$4" >&2; exit 1 ;;
    esac ;;
esac
[[ $1 == buildx && $2 == build ]] || exit 1
metadata=''; file=''; context=${!#}
while (($#)); do
  case "$1" in --metadata-file) metadata=$2; shift ;; --file) file=$2; shift ;; esac
  shift
done
[[ $context != */.local && -n $metadata && -n $file ]]
! grep -q uncommitted "$file"
[[ -z $(find "$context" -name .git -o -name secrets -o -name password) ]]
if [[ ${PUBLISH_FAIL_TOOLS:-false} == true && $file == */images/tools/Dockerfile ]]; then exit 42; fi
printf '{"containerimage.digest":"sha256:%064d"}\n' 2 >"$metadata"
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
expect_failure() {
  if bash "$PROJECT/scripts/publish-images.sh" "$@" >"$WORK/output" 2>&1; then
    printf 'Expected failure: %s\n' "$*" >&2; exit 1
  fi
}
PREFIX=registry.example.com/team
bash "$PROJECT/scripts/publish-images.sh" "$PREFIX" >"$WORK/output"
grep -q '^mode=plan$' "$WORK/output"
[[ ! -e $PUBLISH_LOG && ! -e $PROJECT/.local/publish ]]
expect_failure
expect_failure https://registry.example.com/team
expect_failure registry.example.com/team:latest
expect_failure registry.example.com/team --plan --push
expect_failure "$PREFIX" --builder
[[ ! -e $PUBLISH_LOG ]]
export PUBLISH_INSPECT=present
expect_failure "$PREFIX" --push
[[ -s $PUBLISH_LOG ]]
! grep -q 'buildx build' "$PUBLISH_LOG"
export PUBLISH_INSPECT=denied
expect_failure "$PREFIX" --push
! grep -q 'buildx build' "$PUBLISH_LOG"
unset PUBLISH_INSPECT
: >"$PUBLISH_LOG"
bash "$PROJECT/scripts/publish-images.sh" "$PREFIX" --push --builder fixture >"$WORK/output"
[[ $(grep -c '^buildx build ' "$PUBLISH_LOG") == 2 ]]
[[ $(grep -c -- '--platform linux/amd64,linux/arm64' "$PUBLISH_LOG") == 2 ]]
[[ $(grep -c -- '--provenance=false --sbom=false' "$PUBLISH_LOG") == 2 ]]
grep -q -- '--label org.opencontainers.image.version=pg17.11-patroni4.1.5-' "$PUBLISH_LOG"
grep -q -- '--label org.opencontainers.image.version=pg17.11-' "$PUBLISH_LOG"
! grep -q 'latest\|private-fixture' "$PUBLISH_LOG"
grep -q PUBLISH_COMPLETE "$WORK/output"
grep -q 'postgres_ha_image=registry.example.com/team/one-postgres-ha@sha256:' "$WORK/output"
[[ -z $(find "$PROJECT/.local/publish" -type d -name context -print -quit) ]]
export PUBLISH_FAIL_TOOLS=true
expect_failure "$PREFIX" --push
! grep -q PUBLISH_COMPLETE "$WORK/output"
[[ -z $(find "$PROJECT/.local/publish" -type d -name context -print -quit) ]]
unset PUBLISH_FAIL_TOOLS
printf 'POSTGRES_VERSION=17.11\nPATRONI_VERSION=4.1.5\nPOSTGRES_BASE_IMAGE=postgres:17.10-bookworm@sha256:%064d\n' 1 >"$PROJECT/versions.lock"
git -C "$PROJECT" add versions.lock
git -C "$PROJECT" -c user.name=Fixture -c user.email=fixture@example.com commit -qm 'mismatched base fixture'
: >"$PUBLISH_LOG"
expect_failure "$PREFIX"
grep -q 'base tag must match POSTGRES_VERSION' "$WORK/output"
[[ ! -s $PUBLISH_LOG ]]
echo 'PASS: publication preview, arguments, immutable tags, auth failure, committed contexts, labels, multiarch metadata and partial failure'
