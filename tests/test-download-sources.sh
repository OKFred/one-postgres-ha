#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PROJECT="$WORK/project with spaces"
mkdir -p "$PROJECT/scripts" "$PROJECT/images/postgres" "$WORK/bin" "$WORK/counters"
cp "$ROOT/scripts/download-sources.sh" "$PROJECT/scripts/"
cp "$ROOT/images/postgres/source-profiles.sh" "$PROJECT/images/postgres/"
SELECTOR="$PROJECT/scripts/download-sources.sh"
CACHE="$PROJECT/.local/download-source"
export SOURCES_FIXTURE="$WORK" SOURCES_MODE=normal
# Tests use only synthetic fixture data. Preserve the original stderr descriptor
# so failure diagnostics cannot append to a selector's redirected diagnostic file.
exec 3>&2
PHASE=setup
report_failure() {
  local status=$1 line=$2
  printf 'FAIL: source selector phase=%s line=%s status=%s fixture_mode=%s\n' \
    "$PHASE" "$line" "$status" "$SOURCES_MODE" >&3
  if [[ -f "$WORK/diagnostic" ]]; then
    printf '%s\n' 'Last synthetic selector diagnostic:' >&3
    tail -n 12 "$WORK/diagnostic" >&3
  fi
}
trap 'report_failure "$?" "$LINENO"' ERR
cat >"$WORK/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
output='' url='' format='' proto='' redirects='' connect='' maximum='' filesize='' range=''
while (($#)); do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --write-out) format=$2; shift 2 ;;
    --proto) proto=$2; shift 2 ;;
    --proto-redir) redirects=$2; shift 2 ;;
    --connect-timeout) connect=$2; shift 2 ;;
    --max-time) maximum=$2; shift 2 ;;
    --max-filesize) filesize=$2; shift 2 ;;
    --range) range=$2; shift 2 ;;
    --max-redirs|--retry) [[ $2 =~ ^[0-9]+$ ]]; shift 2 ;;
    --disable|--fail|--silent|--show-error|--location|--tlsv1.2) shift ;;
    https://*) [[ -z $url ]]; url=$1; shift ;;
    *) printf 'Unexpected curl option\n' >&2; exit 93 ;;
  esac
done
[[ -n $output && $format == '%{http_code} %{time_total}' && $proto == '=https' && $redirects == '=https' ]]
[[ $connect == 2 && $maximum == 5 && $filesize == 524288 && $range == 0-32767 ]]
case "$url" in
  https://mirrors.ustc.edu.cn/*) provider=ustc; elapsed=0.010 ;;
  https://mirrors.tuna.tsinghua.edu.cn/*) provider=tuna; elapsed=0.020 ;;
  https://deb.debian.org/*|https://pypi.org/*|https://download.docker.com/*) provider=official; elapsed=0.030 ;;
  *) exit 94 ;;
esac
case "$url" in
  */dists/bookworm/InRelease|*/dists/bookworm-security/InRelease|*/linux/debian/dists/trixie/InRelease) kind=release ;;
  */simple/six/) kind=pypi ;;
  *) exit 95 ;;
esac
printf '%s %s\n' "$provider" "$kind" >>"$SOURCES_FIXTURE/calls"
state="$SOURCES_FIXTURE/counters/$provider"
count=0
if [[ -f $state ]]; then count=$(<"$state"); fi
count=$((count + 1))
printf '%s\n' "$count" >"$state"
code=200
case "$SOURCES_MODE" in
  normal) ;;
  official_unreachable) [[ $provider != official ]] || exit 28 ;;
  wrong_release)
    if [[ $provider == ustc ]]; then printf '<html>not release metadata</html>\n' >"$output"; printf '200 0.001'; exit 0; fi ;;
  wrong_pypi)
    if [[ $provider == ustc && $kind == pypi ]]; then printf '<html>sign in</html>\n' >"$output"; printf '200 0.001'; exit 0; fi ;;
  wrong_status) [[ $provider != ustc ]] || code=503 ;;
  median)
    case "$provider" in
      official) elapsed=0.005; if [[ $count -ge 5 && $count -le 8 ]]; then elapsed=5.000; fi ;;
      ustc) elapsed=0.010 ;;
      tuna) elapsed=0.030 ;;
    esac ;;
  all_fail) exit 28 ;;
  one_success)
    [[ $provider == official && $count -le 4 ]] || exit 28 ;;
  two_success)
    [[ $provider == official && $count != 5 ]] || exit 28 ;;
  malformed_time) [[ $provider != ustc ]] || elapsed='nan' ;;
  oversized_body)
    if [[ $provider == ustc ]]; then
      head -c 1048576 /dev/zero >"$output"
      printf '200 0.001'; exit 0
    fi ;;
  *) exit 96 ;;
