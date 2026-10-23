# one-postgres-ha

三台专用 Linux ARM64 服务器上的 PostgreSQL 18 高可用部署工具。
使用 Bash 命令入口、Ansible 配置部署和 Docker Compose 容器。

源码采用 [MIT](LICENSE)。第三方组件保留各自许可证，见 [THIRD_PARTY.md](THIRD_PARTY.md)。
安全与网络条件见 [SECURITY.md](SECURITY.md)，发布源码见 [开源发布](docs/open-source.md)。

## 支持范围

| 项目 | 范围 |
| --- | --- |
| 生产部署 | ARM64 Linux，三个核心节点及可选新增 PG 副本 |
| 宿主工具自动安装 | Debian 13 ARM64；其他系统需自行准备并验收 |
| 网络与存储 | 核心节点在同一直接相连网络；各自本地 SSD；独占硬件 watchdog |
| 测试 | AMD64、ARM64 隔离 CI；现场故障验收单独记录 |
| 业务迁移 | `one_minihouse`、`nexus` 专用适配器，其他应用需另写并验收适配器 |

etcd 使用双向 TLS；PostgreSQL 和 Patroni 管理 API 当前未启用 TLS，后者使用 HTTP Basic Auth。
当前模板需要可信、隔离的内网，跨不可信网络须另行建立加密通道或配置 TLS。
初始部署与常态健康检查不能替代整机故障、VIP 切换和备份恢复验收。

## 服务

- PostgreSQL 18.6＋Patroni 4.1.5，严格同步一个备库。
- 三成员 etcd 3.6.15，客户端和成员通信使用双向 TLS。
- HAProxy 根据 Patroni 的主库状态转发，Keepalived 在三台宿主机间迁移内网 VIP。
- 数据各自存放在本地 SSD，备份写到独立服务器。

可以用 `backup_target.enabled: false` 先建设空集群，此时不连接备份服务器，也不安装备份定时任务。
接入业务前须配置独立备份目标并通过恢复演练。

根目录的 docker-compose.yml 是实际部署文件。三个核心节点共用它，各自使用生成的 .env 和配置；
新增节点默认只运行 PostgreSQL＋Patroni。

## 准备与启动

控制端需要 Bash、Docker、flock、Git。Windows 使用 WSL，并启用 Docker Desktop 对该发行版的集成。
目标服务器需要 Docker Compose、Python 3、现有 SSD 挂载和可独占使用的 watchdog。

Debian 13 ARM64 首次缺少 Docker 时，在目标机器上先运行：

    bash scripts/prepare-host.sh /your/ssd/mount --plan
    bash scripts/prepare-host.sh /your/ssd/mount --apply

该显式准备命令固定 Docker 软件包版本，把 Docker 和 containerd 数据目录放到已有 SSD 挂载下。
它为两个服务安装 SSD 挂载依赖。已准备的主机重复执行会补齐并验证依赖，只重载 systemd，不重启运行中的服务。
已有 Docker 安装、未知配置或数据需要单独检查，脚本会停止。它不分区、不格式化，也不改 watchdog。

首次使用配置向导，再安装并验收：

```bash
bash ops.sh configure
bash install.sh
```

三个项目统一使用根目录 `install.sh`、`uninstall.sh`。`bash install.sh` 需要交互输入
`INSTALL`；明确执行可用 `bash install.sh --apply`，兼容旧的 `--yes` 别名。
`--apply` 不跳过配置、主机指纹或预检，`--plan`、`--apply`、`--yes` 不能混用或重复。

向导集中询问三台节点 IP、VIP、SSH 身份和共用 SSD 挂载路径，
只读检测主机、网卡、Keepalived 版本及控制端管理来源，生成私有配置。
SSH 指纹须与各主机控制台核对，VIP 须自行预留；确认后才保存。
默认在节点构建 PostgreSQL 镜像，也可填写预构建镜像的固定 digest。
备份初始关闭，接入业务前另行配置并验收。

向导只用于首次配置，拒绝覆盖已有 inventory、主机指纹、控制端环境文件及凭据。
使用私钥时先设置 `HA_SSH_KEY`；默认支持三台共用的 SSH 密码，输入不会显示。
全部现场输入保存到忽略的 `.local/`。详细说明与手动配置方法见 [首次配置向导](docs/configure.md)。

