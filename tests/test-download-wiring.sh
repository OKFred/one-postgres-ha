#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PROJECT="$WORK/project"
mkdir -p "$PROJECT/.local" "$PROJECT/scripts" "$PROJECT/images/postgres" "$WORK/bin"
cp "$ROOT/ops.sh" "$PROJECT/"
cp "$ROOT/scripts/download-sources.sh" "$PROJECT/scripts/"
cp "$ROOT/images/postgres/source-profiles.sh" "$PROJECT/images/postgres/"
printf 'all: {}\n' >"$PROJECT/.local/inventory.yml"
cat >"$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\0' "$@" >>"$SOURCE_WIRING_LOG"
printf '\n' >>"$SOURCE_WIRING_LOG"
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH" SOURCE_WIRING_LOG="$WORK/calls"
unset HA_DOWNLOAD_SOURCE HA_TOOLS_IMAGE HA_SSH_KEY HA_INVENTORY
args_include() { tr '\0' '\n' <"$SOURCE_WIRING_LOG" | grep -Fxq -- "$1"; }
bash "$PROJECT/ops.sh" tools
args_include DOWNLOAD_SOURCE=official
[[ ! -e "$PROJECT/.local/download-source" ]]
: >"$SOURCE_WIRING_LOG"
HA_DOWNLOAD_SOURCE=ustc bash "$PROJECT/ops.sh" tools
args_include DOWNLOAD_SOURCE=ustc
[[ ! -e "$PROJECT/.local/download-source" ]]
printf 'tuna\n' >"$PROJECT/.local/download-source"
: >"$SOURCE_WIRING_LOG"
bash "$PROJECT/ops.sh" tools
args_include DOWNLOAD_SOURCE=tuna
: >"$SOURCE_WIRING_LOG"
bash "$PROJECT/ops.sh" status
args_include HA_DOWNLOAD_SOURCE=tuna
: >"$SOURCE_WIRING_LOG"
HA_DOWNLOAD_SOURCE=official bash "$PROJECT/ops.sh" status
args_include HA_DOWNLOAD_SOURCE=official
[[ $(<"$PROJECT/.local/download-source") == tuna ]]
for setting in '$(touch injected)' 'auto;touch injected' 'https://example.com'; do
  : >"$SOURCE_WIRING_LOG"
  if HA_DOWNLOAD_SOURCE="$setting" bash "$PROJECT/ops.sh" tools >"$WORK/rejected" 2>&1; then exit 1; fi
  [[ ! -s "$SOURCE_WIRING_LOG" && ! -e "$PROJECT/injected" ]]
done
printf '$(touch injected)\n' >"$PROJECT/.local/download-source"
: >"$SOURCE_WIRING_LOG"
if bash "$PROJECT/ops.sh" tools >"$WORK/rejected" 2>&1; then exit 1; fi
[[ ! -s "$SOURCE_WIRING_LOG" && ! -e "$PROJECT/injected" ]]

# Render the real node template with the defaults, then verify that a resolved
# preset reaches Compose's build argument without changing image digests.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
import yaml
from jinja2 import Environment, StrictUndefined

root = Path(sys.argv[1])
defaults = yaml.safe_load((root / 'ansible/roles/cluster/defaults/main.yml').read_text())
template = Environment(undefined=StrictUndefined).from_string(
    (root / 'ansible/roles/cluster/templates/node.env.j2').read_text())
for profile in ('official', 'ustc', 'tuna'):
    values = dict(defaults, download_source=profile, project_root=str(root),
                  inventory_hostname='fixture', groups={'core_nodes': ['fixture']},
                  node_name='fixture', node_ip='192.0.2.11', data_root='/srv/ha')
    values['lookup'] = lambda _plugin, path: Path(path).read_text()
    result = template.render(**values)
    assert result.splitlines().count('HA_DOWNLOAD_SOURCE=' + profile) == 1
    assert 'POSTGRES_BASE_IMAGE=postgres:17.11-bookworm@sha256:' in result
compose = yaml.safe_load((root / 'docker-compose.yml').read_text())
assert compose['services']['postgres']['build']['args']['DOWNLOAD_SOURCE'] == '${HA_DOWNLOAD_SOURCE:-official}'
PY
printf 'PASS: download preset reaches tool builds, runtime control and node Compose; overrides and invalid inputs are guarded\n'
