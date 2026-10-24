# 预构建镜像与旧版记录

## 当前 PG17 基线

当前源码固定 PostgreSQL 17.11＋Patroni 4.1.5，尚未记录本版本的公开预构建镜像。
首次配置时 `PostgreSQL image` 留空，在节点从固定基础镜像构建；工具镜像使用
`one-postgres-ha-tools:pg17.11`。本项目普通官方 `postgres` 基础镜像不能直接替代 PG＋Patroni 应用镜像。

发布方法见 [镜像发布与拉取部署](docs/images.md)。发布后填写实际生成的多架构索引 digest，
不要把下面的 PG18 摘要改标签后当成 PG17 镜像。

## 历史 PG18 镜像

下面两个旧镜像支持 `linux/amd64` 和 `linux/arm64`，只供对应旧源码和既有集群追溯，
不能用于当前 PG17 安装，也不能作为 PG17 的备份／恢复工具镜像。
发布日期：2026-10-12；镜像源码提交：`890b8514dce23082a2e2dc36384486b9e9b6ca8d`。

| 用途 | Docker Hub 仓库 | 版本标签 |
| --- | --- | --- |
| PostgreSQL 18.6＋Patroni 4.1.5 | [hifred/one-postgres-ha](https://hub.docker.com/r/hifred/one-postgres-ha) | `pg18.6-patroni4.1.5-890b8514dce2` |
| 控制端部署工具，Ansible Core 2.19.14 | [hifred/one-postgres-ha-tools](https://hub.docker.com/r/hifred/one-postgres-ha-tools) | `pg18.6-890b8514dce2` |

### 旧版固定镜像地址

以下摘要指向旧版镜像索引，Docker 会选择本机架构。

#### 旧版 PostgreSQL image

```text
docker.io/hifred/one-postgres-ha@sha256:0419a8cc40352bbc17d42598b7365864c93f418221bc37a83c1f8aa7128c0240
```

#### 旧版 Tools image

```text
docker.io/hifred/one-postgres-ha-tools@sha256:65f703e13acc45d7807bdf3d6c5aacf790ac324e3eec8b4b934d632c48ae56ea
```

### 旧版首次配置与安装记录

以下命令仅适用于上述旧源码；PG17 新安装按本文件开头和 README 操作。
旧版首次配置前，在控制端的项目目录执行：

```bash
export HA_TOOLS_IMAGE='docker.io/hifred/one-postgres-ha-tools@sha256:65f703e13acc45d7807bdf3d6c5aacf790ac324e3eec8b4b934d632c48ae56ea'
bash ops.sh configure
```

向导中：

- `PostgreSQL image`：粘贴上面的 PostgreSQL 完整摘要地址。
- `Tools image`：保留通过环境变量传入的工具镜像摘要默认值。

保存后执行：

```bash
bash install.sh --plan
bash install.sh
```

工具镜像地址会保存到私有配置 `.local/controller.env`，后续命令自动读取。
已有配置的修改方式见 [镜像发布与拉取部署](docs/images.md)。

### 历史验证与更新

- 两种架构构建、远端平台与摘要核对、版本和工具自检均通过。
- ARM64 运行自检使用 Docker Desktop 模拟环境；原生硬件集群验收单独进行。
- 构建仅使用已提交的镜像源码，未包含 `.local`、现场配置、数据库数据或凭据。

这些镜像固定对应上述源码版本。后续修改镜像代码或依赖时，重新发布镜像，并更新本文件的版本标签和摘要。
