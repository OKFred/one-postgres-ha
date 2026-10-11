# Docker Hub 预构建镜像

下面两个公开镜像均支持 `linux/amd64` 和 `linux/arm64`，可以直接拉取部署。
发布日期：2026-10-12；镜像源码提交：`890b8514dce23082a2e2dc36384486b9e9b6ca8d`。

| 用途 | Docker Hub 仓库 | 版本标签 |
| --- | --- | --- |
| PostgreSQL 18.6＋Patroni 4.1.5 | [hifred/one-postgres-ha](https://hub.docker.com/r/hifred/one-postgres-ha) | `pg18.6-patroni4.1.5-890b8514dce2` |
| 控制端部署工具，Ansible Core 2.19.14 | [hifred/one-postgres-ha-tools](https://hub.docker.com/r/hifred/one-postgres-ha-tools) | `pg18.6-890b8514dce2` |

## 固定镜像地址

配置时使用以下完整摘要地址。摘要指向包含两种架构的镜像索引，Docker 会选择本机架构。

### PostgreSQL image

```text
docker.io/hifred/one-postgres-ha@sha256:0419a8cc40352bbc17d42598b7365864c93f418221bc37a83c1f8aa7128c0240
```

### Tools image

```text
docker.io/hifred/one-postgres-ha-tools@sha256:65f703e13acc45d7807bdf3d6c5aacf790ac324e3eec8b4b934d632c48ae56ea
```

## 首次配置与安装

首次配置前，在控制端的项目目录执行：

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

## 验证与更新

- 两种架构构建、远端平台与摘要核对、版本和工具自检均通过。
- ARM64 运行自检使用 Docker Desktop 模拟环境；原生硬件集群验收单独进行。
- 构建仅使用已提交的镜像源码，未包含 `.local`、现场配置、数据库数据或凭据。

这些镜像固定对应上述源码版本。后续修改镜像代码或依赖时，重新发布镜像，并更新本文件的版本标签和摘要。
