# 备份、恢复演练与单库迁移

这些操作由 `ansible/data/main.yml` 调度，Bash 在独立 `backup_server` 上运行。SQL 密码、角色哈希、备份、恢复状态和验收输出均属于私有数据。脚本不执行用户配置的任意 shell hook。

## 公共配置

私有 inventory 需要一个独立于 PG 节点的备份主机，已安装 Docker、可以访问数据库 VIP 和旧数据库。该主机目录应位于独立持久化存储，而不是 PG 节点上的同一块盘：

```yaml
backup_target:
  enabled: true
  host: backup-01
  path: /srv/postgres-backups/one-postgres-ha
```

`backup_server` 组恰好一个主机，名称等于 `backup_target.host`。部署只安装 timer；第一次仍须手动执行备份和恢复验收：

如暂未准备独立备份目标，可以保持 `backup_target.enabled: false`，先建设空 HA 集群；不会访问占位备份主机或安装 timer。备份、恢复及业务迁移命令会明确拒绝继续。

```bash
bash ops.sh backup
bash ops.sh restore-test
```

每日 02:00 备份，周日 03:00 隔离恢复，采用备份主机时区。保留最新 14 个完整备份。锁文件同时保护定时任务与手动任务；冲突会失败退出。查看调度结果：

```bash
systemctl status one-postgres-ha-backup.timer one-postgres-ha-restore-test.timer
journalctl -u one-postgres-ha-backup.service -u one-postgres-ha-restore-test.service
```

### 备份目录归属

新路径必须为空。脚本建立 `.one-postgres-ha-data.json`，绑定 `cluster_name`，首次备份再绑定
PostgreSQL `system_identifier`。保留策略只删除归属当前集群和实例的完整备份；外来、不完整或异常目录不自动删除。
即使集群名相同，重建后的新 PG 实例也必须使用新的专用备份路径。

旧版本已有非空备份目录但没有归属标记时，先暂停备份和恢复 timer，保留旧目录原样。
将 `backup_target.path` 改为全新空路径，重新执行 `backup`、`restore-test` 验收，再恢复 timer。
旧备份按原 manifest 和 `SHA256SUMS` 人工核对恢复；不要删除或手写标记来接管共享目录。

全实例备份和隔离恢复是通用功能。下面的迁移部分是 oneMiniHouse、Nexus 专用适配器；
其他业务需要自己实现并验收客户端切换流程。

备份使用固定 PG17 客户端、各库导出的 MVCC snapshot，同时生成结构、数据行校验、ACL、RLS、视图选项、函数、索引、默认权限和序列检查。全实例备份保存全体角色；单库迁移仅导出该库依赖的角色与成员关系闭包。备份期间不要修改角色或执行数据库 DDL；角色变化会使本次备份失败。序列不受 MVCC snapshot 约束：在线备份/演练逐个核对归档中的 `SEQUENCE SET` 与恢复后的实际值，同时核对序列参数；最终冻结迁移再严格比较源库序列值。自定义 tablespace 需要独立存储映射，首版检测到后拒绝继续。

本版本要求实际导出客户端、源库和目标库的大版本为 17，不要求小版本完全相同。
恢复前检查每份归档的数据库版本和导出工具版本；PG18 归档和大版本降级不支持。
全实例备份的 `restore-test` 使用受保护目录身份核对最近完整备份，无需生产库在线；
隔离恢复容器自身仍需通过 PG17 版本检查。迁移演练继续绑定在线目标身份。
这些是本项目业务适配器，不是通用 Supabase 迁移器。

隔离恢复不发布端口、禁用容器网络，逐库恢复并对比校验；完成后移除容器与匿名数据卷。恢复报告绑定 `SHA256SUMS`、集群名、system identifier 和时间。未完成目录不会参与自动保留策略，不会被误认作可恢复备份。完整实例备份包含密码哈希，目录权限为 0700。

## oneMiniHouse 私有配置

下列地址均为示例。路径在工具容器中使用 `/workspace/.local/...`，不要填写 Windows 路径。旧数据库管理凭据仅用于迁移；应用密码继续原样沿用。

