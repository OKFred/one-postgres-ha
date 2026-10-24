# Ansible部署接口

使用仓库根目录的`ops.sh`调用。生产inventory始终显式指定；`ansible.cfg`的默认inventory仅供语法检查，使用RFC5737示例地址。

## 前置条件

- 每台Linux主机已安装Docker、Compose插件、Python3、OpenSSL、`iproute2`、`psmisc`、iptables及curl，管理账号可sudo。`preflight`和`deploy`不自动安装Docker。
- 首次准备Debian13 AMD64或ARM64宿主机，先显式运行`bash scripts/prepare-host.sh /实际SSD挂载点 --plan`，检查后使用`--apply`安装固定版本工具及配置Docker存储。该入口在目标宿主机执行并自动识别软件包架构。
- SSD已有文件系统、已挂载且有足够余量。宿主准备和Ansible部署均不格式化磁盘、不挂载猜测设备、不接管未知非空目录。
- 生产节点支持全AMD64（`x86_64`）或全ARM64（`aarch64`），核心节点及新增副本必须与`expected_architecture`一致。向导自动填写该值，旧inventory默认保留`aarch64`；不接受混合或未知架构，`deployment_environment: test`也不能绕过这些检查。
- 三个核心节点在同一直接相连网络，VIP已在地址池预留，设置`vip_reserved: true`；所有节点名与inventory hostname保持一致。
- 核心节点配置精确的`keepalived_package_version`，例如先用`apt-cache policy keepalived`核实版本。未知现有Keepalived配置会被拒绝覆盖。
- Watchdog是可用字符设备，无其他服务占用，systemd RuntimeWatchdog关闭。本轮只读检查不打开设备；实际整机重启保护必须现场验收。

部署将watchdog设备设为`watchdog_gid`组可读写（0660），并安装udev持久规则：既覆盖`watchdog`子系统的`watchdog0`等设备，也覆盖`misc`子系统的传统`/dev/watchdog`节点。两类节点在重新创建设备或重启后均保留权限；规则不匹配其他misc设备。

## 配置与私有输入

从`inventory.example.yml`复制到`.local/inventory.yml`。核心节点仅`core_nodes`三个；后续PG备库加入`replica_nodes`，同属`pg_nodes`。

每节点必填`node_name`、`node_ip`、`data_mount`、`data_root`、`network_interface`；全局配置`cluster_name`、VIP、`admin_cidrs`、`client_cidrs`。`data_root`必须在已挂载SSD内，不能通过符号链接逃逸。

