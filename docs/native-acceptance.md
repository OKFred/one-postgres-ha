# 原生空集群验收

在控制端项目根目录运行，仅用于尚无业务的空集群。每次只注入一个故障，恢复后 `bash ops.sh verify` 必须通过，才能开始下一项。本文是可复现的操作流程，不代表任何现场步骤已通过。

适用于全 AMD64（Linux `x86_64`）或全 ARM64（`aarch64`）三节点集群。
配置向导保存的 `expected_architecture` 必须与各节点实际架构一致，新增副本也使用同架构。
Debian 13 两种架构使用相同的操作流程，但物理机的 watchdog、网卡和 VRRP 条件仍须逐项验收。
CI、单台 VM、QEMU 和未验证硬件 watchdog 的虚拟集群结果均不能作为完整原生 HA 故障通过证明。

`tests/native-probe.py` 是验收时临时复制到宿主机的 Python 标准库助手，不参与常驻服务或 Bash/Ansible/Compose 部署入口。`snapshot`、`owner` 只读；写 proof、暂停/恢复进程及临时网络规则均要求 root、集群 ownership marker 和显式 `--apply`。硬件测试要求 Linux 支持 pidfd，不支持时拒绝发信号。

## 0. 工具与记录

使用现有工具镜像、私有 inventory 和凭据文件。密码只由 Ansible/psql 读取，不粘贴、不打印。以下函数不默认连接任何节点，只有调用时执行。

```bash
set -euo pipefail
ROOT=$(pwd -P)
RUNID=$(openssl rand -hex 6)
TABLE=native_ha_$RUNID
CHAIN=PGN_$RUNID
mkdir -p .local/evidence/native-$RUNID
EVIDENCE=.local/evidence/native-$RUNID
tool() {
  docker run --rm --init --read-only --tmpfs /tmp:rw,exec,nosuid,size=256m \
    --mount "type=bind,src=$ROOT,dst=/workspace" \
    --mount "type=bind,src=$ROOT/.local/inventory.yml,dst=/inventory.yml,readonly" \
    --mount "type=bind,src=$ROOT/.local/known_hosts,dst=/tmp/known_hosts,readonly" \
    -e ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg \
    -e ANSIBLE_LOCAL_TEMP=/tmp/ansible-local -e ANSIBLE_HOME=/tmp/ansible-home \
    -e 'ANSIBLE_SSH_ARGS=-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/known_hosts' \
    -w /workspace one-postgres-ha-tools:pg17.11 "$@" \
    -i /inventory.yml -e project_root=/workspace -e private_dir=/workspace/.local
}
```

本稿使用 inventory 中的 SSH 密码引用；使用私钥的控制端需要像 ops.sh 一样独立挂载私钥，不能把密钥内容放参数里。所有变更只允许一个控制端执行，不得并发 ops/deploy 或另一项故障。

完成正式 deploy 后：

```bash
bash ops.sh verify | tee "$EVIDENCE/verify-before.txt"
tool ansible core_nodes -m ansible.builtin.copy -a \
  'src=/workspace/tests/native-probe.py dest=/run/one-postgres-ha-native-probe.py owner=root group=root mode=0700'
tool ansible core_nodes -m ansible.builtin.command -a \
  '/usr/bin/python3 /run/one-postgres-ha-native-probe.py snapshot --deployment-root {{ deployment_root }} --data-mount {{ data_mount }}' \
  | tee "$EVIDENCE/resources-before.txt"
tool ansible pg_nodes -m ansible.builtin.uri -a \
  'url=http://{{ node_ip }}:8008/cluster return_content=true' | tee "$EVIDENCE/cluster-before.txt"
tool ansible core_nodes -m ansible.builtin.command -a \
  'ip -j -4 address show' | tee "$EVIDENCE/vip-before.txt"
tool ansible pg_nodes -m ansible.builtin.command -a \
  'uname -m' | tee "$EVIDENCE/architecture.txt"
tool ansible-playbook tests/native-vip.yml | tee "$EVIDENCE/vip-query-before.txt"
```

门槛：唯一主库、统一 system identifier、checksums=on、strict sync1、一个 streaming sync 备库、三个 etcd 健康、三个代理 ready、VIP 仅在一台核心主机。资源记录包含 CPU、内存、load、SSD 来源和 Docker/containerd 启动及挂载时间。新启动必须在 SSD 挂载之后；不接受 eMMC 上的替代数据目录。

## 1. VIP 提交及读回

只在 postgres 数据库建本次唯一小表，禁止使用已有业务表。`CREATE TABLE` 不使用 IF NOT EXISTS，碰撞直接停止。