esac
if [[ $kind == pypi ]]; then
  printf '<a href="https://files.example.invalid/six-1.17.0-py2.py3-none-any.whl">six</a>\n' >"$output"
else
  printf '%s\n' '-----BEGIN PGP SIGNED MESSAGE-----' 'Hash: SHA256' '' 'Codename: bookworm' >"$output"
fi
printf '%s %s' "$code" "$elapsed"
MOCK
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
reset_probe() {
  rm -f -- "$WORK/calls" "$WORK/counters/official" "$WORK/counters/ustc" "$WORK/counters/tuna"
}
choose() { bash "$SELECTOR" "$@" >"$WORK/selected" 2>"$WORK/diagnostic"; }
expect() { [[ $(<"$WORK/selected") == "$1" ]]; }
reject() {
  if choose "$@"; then printf 'Unsafe or unavailable selection was accepted\n' >&2; exit 1; fi
}

# Read-only fallback and a blank menu neither build anything nor create private files.
PHASE=readonly_defaults
choose --show; expect official
choose --resolve saved; expect official
[[ ! -e "$PROJECT/.local" && ! -e "$WORK/calls" ]]
printf '\n' | bash "$SELECTOR" >"$WORK/menu" 2>&1
[[ ! -e "$PROJECT/.local" ]]
grep -Fq 'HTTPS' "$WORK/menu"
grep -Fq '官方源' "$WORK/menu"

# Manual selection and later resolves use one data line and never contact the network.
PHASE=manual_selection
choose --resolve tuna; expect tuna
[[ $(<"$CACHE") == tuna && $(stat -c %a "$CACHE") == 600 && ! -e "$WORK/calls" ]]
choose --resolve auto; expect tuna
choose --resolve saved; expect tuna
choose --show; expect tuna
[[ ! -e "$WORK/calls" ]]
choose official; expect official
[[ ! -e "$WORK/calls" ]]

# Explicit auto always remeasures; complete HTTPS metadata determines the winner.
PHASE=initial_auto_selection
choose auto; expect ustc
[[ $(<"$CACHE") == ustc && $(wc -l <"$WORK/calls") == 36 ]]
grep -Fq 'median' "$WORK/diagnostic"
before=$(wc -l <"$WORK/calls")
choose --resolve auto; expect ustc
[[ $(wc -l <"$WORK/calls") == "$before" ]]

# An outlier in one round does not defeat the faster median candidate.
PHASE=median_outlier
reset_probe
SOURCES_MODE=median choose auto; expect official
[[ $(<"$CACHE") == official ]]
for mode in official_unreachable wrong_release wrong_pypi wrong_status malformed_time oversized_body; do
  PHASE=invalid_probe_$mode
  reset_probe
  SOURCES_MODE=$mode choose auto
  case "$mode" in
    official_unreachable) expect ustc ;;
    *) expect tuna ;;
  esac
done

# Failed or insufficient probes preserve the previous selection, without treating
# an HTTP 200 error page as a working package mirror.
PHASE=failed_probes_preserve_cache
choose ustc
reset_probe
SOURCES_MODE=all_fail reject auto
[[ $(<"$CACHE") == ustc ]]
SOURCES_MODE=one_success reject auto
[[ $(<"$CACHE") == ustc ]]
reset_probe
PHASE=two_successful_rounds
SOURCES_MODE=two_success choose auto; expect official
rm -- "$CACHE"
SOURCES_MODE=all_fail reject --resolve auto
[[ ! -e $CACHE ]]

# Cache content and command arguments are never evaluated.
PHASE=malformed_cache
reset_probe
printf '$(touch injected)\n' >"$CACHE"
reject --resolve saved
[[ ! -e "$PROJECT/injected" && ! -e "$WORK/calls" ]]
printf 'ustc\nextra\n' >"$CACHE"
reject --show
for invalid in $'u\001stc\n' $'ustc\r\n' 'ustc' $'ustc\n\n'; do
  printf '%s' "$invalid" >"$CACHE"
  reject --resolve saved
done
printf 'u\000stc\n' >"$CACHE"
reject --resolve saved
printf 'ustc\000' >"$CACHE"
reject --resolve saved
choose tuna; expect tuna
PHASE=invalid_arguments
for bad in 'unknown' '$(touch injected)' 'ustc;touch injected' '--apply' ''; do
  reject "$bad"