`preflight`对所有PG节点（包括`add-node`新增备库）实际执行IPv4 `ip route get`，
检查到每个其他核心节点的出接口为`network_interface`、源地址为`node_ip`。
核心节点还必须直连，不能经过网关。双网卡位于同一子网时，需要持久固定路由优先级，
避免NetworkManager按激活顺序选择源地址；真实连接名称只放在私有记录。
NetworkManager的[`ipv4.route-metric`](https://networkmanager.dev/docs/api/latest/settings-ipv4.html)
同时作用于子网路由和默认路由；[`device reapply`](https://networkmanager.dev/docs/api/latest/nmcli.html)
尝试把保存的连接变更应用到当前接口。
例如选定eth0承载集群流量、eth1备用时，先保存现有连接配置，再逐台执行：

```bash
primary_profile=$(nmcli -g GENERAL.CONNECTION device show eth0)
secondary_profile=$(nmcli -g GENERAL.CONNECTION device show eth1)
nmcli connection modify "$primary_profile" ipv4.route-metric 100
nmcli connection modify "$secondary_profile" ipv4.route-metric 200
nmcli device reapply eth0
nmcli device reapply eth1
ip -j -4 route get 192.0.2.12
```

示例目标地址应替换为私有inventory中的其他核心节点IP；检查所有peer，
再运行`ops.sh preflight`。这些命令不关闭网卡；若`reapply`失败，停止并检查，
不要在远程会话中直接重启连接。重启后仍需重新验证源地址与接口。

控制端凭据与证书路径：

```text
.local/secrets/
  postgres-password
  replication-password
  rewind-password
  patroni-api-password
  ca.crt
  <node_name>/
    etcd.crt
    etcd.key
    patroni.crt
    patroni.key
```

部署密码、CA与当前输入不一致时拒绝隐式轮换。etcd证书需包含节点IP及127.0.0.1，带服务端和客户端用途；Patroni证书用于etcd客户端TLS。

节点上交付实际`docker-compose.yml`和`.env`，以及`config/`、`secrets/`、本项目防火墙服务。`.env`仅包含版本、节点、路径及profile；密码不嵌入配置或命令参数。数据库进程UID999，etcd UID65532，各自秘密文件0600。

## 命令与行为

| Playbook | 行为 |
|---|---|
| `preflight.yml` | 只读检查主机、SSD、身份、端口PID所属容器、watchdog及私有输入 |
| `plan.yml` | preflight之后展示部署意图 |
| `deploy.yml` | 准备配置、镜像、权限，按集群状态启动或逐节点更新 |
| `status.yml` | 读取Patroni与Compose状态，不输出容器环境或凭据 |
| `verify.yml` | 只读核对PG17、checksum、唯一主库、system identifier、同步复制、etcd及代理 |
| `add-node.yml` | 由`add_node`指定一个新备库，`add_node_plan=true`仅预览 |
| `switchover.yml` | 切换到当前健康同步备库；可用`ops_target`指定当前同步备库 |
| `cleanup.yml` | 审计整个 inventory 的 `pg_nodes`；确认后分阶段停止，按数据档位清理本项目资源 |

根目录 `install.sh` 串联凭据准备、计划、部署、状态和验收，共用控制端锁。
`uninstall.sh` 默认仅预览并保留数据；`--apply` 必须明确选择 `--keep-data` 或 `--purge-data`。
保留数据卸载输入 `UNINSTALL-ONE-POSTGRES-HA`；彻底清理输入 `DELETE-ONE-POSTGRES-HA`。
仅后者永久删除 PG/etcd 数据；两档均保留控制端私有配置、SSD 挂载和 Docker 存储。
具体范围与限制见 [清理与重装](../docs/reinstall.md)。

首次部署先启动三个etcd再等待仲裁，随后仅一个PGbootstrap，再建立两个副本。严格同步模式下，第一主库的角色就绪不能被当作写入验收；必须等同步副本可用。

已有部署不重置DCS或initdb。PG镜像、Compose或Patroni配置变化时先逐台更新备库并追平，再受控切换主库后更新旧主；无变化不主动切主。etcd更新一次一台且每步恢复仲裁。核心节点丢失仲裁且PG仍活动时拒绝部署。

新节点先`nofailover=true`、`nosync=true`克隆，核对身份并追平固定LSN，再验证并平滑reload全部现有HAProxy，最后解除标签。它不会新增etcd投票成员、VIP节点或代理。失败保留隔离标签及pending marker；普通deploy不能绕过pending marker，使用add-node续接。

防火墙只替换本项目专用chain，不清空Docker或宿主其他规则。数据库写入口5432对客户端网段开放；5433、Patroni和etcd只对节点/管理网段开放，etcd启用双向TLS。当前VIP只提供写入口，新增备库不会自动分摊写入或提供只读路由。

## 验收边界

`verify`通过仅证明它实际查询的集群状态。它不会生成HA故障演练、VIP切换、watchdog重启、独立存储恢复或业务回归的通过证据。上述现场验收与备份恢复必须另行完成，业务迁移命令由`data/`的独立门槛控制。

`backup_target.enabled: false`允许先部署空HA集群，并跳过备份主机和timer安装。它不允许绕过业务迁移的恢复验收：正式迁库前必须配置独立备份目标（PVE或另一台独立存储主机），完成实际恢复验证及现场验收。

生产维护期间仅允许一个控制端运行变更命令；`ops.sh`使用本地文件锁。不要从第二个控制端同时执行部署、加入、切换或迁移。