```bash
cat >"$EVIDENCE/vip-vars.json" <<EOF
{"native_apply":true,"native_sql":"CREATE TABLE public.$TABLE (stage text PRIMARY KEY, committed_at timestamptz NOT NULL DEFAULT now()); BEGIN; INSERT INTO public.$TABLE(stage) VALUES ('baseline'); COMMIT; SELECT stage FROM public.$TABLE ORDER BY stage;"}
EOF
tool ansible-playbook tests/native-vip.yml \
  -e "@/workspace/$EVIDENCE/vip-vars.json" | tee "$EVIDENCE/marker-baseline.txt"
```

后续每步把 SQL 改为 `BEGIN; INSERT INTO public.<TABLE>(stage) VALUES ('<唯一阶段>'); COMMIT; SELECT stage FROM public.<TABLE> ORDER BY stage;`，均经同一 VIP 客户端执行并保存结果。阶段为 switchover、etcd_down、proxy_down、dcs_isolated、watchdog_recovered。必须读回此前全部已提交阶段；任何写入超时或缺失都停止验收。

## 2. 受控切主

```bash
bash ops.sh verify
bash ops.sh switchover | tee "$EVIDENCE/switchover.txt"
```

记录新的主库与同步备库，提交 switchover marker，随后再次 verify。该步骤只使用现有同步备库，不强制提升异步副本。

## 3. 一个 etcd 停止和恢复

先 verify，选当前**非主库**核心节点 `TARGET`。以下提前建立独立恢复 timer；timer 验证 active 后才停止 etcd。

```bash
UNIT=pg-native-etcd-$RUNID
tool ansible "$TARGET" -m ansible.builtin.command -a \
  "systemd-run --unit=$UNIT --on-active=90s --collect --working-directory={{ deployment_root }} /usr/bin/docker compose --env-file .env up -d --no-build --no-deps etcd"
tool ansible "$TARGET" -m ansible.builtin.command -a "systemctl is-active $UNIT.timer"
tool ansible "$TARGET" -m ansible.builtin.command -a \
  'chdir={{ deployment_root }} docker compose --env-file .env stop --timeout 10 etcd'
```

确认另两成员仍可形成仲裁，提交 etcd_down marker。立即恢复该节点 etcd：

```bash
tool ansible "$TARGET" -m ansible.builtin.command -a \
  'chdir={{ deployment_root }} docker compose --env-file .env up -d --no-build --no-deps etcd'
bash ops.sh verify
```

失败时只恢复本次 etcd，不继续下一项；独立 timer 仍提供兜底。避免测试期间修改 Compose 文件，否则恢复命令可能发生容器重建。

## 4. HAProxy / VIP 迁移

先 verify，读取三节点 IP 地址确定唯一 VIP 持有者 `TARGET`。复用上一步模式，把 unit 名改为 `pg-native-proxy-$RUNID`，服务改为 haproxy；验证恢复 timer active 后停 haproxy。

Keepalived 应因本地 /ready 失败释放 VIP，另一节点接管。记录原/新持有者，确认全程没有两个节点同时持有 VIP；提交 proxy_down marker。恢复 haproxy，再 verify。该步骤不停止 PostgreSQL 或切换数据库主库。

## 5. 主库 DCS 客户端出口隔离

先 verify，选择当前主库 `TARGET`，从私有 inventory 取三个核心节点 IPv4 地址。包含自身 node_ip 和 127.0.0.1，不能漏掉本地 etcd 客户端地址。

```bash
tool ansible "$TARGET" -m ansible.builtin.command -a \
  "/usr/bin/python3 /run/one-postgres-ha-native-probe.py dcs-isolate --deployment-root {{ deployment_root }} --cluster-name {{ cluster_name }} --run-id $RUNID --chain $CHAIN --addresses {{ groups.core_nodes | map('extract', hostvars, 'node_ip') | join(' ') }} --apply"
```

助手先验证独立 systemd 90 秒清理 timer，再建立专用 OUTPUT 链，仅拒绝到三节点和 loopback 的 TCP2379。SSH、PG复制5433、etcd成员2380及其他防火墙链不变。观察旧主降级、新主产生，VIP 提交 dcs_isolated marker；立即恢复：

```bash
tool ansible "$TARGET" -m ansible.builtin.command -a \
  "/usr/bin/python3 /run/one-postgres-ha-native-probe.py dcs-cleanup --deployment-root {{ deployment_root }} --cluster-name {{ cluster_name }} --run-id $RUNID --chain $CHAIN --apply"
bash ops.sh verify
```

只删除有本次 ownership record 的临时规则；查询失败保留记录，不清空其他规则。此项仅证明 DCS 客户端出口分区处理，不能称为完整网络隔离、断电或全部 fencing 验收。