```yaml
migration_databases:
  one_minihouse:
    source:
      host: 192.0.2.206
      port: 5432
      database: one_minihouse
      user: postgres
      password_file: /workspace/.local/secrets/pg17-password
      sslmode: prefer
    required_roles: [iot_writer, grafana_reader]
    acceptance_file: /workspace/.local/evidence/native-fault-acceptance.json
    client_host: app-01   # 必须是 inventory 中的主机
    endpoint_old_host: 192.0.2.206
    ingestor_config: /opt/ingestor/config/ingestor.json
    ingestor_compose_dir: /opt/ingestor
    ingestor_service: ingestor
    ingestor_queue_file: /srv/ingestor/inbox.sqlite
    ingestor_health_file: /srv/ingestor/health.json
    grafana_url: https://grafana.example.com
    grafana_uid: existing-postgresql-uid
    grafana_token_file: /workspace/.local/secrets/grafana-token
    public_dashboard_url: https://grafana.example.com/public-dashboards/EXAMPLE
    readonly:
      user: grafana_reader
      password_file: /workspace/.local/secrets/grafana-reader-password
      sql_file: /workspace/.local/acceptance/grafana-regression.sql
```

实际配置必须保留当前线上 Grafana UID。`readonly.sql_file` 包含现有面板使用的查询，应覆盖已部署的全部指标类别，使用真实只读账号执行；查询输出写入私有恢复集。页面可访问与数据源健康检查不能替代图表内容、公开页面和空值显示的人工/浏览器验收。

业务账号必须非 superuser、非 replication、非 CREATEROLE，并明确列入 `required_roles`。旧库与新库同名，源实例的 bootstrap 管理员必须为默认的 `postgres`，以保留 `GRANTED BY` 语义。示例中应用连接端口为 5432；客户端适配器只修改 host，若线上端口、JDBC 格式或 JSON 结构不同，则拒绝修改并要求先核对。

原生故障验收记录必须来自当前集群的真实测试，最多有效 24 小时；`verify` 的常态健康报告不能冒充这份记录：

```json
{
  "cluster_name": "one-postgres-ha",
  "system_identifier": "REPLACE_WITH_ACTUAL_IDENTIFIER",
  "completed_at": "REPLACE_WITH_ACTUAL_UTC_TIME",
  "arm64_native": true,
  "primary_failure": true,
  "proxy_failure": true,
  "etcd_failure": true,
  "network_isolation": true,
  "watchdog": true,
  "confirmed_transactions": true,
  "primary_lsn": "REPLACE_WITH_CONFIRMED_TRANSACTION_LSN",
  "replay_lsn": "REPLACE_WITH_REPLAYED_LSN"
}
```

同时验证 replay LSN 不落后于被确认的事务 LSN；迁移当时须有 streaming 同步备库。SQL 文件、凭据和现场证据缺失、过期或校验失败时均停止。

```bash
bash ops.sh migrate-plan one_minihouse
bash ops.sh migrate-apply one_minihouse
```

`migrate-plan` 进行真实导出和隔离恢复演练，写入备份文件，但不修改生产数据库或客户端；它也需要运维锁。`migrate-apply` 要求 24 小时内完成的、checksum 仍匹配的该库演练，以及集群原生故障验收。

执行时先用 SQLite 在线 backup API 保存含 WAL 最新提交的队列；ingestor 持续采集。只对所选旧库设置 `CONNECTION LIMIT 0` 并终止该库连接，其他旧库继续工作。冻结后完成最终导出、隔离恢复、HA 恢复与同步备库 replay 检查。整个暂停期间旧库不接受普通业务连接，避免已标记 done 的数据掉在 dump 快照之外。

切换之前先持久化 `write-started`，再解除新库 connection limit、修改 ingestor local target host 和 Grafana 原 UID 的 url；重建一次 ingestor 容器以刷新文件挂载。队列文件和 MQTT 配置保留。等待暂停期间积压完成、出现真实新投递、永久失败不增加，再执行只读查询回归。旧库继续冻结，不自动删除。

## Nexus 后续迁移