已有主机保留 Docker、SSD 挂载和 watchdog 的准备工作即可。脚本生成缺少的凭据，
保留已有凭据，运行预检、计划、部署、状态和验收；中途失败立即停止。
整个安装过程共用一把操作锁。重复执行沿用现有集群，不重置数据库。

只查看安装计划，先准备本地凭据再运行：

```bash
bash ops.sh secrets
bash install.sh --plan
```

需要分步操作时，原命令仍可用：

    bash ops.sh tools
    bash ops.sh secrets
    bash ops.sh preflight
    bash ops.sh plan
    bash ops.sh deploy
    bash ops.sh status
    bash ops.sh verify

secrets 只生成本地密码及证书，重复执行保留原值。preflight 和 plan 不部署服务。
deploy 准备目录、文件权限、专属防火墙规则和宿主 Keepalived，再启动容器；
业务数据库迁移是独立步骤。第一次不会自动导入原数据库。

防火墙加载成功是 Docker 和核心节点 Keepalived 的启动条件；失败时服务拒绝上线。
这项依赖作用于整台机器的 Docker，因此使用专用节点。更新防火墙规则使用 reload，不重启 Docker。

准备完成后，每台服务器在部署目录可以直接运行：

    docker compose up -d
    docker compose logs -f

Compose 管理单台宿主机。跨机器启动顺序、滚动更新和验收由 Ansible 完成。
Keepalived 是宿主机服务，所以完整首次部署需要 ops.sh deploy。

## 使用预构建镜像

可直接使用 [Docker Hub 预构建镜像](PREBUILT-IMAGES.md)，其中记录已发布镜像的固定摘要和配置向导填写方式。

不需要 Docker Swarm。控制端仍通过 Ansible 在三台服务器上分别运行 Compose，
按顺序建立 etcd 仲裁、主库和副本，并配置宿主机 Keepalived 与 watchdog。

默认 `postgres_image_mode: source` 在节点构建 PostgreSQL＋Patroni 镜像。
已有发布镜像时，在私有 inventory 的 `all.vars` 中改为：

```yaml
postgres_image_mode: prebuilt
postgres_ha_image: registry.example.com/your-namespace/one-postgres-ha@sha256:<64位digest>
```

控制端也可直接拉取已发布的 Ansible 工具镜像，再执行同一个安装入口：

```bash
export HA_TOOLS_IMAGE='registry.example.com/your-namespace/one-postgres-ha-tools@sha256:<64位digest>'
bash install.sh
```

用实际发布的 digest 替换占位符。注册表镜像必须按 digest 固定；只写 tag 会被拒绝。
工具镜像已缓存时直接使用，缺少时拉取。节点的部署和 `add-node` 都会拉取 PostgreSQL 镜像，
不复制构建目录、不在目标服务器编译。镜像失败时停止部署，不切换到其他版本。
使用私有仓库时，控制端和各目标节点须提前完成 `docker login`，密码通过 `--password-stdin` 输入；
项目不分发注册表密码。etcd、HAProxy 继续使用已有固定 digest。

在发布机器登录 Registry 后，使用下面的脚本发布两个自建镜像：

```bash
docker login YOUR_REGISTRY
bash scripts/publish-images.sh YOUR_REGISTRY/YOUR_NAMESPACE          # 预览
bash scripts/publish-images.sh YOUR_REGISTRY/YOUR_NAMESPACE --push   # AMD64、ARM64
```

发布使用已提交 HEAD，标签包含版本和提交号，拒绝覆盖已有标签。
摘要和部署片段保存在忽略的 `.local/publish/`，详细步骤见 [镜像发布与拉取部署](docs/images.md)。

## 清理后重新安装

在控制端的项目目录运行。清理范围为私有 inventory 中全部 `pg_nodes`，
包括后续加入的副本；不是只清理当前机器。

```bash
# 保留数据卸载
bash uninstall.sh --plan --keep-data
bash uninstall.sh --apply --keep-data

# 或：彻底清理本集群数据
bash uninstall.sh --plan --purge-data
bash uninstall.sh --apply --purge-data

bash install.sh
```

不传参数的 `bash uninstall.sh` 等同于 `--plan --keep-data`；执行必须显式选择档位。
`--keep-data` 保留 PostgreSQL、etcd 数据及节点 Compose、配置、凭据和归属标记，供同配置重装。
**`--purge-data` 永久删除该集群的 PostgreSQL、etcd 数据及节点部署目录。**
脚本先核对所有节点的目录归属和容器，再依次停止 VIP/代理、所有 PostgreSQL 和 etcd，
最后按档位清理运行资源与本项目的宿主配置。任一节点审计失败时，整个清理停止。

