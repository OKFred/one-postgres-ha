# 下载源与自动测速

下载源可在中英双语菜单的 `09. Download sources -- 下载源与测速` 中选择，
也可在控制端项目目录直接运行 `bash ops.sh sources`。不需要先构建工具镜像。

## 自动或手动选择

```bash
bash ops.sh sources auto       # 重新测速并保存最快的可用来源
bash ops.sh sources official   # 手动使用官方源，不测速
bash ops.sh sources ustc       # 手动使用中科大，不测速
bash ops.sh sources tuna       # 手动使用清华，不测速
bash ops.sh sources --show     # 只查看保存的来源；没有配置时显示 official
```

不带参数时显示交互选项，直接回车退出。源选择不安装软件，也不部署或重启集群。

自动模式使用 curl 请求各来源的小型 HTTPS 元数据。DNS、TCP 连接、TLS、HTTP 状态和响应内容
都通过后才计入耗时。每轮请求 Debian、安全更新、PyPI 和 Docker CE 四类元数据，
进行三轮，至少两轮完整成功后比较总耗时的中位数；成功轮数不足的候选不参与选择。
全部候选失败时会报错，不写入一个未经验证的选择，也不把失败当作零延迟。

ICMP 可能被镜像站、CDN 或网络设备限制，因此不按 ping 时长决定来源。
HTTPS 小请求主要反映当前控制端的连通性与请求耗时，不能代替大包吞吐测试，
也不保证每台节点都具有相同的最优网络路径。可以随时手动指定或重新测速。

`official` 保留基础镜像原有的 APT 配置；当前固定镜像使用 HTTP Debian 源，
并附带 PostgreSQL APT 仓库（PGDG）。自动探测使用 HTTPS，且不探测 PGDG，
因此探测通过不代表这些构建下载路径也一定可用。构建若因网络失败会停止，
可显式选择国内源后重试；项目不会静默回退。

## 保存与首次构建

选择以一个名称保存在 `.local/download-source` 中，文件权限为 `0600`。
它按数据解析，不作为 shell 脚本执行；不接受任意 URL、命令、额外配置行或符号链接。
示例见 [config/download-source.example](../config/download-source.example)。真实选择和测速记录留在 Git 忽略的 `.local/`。

后续操作复用已保存选择，不重复探测。只有显式运行 `sources auto` 才重新测速；
手动选择也会保存。读取到损坏或不安全的缓存时停止并提示，不静默执行其中内容。

工具镜像在配置向导显示前就可能需要构建，因此也支持提前指定：

```bash
HA_DOWNLOAD_SOURCE=auto bash ops.sh configure
HA_DOWNLOAD_SOURCE=ustc bash ops.sh tools
```

显式 `HA_DOWNLOAD_SOURCE=official|ustc|tuna` 仅覆盖本次操作，不改写保存值。
`auto` 复用有效的已保存选择，缺少时才测速。首次交互配置或工具构建没有选择时可自动检测；
已有 inventory 或非交互执行且没有源配置时继续使用官方源，兼容旧部署和 CI。
切换来源影响后续构建；已有镜像不会因此自动重建，运行中的服务也不会因此重启。

## 覆盖范围

| 下载内容 | 官方来源 | 国内来源 |
| --- | --- | --- |
| 工具与 PostgreSQL 镜像内的 Debian 包 | Debian | 中科大或清华的 Debian、安全更新镜像 |
| Python 依赖 | PyPI | 中科大或清华 PyPI |
| 显式首次准备宿主时的 Docker CE 安装包 | Docker 官方仓库 | 中科大或清华 Docker CE |

Docker 与 PostgreSQL 版本、基础镜像 digest、PG 依赖锁文件和哈希校验保持不变。
APT 继续校验 Debian 或 Docker 的签名，pip 使用单个已选择的索引。
连接失败时停止，不自动切换到未经本轮选择的来源或关闭 TLS 校验。

使用国内源且基础镜像缺少 CA 证书时，容器构建先通过 Debian 签名验证取得 CA 包，
再使用 HTTPS 安装其余依赖。此准备限于镜像构建，不更改宿主机的证书信任或软件源。
目标主机的全局 Debian APT 源由使用者管理，Keepalived 安装仍沿用目标主机已有源。
已有 Docker 安装也不会因为更换项目下载源而被迁移或重装。

容器镜像本身通过 Registry 拉取。Docker Hub、Quay，以及 GitHub 上的 Ansible collection、
Compose CLI 等资源有各自的下载路径，不受 Debian／PyPI 换源覆盖。
可使用自己的 Registry 发布预构建工具和 PostgreSQL 镜像，并按 digest 固定，
减少部署现场的构建和外部下载。步骤见 [镜像发布与拉取部署](images.md)。

## 镜像站说明

- [中科大 Debian](https://mirrors.ustc.edu.cn/help/debian.html)
- [中科大 Docker CE](https://mirrors.ustc.edu.cn/help/docker-ce.html)
- [清华 PyPI](https://mirrors.tuna.tsinghua.edu.cn/help/pypi/)
- [中科大容器镜像缓存状态](https://mirrors.ustc.edu.cn/help/dockerhub.html)

Docker CE 镜像提供安装软件包。容器镜像的获取需另行配置 Registry；
中科大的公共 Docker Hub／Quay 缓存已关闭，项目不会自动写入该失效加速地址。
