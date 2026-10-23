#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/project/.local" "$WORK/bin"
cp "$ROOT/"{ops,install,uninstall}.sh "$WORK/project/"
printf 'all: {}\n' >"$WORK/project/.local/inventory.yml"
printf 'test-host ssh-ed25519 fixture\n' >"$WORK/project/.local/known_hosts"
export ENTRY_ROOT="$WORK/project" ENTRY_LOG="$WORK/stages"
export ENTRY_LEVEL_LOG="$WORK/levels"
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
    ha_cleanup_level=*) printf '%s\n' "$1" >>"$ENTRY_LEVEL_LOG" ;;
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

bash "$WORK/project/install.sh" --apply
expect_stages secrets ansible/plan.yml ansible/deploy.yml ansible/status.yml ansible/verify.yml
bash "$WORK/project/install.sh" --yes
expect_stages secrets ansible/plan.yml ansible/deploy.yml ansible/status.yml ansible/verify.yml
bash "$WORK/project/install.sh" --plan
expect_stages ansible/plan.yml

# Stop immediately on preflight/deployment failure; preserve the original exit code.
export ENTRY_FAIL_STAGE=ansible/plan.yml
result=0
bash "$WORK/project/install.sh" --apply >"$WORK/output" 2>&1 || result=$?
[[ $result == 42 ]]
expect_stages secrets ansible/plan.yml
export ENTRY_FAIL_STAGE=ansible/deploy.yml
expect_failure install.sh --apply
expect_stages secrets ansible/plan.yml ansible/deploy.yml
unset ENTRY_FAIL_STAGE

export ENTRY_REQUIRE_LOCK=false
bash "$WORK/project/uninstall.sh" --plan --purge-data
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
expect_failure uninstall.sh --apply --purge-data
expect_failure uninstall.sh --apply --purge-data --confirm wrong
expect_failure uninstall.sh --plan --purge-data --confirm DELETE-ONE-POSTGRES-HA
[[ ! -s $ENTRY_LOG ]]
export ENTRY_REQUIRE_LOCK=true
bash "$WORK/project/uninstall.sh" --apply --purge-data --confirm DELETE-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false ansible/cleanup.yml:ha_cleanup_apply=true
export ENTRY_FAIL_STAGE=ansible/cleanup.yml:ha_cleanup_apply=false
expect_failure uninstall.sh --apply --purge-data --confirm DELETE-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
unset ENTRY_FAIL_STAGE

# A source inventory edit during preview must not change subsequent host targets.
cp "$WORK/project/.local/inventory.yml" "$WORK/expected-inventory.yml"
export ENTRY_CHECK_SNAPSHOT=true ENTRY_EXPECTED_INVENTORY="$WORK/expected-inventory.yml"
bash "$WORK/project/uninstall.sh" --apply --purge-data --confirm DELETE-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false ansible/cleanup.yml:ha_cleanup_apply=true
cmp "$WORK/project/.local/inventory.yml" <(printf 'changed during preview\n')
cp "$WORK/expected-inventory.yml" "$WORK/project/.local/inventory.yml"
unset ENTRY_CHECK_SNAPSHOT ENTRY_EXPECTED_INVENTORY
[[ -z $(find "$WORK/project/.local" -name inventory.yml ! -path "$WORK/project/.local/inventory.yml" -print -quit) ]]

exec 8>"$WORK/project/.local/operations.lock"
flock -n 8
expect_failure install.sh --apply
expect_failure uninstall.sh --apply --purge-data --confirm DELETE-ONE-POSTGRES-HA
[[ ! -s $ENTRY_LOG ]]
flock -u 8

mv "$WORK/project/.local/known_hosts" "$WORK/known_hosts"
expect_failure install.sh --apply
expect_failure uninstall.sh --plan --purge-data
[[ ! -s $ENTRY_LOG ]]
mv "$WORK/known_hosts" "$WORK/project/.local/known_hosts"
cp "$WORK/project/.local/inventory.yml" "$WORK/site config.yml"
bash "$WORK/project/install.sh" --inventory "$WORK/site config.yml" --plan
expect_stages ansible/plan.yml
cp "$WORK/project/.local/inventory.yml" "$WORK/saved-inventory.yml"
: >"$WORK/project/.local/inventory.yml"
expect_failure install.sh --apply
cp "$WORK/saved-inventory.yml" "$WORK/project/.local/inventory.yml"
ln -s "$WORK/site config.yml" "$WORK/linked-inventory.yml"
expect_failure install.sh --apply --inventory "$WORK/linked-inventory.yml"
mv "$WORK/project/.local/inventory.yml" "$WORK/temporarily-missing.yml"
expect_failure install.sh --apply
mv "$WORK/temporarily-missing.yml" "$WORK/project/.local/inventory.yml"
[[ ! -s $ENTRY_LOG ]]
expect_failure install.sh --inventory
expect_failure install.sh --unexpected
expect_failure uninstall.sh --unexpected