控制端 `.local/`（inventory、SSH 凭据、证书和记录）、独立备份服务器、Docker/containerd
存储、SSD 文件系统与挂载、其他项目均保留。清理不运行 `docker system prune`，不格式化磁盘，
不删除镜像缓存。保留数据卸载后通过安装入口恢复宿主配置和服务；彻底清理后重装才生成新的空数据库及集群标识。

自动化场景可显式传入确认值：

```bash
bash uninstall.sh --apply --keep-data --confirm UNINSTALL-ONE-POSTGRES-HA
bash uninstall.sh --apply --purge-data --confirm DELETE-ONE-POSTGRES-HA
```

交互执行时按提示输入对应确认值；不支持用 `--yes` 跳过卸载确认。
安装、卸载入口均支持 `--inventory FILE`，默认使用本项目 `.local/inventory.yml`，不读取另两个项目的配置。
旧的根目录 `cleanup.sh` 已移除，安装和卸载分别使用 `install.sh`、`uninstall.sh`。
`ops.sh` 仍是这两个入口调用的调度实现，也提供配置、状态、验收和备份等维护命令。
若系统或 SSD 挂载也被删除，先按“准备与启动”恢复宿主条件。
若控制端 `.local/` 也被删除且各节点 PG/etcd 数据已清空，重新运行 `bash ops.sh configure`。
旧 PG/etcd 数据仍在时必须恢复匹配的旧 CA/密码，不能靠重新生成凭据接管旧库。

详细范围和失败处理见 [清理与重装](docs/reinstall.md)。

## 日常操作

    bash ops.sh backup
    bash ops.sh restore-test
    bash ops.sh add-node armbian-04 --plan
    bash ops.sh add-node armbian-04
    bash ops.sh switchover

新增节点需要先加入私有 inventory。初次克隆会占用网络、SSD 和 WAL 空间。
新节点验收完成并更新所有代理后才允许参与切主；不会增加 etcd 成员或强制切主。
已有集群升级一次只更新一个节点，等待复制恢复后继续。

## 可选业务迁移适配器

通用 HA 部署、新增节点、全实例备份和隔离恢复可独立使用。
下面两个适配器包含各自的停写、客户端切换及应用验收规则，不是任意数据库的通用迁移命令。

    bash ops.sh migrate-plan one_minihouse
    bash ops.sh migrate-apply one_minihouse
    bash ops.sh migrate-plan nexus
    bash ops.sh migrate-apply nexus

migrate-plan 包含逻辑备份和隔离恢复演练，会占用资源并保存私有报告，不切换业务入口。
migrate-apply 要求真实故障验收和恢复测试通过；缺少凭据、客户端配置或验收证据时直接失败。
oneMiniHouse 首批迁移，保留队列、角色、权限、RLS、Grafana UID 和查询。
稳定运行至少 24 小时后才允许迁移 Nexus，其数据库和 blob 必须一致备份。

PG18 接受业务写入前可以回退。切换到业务写入阶段之后，rollback 拒绝直接退回落后的旧库。
此时应修复或恢复 PG18，保留旧库和迁移备份。

详细参数与步骤见 scripts/data/README.md 和 ansible/README.md。

## 检查和部署包

    bash ops.sh check
    bash tests/integration.sh
    bash scripts/data/test-integration.sh
    bash ops.sh package

CI 配置为在 AMD64、ARM64 runner 上构建并运行隔离测试。隔离测试明确禁用 watchdog；
现场 watchdog、VRRP、真实应用和备份设备需单独验收，结果记录在忽略的 .local/ 目录。
原生空集群故障测试步骤及临时助手见 [原生验收流程](docs/native-acceptance.md)。
部署包只含 Git 已提交源码，输出到 .local/dist/，附 SHA256。

## 资源与故障边界

初始上限：PG＋Patroni 2 CPU／1.5 GiB，etcd 0.5 CPU／256 MiB，HAProxy 0.25 CPU／64 MiB。
这些是限制，常态占用及复制、备份、恢复峰值需现场测量。
严格同步会在无合格同步备库时等待写入；不会自动降级为异步。
watchdog 可能重启对应宿主机；无法提供保护时不允许上线。
共享交换机、路由和供电仍会影响整个集群，数据库复制也不能替代备份。