done
[[ ! -e "$PROJECT/injected" && ! -e "$WORK/calls" ]]
rm -- "$CACHE"
PHASE=linked_cache
printf 'official\n' >"$WORK/outside"
ln -s "$WORK/outside" "$CACHE"
reject --show
reject ustc
reject auto
[[ $(<"$WORK/outside") == official && ! -e "$WORK/calls" ]]
rm -- "$CACHE"
ln "$WORK/outside" "$CACHE"
reject official
reject --show
reject --resolve saved
rm -- "$CACHE"
if [[ $(id -u) == 0 ]]; then
  PHASE=foreign_cache_owner
  printf 'official\n' >"$CACHE"
  chown 1 "$CACHE"
  reject --show
  reject official
  rm -- "$CACHE"
fi
mv -- "$PROJECT/.local" "$PROJECT/private-saved"
PHASE=linked_private_directory
ln -s "$PROJECT/private-saved" "$PROJECT/.local"
reject --show
reject official
rm -- "$PROJECT/.local"
mv -- "$PROJECT/private-saved" "$PROJECT/.local"
rm -- "$PROJECT/.local/download-source.lock"
PHASE=linked_lock
ln -s "$WORK/outside" "$PROJECT/.local/download-source.lock"
reject official
rm -- "$PROJECT/.local/download-source.lock"

# Concurrent writers publish complete valid files; readers never see partial data.
PHASE=concurrent_cli_writers
choose official
pids=()
for profile in official ustc tuna official ustc tuna official ustc tuna; do
  bash "$SELECTOR" --resolve "$profile" >"$WORK/write-$profile" 2>"$WORK/write-error-$profile" &
  pids+=("$!")
done
for ((iteration=0; iteration<12; iteration++)); do
  choose --resolve saved
  case "$(<"$WORK/selected")" in official|ustc|tuna) ;; *) exit 1 ;; esac
done
for pid in "${pids[@]}"; do wait "$pid"; done
[[ $(wc -l <"$CACHE") == 1 && $(stat -c %a "$CACHE") == 600 ]]
[[ -z $(find "$PROJECT/.local" -maxdepth 1 -name 'download-source.*' ! -name 'download-source.lock' -print) ]]
[[ ! -e "$WORK/calls" ]]

# Repeatedly publish complete valid files while readers open the cache. Each
# reader may see either valid version; replacement must never look like damage.
(
  writer=''
  trap '[[ -z $writer ]] || { kill "$writer" 2>/dev/null || true; wait "$writer" 2>/dev/null || true; }' EXIT
  for ((round=0; round<3; round++)); do
    PHASE=atomic_cache_readers_round_$round
    (
      umask 077
      for ((replacement=0; replacement<300; replacement++)); do
        for profile in official ustc tuna; do
          printf '%s\n' "$profile" >"$PROJECT/.local/atomic-swap"
          mv -fT -- "$PROJECT/.local/atomic-swap" "$CACHE"
        done
      done
    ) &
    writer=$!
    for ((reader=0; reader<100; reader++)); do
      choose --show
      case "$(<"$WORK/selected")" in official|ustc|tuna) ;; *) exit 1 ;; esac
    done
    wait "$writer"
    writer=''
  done
)
[[ ! -e "$WORK/calls" && ! -e "$PROJECT/.local/atomic-swap" ]]

# Force an atomic replacement after a reader has opened its snapshot but before
# metadata validation. The old inode is now unlinked, yet its complete value
# must remain readable; rereading the path would incorrectly see the new value.
PHASE=held_snapshot_after_replacement
choose official
export SOURCE_TEST_REAL_STAT SOURCE_TEST_CACHE="$CACHE" SOURCE_TEST_STAT_HOOK="$WORK/stat-hook"
SOURCE_TEST_REAL_STAT=$(command -v stat)
cat >"$WORK/bin/stat" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
for argument in "$@"; do
  if [[ $argument =~ ^/proc/[0-9]+/fd/[0-9]+$ && ! -e $SOURCE_TEST_STAT_HOOK ]]; then
    umask 077
    printf 'tuna\n' >"$SOURCE_TEST_CACHE.swap"
    mv -fT -- "$SOURCE_TEST_CACHE.swap" "$SOURCE_TEST_CACHE"
    printf 'replaced\n' >"$SOURCE_TEST_STAT_HOOK"
    break
  fi
done
exec "$SOURCE_TEST_REAL_STAT" "$@"
MOCK
chmod +x "$WORK/bin/stat"
choose --show; expect official
[[ -f "$SOURCE_TEST_STAT_HOOK" && $(<"$CACHE") == tuna && ! -e "$WORK/calls" ]]
choose --show; expect tuna
printf 'PASS: HTTPS source selection, robust medians, bounded probes, cache reuse, manual overrides and concurrent atomic cache publication/readers\n'
