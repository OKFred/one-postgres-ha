#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/config/versions.env"
TOOLS_IMAGE=${HA_TOOLS_IMAGE:-one-postgres-ha-tools:0.1.0}
docker() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command docker "$@"; }
host_path() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
mkdir -p "$ROOT/.local"
WORK=$(mktemp -d "$ROOT/.local/inspect-format.XXXXXXXX")
FIXTURE=''
cleanup() {
  local result=$?
  trap - EXIT
  [[ -z "$FIXTURE" ]] || docker rm -f "$FIXTURE" >/dev/null 2>&1 || true
  exit "$result"
}
trap cleanup EXIT
# Make the Compose identity differ from .Image to detect accidental comparison.
EXPECTED=fixtureimage
FIXTURE=$(docker create --label "com.docker.compose.image=$EXPECTED" \
  --label com.docker.compose.config-hash=fixture_config_hash "$POSTGRES_BASE_IMAGE")
docker run --rm --read-only --tmpfs /tmp:rw,exec,nosuid,size=128m \
  --mount "type=bind,src=$(host_path "$ROOT"),dst=/workspace,readonly" \
  --mount "type=bind,src=$(host_path "$WORK"),dst=/output" \
  -e "FIXTURE_CONTAINER=$FIXTURE" -e ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg \
  -e ANSIBLE_LOCAL_TEMP=/tmp/ansible-local -e ANSIBLE_HOME=/tmp/ansible-home \
  --entrypoint bash "$TOOLS_IMAGE" -c '
set -euo pipefail
python3 - <<"PY"
import os,pathlib,yaml
tasks=yaml.safe_load(pathlib.Path("/workspace/ansible/roles/cluster/tasks/inspect-update.yml").read_text())
selected=next(task for task in tasks if task["name"]=="Read only existing image and configuration identity")
selected["ansible.builtin.command"]["argv"][0]="/tmp/capture-docker"
capture=pathlib.Path("/tmp/capture-docker")
capture.write_text("#!/usr/bin/env python3\nimport pathlib,sys\np=pathlib.Path(\"/output/format.txt\")\np.write_text(sys.argv[sys.argv.index(\"--format\")+1])\np.chmod(0o644)\nprint(\"fixtureimage fixture_config_hash\")\n")
capture.chmod(0o755)
play=[dict(name="Render the real Docker inspect task through Ansible",hosts="localhost",connection="local",gather_facts=False,
  vars=dict(ansible_python_interpreter="{{ ansible_playbook_python }}",pg_ha_existing_pg_container=dict(stdout=os.environ["FIXTURE_CONTAINER"])),tasks=[selected])]
pathlib.Path("/tmp/play.yml").write_text(yaml.safe_dump(play))
PY
ansible-playbook -i localhost, /tmp/play.yml
'
FORMAT=$(cat "$WORK/format.txt")
ACTUAL=$(docker inspect --format "$FORMAT" "$FIXTURE")
[[ "$ACTUAL" == "$EXPECTED fixture_config_hash" ]]
printf 'PASS: Ansible-rendered Docker format uses Compose image/configuration labels\n'
