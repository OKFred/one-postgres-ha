# 开源发布

项目源码采用 [MIT](../LICENSE)，构建时使用的第三方软件保留各自许可证，见 [第三方组件](../THIRD_PARTY.md)。
当前交付是 Bash、Ansible 和 Compose 源码，构建过程从上游下载组件。
发布自建容器镜像之前，还需整理镜像中所有软件的版权、许可证和所需源码。

## 保留私有部署历史，准备公开源码

部署仓库可能曾提交过现场标识或个人邮箱。修改当前文件后直接把仓库改为 public，会同时公开旧提交。
先保留原私有仓库和部署记录，再从检查过的提交生成独立的单提交仓库：

```bash
bash ops.sh check
bash scripts/export-public.sh
```

导出只读取已提交的 Git HEAD，拒绝未提交的源码；
不会复制原 `.git`、旧提交、remote、`.local/`、缓存、凭据或现场证据。
即使 `.local/`、`.cache/` 或 `.ansible/` 中的文件被强制加入 Git，导出也会拒绝。
默认提交身份为 `one-postgres-ha contributors <opensource@users.noreply.github.com>`。
需要关联自己的 GitHub 身份时，显式设置 `HA_PUBLIC_AUTHOR_NAME` 和 GitHub noreply 邮箱：

```bash
HA_PUBLIC_AUTHOR_NAME=YourGitHubName \
HA_PUBLIC_AUTHOR_EMAIL=YourGitHubName@users.noreply.github.com \
bash scripts/export-public.sh
```

输出目录为忽略的 `.local/public/`，部署源码包与 SHA256 放在 `.local/dist/`。
每次使用新的目录，失败输出可检查，不覆盖或改写原仓库历史。
导出的仓库没有 remote；工具不会创建 GitHub 仓库、改变可见性或推送代码。

发布前，在导出目录运行 `git log --all`（应只有一个提交）、`git remote -v`（应为空），
并使用 Gitleaks 再扫描。原来的私有仓库和旧部署包继续按私有数据管理。
公共仓库发布后，后续只推送已经检查过的新提交；不要合并原私有历史。

## 现场规则与自动扫描

将真实域名、地址、账号 ID 等禁用字符串放到 `.local/private-source-rules.txt`，每行一个。
文件不会进入 Git、Docker 构建上下文或导出包；源码扫描同时识别单字符正则转义，防止可还原的值被当作脱敏。
通用扫描规则不保存具体现场值。
显式设置 `HA_PRIVATE_SCAN_RULES` 时，文件缺失或无效会导致检查失败。

CI 拉取完整 Git 历史，使用固定版本及校验和的 Gitleaks 扫描。日志和报告不显示检测到的凭据值。
自动扫描之外，仍需人工检查 Git 提交邮箱、README、截图、issue 附件、工作流日志和发布资产。

## 发布定位

说明支持的主机、网络、watchdog 条件，以及验证是源码检查、隔离测试还是原生现场验收。
不要将常态启动验证写成已完成整机故障、网络隔离、VIP 切换或备份恢复验收。

`one_minihouse`、`nexus` 是可选的专用业务迁移适配器，不能通过改数据库名直接迁移任意应用。
通用 HA 部署、新增副本、全实例备份和隔离恢复不需要使用这两个适配器。
迁移其他应用前应实现并验收对应的停写、配置切换和应用回归流程。
