#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/cli/.local" "$WORK/bin"
cp "$ROOT/ops.sh" "$WORK/cli/ops.sh"
printf 'all: {}\n' >"$WORK/cli/.local/inventory.yml"
export IMAGE_FIXTURE_LOG="$WORK/docker.log"
cat >"$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
for argument in "$@"; do printf '%s\t' "${argument//$'\n'/\\n}" >>"$IMAGE_FIXTURE_LOG"; done
printf '\n' >>"$IMAGE_FIXTURE_LOG"
if [[ "$1 ${2:-}" == 'image inspect' ]]; then
  if [[ ${3:-} == --format ]]; then
    [[ $4 == '{{.Id}}' && $5 == "$IMAGE_FIXTURE_CONFIG_IMAGE" ]]
    printf 'sha256:%064d\n' 2
  else
    [[ ${IMAGE_FIXTURE_CACHED:-false} == true ]]
  fi
elif [[ "$1 ${2:-} ${3:-} ${4:-} ${5:-} ${6:-}" == 'compose --env-file .env config --format json' ]]; then
  printf '{"services":{"postgres":{"image":"%s"}}}\n' "$IMAGE_FIXTURE_CONFIG_IMAGE"
elif [[ $1 == run && ${3:-} == --init && ${4:-} == --pull=never ]]; then
  printf 'PostgreSQL 17 project image verified.\n'
fi
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
digest=$(printf '%064d' 1)
export HA_TOOLS_IMAGE="registry.example.com/ha/tools@sha256:$digest"
bash "$WORK/cli/ops.sh" plan
grep -Fq $'pull\t'"$HA_TOOLS_IMAGE" "$IMAGE_FIXTURE_LOG"
! grep -q '^build' "$IMAGE_FIXTURE_LOG"
export IMAGE_FIXTURE_CACHED=true
: >"$IMAGE_FIXTURE_LOG"
bash "$WORK/cli/ops.sh" plan
! grep -q '^pull' "$IMAGE_FIXTURE_LOG"
bash "$WORK/cli/ops.sh" tools
grep -Fq $'pull\t'"$HA_TOOLS_IMAGE" "$IMAGE_FIXTURE_LOG"
! grep -q '^build' "$IMAGE_FIXTURE_LOG"
for image in 'registry.example.com/ha/tools:latest' \
  "registry.example.com/ha/tools@sha256:$digest unsafe" \
  "user:password@registry.example.com/ha/tools@sha256:$digest"; do
  : >"$IMAGE_FIXTURE_LOG"
  if HA_TOOLS_IMAGE="$image" bash "$WORK/cli/ops.sh" tools >"$WORK/rejected.log" 2>&1; then
    echo 'An unsafe or mutable controller image was accepted' >&2; exit 1
  fi
  grep -q 'Registry HA_TOOLS_IMAGE must use a sha256 digest' "$WORK/rejected.log"
  [[ ! -s "$IMAGE_FIXTURE_LOG" ]]
done
unset HA_TOOLS_IMAGE
: >"$IMAGE_FIXTURE_LOG"
bash "$WORK/cli/ops.sh" tools
grep -q '^build' "$IMAGE_FIXTURE_LOG"
! grep -q '^pull' "$IMAGE_FIXTURE_LOG"
echo 'PASS: controller pulls immutable remote images, keeps cached digests and retains source builds'

python3 - "$ROOT" "$WORK" "$WORK/bin/docker" <<'PY'
import json, pathlib, sys, yaml
from jinja2 import Environment, StrictUndefined
root, work, fake = map(pathlib.Path, sys.argv[1:])
roles = work/'roles'
roles.mkdir()
import shutil
shutil.copytree(root/'ansible/roles/cluster', roles/'cluster')
prepare = roles/'cluster/tasks/prepare-image.yml'
tasks = yaml.safe_load(prepare.read_text())
for task in tasks:
    if 'ansible.builtin.command' in task:
        arguments = task['ansible.builtin.command']['argv']
        arguments[arguments.index('docker')] = str(fake)
prepare.write_text(yaml.safe_dump(tasks))
source = work/'source/images/postgres'
source.mkdir(parents=True)
(source/'Dockerfile').write_text('FROM scratch\n')
(work/'inventory.yml').write_text(yaml.safe_dump({'all':{'hosts':{'fixture':{
    'ansible_connection':'local',
    'ansible_python_interpreter':'{{ ansible_playbook_python }}'}}}}))
