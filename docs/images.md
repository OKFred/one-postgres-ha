# 镜像发布与拉取部署

本项目继续使用三台独立 Docker Compose 节点，不需要 Docker Swarm。
`install.sh` 通过工具容器运行 Ansible，负责跨节点准备、启动顺序和验收。
单独 `docker compose up -d` 用于已经准备好的节点，不能替代宿主防火墙、watchdog 和 Keepalived 的首次配置。

## 发布两个自建镜像

发布机器需要 Bash、Git、Docker Buildx、tar、flock，以及能够构建 AMD64 和 ARM64 的 builder。
在 Linux 或 Windows WSL 中运行，先用 Docker 登录目标 Registry。交互输入密码或通过
`--password-stdin` 从独立凭据文件输入，不要把密码放在命令参数、源码或镜像构建参数中。

```bash
docker login YOUR_REGISTRY
bash scripts/publish-images.sh YOUR_REGISTRY/YOUR_NAMESPACE
bash scripts/publish-images.sh YOUR_REGISTRY/YOUR_NAMESPACE --push
```

需要指定已有 builder 时加 `--builder NAME`。脚本不创建云端仓库；目标命名空间和仓库必须已准备好。
两个仓库名分别为 `one-postgres-ha` 和 `one-postgres-ha-tools`。

默认只展示计划。`--push` 从 **Git 已提交 HEAD** 提取镜像源码，发布
`linux/amd64,linux/arm64` 镜像索引；未提交修改及 `.local/`、`.git` 不会进入构建上下文。
修改 Dockerfile 或依赖后，应先提交再发布。

标签格式为 `pg<PG版本>-patroni<Patroni版本>-<提交前12字符>` 和
`pg<PG版本>-<提交前12字符>`。已有目标标签直接停止，不覆盖 `latest` 或复用标签。
认证、网络或服务端查询错误也会停止，避免把查询失败误当成仓库为空。
两个镜像不是原子发布：第二个失败时，第一个可能已经上传，需要检查保留的报告。

构建关闭额外 provenance/SBOM 对象，镜像注明源码提交。索引 digest 与部署片段保存到
忽略的 `.local/publish/`，不包含登录密码。Registry 能否接收多架构索引，以及两种架构的拉取运行，
需要分别做真实验收；云端构建能力与接收本地构建镜像是不同功能。

## 使用发布镜像安装

将发布输出的摘要填入私有 `.local/inventory.yml`，保留全部现有节点、网络、SSD 和凭据配置：

```yaml
all:
  vars:
    postgres_image_mode: prebuilt
    postgres_ha_image: YOUR_REGISTRY/YOUR_NAMESPACE/one-postgres-ha@sha256:YOUR_INDEX_DIGEST
```

工具镜像通过环境变量指定，使用输出中的完整摘要：

```bash
export HA_TOOLS_IMAGE=YOUR_REGISTRY/YOUR_NAMESPACE/one-postgres-ha-tools@sha256:YOUR_INDEX_DIGEST
bash install.sh --plan
bash install.sh
```

控制端及每个目标节点必须先完成私有 Registry 的 Docker 登录。安装脚本不会自动分发 Registry 密码。
工具镜像缺失时拉取；PG 在 `prebuilt` 模式下只拉取指定摘要，不在节点编译。
默认 `postgres_image_mode: source` 保留原有本地构建流程；etcd 和 HAProxy 继续使用固定上游摘要。

这些命令部署或更新集群，不清空已有数据库。确实要得到空集群时，按
[清理与重装](reinstall.md) 先预览并确认执行清理。
