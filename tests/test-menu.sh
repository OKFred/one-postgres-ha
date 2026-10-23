#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
project="$work/project with spaces"
mkdir -p "$project" "$work/elsewhere"
cp "$ROOT/menu.sh" "$project/menu.sh"
export MENU_TEST_ROOT="$project" MENU_TEST_LOG="$work/calls"
for script in ops install uninstall; do
  cat >"$project/$script.sh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $PWD == "$MENU_TEST_ROOT" ]] || exit 87
printf '%s' "${0##*/}" >>"$MENU_TEST_LOG"
if (($#)); then printf ' <%s>' "$@" >>"$MENU_TEST_LOG"; fi
printf '\n' >>"$MENU_TEST_LOG"
if [[ ${MENU_TEST_CONFIRM:-false} == true ]]; then
  token=''
  case "${0##*/}:${1:-}:${2:-}" in
    install.sh::) token=INSTALL ;;
    uninstall.sh:--apply:--keep-data) token=UNINSTALL-ONE-POSTGRES-HA ;;
    uninstall.sh:--apply:--purge-data) token=DELETE-ONE-POSTGRES-HA ;;
  esac
  if [[ -n $token ]]; then
    IFS= read -r confirmation || exit 21
    [[ $confirmation == "$token" ]] || exit 21
  fi
fi
if [[ ${1:-} == status && ${MENU_TEST_FAIL:-false} == true ]]; then exit 42; fi
MOCK
done
run_menu() {
  : >"$MENU_TEST_LOG"
  (cd "$work/elsewhere" && printf '%s' "$1" | bash "$project/menu.sh") >"$work/output" 2>&1
}
expect_calls() {
  printf '%s' "$1" >"$work/expected"
  diff -u "$work/expected" "$MENU_TEST_LOG"
}

# Help, invalid arguments, EOF and invalid input never invoke a backend.
bash "$project/menu.sh" --help >"$work/output"
if bash "$project/menu.sh" --apply >"$work/output" 2>&1; then exit 1; fi
run_menu ''
expect_calls ''
run_menu $'bogus\n00\n'
expect_calls ''
run_menu $'02\n'
expect_calls ''
run_menu $'05\n03\nreplica04\n'
expect_calls ''

run_menu $'01\n03\n04\n01\n02\n0\n08\n00\n'
expect_calls $'ops.sh <configure>\nops.sh <status>\nops.sh <preflight>\nops.sh <verify>\nops.sh <help>\n'
run_menu $'2\n1\n2\n0\n7\n1\n2\n3\n4\n0\n0\n'
expect_calls $'install.sh <--plan>\ninstall.sh\nuninstall.sh <--plan> <--keep-data>\nuninstall.sh <--apply> <--keep-data>\nuninstall.sh <--plan> <--purge-data>\nuninstall.sh <--apply> <--purge-data>\n'
# Root entries retain their own INSTALL/instance/path confirmations.
if grep -E -- '--confirm|--yes|^install.sh <--apply>' "$MENU_TEST_LOG"; then exit 1; fi
export MENU_TEST_CONFIRM=true
run_menu $'2\n2\nINSTALL\n0\n7\n2\nUNINSTALL-ONE-POSTGRES-HA\n4\nDELETE-ONE-POSTGRES-HA\n0\n0\n'
expect_calls $'install.sh\nuninstall.sh <--apply> <--keep-data>\nuninstall.sh <--apply> <--purge-data>\n'
run_menu $'2\n2\nNO\n0\n7\n4\nNO\n0\n8\n0\n'
expect_calls $'install.sh\nuninstall.sh <--apply> <--purge-data>\nops.sh <help>\n'
grep -Fq '21' "$work/output"
unset MENU_TEST_CONFIRM

run_menu $'5\n2\nreplica04\n3\nreplica04\nno\n4\nno\n5\n0\n0\n'
expect_calls $'ops.sh <add-node> <replica04> <--plan>\n'
grep -Fq 'remove-node' "$work/output"
run_menu $'5\n3\nreplica04\nAPPLY\n4\nAPPLY\n0\n6\n1\nAPPLY\n2\nAPPLY\n0\n0\n'
expect_calls $'ops.sh <add-node> <replica04>\nops.sh <switchover>\nops.sh <backup>\nops.sh <restore-test>\n'
run_menu $'6\n1\nno\n2\nno\n0\n0\n'
expect_calls ''

# Node text is validated data, never evaluated as a shell expression or option.
run_menu $'5\n2\nreplica04;touch injected\n3\n--help\n2\n$(touch injected)\n0\n0\n'
expect_calls ''
[[ ! -e $project/injected && ! -e $work/elsewhere/injected ]]
export MENU_TEST_FAIL=true
run_menu $'3\n8\n0\n'
expect_calls $'ops.sh <status>\nops.sh <help>\n'
grep -Fq '42' "$work/output"
echo 'PASS: menu routing, confirmations, node validation, EOF and caller directory isolation'
