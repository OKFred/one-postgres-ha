# 第三方组件与许可证

本仓库原创源码采用 [MIT License](LICENSE)。第三方组件仍受各自许可证约束；本项目的 MIT 许可不替代这些许可证。

当前源码发布包含部署脚本、配置模板和构建说明，第三方源码、二进制及容器镜像由构建或部署流程从上游获取。下表按 2026-10-06 的 `versions.lock`、`images/postgres/requirements.lock`、`images/postgres/build-requirements.lock`、`images/tools/requirements.txt` 和 `images/tools/collections.yml` 核对，覆盖主要组件及需要特别留意的 Python 依赖，未逐项列出所有间接依赖或系统包。

## 主要组件

| 组件 | 仓库指定版本 | 许可证与官方来源 |
| --- | --- | --- |
| PostgreSQL | 18.6 | [PostgreSQL License](https://www.postgresql.org/about/licence/) |
| Patroni | 4.1.5 | [MIT](https://github.com/patroni/patroni/blob/v4.1.5/LICENSE) |
| etcd | 3.6.15 | [Apache-2.0](https://github.com/etcd-io/etcd/blob/v3.6.15/LICENSE) |
| HAProxy | 3.2.25 | 核心为 GPL-2.0，可导出头文件为 LGPL-2.1，带 OpenSSL 例外；个别文件以自身声明为准。见[官方 3.2 文档](https://www.haproxy.org/download/3.2/doc/intro.txt)及[该版本源码包](https://www.haproxy.org/download/3.2/src/haproxy-3.2.25.tar.gz)中的 `LICENSE`、`doc/gpl.txt`、`doc/lgpl.txt`。 |
| Keepalived | 由部署 inventory 显式指定，仓库未统一锁定 | 上游为 [GPL-2.0-or-later，带 OpenSSL 例外](https://github.com/acassen/keepalived/blob/master/README.md#license)；实际 Debian 包的版权文件需按所选版本核对。 |
| ansible-core | 2.19.14 | [GPL-3.0-or-later](https://github.com/ansible/ansible/blob/v2.19.14/pyproject.toml)，并有逐文件许可声明。 |
| community.crypto collection | 3.5.0 | 整体主要为 GPL-3.0-or-later；[版本元数据](https://github.com/ansible-collections/community.crypto/blob/3.5.0/galaxy.yml)另列 Apache-2.0、BSD-2-Clause、BSD-3-Clause、PSF-2.0。以各文件 SPDX 声明为准。 |
| ansible-lint | 26.9.0 | [分发整体为 GPL-3.0-or-later；自身历史代码为 MIT](https://github.com/ansible/ansible-lint/blob/v26.9.0/README.md#licensing)。 |
| yamllint | 1.38.0 | [GPL-3.0-or-later](https://github.com/adrienverge/yamllint/blob/v1.38.0/pyproject.toml) |
| Gitleaks（CI 扫描工具） | 8.30.1 | [MIT](https://github.com/gitleaks/gitleaks/blob/v8.30.1/LICENSE) |

## Python 依赖节选

| 组件 | 锁定版本 | 许可证与上游来源 |
| --- | --- | --- |
| psycopg2-binary | 2.9.13 | [LGPL-3.0-or-later，带 OpenSSL 例外](https://www.psycopg.org/docs/license.html)；部分源文件另有宽松许可。wheel 中附带的库也需单独核对。 |
| certifi | 2026.7.22 | [MPL-2.0](https://pypi.org/project/certifi/2026.7.22/) |
| cryptography | 50.0.2 | [Apache-2.0 或 BSD-3-Clause](https://github.com/pyca/cryptography/blob/50.0.2/LICENSE) |
| requests | 2.32.5 | [Apache-2.0](https://github.com/psf/requests/blob/v2.32.5/LICENSE) |
| urllib3 | 2.8.0 | [MIT](https://pypi.org/project/urllib3/2.8.0/) |
| PyYAML | 6.0.3 | [MIT](https://pypi.org/project/PyYAML/6.0.3/) |
| python-etcd / py-consul | 0.4.5 / 1.7.1 | [MIT（python-etcd）](https://pypi.org/project/python-etcd/0.4.5/)、[MIT（py-consul）](https://pypi.org/project/py-consul/1.7.1/) |
| setuptools / wheel | 80.9.0 / 0.45.1 | [MIT（setuptools）](https://pypi.org/project/setuptools/80.9.0/)、[MIT（wheel）](https://pypi.org/project/wheel/0.45.1/) |

工具镜像还安装其他 Python 包。完整版本见对应 requirements 文件；本节不将这些包统一归为某一种许可证。

## 基础系统与镜像发布

PostgreSQL 和工具镜像使用 Debian Bookworm 基础镜像，HAProxy 使用 Alpine 变体；基础系统包含多种许可证，不能用主程序的许可证代表整个镜像。Debian 包应保留 `/usr/share/doc/<包名>/copyright`，并按[Debian 许可资料](https://www.debian.org/legal/licenses/)核对实际版本；Alpine 包应按实际安装包及其上游许可核对。APT 新增系统包的版本未在本仓库逐项锁定。

Debian 提供的 Python 3.11 使用 [PSF License Agreement](https://docs.python.org/3.11/license.html)，其附带代码另有许可和致谢。Python 的精确补丁版本随实际 Debian 包而定。

对外发布构建后的镜像或包含第三方二进制的安装包时，应按最终产物的实际组件清单：

- 随产物保留各组件要求的版权声明、许可证全文、NOTICE 和必要的修改说明。
- 为 GPL/LGPL 组件按适用条款提供对应源码及所需构建材料或有效的源码提供安排；LGPL 的适用链接、替换或重新链接要求也应落实。
- 对 MPL 覆盖文件按许可提供相应源码，保留其声明；二进制 wheel 附带的库和镜像基础层同样纳入核对。

仅提供本文的上游链接不能替代这些发布义务。使用 GPL 工具执行本项目脚本或模板，也不能据此将本仓库所有原创文件统一认定为 GPL；复制或修改第三方源码时，须另按所复制文件的许可处理。

本文是源码发布的依赖说明，尚未构成任一镜像的完整组件清单或分发合规验收。更换锁定版本、基础镜像或构建依赖后，应同步更新。
