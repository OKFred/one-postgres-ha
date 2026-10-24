# PG17 与数据迁移

## 当前版本

新安装固定 PostgreSQL 17.11＋Patroni 4.1.5。基础镜像使用官方
`postgres:17.11-bookworm@sha256:858bb5e98eed02eb8cafbcdc007f9a65d1b613972028944a8ec2133ccaf80d27`，
索引包含 Linux AMD64 和 ARM64；镜像摘要同时记录在 `versions.lock` 和 `config/versions.env`。
安装向导仍选择源码构建或符合本项目契约的预构建镜像，不接受任意大版本切换。

本分支尚未发布新的 PG17 应用及工具镜像。首次配置时 `PostgreSQL image` 留空，
由节点构建 PG＋Patroni 镜像。发布自己的预构建镜像后再填写该镜像的完整 digest。
普通官方 `postgres:17` 镜像只有数据库，不包含本项目的 Patroni、文件凭据入口和辅助脚本。

## 更新控制端工具

工具镜像也包含 PostgreSQL 客户端。本版本的本地标签为 `one-postgres-ha-tools:pg17.11`，
用于避免沿用旧 PG18 工具缓存。若旧 `.local/controller.env` 或 `HA_TOOLS_IMAGE` 环境变量
显式指定了旧的 PG18 工具摘要／标签，需要先自行改为本版本工具镜像或新发布的 PG17 工具 digest；
脚本不会自动覆盖私有配置。然后在控制端项目目录构建工具镜像：

```bash
bash ops.sh tools
```

同样，旧 inventory 中的 PG18 `postgres_ha_image` 必须先审查，不能用于新的 PG17 部署。
首次配置向导不会覆盖已有 inventory。

## 已有 PG18 数据

当前版本不提供原地降级。预检、启动、数据审计和保留数据重装都要求 PG17；发现 PG18 数据会停止，
不会把旧目录改写成 PG17，也不会清除 DCS 后冒充新集群。

需要从旧 PG18 实例重新开始时，先保留旧源码、配置和有效备份。旧 PG18 的卸载应使用
对应旧版本的入口及原私有配置，先预览再明确选择数据档位。不要在生产控制目录直接切换版本后运行安装，
也不要只改 `.env` 中的镜像标签。

若旧实例仍有数据要保留，应另建独立 PG17 测试集群，评估逻辑导出／恢复；PG18 到 PG17 的跨大版本
逆向恢复不由本项目保证。现有数据工具仅提供已覆盖的 PG17 业务适配器，不能用于自动降级旧 PG18。

## 为将来离开 Supabase 做准备

Supabase 与本地 PostgreSQL 不必使用完全相同的小版本。先核对实际源库版本，并在源库运行以下只读 SQL：

```sql
SHOW server_version;
SHOW server_version_num;
SELECT extname, extversion FROM pg_extension ORDER BY extname;
```

使用 PG17 作为共同基线可减少版本差异，但迁移是否成功还取决于：

- 扩展及其版本：本项目的普通 PostgreSQL 镜像不自动包含 Supabase 的全部扩展。
- 角色、owner、权限、RLS、函数、触发器和序列：需要在独立目标库恢复并逐项验证。
- 应用依赖：Auth、REST API、Realtime、Storage、Edge Functions 需要另行替代或部署；
  只把数据库导入本地 PG 集群不会生成这些服务，Storage 文件也需要单独迁移。

本项目不读取 Supabase 项目配置，不安装 Supabase 服务，也不保存云项目地址或密钥。
现有 `migrate-plan`／`migrate-apply` 是指定业务的适配器，不是通用 Supabase 导出器。
实际迁移前应单独确定需要保留的业务 schema、云平台内部 schema 的处理方式、停写窗口和验收步骤。

官方参考：

- [PostgreSQL pg_dump 版本兼容说明](https://www.postgresql.org/docs/17/app-pgdump.html)
- [PostgreSQL 版本维护策略](https://www.postgresql.org/support/versioning/)
- [Supabase 备份与恢复](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)
- [Supabase 迁移到自托管实例](https://supabase.com/docs/guides/self-hosting/restore-from-platform)
