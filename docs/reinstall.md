# 清理与重装

## 使用位置

在管理这套集群的控制端项目目录执行，控制端需要 Bash、Docker 和 flock。
Windows 使用 WSL。根目录 `install.sh`、`cleanup.sh` 复用 `ops.sh`，
Ansible 在工具容器中通过 SSH 操作 inventory 内的服务器。

首次使用 `bash ops.sh configure` 生成 `.local/inventory.yml`、SSH 身份引用及
核实过的 `.local/known_hosts`，然后运行安装入口。真实配置和凭据不包含在部署包里。
向导只读检测节点，主机指纹须与每台控制台核对；详见 [首次配置向导](configure.md)。

## 一键安装

```bash
bash install.sh
```

缺少所选工具镜像时自动构建或拉取，依次执行：

1. `secrets`：生成缺失的密码和证书，保留已有值。
2. `plan`：完整预检后展示配置与部署计划。
3. `deploy`：启动 etcd 仲裁、初始化首个 PostgreSQL、建立副本并启动代理和 VIP。
4. `status`、`verify`：读取状态，核对版本、数据校验和、唯一主库和同步复制。

全部阶段共用操作锁；任何一步失败立即退出，保留现场以便检查后重试。
安装和清理各自使用本轮 inventory 快照，预览后修改原文件不会改变本轮目标节点。
脚本部署空集群，不迁移 PG17 或 Nexus 业务数据。
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

## 一键清理

先检查删除范围：

```bash
bash cleanup.sh
```

确认需要清空整套集群时：

```bash
bash cleanup.sh --apply
```

脚本展示全部目标节点及目录，要求输入 `DELETE-ONE-POSTGRES-HA`。
非交互运行必须明确传入确认值：

```bash
bash cleanup.sh --apply --confirm DELETE-ONE-POSTGRES-HA
```

清理前停用指向该集群的业务，并确保所需备份可恢复。
清理后本地数据无法通过安装脚本恢复。
如果已启用独立备份服务器的定时作业，先暂停这些作业；清理不会访问或删除备份服务器。

### 删除和保留范围

| 对象 | 行为 |
|---|---|
| inventory 内所有 `pg_nodes` 的 PostgreSQL、etcd、HAProxy 容器 | 核对标签、部署身份和挂载后停止并删除 |
| 各节点 `deployment_root` | 核对集群归属后删除，包含节点配置和凭据副本 |
| 各节点 `data_root` | 删除本项目 PG/etcd 数据与归属标记，未知内容拒绝 |
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
4. 重新核对归属和挂载，再删除容器、目录和本项目配置。

审计拒绝错误集群名、未知目录内容、符号链接路径、嵌套挂载或占用这些路径的其他容器。
初次审计时某节点无法连接，会阻止整个集群进入停止或删除阶段。
开始停止服务后如果后续失败，已经完成的步骤不会自动撤销。
保留错误输出，检查节点后重试；不要手动删除归属标记来绕过审计。

## 重新安装

清理成功后：

```bash
bash install.sh
```

SSH 配置、原密码和 CA 可直接沿用。新集群为空，具有新的 PostgreSQL system identifier
和 etcd 数据；旧验收记录不能证明新集群通过故障测试。业务接入前重新验收，并完成独立备份恢复演练。

如果项目源码也删除了，重新下载仓库或部署包，恢复 `.local/` 后再运行安装脚本。
若 `.local/` 也丢失且所有节点 PG/etcd 数据已删除，可以从零配置并生成新凭据：

```bash
bash ops.sh configure
bash install.sh
```

若旧数据仍在，应恢复旧凭据；安装入口不提供丢失 DCS 的自动接管或全节点冷启动恢复。

自定义 inventory：

```bash
bash cleanup.sh --inventory /私有配置/site.yml --apply
bash install.sh --inventory /私有配置/site.yml
```

清理、部署和手动维护共用控制端的操作锁。应固定使用同一个控制端，避免多个控制端同时操作集群。

## 验证范围

`bash ops.sh check` 检查命令入口、操作锁、目录归属、挂载和容器保护，以及完整 inventory 审计顺序。
`bash tests/test-cleanup-containers.sh` 使用隔离 Docker 卷与内部网络，运行真实 PostgreSQL 18 和
单成员 etcd，验证预览无业务变更、拒绝外部容器占用、只删除本项目数据及重建空数据库。
该测试保留其他容器和 PG18 基础镜像继承的父目录匿名卷。

容器测试模拟 SSD 元数据、Docker 存储边界、宿主 systemd、防火墙、udev 和未打开的 watchdog
字符设备；准确排除代替宿主执行的测试控制容器。它不验证真实 watchdog、VIP 或 Patroni 故障切换。
现场只读预览与隔离删除测试分别记录，现有集群不会为测试脚本而清空。
