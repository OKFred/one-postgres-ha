# 清理与重装

## 使用位置

在管理这套集群的控制端项目目录执行，控制端需要 Bash、Docker 和 flock。
Windows 使用 WSL。根目录 `install.sh`、`uninstall.sh` 复用 `ops.sh`，
Ansible 在工具容器中通过 SSH 操作 inventory 内的服务器。

首次使用 `bash ops.sh configure` 生成 `.local/inventory.yml`、SSH 身份引用及
核实过的 `.local/known_hosts`，然后运行安装入口。真实配置和凭据不包含在部署包里。
向导只读检测节点，主机指纹须与每台控制台核对；详见 [首次配置向导](configure.md)。

## 一键安装

```bash
bash install.sh
```

默认在交互终端输入 `INSTALL` 后执行；无配置时先进入本项目向导。
使用 `bash install.sh --apply` 明确批准安装，`--yes` 为兼容别名。
这两个参数不跳过配置、SSH 指纹和预检；不能与 `--plan` 混用或重复。
非交互执行必须传 `--apply` 或 `--yes`。

缺少所选工具镜像时自动构建或拉取，依次执行：

1. `secrets`：生成缺失的密码和证书，保留已有值。
2. `plan`：完整预检后展示配置与部署计划。
3. `deploy`：启动 etcd 仲裁、初始化首个 PostgreSQL、建立副本并启动代理和 VIP。
4. `status`、`verify`：读取状态，核对版本、数据校验和、唯一主库和同步复制。

全部阶段共用操作锁；任何一步失败立即退出，保留现场以便检查后重试。
安装和清理各自使用本轮 inventory 快照，预览后修改原文件不会改变本轮目标节点。
首次空数据安装会创建空集群，不迁移 PG17 或 Nexus 业务数据。
对正常运行的集群重复执行会按现有滚动部署流程处理。

预览方式：

```bash
bash ops.sh secrets
bash install.sh --plan
```

`--plan` 不生成或轮换凭据，不修改目标主机。
它仍需要完整的本地凭据供现有预检校验。

目标主机须已准备 Docker/Compose、Python 3、可独占 watchdog 和现有 SSD 挂载。
若 Debian 13 ARM64 尚无 Docker，先在每台目标主机运行：

```bash
bash scripts/prepare-host.sh /实际SSD挂载点 --plan
bash scripts/prepare-host.sh /实际SSD挂载点 --apply
```

宿主准备拒绝接管未知 Docker 配置；磁盘分区、格式化、挂载和 watchdog 移交需先完成。
安装脚本不猜测磁盘或网卡，也不把数据写入缺失 SSD 的普通目录。

## 一键卸载

先检查删除范围：

```bash
bash uninstall.sh
# 等同于：bash uninstall.sh --plan --keep-data
```

保留数据，移除本集群的运行资源：

```bash
bash uninstall.sh --plan --keep-data
bash uninstall.sh --apply --keep-data
```

彻底清理本集群及其数据：

```bash
bash uninstall.sh --plan --purge-data
bash uninstall.sh --apply --purge-data
```

`--apply` 必须明确选择 `--keep-data` 或 `--purge-data`，不能同时选择或重复。
先展示全部目标节点及目录，再要求输入档位对应的确认值。
非交互执行使用：

```bash
bash uninstall.sh --apply --keep-data --confirm UNINSTALL-ONE-POSTGRES-HA
bash uninstall.sh --apply --purge-data --confirm DELETE-ONE-POSTGRES-HA
```

卸载前停用指向该集群的业务；彻底清理前确保所需备份可恢复。
`--purge-data` 删除的数据无法通过安装脚本恢复。
如果已启用独立备份服务器的定时作业，先暂停这些作业；清理不会访问或删除备份服务器。

### 删除和保留范围

| 对象 | 行为 |
|---|---|
| inventory 内所有 `pg_nodes` 的 PostgreSQL、etcd、HAProxy 容器 | 核对标签、部署身份和挂载后停止并删除 |
| 各节点 `deployment_root` | `--keep-data` 完整保留 Compose、配置、凭据及归属标记；`--purge-data` 核对归属后删除 |
| 各节点 `data_root` | `--keep-data` 完整保留；`--purge-data` 删除本项目 PG/etcd 数据与归属标记，未知内容拒绝 |
| 本项目 Keepalived 配置、防火墙启动依赖与 watchdog 权限持久规则 | 核对归属后移除；先移除启动依赖再删除防火墙服务，不猜测恢复当前 watchdog 设备权限 |
| 控制端 `.local/` | 保留，包括 inventory、SSH 凭据、CA、数据库密码及历史证据 |
| 独立备份服务器及其定时任务 | 保留，清理不访问它 |
| SSD 分区、文件系统、挂载 | 保留 |
| Docker/containerd、镜像缓存和其他项目 | 保留 |

