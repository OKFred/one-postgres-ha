#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/project/.local" "$WORK/bin"
cp "$ROOT/"{ops,install,cleanup}.sh "$WORK/project/"
printf 'all: {}\n' >"$WORK/project/.local/inventory.yml"
printf 'test-host ssh-ed25519 fixture\n' >"$WORK/project/.local/known_hosts"
export ENTRY_ROOT="$WORK/project" ENTRY_LOG="$WORK/stages"
cat >"$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $1 == container && -f ${ENTRY_UNCERTAIN_FILE:-/does-not-exist} ]]; then exit 125; fi
case "$1 ${2:-}" in
  'image inspect') exit 0 ;;
  'container inspect') printf 'false\n'; exit 0 ;;
  'container ls') exit 0 ;;
esac
[[ $1 == run ]] || exit 0
stage=''
snapshot=''
while (($#)); do
  case "$1" in
    --cidfile)
      [[ ! -e $2 ]] || { echo 'Controller cidfile was not recycled safely' >&2; exit 1; }
      printf '%064d' 1 >"$2"; shift ;;
    scripts/bootstrap-secrets.sh) stage=secrets ;;
    ansible/*.yml) stage=$1 ;;
    ha_cleanup_apply=*) stage="$stage:$1" ;;
    type=bind,src=*,dst=/inventory.yml,readonly)
      snapshot=${1#type=bind,src=}
      snapshot=${snapshot%,dst=/inventory.yml,readonly} ;;
  esac
  shift
done
printf '%s\n' "$stage" >>"$ENTRY_LOG"
if [[ ${ENTRY_CHECK_SNAPSHOT:-false} == true ]]; then
  [[ $snapshot == "$ENTRY_ROOT"/.local/tool.*/inventory.yml ]]
  cmp "$snapshot" "$ENTRY_EXPECTED_INVENTORY"
  printf 'changed during preview\n' >"$ENTRY_ROOT/.local/inventory.yml"
fi
if [[ ${ENTRY_REQUIRE_LOCK:-false} == true ]]; then
  if flock -n "$ENTRY_ROOT/.local/operations.lock" true; then
    echo 'One-click operation lost its lock between stages' >&2; exit 1
  fi
fi
[[ ${ENTRY_FAIL_STAGE:-} != "$stage" ]] || exit 42
if [[ ${ENTRY_UNCERTAIN_STAGE:-} == "$stage" ]]; then
  # Next controller inspection must block all subsequent steps.
  touch "$ENTRY_UNCERTAIN_FILE"
fi
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH" ENTRY_REQUIRE_LOCK=true
expect_failure() {
  if bash "$WORK/project/$1" "${@:2}" >"$WORK/output" 2>&1; then
    printf 'Expected failure: %s\n' "$*" >&2
    exit 1
  fi
}
expect_stages() {
  printf '%s\n' "$@" >"$WORK/expected"
  diff -u "$WORK/expected" "$ENTRY_LOG"
  : >"$ENTRY_LOG"
}

bash "$WORK/project/install.sh"
expect_stages secrets ansible/plan.yml ansible/deploy.yml ansible/status.yml ansible/verify.yml
bash "$WORK/project/install.sh" --plan
expect_stages ansible/plan.yml

# Stop immediately on preflight/deployment failure; preserve the original exit code.
export ENTRY_FAIL_STAGE=ansible/plan.yml
result=0
bash "$WORK/project/install.sh" >"$WORK/output" 2>&1 || result=$?
[[ $result == 42 ]]
expect_stages secrets ansible/plan.yml
export ENTRY_FAIL_STAGE=ansible/deploy.yml
expect_failure install.sh
expect_stages secrets ansible/plan.yml ansible/deploy.yml
unset ENTRY_FAIL_STAGE

export ENTRY_REQUIRE_LOCK=false
bash "$WORK/project/cleanup.sh"
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
expect_failure cleanup.sh --apply
expect_failure cleanup.sh --apply --confirm wrong
expect_failure cleanup.sh --plan --confirm DELETE-ONE-POSTGRES-HA
[[ ! -s $ENTRY_LOG ]]
export ENTRY_REQUIRE_LOCK=true
bash "$WORK/project/cleanup.sh" --apply --confirm DELETE-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false ansible/cleanup.yml:ha_cleanup_apply=true
export ENTRY_FAIL_STAGE=ansible/cleanup.yml:ha_cleanup_apply=false
expect_failure cleanup.sh --apply --confirm DELETE-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
unset ENTRY_FAIL_STAGE

# A source inventory edit during preview must not change subsequent host targets.
cp "$WORK/project/.local/inventory.yml" "$WORK/expected-inventory.yml"
export ENTRY_CHECK_SNAPSHOT=true ENTRY_EXPECTED_INVENTORY="$WORK/expected-inventory.yml"
bash "$WORK/project/cleanup.sh" --apply --confirm DELETE-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false ansible/cleanup.yml:ha_cleanup_apply=true
cmp "$WORK/project/.local/inventory.yml" <(printf 'changed during preview\n')
cp "$WORK/expected-inventory.yml" "$WORK/project/.local/inventory.yml"
unset ENTRY_CHECK_SNAPSHOT ENTRY_EXPECTED_INVENTORY
[[ -z $(find "$WORK/project/.local" -name inventory.yml ! -path "$WORK/project/.local/inventory.yml" -print -quit) ]]

exec 8>"$WORK/project/.local/operations.lock"
flock -n 8
expect_failure install.sh
expect_failure cleanup.sh --apply --confirm DELETE-ONE-POSTGRES-HA
[[ ! -s $ENTRY_LOG ]]
flock -u 8

mv "$WORK/project/.local/known_hosts" "$WORK/known_hosts"
expect_failure install.sh
expect_failure cleanup.sh
[[ ! -s $ENTRY_LOG ]]
mv "$WORK/known_hosts" "$WORK/project/.local/known_hosts"
cp "$WORK/project/.local/inventory.yml" "$WORK/site config.yml"
bash "$WORK/project/install.sh" --inventory "$WORK/site config.yml" --plan
expect_stages ansible/plan.yml
expect_failure install.sh --inventory
expect_failure install.sh --unexpected
expect_failure cleanup.sh --unexpected

export ENTRY_UNCERTAIN_STAGE=secrets ENTRY_UNCERTAIN_FILE="$WORK/uncertain"
expect_failure install.sh
expect_stages secrets
[[ -s $(find "$WORK/project/.local" -name container.cid -print -quit) ]]
echo 'PASS: install/cleanup routing, confirmation, shared lock, stage failure and uncertain-controller guard'
