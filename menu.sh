#!/usr/bin/env bash
# Interactive control surface; all operations retain their existing backend guards.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if (($#)); then
  if [[ $# == 1 && ($1 == --help || $1 == -h) ]]; then
    printf '%s\n' 'Usage: bash menu.sh' \
      'PostgreSQL 中文运维菜单：配置、安装、状态、验收、节点、备份、卸载。' \
      '在控制端运行；配置沿用本项目 .local/，也支持既有 HA_INVENTORY。' \
      '安装和卸载仍需原入口确认；菜单不会自动填写确认令牌。'
    exit 0
  fi
  printf 'ERROR: Usage: bash menu.sh [--help]\n' >&2
  exit 2
fi

ask() {
  # EOF at any prompt exits the menu, including nested menus and confirmations.
  IFS= read -r -p "$1" answer || exit 0
}
run() {
  local script=$1 code
  shift
  printf '\n执行：bash %q' "$script"
  if (($#)); then printf ' %q' "$@"; fi
  printf '\n'
  if (cd -- "$ROOT" && bash "$ROOT/$script" "$@"); then
    printf '\n操作完成。\n'
  else
    code=$?
    printf '\n操作未完成（退出码 %d），请检查上方输出；可重试或返回。\n' "$code" >&2
  fi
}
confirm() {
  printf '\n%s\n' "$1"
  ask '输入 APPLY 执行，其他输入取消：'
  [[ $answer == APPLY ]] && return 0
  printf '已取消。\n'
  return 1
}
node_name() {
  ask '输入已登记在本项目 inventory 的新增副本名（留空取消）：'
  node=$answer
  [[ -n $node ]] || return 1
  if [[ ! $node =~ ^[a-z][a-z0-9_-]{0,62}$ ]]; then
    printf '节点名无效，请使用小写字母开头的字母、数字、下划线或连字符。\n' >&2
    return 1
  fi
}
install_menu() {
  while true; do
    printf '\n安装\n1. 安装预览\n2. 执行安装（保留 INSTALL 确认）\n0. 返回\n'
    ask '请选择：'
    case "$answer" in
      1|01) run install.sh --plan ;;
      2|02) run install.sh ;;
      0|00) return ;;
      *) printf '输入有误，请重新选择。\n' ;;
    esac
  done
}
check_menu() {
  while true; do
    printf '\n检查与验收\n1. 环境预检\n2. 集群验收\n0. 返回\n'
    ask '请选择：'
    case "$answer" in
      1|01) run ops.sh preflight ;;
      2|02) run ops.sh verify ;;
      0|00) return ;;
      *) printf '输入有误，请重新选择。\n' ;;
    esac
  done
}
node_menu() {
  while true; do
    printf '\n节点与 HA\n1. 查看集群状态\n2. 新增 PG 副本预览\n3. 执行新增 PG 副本\n4. 受控切主（自动选择合格同步副本）\n5. 移除节点说明\n0. 返回\n'
    ask '请选择：'
    case "$answer" in
      1|01) run ops.sh status ;;
      2|02)
        node_name || continue
        run ops.sh add-node "$node" --plan ;;
      3|03)
        node_name || continue
        confirm '将克隆已登记的新副本并更新代理；请先查看新增预览。不会增加 etcd 成员。' || continue
        run ops.sh add-node "$node" ;;
      4|04)
        confirm '将切换 PostgreSQL 主库并影响已有连接；目标由既有流程选择合格同步副本。' || continue
        run ops.sh switchover ;;
      5|05)
        printf '%s\n' '当前没有受控 remove-node 命令。不要仅从 inventory 删除节点或修改 etcd 成员。' \
          '新增节点只支持 PG 副本；移除需另行设计复制、代理和成员清理流程。' ;;
      0|00) return ;;
      *) printf '输入有误，请重新选择。\n' ;;
    esac
  done
}
backup_menu() {
  while true; do
    printf '\n备份与恢复\n需先在本项目配置独立备份目标，处理范围为所有非模板数据库及角色。\n1. 全实例备份\n2. 最近备份的隔离恢复演练（不覆盖在线集群）\n0. 返回\n'
    ask '请选择：'
    case "$answer" in
      1|01)
        confirm '将读取在线数据库并写入独立备份目标，产生磁盘与网络负载，并执行既有备份保留策略。' || continue
        run ops.sh backup ;;
      2|02)
        confirm '将在独立备份服务器执行隔离恢复演练，需要可用备份和额外空间。' || continue
        run ops.sh restore-test ;;
      0|00) return ;;
      *) printf '输入有误，请重新选择。\n' ;;
    esac
  done
}
uninstall_menu() {
  while true; do
    printf '\n卸载\n1. 预览卸载，保留数据\n2. 执行卸载，保留数据\n3. 预览彻底清理本集群数据\n4. 执行彻底清理本集群数据（不可恢复）\n0. 返回\n'
    ask '请选择：'
    case "$answer" in
      1|01) run uninstall.sh --plan --keep-data ;;
      2|02) run uninstall.sh --apply --keep-data ;;
      3|03) run uninstall.sh --plan --purge-data ;;
      4|04) run uninstall.sh --apply --purge-data ;;
      0|00) return ;;
      *) printf '输入有误，请重新选择。\n' ;;
    esac
  done
}

while true; do
  printf '\none-postgres-ha 运维菜单\n01. 配置向导\n02. 安装\n03. 状态\n04. 检查与验收\n05. 节点与 HA\n06. 备份与恢复\n07. 卸载\n08. 命令帮助\n00. 退出\n'
  ask '请选择：'
  case "$answer" in
    1|01) run ops.sh configure ;;
    2|02) install_menu ;;
    3|03) run ops.sh status ;;
    4|04) check_menu ;;
    5|05) node_menu ;;
    6|06) backup_menu ;;
    7|07) uninstall_menu ;;
    8|08) run ops.sh help ;;
    0|00) exit 0 ;;
    *) printf '输入有误，请重新选择。\n' ;;
  esac
done
