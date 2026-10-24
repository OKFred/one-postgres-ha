#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def text(name):
    return (root / name).read_text(encoding="utf-8")

def settings(name):
    result = {}
    for line in text(name).splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        assert separator and key not in result, f"Invalid or duplicate setting in {name}"
        result[key] = value
    return result

locked = settings("versions.lock")
defaults = settings("config/versions.env")
version = locked["POSTGRES_VERSION"]
assert re.fullmatch(r"17\.[0-9]+", version), "Default PostgreSQL must stay on major 17"
base = locked["POSTGRES_BASE_IMAGE"]
assert re.fullmatch(r"postgres:" + re.escape(version) + r"-bookworm@sha256:[0-9a-f]{64}", base)
patroni = locked["PATRONI_VERSION"]
assert patroni == "4.1.5"
assert defaults["POSTGRES_VERSION"] == version
assert defaults["POSTGRES_BASE_IMAGE"] == base
assert defaults["PATRONI_VERSION"] == patroni
tag = f"one-postgres-ha:pg{version}-patroni{patroni}"
assert defaults["POSTGRES_HA_IMAGE"] == tag
compose = text("docker-compose.yml")
assert f"image: ${{POSTGRES_HA_IMAGE:-{tag}}}" in compose
assert f"POSTGRES_BASE_IMAGE: ${{POSTGRES_BASE_IMAGE:-{base}}}" in compose
assert "PGDATA: /var/lib/postgresql/data" in compose
assert "target: /var/lib/postgresql/data" in compose
assert "target: /var/lib/postgresql\n" not in compose
pg_dockerfile = text("images/postgres/Dockerfile")
assert f"ARG POSTGRES_BASE_IMAGE={base}\n" in pg_dockerfile
assert "PGDATA=/var/lib/postgresql/data" in pg_dockerfile
assert f"PostgreSQL {version} with Patroni {patroni}" in pg_dockerfile
assert f"ARG POSTGRES_BASE={base}\n" in text("images/tools/Dockerfile")
assert f"patroni[etcd3]=={patroni} " in text("images/postgres/requirements.lock")
tool_tag = f"one-postgres-ha-tools:pg{version}"
assert f'TOOLS_IMAGE="${{HA_TOOLS_IMAGE:-{tool_tag}}}"' in text("ops.sh")
assert f'${{HA_CONFIGURE_TOOLS_IMAGE:-{tool_tag}}}' in text("scripts/configure.sh")
assert "bin_dir: /usr/lib/postgresql/17/bin" in text("config/patroni.example.yml")
assert "bin_dir: /usr/lib/postgresql/17/bin" in text("ansible/roles/cluster/templates/patroni.yml.j2")
assert "bin_dir: /usr/lib/postgresql/17/bin" in text("tests/integration.sh")
print("PASS: PG17 baseline, immutable base, runtime/client build inputs, tool cache tag and deployment defaults agree")
PY