valid = 'registry.example.com/ha/postgres@sha256:'+'a'*64
cases = [('source_default','source','',True,'build'),
         ('source_ustc','source','',True,'build'),
         ('source_tuna','source','',True,'build'),
         ('bad_download_source','source','',False,None),
         ('source_tag','source','custom-ha:v1',True,'build'),
         ('prebuilt','prebuilt',valid,True,'pull'),
         ('prebuilt_port','prebuilt','localhost:5000/ha/postgres:v1@sha256:'+'b'*64,True,'pull'),
         ('prebuilt_tag','prebuilt','registry.example.com/ha/postgres:latest',False,None),
         ('prebuilt_missing','prebuilt','',False,None),
         ('prebuilt_credentials','prebuilt','user:password@'+valid,False,None),
         ('prebuilt_newline','prebuilt',valid+'\nENV=unsafe',False,None),
         ('prebuilt_local','prebuilt','ha/postgres@sha256:'+'a'*64,False,None),
         ('source_digest','source',valid,False,None),
         ('unknown_mode','guess','',False,None)]
for name, mode, image, accepted, action in cases:
    directory = work/name
    directory.mkdir()
    play = [dict(name='Exercise production image preparation',hosts='fixture',gather_facts=False,
        vars=dict(project_root=str(work/'source'),deployment_root=str(directory),
            postgres_image_mode=mode,postgres_ha_image=image,
            download_source={'source_ustc': 'ustc', 'source_tuna': 'tuna',
                             'bad_download_source': 'auto'}.get(name, 'official')),
        tasks=[dict(name='Execute image preparation',**{'ansible.builtin.include_role':dict(
            name='cluster',tasks_from='prepare-image')})])]
    (work/(name+'.yml')).write_text(yaml.safe_dump(play))
(work/'cases.json').write_text(json.dumps(cases))
defaults = yaml.safe_load((root/'ansible/roles/cluster/defaults/main.yml').read_text())
template = Environment(undefined=StrictUndefined).from_string(
    (root/'ansible/roles/cluster/templates/node.env.j2').read_text())
for name, mode, image, accepted, action in cases:
    if not accepted:
        continue
    variables = dict(defaults,postgres_image_mode=mode,postgres_ha_image=image,download_source='ustc',
        project_root=str(root),inventory_hostname='fixture',groups={'core_nodes':['fixture']},
        node_name='fixture',node_ip='192.0.2.11',data_root='/mnt/test/one-postgres-ha')
    variables['lookup'] = lambda plugin, path: pathlib.Path(path).read_text()
    rendered = template.render(**variables)
    settings = [line for line in rendered.splitlines() if line.startswith('POSTGRES_HA_IMAGE=')]
    assert len(settings)==1, (name,settings)
    expected = image or 'one-postgres-ha:pg17.11-patroni4.1.5'
    assert settings[0]=='POSTGRES_HA_IMAGE='+expected, (name,settings)
    assert rendered.splitlines().count('HA_DOWNLOAD_SOURCE=ustc') == 1
# Both initial and online replica deployments must share the production selector.
deploy = yaml.safe_load((root/'ansible/deploy.yml').read_text())
assert any(task.get('ansible.builtin.include_role',{}).get('tasks_from')=='prepare-image'
           for play in deploy for task in play.get('post_tasks',[]))
join = yaml.safe_load((root/'ansible/roles/cluster/tasks/join-replica.yml').read_text())
assert any(task.get('ansible.builtin.include_tasks')=='prepare-image.yml'
           for task in join[0]['block'])
PY
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" ANSIBLE_ROLES_PATH="$WORK/roles"
python3 - "$WORK" <<'PY'
import json, os, pathlib, subprocess, sys
work = pathlib.Path(sys.argv[1])
for name, mode, image, accepted, action in json.loads((work/'cases.json').read_text()):
    log = work/'docker.log'
    log.write_text('')
    environment = os.environ.copy()
    environment['IMAGE_FIXTURE_CONFIG_IMAGE'] = image or 'one-postgres-ha:pg17.11-patroni4.1.5'
    result = subprocess.run(['ansible-playbook','-i',str(work/'inventory.yml'),str(work/(name+'.yml'))],
        stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=environment)
    if (result.returncode==0) != accepted:
        print(result.stdout, file=sys.stderr)
        raise SystemExit('Unexpected image gate outcome: '+name)
    commands = log.read_text().splitlines()
    if accepted:
        assert len(commands)==4, (name,commands)
        assert commands[0].split('\t')[:6]==['compose','--env-file','.env',action,'postgres',''], commands
        assert commands[1].split('\t')==['compose','--env-file','.env','config','--format','json',''], commands
        assert commands[2].split('\t')==['image','inspect','--format','{{.Id}}',environment['IMAGE_FIXTURE_CONFIG_IMAGE'],''], commands
        probe = commands[3].split('\t')
        assert probe[:6]==['run','--rm','--init','--pull=never','--network','none'], probe
        assert '--read-only' in probe and probe[probe.index('--entrypoint')+1]=='/bin/sh', probe
        assert probe[probe.index('/bin/sh')+1]=='sha256:'+f'{2:064d}', probe
        assert not any(argument in ('stop','start','up','restart') for command in commands for argument in command.split('\t')), commands
        assert (work/name/'images/postgres/Dockerfile').exists()==(mode=='source'), name
    else:
        assert not commands and not (work/name/'images').exists(), name
    print('PASS: production image selection '+name)
PY
