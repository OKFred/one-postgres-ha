# 首次配置向导

在控制端项目目录执行：

```bash
bash ops.sh configure
bash install.sh
```

`configure` 只读检测三台节点并保存本地配置；`install.sh` 随后生成数据库密码、CA 和节点证书，
完成预检、部署和健康验证。Windows 使用 WSL。向导需要交互终端，inventory 固定为 `.local/inventory.yml`。

## 开始前

- 控制端具备 Bash、Docker 和 flock，能通过 SSH 访问三台节点。
- 三台节点使用相同架构的 Debian 派生 Linux 系统：全 ARM64 或全 AMD64；具备 Docker/Compose、Python 3、已挂载 SSD 和可独占 watchdog。
- 三台核心节点处于同一直接相连网络，共用相同的 SSD 挂载路径。
- SSD 必须本地可写、至少有 20 GiB 空闲，且不含旧 `one-postgres-ha` 数据目录。
- 在 DHCP 中预留 VIP，并确认地址未被其他设备占用。
- 准备三台共用的 SSH 登录密码，或可登录三台的私钥。非 root 账号须可免密码 sudo。

向导复用现有工具镜像，缺少时构建或拉取。它不安装目标主机工具、不格式化磁盘、不部署服务。
初始关闭独立备份；接入业务前仍须配置备份目标并通过恢复演练。

## 输入和确认

向导需要以下输入，并展示检测结果：

| 项目 | 处理方式 |
| --- | --- |
| 三台节点地址、VIP | 输入 IPv4 地址，检查格式和重复 |
| SSH 用户 | 默认 `root` |
| SSH 身份 | 默认输入共用密码并再次确认；设置 `HA_SSH_KEY` 时使用该私钥 |
| 主机指纹 | 展示采集结果，与各主机控制台核对后输入 `VERIFY` |
| 主机信息 | 只读检测系统、架构、地址与网卡、Keepalived 可用版本；用节点实际看到的 SSH 来源配置控制端管理权限 |
| SSD 路径 | 输入三台共用的已有挂载点；数据目录生成在该挂载点的 `one-postgres-ha` 下 |
| VIP 预留 | 确认已预留并无冲突后输入 `RESERVED` |
| 客户端网段 | 默认使用检测出的节点子网，可改为允许访问数据库入口的 CIDR |
| PostgreSQL 镜像 | 留空在节点构建；预构建镜像须填写完整 `@sha256:` 摘要 |
| 控制端工具镜像 | 使用默认值，或填写预构建工具镜像的完整摘要 |
| 保存 | 检查配置摘要后输入 `SAVE` |

密码不会显示，也不会出现在配置摘要中。SSH 主机指纹来自网络采集，仍需独立核对。
向导分别读取三台节点的实际架构，自动写入 `expected_architecture: aarch64`（ARM64）
或 `expected_architecture: x86_64`（AMD64），无需手动选择。三台架构混用、未知架构或发现不完整时，
停止配置且不保存可部署的 inventory。生产预检会再次核对所有 PG 节点，包括以后新增的副本；
手动 inventory 未指定时仍默认 ARM64，AMD64 须在 `all.vars` 明确设置 `expected_architecture: x86_64`，
让独立备份主机也能读取目标集群架构。
两种架构共用相同的 SSD、网络、watchdog 和同步复制要求；虚拟机也必须具备可用且独占的 watchdog，不能跳过检查。

通过主机控制台或已有可信管理连接，在三台机器分别执行：

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

将每台的 SHA256 指纹与向导展示结果逐一比较。指纹不一致时停止，先确认地址和主机身份。
`RESERVED` 记录你的确认；向导不会修改路由器 DHCP 或证明地址没有冲突。

## 使用私钥

先指定控制端的私钥路径，再运行向导：

```bash
export HA_SSH_KEY=/安全目录/cluster_ed25519
bash ops.sh configure
```

私钥由工具容器只读挂载，实际内容不复制到 inventory。使用需交互解锁的私钥时，
应先准备适用于该部署入口的 SSH 身份；向导不收集私钥口令。

## 保存的文件

```text
.local/
  inventory.yml           # 节点、网络、SSD、镜像和 SSH 身份引用
  known_hosts             # 经你核对的三台主机公钥
  controller.env          # 控制端镜像与 SSH 私钥路径（如使用）
  secrets/
    ssh-password          # 仅在密码登录模式生成，权限 0600
```

真实配置都放在 Git 忽略的 `.local/` 中；不要提交、公开分享或放入镜像构建上下文。
`configure` 不生成数据库密码和 CA，安装入口会生成缺少的凭据并保留已有值。
`ops.sh` 自动读取 `controller.env` 中的镜像及私钥路径，无需每次手动 export 或 source。
当前终端显式设置的 `HA_TOOLS_IMAGE`、`HA_SSH_KEY` 优先于保存值。

## 预构建镜像与私有仓库

镜像输入使用自己的 Registry 和发布摘要，例如：

```text
registry.example.com/your-namespace/one-postgres-ha@sha256:<64位digest>
registry.example.com/your-namespace/one-postgres-ha-tools@sha256:<64位digest>
```

只写 tag 会被拒绝。私有镜像需要提前在控制端和各节点的 Docker 上登录对应 Registry。
密码通过交互输入或 `--password-stdin` 提供；向导不收集、复制或分发 Registry 密码。
详细发布与安装方式见 [镜像发布与拉取部署](images.md)。

## 已有配置、重装与手动编辑

向导拒绝覆盖已有 `inventory.yml`、`known_hosts`、`controller.env` 或非空的 `secrets/`。
日常调整和新增节点时直接修改私有 inventory，并使用现有维护命令。

清理节点后仍保留 `.local/` 时，直接运行 `bash install.sh`，沿用原凭据即可。
只有控制端私有配置和各节点 PG/etcd 数据都已清空，才使用向导从零配置。
旧 PG/etcd 数据仍在时，必须恢复匹配的旧 CA 和密码，不能新建凭据接管。
清理范围见 [清理与重装](reinstall.md)。

不同 SSD 路径、不同 SSH 身份、其他系统、备份服务器或其他高级设置，使用手动配置并验收：
复制 `ansible/inventory.example.yml` 到 `.local/inventory.yml`，填写现场信息，
提供 SSH 身份并保存核实过的 `.local/known_hosts`。字段和限制见 [Ansible 部署接口](../ansible/README.md)。