先完成 oneMiniHouse 迁移并运行至少 24 小时。补充稳定观察报告，包含当前集群身份、`database: one_minihouse`、`observation_hours >= 24`、`pending_drained: true`、`permanent_failures_increased: false`、`grafana_readonly: true`、`public_dashboard: true` 和真实 `completed_at`；报告不能超过 24 小时。

Nexus 配置保留上面同样的 `source`、`required_roles`、`acceptance_file`、`client_host` 和 `readonly`，再增加：

```yaml
    stable_minihouse_file: /workspace/.local/evidence/minihouse-24h.json
    endpoint_old_host: nexus-postgres
    nexus_compose_dir: /opt/nexus
    nexus_service: nexus
    old_postgres_service: postgres
    blob_directory: /srv/nexus/blobs
    jdbc_properties_file: /srv/nexus/etc/fabric/nexus-store.properties
    jdbc_property_key: jdbcUrl
    health_url: https://nexus.example.com/service/rest/v1/status
    blob_ssh_user: backup-transfer
    blob_ssh_identity_file: /root/.ssh/nexus-backup  # 此路径在备份主机
    registry:
      host: registry.example.com
      user: migration-check
      password_file: /workspace/.local/secrets/nexus-migration-password
      base_image: docker.io/library/busybox@sha256:REPLACE_WITH_VERIFIED_DIGEST
      namespace: ha-migration-acceptance
```

备份主机提前配置只用于获取 blob 快照的 SSH 身份和 `known_hosts`；脚本不自动放宽主机身份验证。该身份应只允许读取快照目录。`source.host/port` 是 SQL 管理连接；`endpoint_old_host` 是现有 JDBC URL 内的主机，两者可能不同。

```bash
bash ops.sh migrate-plan nexus
bash ops.sh migrate-apply nexus
```

停止 Nexus 后冻结旧库，取得数据库和 blob 的一致恢复集，并把 blob 归档复制到独立备份主机。更改 JDBC host，保留端口、数据库名、查询参数及其他 properties。启动后执行专用 namespace 的真实 Docker 登录、全新镜像构建、推送、移除本地 tag、拉取并核对 image ID/manifest digest。验收标签保留作为证据，不自动删除远端镜像。全部数据库与推拉验收完成后，才停止旧的专用 PG 容器；不删除其数据或改变 Nexus 版本与 blob 布局。

## 失败与恢复

恢复状态在备份主机 `backup_target.path/state/<database>.json`；dump 与指纹保存在 `migrations/`。连接信息与密码不会写入 Git。出错时保持当前业务冻结/停写状态，先读取状态，不要重复导入或直接把地址改回旧库。

- `freezing`、`frozen`、`restored`：`bash ops.sh rollback <database>` 可恢复旧库原 connection limit；Nexus 重启使用尚未改变的旧 JDBC 配置。目标库保留，下一次导入前需明确处理该库，脚本不会自动覆盖。
- `write-started`、`migrated`：新库可能已接受业务写入，拒绝返回旧库。优先修复 HA/客户端配置，或在维护窗口恢复 PG17 备份并校验。
- 全量恢复脚本默认只做隔离演练，绝不将整个实例自动覆盖到当前生产集群。

如中断发生在客户端切换阶段，`write-started` 标记会保守地阻止旧库回退，即使当时尚未产生实际写入。需要检查备份、服务配置副本及数据库状态后修复目标集群；自动流程不会猜测。

## 本地回归

在具有 Linux Docker、Bash、jq、flock、openssl、sqlite3 的开发环境执行：

```bash
bash scripts/data/test-integration.sh
bash scripts/data/test-client.sh
```

第一项只创建隔离测试容器，验证 PG17→18 角色/密码/成员关系、ACL/RLS/序列、冻结与其它库不受影响、逻辑备份及危险回退拒绝。结果保存在忽略的 `.local/data-tests/`。第二项验证客户端只改 host、保留其他配置，以及未 checkpoint 的 SQLite WAL 已提交记录能够进入在线备份。两者均不连接 inventory 中的现场服务器；Docker/Ansible、ARM64 原生和真实应用验收分别记录。
