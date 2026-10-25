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
  network_changed) [[ $provider != tuna ]] || elapsed=0.001 ;;
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
  held_initial_probe)
    : >"$SOURCES_FIXTURE/probe-started-$provider"
    while [[ ! -e $SOURCES_FIXTURE/release-probe ]]; do sleep 0.01; done ;;
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
expect_table_row() {
  local profile=$1 status=$2 rounds=$3 milliseconds=$4
  grep -Eq "^[[:space:]]*${profile}[[:space:]]+${status}[[:space:]]+${rounds}[[:space:]]+${milliseconds}([[:space:]]|$)" "$WORK/diagnostic"
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
grep -Fq '6. Clear saved selection -- 清除已保存选择' "$WORK/menu"
grep -Fq '未保存源选择' "$WORK/menu"

# Clearing an unused project does not create private state or contact a source.
PHASE=clear_unused_project
choose clear
choose clear
printf '6\n\n' | bash "$SELECTOR" >"$WORK/menu" 2>&1
[[ ! -e "$PROJECT/.local" && ! -e "$WORK/calls" ]]

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

# Clear only the saved profile. Preserve the common lock inode and unrelated
# private input or reports; repeats remain idempotent and never probe.
PHASE=clear_saved_selection
lock_identity=$(stat -c '%d:%i' "$PROJECT/.local/download-source.lock")
printf 'private configuration sentinel\n' >"$PROJECT/.local/keep-config"
mkdir "$PROJECT/.local/reports"
printf '{"fixture":"report sentinel"}\n' >"$PROJECT/.local/reports/keep.json"
choose clear
[[ ! -e $CACHE && ! -e "$WORK/calls" ]]
[[ $(stat -c '%d:%i' "$PROJECT/.local/download-source.lock") == "$lock_identity" ]]
[[ $(<"$PROJECT/.local/keep-config") == 'private configuration sentinel' ]]
[[ $(<"$PROJECT/.local/reports/keep.json") == '{"fixture":"report sentinel"}' ]]
choose clear
choose --show; expect official
choose --resolve saved; expect official
[[ ! -e $CACHE && ! -e "$WORK/calls" ]]
choose tuna
reject clear unexpected
[[ $(<"$CACHE") == tuna ]]

# The menu remains usable when the cached bytes are invalid or too large.
# Clearing is metadata-guarded, not dependent on parsing those bytes first.
PHASE=clear_malformed_selection
for malformed in '$(touch injected)' $'tuna\nextra\n'; do
  printf '%s' "$malformed" >"$CACHE"
  printf '6\n\n' | bash "$SELECTOR" >"$WORK/menu" 2>&1
  [[ ! -e $CACHE && ! -e "$PROJECT/injected" && ! -e "$WORK/calls" ]]
  grep -Fq '已保存选择无效或不可读' "$WORK/menu"
  grep -Fq '未保存源选择' "$WORK/menu"
done
head -c 1024 /dev/zero >"$CACHE"
choose clear
[[ ! -e $CACHE && ! -e "$WORK/calls" ]]
mkdir "$CACHE"
reject clear
[[ -d $CACHE ]]
rmdir "$CACHE"

# Explicit auto always remeasures; complete HTTPS metadata determines the winner.
PHASE=initial_auto_selection
choose tuna; expect tuna
choose auto; expect ustc
[[ $(<"$CACHE") == ustc && $(wc -l <"$WORK/calls") == 36 ]]
grep -Fq 'median' "$WORK/diagnostic"
grep -Fq 'HTTPS test results -- HTTPS 测速结果' "$WORK/diagnostic"
expect_table_row official available 3/3 120
expect_table_row ustc available 3/3 40
expect_table_row tuna available 3/3 80
grep -Fq 'Selected source -- 已选择源：ustc' "$WORK/diagnostic"
before=$(wc -l <"$WORK/calls")
choose --resolve auto; expect ustc
[[ $(wc -l <"$WORK/calls") == "$before" ]]

# Forgetting the selected profile makes a later cached-auto resolve evaluate
# current requests again. A changed winner is saved, then reused without calls.
PHASE=clear_then_resolve_after_network_change
choose clear
[[ ! -e $CACHE && $(wc -l <"$WORK/calls") == "$before" ]]
SOURCES_MODE=network_changed choose --resolve auto; expect tuna
[[ $(wc -l <"$WORK/calls") == $((before + 36)) && $(<"$CACHE") == tuna ]]
expect_table_row tuna available 3/3 4
after_network_change=$(wc -l <"$WORK/calls")
choose --resolve auto; expect tuna
[[ $(wc -l <"$WORK/calls") == "$after_network_change" ]]

# An outlier in one round does not defeat the faster median candidate.
PHASE=median_outlier
reset_probe
SOURCES_MODE=median choose auto; expect official
[[ $(<"$CACHE") == official ]]
expect_table_row official available 3/3 20
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
for profile in official ustc tuna; do expect_table_row "$profile" unavailable 0/2 -; done
reset_probe
SOURCES_MODE=one_success reject auto
[[ $(<"$CACHE") == ustc ]]
expect_table_row official unavailable 1/3 -
expect_table_row ustc unavailable 0/2 -
expect_table_row tuna unavailable 0/2 -
reset_probe
PHASE=two_successful_rounds
SOURCES_MODE=two_success choose auto; expect official
expect_table_row official available 2/3 120
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
reject clear
[[ $(<"$WORK/outside") == official && ! -e "$WORK/calls" ]]
rm -- "$CACHE"
ln "$WORK/outside" "$CACHE"
reject official
reject --show
reject --resolve saved
reject clear
rm -- "$CACHE"
if [[ $(id -u) == 0 ]]; then
  PHASE=foreign_cache_owner
  printf 'official\n' >"$CACHE"
  chown 1 "$CACHE"
  reject --show
  reject official
  reject clear
  rm -- "$CACHE"
fi
mv -- "$PROJECT/.local" "$PROJECT/private-saved"
PHASE=linked_private_directory
ln -s "$PROJECT/private-saved" "$PROJECT/.local"
reject --show
reject official
reject clear
rm -- "$PROJECT/.local"
mv -- "$PROJECT/private-saved" "$PROJECT/.local"
rm -- "$PROJECT/.local/download-source.lock"
PHASE=linked_lock
ln -s "$WORK/outside" "$PROJECT/.local/download-source.lock"
reject official
reject clear
rm -- "$PROJECT/.local/download-source.lock"

# An initial auto selection owns the lock before it has published any cache.
# Clearing must queue behind that operation and remove its eventual result.
PHASE=clear_waits_for_initial_probe
reset_probe
export SOURCE_TEST_REAL_FLOCK
SOURCE_TEST_REAL_FLOCK=$(command -v flock)
cat >"$WORK/bin/flock" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -n ${SOURCES_CLEAR_LOCK_NOTIFY:-} ]]; then : >"$SOURCES_CLEAR_LOCK_NOTIFY"; fi
exec "$SOURCE_TEST_REAL_FLOCK" "$@"
MOCK
chmod +x "$WORK/bin/flock"
(
  probe_pid='' clear_pid=''
  finish_probe_test() {
    local pid
    : >"$WORK/release-probe"
    for pid in "$probe_pid" "$clear_pid"; do [[ -z $pid ]] || kill "$pid" 2>/dev/null || true; done
    for pid in "$probe_pid" "$clear_pid"; do [[ -z $pid ]] || wait "$pid" 2>/dev/null || true; done
  }
  trap finish_probe_test EXIT
  SOURCES_MODE=held_initial_probe bash "$SELECTOR" auto >"$WORK/initial-selected" 2>"$WORK/initial-diagnostic" &
  probe_pid=$!
  for ((attempt=0; attempt<500; attempt++)); do
    [[ ! -e "$WORK/probe-started-official" ]] || break
    sleep 0.01
  done
  [[ -e "$WORK/probe-started-official" && ! -e $CACHE ]]
  SOURCES_CLEAR_LOCK_NOTIFY="$WORK/clear-lock-attempted" bash "$SELECTOR" clear >"$WORK/clear-selected" 2>"$WORK/clear-diagnostic" &
  clear_pid=$!
  for ((attempt=0; attempt<500; attempt++)); do
    [[ ! -e "$WORK/clear-lock-attempted" ]] || break
    sleep 0.01
  done
  [[ -e "$WORK/clear-lock-attempted" && ! -e $CACHE ]]
  : >"$WORK/release-probe"
  wait "$probe_pid"; probe_pid=''
  wait "$clear_pid"; clear_pid=''
  [[ $(<"$WORK/initial-selected") == ustc && ! -e $CACHE ]]
  [[ $(wc -l <"$WORK/calls") == 36 ]]
)
rm -- "$WORK/bin/flock"
reset_probe

