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
  printf '%s\n' 'Usage: bash ops.sh sources [auto|official|ustc|tuna|--show]' \
    'No argument opens the menu; Enter exits -- 无参数显示菜单，直接回车退出。' \
    'auto remeasures verified HTTPS endpoints; manual choices do not contact the network -- auto 重新测速，手动选择不联网。' \
    'Saved choices are reused until explicitly changed -- 保存的选择会复用，直到手动修改或重新测速。'
}
check_private() {
  [[ ! -L "$ROOT/.local" && (! -e "$ROOT/.local" || -d "$ROOT/.local") ]] || die 'Invalid private directory -- 私有目录无效'
}
check_cache_file() {
  check_private
  [[ -f $CACHE && ! -L $CACHE ]] || die 'Invalid saved source file -- 保存的源文件无效'
  [[ $(stat -c %u -- "$CACHE") == "$(id -u)" && $(stat -c %h -- "$CACHE") == 1 \
    && $(stat -c %s -- "$CACHE") -le 32 ]] || die 'Unsafe saved source file -- 保存的源文件不安全'
}
read_cache() {
  local snapshot
  check_private
  if [[ ! -e $CACHE && ! -L $CACHE ]]; then return 1; fi
  check_cache_file
  # Read one bounded byte snapshot. A writer may atomically replace the path
  # between reads, so separate parsing/comparison opens could disagree even
  # when both versions are valid. Hex retains NUL/CR/LF that Bash would strip.
  snapshot=$(od -An -v -tx1 -N 33 -- "$CACHE" | tr -d '[:space:]') || die 'Cannot read saved source -- 无法读取已保存源'
  # Exact ASCII bytes of official/ustc/tuna followed by one LF (0a).
  case "$snapshot" in
    6f6666696369616c0a) SAVED_SOURCE=official ;;
    757374630a) SAVED_SOURCE=ustc ;;
    74756e610a) SAVED_SOURCE=tuna ;;
    *) die 'Saved source must contain exactly one known profile and LF -- 保存值须为单个已知源名称及换行' ;;
  esac
}
lock_cache() {
  local lock="$ROOT/.local/download-source.lock"
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
  if [[ -e $CACHE || -L $CACHE ]]; then check_cache_file; fi
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
  local profile=$1 directory=$2 round endpoint total elapsed failed=0 score
  local -a rounds=() urls=() markers=(release release pypi release)
  # Worker exits must not run the parent's shared temporary-directory cleanup.
  trap - EXIT INT TERM
  ha_source_urls "$profile"
  urls=("${HA_DEBIAN_URL%/}/dists/bookworm/InRelease"
    "${HA_DEBIAN_SECURITY_URL%/}/dists/bookworm-security/InRelease"
    "${HA_PYPI_URL%/}/six/"
    "${HA_DOCKER_CE_URL%/}/linux/debian/dists/trixie/InRelease")
  for ((round=0; round<3; round++)); do
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
    printf '%s %s %s\n' "$score" "$profile" "${#rounds[@]}" >"$directory/$profile-result"
  else
    printf 'unavailable %s 0\n' "$profile" >"$directory/$profile-result"
  fi
}
measure_sources() {
  local profile pid score selected successes best='' best_score=''
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
  for profile in official ustc tuna; do
    if [[ ! -f "$WORK/$profile-result" ]]; then
      printf '%s: unavailable -- 不可用\n' "$profile" >&2; continue
    fi
    read -r score selected successes <"$WORK/$profile-result"
    if [[ $score == unavailable ]]; then
      printf '%s: unavailable -- 不可用\n' "$profile" >&2; continue
    fi
    [[ $score =~ ^[0-9]+$ && $selected == "$profile" && $successes =~ ^[23]$ ]] || die 'Unexpected probe result -- 测速结果无效'
    printf '%s: %s ms (median total; %s successful rounds) -- 中位总耗时，%s 轮成功\n' "$profile" "$score" "$successes" "$successes" >&2
    if [[ -z $best || $score -lt $best_score ]]; then best=$profile; best_score=$score; fi
  done
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
    printf '%s\n' '' 'Download sources -- 下载源' \
      '1. Auto (HTTPS timing) -- 自动选择（HTTPS 测速）' \
      '2. Official -- 官方源' '3. USTC -- 中科大源' '4. TUNA -- 清华源' \
      '5. Show saved selection -- 显示已保存选择' '0. Back -- 返回' >&2
    printf 'Choose an option (Enter to exit) -- 请选择（直接回车退出）：' >&2
    IFS= read -r answer || return 0
    case "$answer" in
      ''|0|00) return 0 ;;
      1|01) select_source auto false; return ;;
      2|02) select_source official false; return ;;
      3|03) select_source ustc false; return ;;
      4|04) select_source tuna false; return ;;
      5|05) if read_cache; then printf '%s\n' "$SAVED_SOURCE"; else printf 'official\n'; fi ;;
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
