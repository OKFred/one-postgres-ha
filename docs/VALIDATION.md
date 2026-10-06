# 已执行的验证

记录日期：2026-10-06。源码检查与隔离实验在 Windows Docker Desktop 上执行。

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Bash 语法、ShellCheck、YAML、Ansible production lint、入口语法 | 通过 | 源码及配置 |
| 参数检查、操作锁、SIGTERM 收尾、停止状态不确定时拒绝下一次变更 | 通过 | CLI 测试 |
| 密码与证书重复生成保持原值、损坏凭据拒绝 | 通过 | 临时测试凭据 |
| PostgreSQL 18.6 / Patroni 4.1.5 构建 | 通过 | AMD64、ARM64 QEMU |
| 三 etcd 双向 TLS、三 PG 严格同步、只读角色 | 通过 | AMD64、ARM64 QEMU |
| 全部备库离线后提交等待、恢复后提交完成 | 通过 | 隔离实验 |
| 受控切主、主库 SIGKILL、旧主回归、一个 etcd 停机 | 通过 | 已确认实验事务保留 |
| 第四节点克隆、隔离标签、代理更新、成为同步备库并切主 | 通过 | 隔离实验 |
| 日志测试凭据检查、容器 OOM 检查 | 通过 | 实验负载及所设资源上限 |
| 三核心节点与新增 PG 节点的实际 Ansible 模板渲染 | 通过 | 配置解析和脚本语法 |
| PG17.11→PG18.6 的角色、密码、ACL、RLS、序列及 grantor | 通过 | AMD64 隔离恢复预演 |
| 单库冻结时其他库可写、全实例备份恢复、写入后回退保护 | 通过 | AMD64 实际 SQL 与数据命令 |
| 客户端仅修改目标地址、SQLite WAL 在线备份 | 通过 | 本地客户端测试 |

实验记录保存在忽略的 `.local/integration/`。可用 `bash tests/integration.sh` 重跑。

## 本轮开源准备回归

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| 防火墙旧配置升级、重复部署、未知文件拒绝、加载依赖校验 | 通过 | Ansible 临时目录与 systemctl fixture；只读工具容器 |
| 防火墙失败阻止入口服务启动、reload 保持依赖服务运行、清理后可重启 | 通过 | WSL Debian 的真实 systemd，使用独立临时服务；未操作 Docker 或 Keepalived |
| 备份目录归属、实例身份绑定、保留 14 份完整备份及外来备份保护 | 通过 | 临时目录与命令 fixture |
| PG17→PG18、全实例备份与隔离恢复、写入后回退保护 | 通过 | 当前数据脚本，Docker Desktop Linux AMD64 的真实 PostgreSQL |
| 清理、重装、其他容器/卷保留、重复启动 | 通过 | 真实 Docker/Compose；宿主 systemd、防火墙、SSD、watchdog 为 fixture |
| 源码扫描及独立导出历史/邮箱/私有文件隔离 | 通过 | 临时 Git 仓库；含强制跟踪缓存文件和带制表符私有路径 |

本轮记录保存在忽略的 `.local/reports/`，不随公开源码分发。
这些回归不替代下列现场验收。

## 资源记录的含义

AMD64 空库实验的单次快照：PG＋Patroni 每节点约 30–77 MiB，etcd 约 24–35 MiB，
HAProxy 约 24 MiB。ARM64 QEMU 的进程翻译会增加资源占用。
这些快照只说明实验期间的占用；业务负载、SSD 缓存、复制、恢复峰值需在现场测量。

## 尚需现场验收

修改前的部署版本已完成三台 ARM64 原生空集群安装、常态健康检查和带认证的 VIP 只读查询。
本轮开源整理涉及的防火墙启动依赖和备份目录保护有隔离测试；它们尚未部署到现场。

宿主 VIP／VRRP 自动切换、硬件 watchdog 隔离、网络隔离及整机故障，
以及 oneMiniHouse、Grafana、Nexus 和独立备份存储的验收仍按 ACCEPTANCE.md 执行。
隔离实验明确禁用 watchdog，没有测量宿主 VIP 自动切换。

原生空集群验收尚未启用独立备份存储。业务迁移继续要求有效备份和真实恢复证据。