## 6. 实际硬件 watchdog 重启

最后进行。先 verify，当前主库必须是**控制端以外的主机**；记录全部此前 markers。禁止冻结运行工具容器的控制端，避免失去监管。

```bash
tool ansible "$TARGET" -m ansible.builtin.command -a \
  "/usr/bin/python3 /run/one-postgres-ha-native-probe.py proof --deployment-root {{ deployment_root }} --cluster-name {{ cluster_name }} --proof /run/native-watchdog-$RUNID.json --run-id $RUNID --apply" \
  | tee "$EVIDENCE/watchdog-owner-before.txt"
tool ansible "$TARGET" -m ansible.builtin.fetch -a \
  "src=/run/native-watchdog-$RUNID.json dest=/workspace/$EVIDENCE/watchdog-proof.json flat=true"
date -u +%FT%TZ | tee "$EVIDENCE/watchdog-trigger-utc.txt"
tool ansible "$TARGET" -m ansible.builtin.command -a \
  "/usr/bin/python3 /run/one-postgres-ha-native-probe.py pause --deployment-root {{ deployment_root }} --cluster-name {{ cluster_name }} --proof /run/native-watchdog-$RUNID.json --run-id $RUNID --apply" \
  | tee "$EVIDENCE/watchdog-paused.txt"
```

助手以 `/proc/<hostPID>/fd` 的字符设备 rdev 比较确认实际 watchdog FD（设备 inode 在容器和宿主可不同，不能依赖 fuser）。同时核对 Patroni cmdline hash、starttime、容器 cgroup 和 boot_id；通过 pidfd 只冻结这个进程，避免信号发送瞬间 PID 被复用。先建立90秒 SIGCONT 兜底 timer，然后发 SIGSTOP。

每2秒从控制端记录 SSH 可达性、当前主库和 boot_id；总等待上限180秒。保存第一次失联时间与首次读到新 boot_id 的时间，两者与触发时间的差分别记为 `time_to_disconnect`、`time_to_new_boot_id`。它们是控制端观测值，包含轮询及启动时间，不能冒充硬件精确复位延迟。另记录 Patroni 原生日志实际激活的 watchdog 类型和 timeout。

节点应因硬件 watchdog 重启，boot_id 必须变化；同一已提交 marker 应可经 VIP 读到。分别记录硬件复位与主库角色变化：节点可能在当前 DCS TTL 到期前恢复，保留原 leader 也不能否定已观测的硬件复位。主库故障切换由前一步 DCS 客户端分区的旧主降级、新主出现证明。等待达到配置的 watchdog timeout 加15秒仍未观察到复位，或恢复异常，就停止验收并用同一 proof 执行 resume（带 --apply 和相同 run-id），只做本次恢复。

**禁止直接 `kill -CONT <旧PID>`。** 助手在同 boot_id、相同 PID starttime/cmdline hash、相同容器及 watchdog FD 均匹配时才发 SIGCONT；重启、PID复用或身份变化都不发信号。重启后 /run proof 和兜底 transient timer会消失，无需恢复旧PID。

恢复后先确认 SSD 仍为原设备且 Docker/containerd 在挂载之后启动，随后 `bash ops.sh verify`；保存 checksums、sync、统一 identity、实际新主库和资源快照。只在恢复完整后提交 watchdog_recovered marker。

## 7. 收尾与证据

再次经VIP读回本次所有 marker，保存 final verify、所有节点 boot_id、SSD及资源快照，核查对应时间段 OOM/重启日志。恢复所有本次停止服务，检查本次临时链已删除；90秒 timer只能恢复本次服务/规则，不能拿它当恢复已经完成的证明。

最后只删除本次创建的 `public.<TABLE>`（以最初 RUNID 为准）；禁止通配删除、删 schema 或操作业务库。保留 `.local/evidence/native-<RUNID>/` 私有记录，分别标注代码检查、实际原生硬件结果、尚未完成的独立备份恢复与业务验收。任何一项失败就停止，不填造通过状态。

业务迁移需要独立的故障验收 JSON，字段见 [数据迁移验收](../scripts/data/README.md)。
仅在对应真实测试全部完成后填写 `native: true`、实际的 `architecture`（`x86_64` 或 `aarch64`）及各项通过状态；
记录必须绑定当前 `cluster_name`、`system_identifier`、真实 UTC 完成时间和确认事务 LSN。
迁移脚本只接受与 inventory `expected_architecture` 一致且 24 小时内完成的记录。
旧 `arm64_native: true` 记录只兼容 ARM64 目标，不可复制到 AMD64 集群沿用。
本文的 DCS 出口隔离步骤不能独自证明 JSON 中完整的 `network_isolation` 项，须另外完成相应故障场景。
