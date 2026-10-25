#!/usr/bin/env bash
# Pick download endpoints before a control-tool image exists.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CACHE="$ROOT/.local/download-source"
WORK=''
CACHE_TMP=''
PIDS=()
die() { printf 'Download sources -- 下载源：%s\n' "$*" >&2; exit 2; }
profile_valid() { [[ $1 == official || $1 == ustc || $1 == tuna ]]; }
cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  [[ -z $CACHE_TMP ]] || rm -f -- "$CACHE_TMP"
  [[ -z $WORK ]] || rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
usage() {
  printf '%s\n' 'Usage: bash ops.sh sources [auto|official|ustc|tuna|clear|--show]' \
    'No argument opens the menu; Enter exits -- 无参数显示菜单，直接回车退出。' \
    'auto remeasures verified HTTPS endpoints; manual choices do not contact the network -- auto 重新测速，手动选择不联网。' \
    'Saved choices are reused until changed or cleared -- 保存的选择会复用，直到修改或清除。' \
    'clear removes the saved choice; select auto to measure again -- clear 清除已保存选择；运行 auto 可重新测速。'
}
check_private() {
  [[ ! -L "$ROOT/.local" && (! -e "$ROOT/.local" || -d "$ROOT/.local") ]] || die 'Invalid private directory -- 私有目录无效'
}
check_cache_file() {
  local enforce_size=${1:-true}
  check_private
  [[ -f $CACHE && ! -L $CACHE ]] || die 'Invalid saved source file -- 保存的源文件无效'
  [[ $(stat -c %u -- "$CACHE") == "$(id -u)" && $(stat -c %h -- "$CACHE") == 1 \
    && ($enforce_size == false || $(stat -c %s -- "$CACHE") -le 32) ]] || die 'Unsafe saved source file -- 保存的源文件不安全'
}
read_cache() {
  local snapshot cache_fd cache_object metadata cache_owner cache_links cache_size attempt opened=false
  check_private
  # Clearing may unlink the path between lookup and open. Retry a changing
  # path briefly; once opened, the existing snapshot checks remain authoritative.
  for ((attempt=0; attempt<8; attempt++)); do
    if [[ ! -e $CACHE && ! -L $CACHE ]]; then return 1; fi
    [[ -f $CACHE && ! -L $CACHE ]] || continue
    if { exec {cache_fd}<"$CACHE"; } 2>/dev/null; then opened=true; break; fi
  done
  if [[ $opened != true ]]; then
    if [[ ! -e $CACHE && ! -L $CACHE ]]; then return 1; fi
    die 'Cannot open a safe saved source -- 无法打开安全的已保存源'
  fi
  cache_object="/proc/$BASHPID/fd/$cache_fd"
  # Linux /proc lets metadata checks and the bounded read share one held inode.
  # Atomic publication may unlink that inode after open (links=0); additional
  # hard links remain unsafe. Writer checks stay strict under their file lock.
  [[ -f $cache_object ]] || die 'Invalid saved source object -- 保存的源文件对象无效'
  metadata=$(stat -Lc '%u %h %s' -- "$cache_object") || die 'Cannot inspect saved source -- 无法检查已保存源'
  [[ $metadata =~ ^([0-9]+)' '([0-9]+)' '([0-9]+)$ ]] || die 'Invalid saved source metadata -- 保存的源文件元数据无效'
  cache_owner=${BASH_REMATCH[1]} cache_links=${BASH_REMATCH[2]} cache_size=${BASH_REMATCH[3]}
  [[ $cache_owner == "$(id -u)" && $cache_links -le 1 && $cache_size -le 32 ]] || die 'Unsafe saved source file -- 保存的源文件不安全'
  # Hex retains NUL/CR/LF that Bash strings would strip; 33 bytes also rejects a
  # file growing beyond the allowed size without reading an unbounded payload.
  snapshot=$(od -An -v -tx1 -N 33 <&"$cache_fd" | tr -d '[:space:]') || die 'Cannot read saved source -- 无法读取已保存源'
  exec {cache_fd}<&-
  # Exact ASCII bytes of official/ustc/tuna followed by one LF (0a).
  case "$snapshot" in
    6f6666696369616c0a) SAVED_SOURCE=official ;;
    757374630a) SAVED_SOURCE=ustc ;;
    74756e610a) SAVED_SOURCE=tuna ;;
    *) die 'Saved source must contain exactly one known profile and LF -- 保存值须为单个已知源名称及换行' ;;
  esac
}
lock_cache() {
  local lock="$ROOT/.local/download-source.lock" enforce_size=${1:-true}
  check_private
  mkdir -p -- "$ROOT/.local"
  [[ ! -L $lock && (! -e $lock || -f $lock) ]] || die 'Invalid source lock -- 源配置锁无效'
  if [[ -e $lock ]]; then
    [[ $(stat -c %u -- "$lock") == "$(id -u)" && $(stat -c %h -- "$lock") == 1 ]] || die 'Unsafe source lock -- 源配置锁不安全'
  fi
  command -v flock >/dev/null || die 'flock is required -- 需要 flock'
  exec 9>>"$lock"
  chmod 0600 "$lock"
  flock -w 75 9 || die 'Another source selection is running -- 另一源选择任务正在运行'
  if [[ -e $CACHE || -L $CACHE ]]; then check_cache_file "$enforce_size"; fi
}
clear_saved_source() {
  local lock="$ROOT/.local/download-source.lock"
  check_private
  if [[ ! -e $CACHE && ! -L $CACHE && ! -e $lock && ! -L $lock ]]; then
    printf 'No saved selection to clear -- 没有已保存的源选择。\n'
    return 0
  fi
  # Wait for an initial probe even if its cache has not yet been published.
  # Size/content do not matter for removal; type, owner and link guards do.
  lock_cache false
  if [[ -e $CACHE || -L $CACHE ]]; then
    check_cache_file false
    rm -- "$CACHE" || die 'Cannot clear saved selection -- 无法清除已保存选择'
  fi
  # Retain the lock inode so concurrent operations keep sharing the same lock.
  printf 'Saved selection cleared; choose 1 to remeasure -- 已清除已保存选择；请选择 1 重新测速。\n'
}
show_selection() {
  local current result
  if current=$(read_cache && printf '%s\n' "$SAVED_SOURCE") 2>/dev/null; then
    printf 'Saved selection -- 当前已保存源：%s\n' "$current" >&2
  else
    result=$?
    if [[ $result == 1 ]]; then
      printf 'No saved selection (default: official) -- 未保存源选择（默认：官方源）。\n' >&2
    else
      printf 'Saved selection is invalid or unreadable; clear or check permissions -- 已保存选择无效或不可读；可清除或检查文件权限。\n' >&2
    fi
  fi
}
save_cache() {
  local selected=$1
  profile_valid "$selected" || die 'Unexpected selected source -- 源名称无效'
  if [[ -e $CACHE || -L $CACHE ]]; then check_cache_file; fi
  CACHE_TMP=$(mktemp "$ROOT/.local/download-source.XXXXXXXX")
  chmod 0600 "$CACHE_TMP"
  printf '%s\n' "$selected" >"$CACHE_TMP"
  # Rename the file itself; never follow or write through a target link.
  if [[ -e $CACHE || -L $CACHE ]]; then check_cache_file; fi
  mv -fT -- "$CACHE_TMP" "$CACHE"
  CACHE_TMP=''
}
probe_endpoint() {
  local url=$1 marker=$2 output=$3 status code elapsed milliseconds
  if ! status=$(
      ulimit -c 0
      ulimit -f 512
      curl --disable --fail --silent --show-error --location --max-redirs 3 \
      --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --connect-timeout 2 --max-time 5 --retry 0 --range 0-32767 \
      --max-filesize 524288 --output "$output" --write-out '%{http_code} %{time_total}' \
      "$url" 2>/dev/null
    ); then return 1; fi
  [[ $status =~ ^(200|206)' '([0-9]+([.][0-9]+)?)$ ]] || return 1
  code=${BASH_REMATCH[1]}
  elapsed=${BASH_REMATCH[2]}
  [[ $code == 200 || $code == 206 ]] || return 1
  [[ -s $output && $(stat -c %s -- "$output") -le 524288 ]] || return 1
  case "$marker" in
    release) grep -Fq -- '-----BEGIN PGP SIGNED MESSAGE-----' "$output" || return 1 ;;
    pypi) grep -Eiq 'href[[:space:]]*=[^>]*six[-_.]' "$output" || return 1 ;;
    *) return 1 ;;
  esac
  milliseconds=$(awk -v elapsed="$elapsed" 'BEGIN { if (elapsed < 0 || elapsed > 6) exit 1; printf "%.0f", elapsed * 1000 }') || return 1
  printf '%s' "$milliseconds"
}
probe_candidate() {
  local profile=$1 directory=$2 round endpoint total elapsed failed=0 attempted=0 score
  local -a rounds=() urls=() markers=(release release pypi release)
  # Worker exits must not run the parent's shared temporary-directory cleanup.
  trap - EXIT INT TERM
  ha_source_urls "$profile"
  urls=("${HA_DEBIAN_URL%/}/dists/bookworm/InRelease"
    "${HA_DEBIAN_SECURITY_URL%/}/dists/bookworm-security/InRelease"
    "${HA_PYPI_URL%/}/six/"
    "${HA_DOCKER_CE_URL%/}/linux/debian/dists/trixie/InRelease")
  for ((round=0; round<3; round++)); do
    attempted=$((attempted + 1))
    total=0
    for endpoint in 0 1 2 3; do
      if elapsed=$(probe_endpoint "${urls[$endpoint]}" "${markers[$endpoint]}" "$directory/$profile-body"); then
        total=$((total + elapsed))
      else
        total='failed'; break
      fi
    done
    if [[ $total == failed ]]; then
      failed=$((failed + 1))
      # Two failed rounds cannot meet the required two complete successful rounds.
      [[ $failed -lt 2 ]] || break
    else
      rounds+=("$total")
    fi
  done
  if [[ ${#rounds[@]} -ge 2 ]]; then
    score=$(printf '%s\n' "${rounds[@]}" | sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else printf "%.0f\n", (a[NR/2]+a[NR/2+1])/2}')
    printf '%s %s %s %s\n' "$score" "$profile" "${#rounds[@]}" "$attempted" >"$directory/$profile-result"
  else
    printf 'unavailable %s %s %s\n' "$profile" "${#rounds[@]}" "$attempted" >"$directory/$profile-result"
  fi
}
measure_sources() {
  local profile pid score selected successes attempted best='' best_score=''
  for tool in curl awk sort stat; do command -v "$tool" >/dev/null || die "Missing required tool -- 缺少工具：$tool"; done
  [[ -f "$ROOT/images/postgres/source-profiles.sh" && ! -L "$ROOT/images/postgres/source-profiles.sh" ]] || die 'Missing source profiles -- 缺少源配置定义'
  # Trusted project code; cached input is never sourced or evaluated.
  source "$ROOT/images/postgres/source-profiles.sh"
  WORK=$(mktemp -d)
  printf 'Testing HTTPS metadata (3 rounds, bounded requests) -- 正在测试 HTTPS 元数据（3 轮，有超时限制）\n' >&2
  for profile in official ustc tuna; do
    probe_candidate "$profile" "$WORK" &
    PIDS+=("$!")
  done
  for pid in "${PIDS[@]}"; do wait "$pid" || true; done
  PIDS=()
  printf '\nHTTPS test results -- HTTPS 测速结果\n' >&2
  printf '%-12s%-14s%-10s%s\n' Source Status Rounds 'median total (ms)' >&2
  printf '来源        状态          成功/尝试 总耗时中位数(ms)\n' >&2
  for profile in official ustc tuna; do
    if [[ ! -f "$WORK/$profile-result" ]]; then
      printf '%-12s%-14s%-10s%s\n' "$profile" error - - >&2; continue
    fi
    read -r score selected successes attempted <"$WORK/$profile-result"
    [[ $selected == "$profile" && $successes =~ ^[0-3]$ && $attempted =~ ^[23]$ ]] || die 'Unexpected probe result -- 测速结果无效'
    if [[ $score == unavailable ]]; then
      [[ $successes =~ ^[01]$ ]] || die 'Unexpected probe result -- 测速结果无效'
      printf '%-12s%-14s%-10s%s\n' "$profile" unavailable "$successes/$attempted" - >&2; continue
    fi
    [[ $score =~ ^[0-9]+$ && $successes =~ ^[23]$ && $attempted == 3 ]] || die 'Unexpected probe result -- 测速结果无效'
    printf '%-12s%-14s%-10s%s\n' "$profile" available "$successes/$attempted" "$score" >&2
    if [[ -z $best || $score -lt $best_score ]]; then best=$profile; best_score=$score; fi
  done
  printf '%s\n' 'available = 可用；unavailable = 不可用；error = 测试异常。' \
    'Rounds = successful/attempted; 2 successes required -- 成功/实际尝试；至少成功 2 轮。' \
    'Each round totals 4 HTTPS requests -- 每轮累计 4 项 HTTPS 请求的耗时。' >&2
  [[ -n $best ]] || die 'No usable HTTPS source; saved choice was not changed -- 没有可用 HTTPS 源，原选择未修改'
  SELECTED_SOURCE=$best
}
select_source() {
  local requested=$1 reuse=$2
  if [[ $reuse == true ]] && read_cache; then printf '%s\n' "$SAVED_SOURCE"; return; fi
  lock_cache
  # A concurrent resolver may have completed while this process waited for its lock.
  if [[ $reuse == true ]] && read_cache; then printf '%s\n' "$SAVED_SOURCE"; return; fi
  if [[ $requested == auto ]]; then measure_sources; else SELECTED_SOURCE=$requested; fi
  save_cache "$SELECTED_SOURCE"
  printf 'Selected source -- 已选择源：%s\n' "$SELECTED_SOURCE" >&2
  printf '%s\n' "$SELECTED_SOURCE"
}
interactive() {
  local answer
  while true; do
    printf '%s\n' '' 'Download sources -- 下载源' >&2
    show_selection
    printf '%s\n' \
      '1. Remeasure and select (HTTPS) -- 重新测速并选择（HTTPS）' \
      '2. Official -- 官方源' '3. USTC -- 中科大源' '4. TUNA -- 清华源' \
      '5. Show saved selection -- 显示已保存选择' \
      '6. Clear saved selection -- 清除已保存选择' '0. Back -- 返回' >&2
    printf 'Choose an option (Enter to exit) -- 请选择（直接回车退出）：' >&2
    IFS= read -r answer || return 0
    case "$answer" in
      ''|0|00) return 0 ;;
      1|01) select_source auto false; return ;;
      2|02) select_source official false; return ;;
      3|03) select_source ustc false; return ;;
      4|04) select_source tuna false; return ;;
      5|05) show_selection ;;
      6|06) clear_saved_source ;;
      *) printf 'Invalid option -- 选项无效\n' >&2 ;;
    esac
  done
}
case "${1:-}" in
  --help|-h) [[ $# == 1 ]] || die 'Unexpected arguments -- 参数无效'; usage ;;
  --show)
    [[ $# == 1 ]] || die 'Unexpected arguments -- 参数无效'
    if read_cache; then printf '%s\n' "$SAVED_SOURCE"; else printf 'official\n'; fi
    ;;
  clear)
    [[ $# == 1 ]] || die 'Unexpected arguments -- 参数无效'
    clear_saved_source
    ;;
  --resolve)
    [[ $# == 2 ]] || die '--resolve needs one source -- --resolve 需要一个源名称'
    case "$2" in
      saved) if read_cache; then printf '%s\n' "$SAVED_SOURCE"; else printf 'official\n'; fi ;;
      auto) select_source auto true ;;
      official|ustc|tuna) select_source "$2" false ;;
      *) die 'Unknown source -- 未知源' ;;
    esac
    ;;
  auto|official|ustc|tuna)
    [[ $# == 1 ]] || die 'Unexpected arguments -- 参数无效'
    select_source "$1" false
    ;;
  '') [[ $# == 0 ]] || die 'Empty source argument -- 源参数为空'; interactive ;;
  *) die 'Unknown source -- 未知源' ;;
esac