export ENTRY_UNCERTAIN_STAGE=secrets ENTRY_UNCERTAIN_FILE="$WORK/uncertain"
expect_failure install.sh --apply
expect_stages secrets
[[ -s $(find "$WORK/project/.local" -name container.cid -print -quit) ]]
unset ENTRY_UNCERTAIN_STAGE
rm -- "$ENTRY_UNCERTAIN_FILE"
unset ENTRY_UNCERTAIN_FILE
# The common root entrypoints are safe without an explicit execution mode.
expect_failure install.sh
expect_failure install.sh --plan --apply
expect_failure install.sh --yes --apply
expect_failure install.sh --apply --apply
expect_failure install.sh --inventory "$WORK/site config.yml" --inventory "$WORK/site config.yml"
[[ ! -s $ENTRY_LOG ]]
printf 'NO\n' | script --quiet --return --command "bash '$WORK/project/install.sh'" /dev/null >"$WORK/output" 2>&1 && exit 1
[[ ! -s $ENTRY_LOG ]]
printf 'INSTALL\n' | script --quiet --return --command "bash '$WORK/project/install.sh'" /dev/null >"$WORK/output" 2>&1
expect_stages secrets ansible/plan.yml ansible/deploy.yml ansible/status.yml ansible/verify.yml
export ENTRY_REQUIRE_LOCK=false
: >"$ENTRY_LEVEL_LOG"
bash "$WORK/project/uninstall.sh"
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
grep -Fxq ha_cleanup_level=keep-data "$ENTRY_LEVEL_LOG"
: >"$ENTRY_LEVEL_LOG"
bash "$WORK/project/uninstall.sh" --plan --purge-data
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
grep -Fxq ha_cleanup_level=purge-data "$ENTRY_LEVEL_LOG"
printf 'NO\n' | script --quiet --return --command "bash '$WORK/project/uninstall.sh' --apply --keep-data" /dev/null >"$WORK/output" 2>&1 && exit 1
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
expect_failure uninstall.sh --apply
expect_failure uninstall.sh --plan --apply
expect_failure uninstall.sh --apply --keep-data --purge-data
expect_failure uninstall.sh --plan --confirm DELETE-ONE-POSTGRES-HA
expect_failure uninstall.sh --apply --keep-data --confirm DELETE-ONE-POSTGRES-HA
expect_failure uninstall.sh --apply --purge-data --confirm UNINSTALL-ONE-POSTGRES-HA
expect_failure uninstall.sh --yes
[[ ! -s $ENTRY_LOG ]]
export ENTRY_REQUIRE_LOCK=true
: >"$ENTRY_LEVEL_LOG"
bash "$WORK/project/uninstall.sh" --apply --keep-data --confirm UNINSTALL-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false ansible/cleanup.yml:ha_cleanup_apply=true
[[ $(grep -Fxc ha_cleanup_level=keep-data "$ENTRY_LEVEL_LOG") == 2 ]]
bash "$WORK/project/uninstall.sh" --apply --purge-data --confirm DELETE-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false ansible/cleanup.yml:ha_cleanup_apply=true
export ENTRY_FAIL_STAGE=ansible/cleanup.yml:ha_cleanup_apply=false
expect_failure uninstall.sh --apply --keep-data --confirm UNINSTALL-ONE-POSTGRES-HA
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
unset ENTRY_FAIL_STAGE
export ENTRY_REQUIRE_LOCK=false
bash "$WORK/project/ops.sh" uninstall --plan --keep-data
expect_stages ansible/cleanup.yml:ha_cleanup_apply=false
echo 'PASS: common install/uninstall entrypoints, safe defaults, confirmation, shared lock and retries'