### 执行顺序与失败

先在**全部节点**完成只读审计，全部通过后依次：

1. 停止所有入口 Keepalived/HAProxy。
2. 正常停止所有 PostgreSQL/Patroni，确保 watchdog 释放。
3. 停止所有 etcd。
4. 重新核对归属和挂载，删除容器与本项目宿主配置；仅 `--purge-data` 删除节点部署和数据目录。

审计拒绝错误集群名、未知目录内容、符号链接路径、嵌套挂载或占用这些路径的其他容器。
初次审计时某节点无法连接，会阻止整个集群进入停止或删除阶段。
开始停止服务后如果后续失败，已经完成的步骤不会自动撤销。
保留错误输出，检查节点后重试；不要手动删除归属标记来绕过审计。

## 重新安装

清理成功后：

```bash
bash install.sh
```

SSH 配置、原密码和 CA 可直接沿用。保留数据卸载后，安装会恢复宿主配置并继续使用原 PostgreSQL／etcd 数据，
不要只在节点上执行 Compose 来代替这一步。彻底清理后重装的集群为空，具有新的 PostgreSQL system identifier
和 etcd 数据；旧验收记录不能证明新集群通过故障测试。业务接入前重新验收，并完成独立备份恢复演练。

保留数据卸载会在各节点部署目录保存权限 `0600` 的 `.one-postgres-ha-retained.json`。
安装仅在全部成员的受控停机记录、节点和路径、PostgreSQL 系统标识与既有 DCS 一致时恢复；
不会删除 `initialize` 或把旧数据库当新集群初始化。缺少或冲突的记录会停止自动恢复。
成功恢复后保留完成记录供审计；完成记录不会让后续普通断电或网络故障进入这条恢复路径。
不要手动复制、修改或删除记录来绕过检查，新增副本也须包含在本次卸载和恢复的 inventory 中。

如果项目源码也删除了，重新下载仓库或部署包，恢复 `.local/` 后再运行安装脚本。
若 `.local/` 也丢失且所有节点 PG/etcd 数据已删除，可以从零配置并生成新凭据：

```bash
bash ops.sh configure
bash install.sh
```

若旧数据仍在，应恢复旧凭据；安装入口不提供丢失 DCS 的自动接管或全节点冷启动恢复。

自定义 inventory：

```bash
bash uninstall.sh --inventory /私有配置/site.yml --apply --purge-data
bash install.sh --inventory /私有配置/site.yml
```

旧的根目录 `cleanup.sh` 已删除，卸载统一使用 `uninstall.sh` 并明确选择数据档位。
`ops.sh uninstall` 与根卸载入口相同；底层 `ops.sh install` 仍供已有自动化使用，交互用户使用根安装入口。
三个项目分别维护私有配置，本项目不会加载 Nexus 或 RustFS inventory。

清理、部署和手动维护共用控制端的操作锁。应固定使用同一个控制端，避免多个控制端同时操作集群。

## 验证范围

`bash ops.sh check` 检查命令入口、操作锁、目录归属、挂载和容器保护，以及完整 inventory 审计顺序。
`bash tests/test-retained-recovery.sh` 使用真实 Ansible 任务、隔离 HTTP 状态接口及模拟 Docker，
覆盖受控恢复、部分完成重试、普通升级不触发恢复，以及缺失记录、事务或系统标识冲突的拒绝。
它不等同于真实 Patroni／etcd 的三节点恢复验收。
`bash tests/test-cleanup-containers.sh` 使用隔离 Docker 卷与内部网络，运行真实 PostgreSQL 17 和
单成员 etcd，验证预览无业务变更、拒绝外部容器占用、只删除本项目数据及重建空数据库。
该测试保留其他容器和外来卷，并单独覆盖旧布局父目录匿名卷的保护场景。

容器测试模拟 SSD 元数据、Docker 存储边界、宿主 systemd、防火墙、udev 和未打开的 watchdog
字符设备；准确排除代替宿主执行的测试控制容器。它不验证真实 watchdog、VIP 或 Patroni 故障切换。
现场只读预览与隔离删除测试分别记录，现有集群不会为测试脚本而清空。