# Readers may observe a saved snapshot or the no-saved fallback while clear and
# manual selection serialize their changes. Neither operation starts a probe.
PHASE=clear_with_concurrent_readers_and_savers
choose official
lock_identity=$(stat -c '%d:%i' "$PROJECT/.local/download-source.lock")
(
  writer=''
  trap '[[ -z $writer ]] || { kill "$writer" 2>/dev/null || true; wait "$writer" 2>/dev/null || true; }' EXIT
  (
    for ((round=0; round<15; round++)); do
      for profile in tuna ustc; do
        bash "$SELECTOR" --resolve "$profile" >>"$WORK/clear-writer-output" 2>>"$WORK/clear-writer-error"
        bash "$SELECTOR" clear >>"$WORK/clear-writer-output" 2>>"$WORK/clear-writer-error"
      done
    done
  ) &
  writer=$!
  for ((reader=0; reader<75; reader++)); do
    choose --show
    case "$(<"$WORK/selected")" in official|ustc|tuna) ;; *) exit 1 ;; esac
    choose --resolve saved
    case "$(<"$WORK/selected")" in official|ustc|tuna) ;; *) exit 1 ;; esac
  done
  wait "$writer"; writer=''
)
[[ ! -e $CACHE && ! -e "$WORK/calls" ]]
[[ $(stat -c '%d:%i' "$PROJECT/.local/download-source.lock") == "$lock_identity" ]]

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
printf 'PASS: HTTPS source timing tables, cache reuse/reset, lock-safe clear, strict inputs and concurrent atomic publication/readers\n'
