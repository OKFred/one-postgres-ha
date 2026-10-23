#!/usr/bin/env bash
# Host cleanup only; the controller's inventory, keys and backup evidence stay intact.
set -Eeuo pipefail
umask 077
die() {
  printf 'cleanup-node: %s\n' "$*" >&2
  exit 2
}
PHASE=audit
APPLY=false
# Preserve the legacy cleanup command's destructive behavior unless the new
# uninstall entrypoint explicitly selects keep-data.
CLEANUP_LEVEL=purge-data
CLEANUP_ID=''
CORE=false
DEPLOYMENT=''
DATA=''
MOUNT=''
CLUSTER=''
NODE=''
NODE_IP=''
PROJECT=''
WATCHDOG=/dev/watchdog
WATCHDOG_GID=999
SYSTEM_ROOT=/etc
LOCK_ROOT=/run/lock
if [[ ${1:-} != --* && $# -gt 0 ]]; then
  PHASE=$1
  shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-root | --data-root | --data-mount | --cluster-name | --node-name | --node-ip | --compose-project | --watchdog-device | --watchdog-gid | --cleanup-level | --cleanup-id)
      [[ $# -ge 2 ]] || die 'An option value is missing'
      case "$1" in
        --deployment-root) DEPLOYMENT=$2 ;; --data-root) DATA=$2 ;; --data-mount) MOUNT=$2 ;;
        --cluster-name) CLUSTER=$2 ;; --node-name) NODE=$2 ;; --node-ip) NODE_IP=$2 ;; --compose-project) PROJECT=$2 ;;
        --watchdog-device) WATCHDOG=$2 ;; --watchdog-gid) WATCHDOG_GID=$2 ;;
        --cleanup-level) CLEANUP_LEVEL=$2 ;;
        --cleanup-id) CLEANUP_ID=$2 ;;
      esac
      shift 2
      ;;
    --core)
      CORE=true
      shift
      ;;
    --replica)
      CORE=false
      shift
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    --help)
      printf 'Usage: cleanup-node.sh [audit|stop-ingress|stop-postgres|stop-etcd|remove] --deployment-root PATH --data-root PATH --data-mount PATH --cluster-name NAME --node-name NAME --node-ip IP --compose-project NAME [--watchdog-device PATH] [--watchdog-gid GID] [--cleanup-level keep-data|purge-data] [--cleanup-id ID] [--core|--replica] [--apply]\n'
      exit 0
      ;;
    *) die 'Unknown option' ;;
  esac
done
case "$PHASE" in audit | stop-ingress | stop-postgres | stop-etcd | remove) ;; *) die 'Unknown phase' ;; esac
case "$CLEANUP_LEVEL" in keep-data | purge-data) ;; *) die 'Unknown cleanup level' ;; esac
[[ -z "$CLEANUP_ID" || "$CLEANUP_ID" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid cleanup transaction'
[[ "$PHASE" == audit || "$APPLY" == true ]] || die 'A mutation requires explicit --apply'
[[ $(id -u) == 0 ]] || die 'Run this backend as root'
for tool in python3 docker realpath findmnt systemctl iptables ip6tables flock rm rmdir stat udevadm; do
  command -v "$tool" >/dev/null || die "Missing required tool: $tool"
done
if [[ "$PHASE" != audit ]]; then
  [[ ! -L "$LOCK_ROOT" && -d "$LOCK_ROOT" ]] || die 'Unsafe lock directory'
  LOCK="$LOCK_ROOT/one-postgres-ha-cleanup.lock"
  [[ ! -L "$LOCK" ]] || die 'Unsafe lock file'
  [[ ! -e "$LOCK" || (-f "$LOCK" && $(stat -c '%u' "$LOCK") == 0) ]] || die 'Unowned lock file'
  exec 9>"$LOCK"
  flock -n 9 || die 'Another node cleanup is running'
fi

# Audit every phase again. No Compose file or arbitrary shell/config content is executed.
AUDIT=$(
  python3 - "$DEPLOYMENT" "$DATA" "$MOUNT" "$CLUSTER" "$NODE" "$NODE_IP" "$PROJECT" "$CORE" "$SYSTEM_ROOT" "$WATCHDOG" "$WATCHDOG_GID" "$PHASE" "$CLEANUP_LEVEL" <<'PY'
import ipaddress, json, os, pathlib, re, shlex, stat, subprocess, sys
deployment, data, mount, cluster, node, node_ip, project, core, system, watchdog, watchdog_gid, phase, cleanup_level = sys.argv[1:]
core = core == 'true'
def require(condition, message):
    if not condition: raise RuntimeError(message)
def run(args, allowed=(0,)):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode in allowed, 'Cannot inspect '+args[0]+' state safely')
    return result
def overlap(a,b): return a == b or a.startswith(b.rstrip('/')+'/') or b.startswith(a.rstrip('/')+'/')
def regular(path, required=False, owner=0):
    p=pathlib.Path(path)
    require(not p.is_symlink(), 'A marker or managed configuration is a symlink')
    if not p.exists():
        require(not required, 'A required identity/configuration file is missing')
        return False
    st=p.stat()
    require(stat.S_ISREG(st.st_mode) and st.st_uid == owner and not st.st_mode & 0o022,
            'Unowned or writable identity/configuration file')
    return True
def owned_root(path):
    p=pathlib.Path(path)
    require(not p.is_symlink(), 'An owned root is a symlink')
    if not p.exists(): return False
    require(p.is_dir() and p.stat().st_uid == 0 and not p.stat().st_mode & 0o022, 'An owned root has an unexpected type owner or permissions')
    marker=p/'.one-postgres-ha-cluster'
    regular(marker, True)
    require(marker.read_text().strip() == cluster, 'Cluster ownership marker mismatch')
    return True
try:
    for value,pattern in [(cluster,r'[a-z][a-z0-9-]{2,48}'),(node,r'[a-z][a-z0-9-]{1,48}'),
                          (project,r'[a-z0-9][a-z0-9_-]{0,62}')]:
        require(bool(re.fullmatch(pattern,value)), 'Invalid identity')
    ipaddress.IPv4Address(node_ip)
    require(watchdog_gid.isdigit() and 0 <= int(watchdog_gid) <= 65535, 'Invalid watchdog group')
    require(os.path.isabs(watchdog), 'Use an explicit watchdog device path')
    watchdog_stat=os.stat(watchdog)
    require(stat.S_ISCHR(watchdog_stat.st_mode), 'Watchdog must be a character device; cleanup never opens it')
    for path in [deployment,data,mount]:
        require(bool(re.fullmatch(r'/[A-Za-z0-9_./-]+',path)), 'Use explicit absolute paths')
        require(path == os.path.normpath(path) and path not in ['/', '/etc', '/var', '/opt', '/srv', '/home', '/usr', '/tmp', '/mnt'],
                'Unsafe or noncanonical root path')
        require(run(['realpath','--canonicalize-missing','--',path]).stdout.strip() == path,
                'A root path or parent resolves through a symlink')
        for parent in [pathlib.Path(path),*pathlib.Path(path).parents]:
            if not parent.exists(): continue
            st=parent.stat()
            require(parent.is_dir() and not parent.is_symlink() and st.st_uid==0
                    and (not st.st_mode & 0o022 or stat.S_ISVTX & st.st_mode),
                    'A cleanup root or parent is not protected against replacement')
    require(data.startswith(mount+'/') and not overlap(deployment,data), 'Storage and deployment roots overlap or escape the SSD')
    for forbidden in [mount+'/docker',mount+'/containerd',run(['docker','info','--format','{{.DockerRootDir}}']).stdout.strip()]:
        require(forbidden.startswith('/') and not overlap(deployment,forbidden) and not overlap(data,forbidden),
                'A cleanup root overlaps Docker/containerd storage')
    mounts=json.loads(run(['findmnt','--json','--list','--output','TARGET,SOURCE,FSTYPE,OPTIONS']).stdout)['filesystems']
    exact=[item for item in mounts if item['target'] == mount]
    require(len(exact)==1 and exact[0]['source'].startswith('/dev/') and exact[0]['fstype'] in ['ext4','xfs','btrfs']
            and 'rw' in exact[0]['options'].split(','), 'The original writable local SSD must be mounted')
    require(pathlib.Path(mount).stat().st_uid==0 and not pathlib.Path(mount).stat().st_mode & 0o022, 'SSD mount permissions allow replacement')
    require(not any(item['target'] == deployment or item['target'].startswith(deployment+'/')
                    or item['target'] == data or item['target'].startswith(data+'/') for item in mounts),
            'A cleanup root contains a mountpoint; nested mounts are never removed')
    deployed=owned_root(deployment)
    stored=owned_root(data)
    require(deployed == stored, 'Deployment and data ownership must both be present or both absent')
    if deployed:
        permitted={'.one-postgres-ha-cluster','.one-postgres-ha-retained.json','.env','docker-compose.yml','config','secrets','bin','images'}
        require(all(entry.name in permitted for entry in pathlib.Path(deployment).iterdir()), 'Unknown deployment files require manual review')
        permitted={'.one-postgres-ha-cluster','.one-postgres-ha-join-pending','postgres','etcd'}
        require(all(entry.name in permitted for entry in pathlib.Path(data).iterdir()), 'Unknown data-root files require manual review')
        for directory in [deployment+'/config',deployment+'/secrets',deployment+'/bin',deployment+'/images',data+'/postgres',data+'/etcd']:
            p=pathlib.Path(directory)
            require(not p.is_symlink() and (not p.exists() or p.is_dir()), 'A managed child root is linked or not a directory')
        if regular(data+'/.one-postgres-ha-join-pending'):
            require(pathlib.Path(data+'/.one-postgres-ha-join-pending').read_text().strip() == cluster, 'Pending marker identity mismatch')
        if regular(data+'/postgres/PG_VERSION',owner=999):
            require(pathlib.Path(data+'/postgres/PG_VERSION').read_text().strip() == '18', 'Unexpected PostgreSQL major version')
        if not core: require(not pathlib.Path(data+'/etcd').exists(), 'A PG-only node contains etcd data')
        regular(deployment+'/.env',True)
        regular(deployment+'/docker-compose.yml',True)
        lines=pathlib.Path(deployment+'/.env').read_text().splitlines()
        expected={'COMPOSE_PROJECT_NAME':project,'NODE_NAME':node,'NODE_IP':node_ip,
                  'CONFIG_DIR':deployment+'/config','SECRETS_DIR':deployment+'/secrets',
                  'PG_DATA_DIR':data+'/postgres','ETCD_DATA_DIR':data+'/etcd',
                  'COMPOSE_PROFILES':'core' if core else '',
                  'WATCHDOG_DEVICE':watchdog,'WATCHDOG_GID':watchdog_gid}
        for key,value in expected.items():
            require([line.split('=',1)[1] for line in lines if line.startswith(key+'=')] == [value],
                    'Node environment identity or paths differ from inventory')
        regular(deployment+'/config/patroni.yml',True)
        config=pathlib.Path(deployment+'/config/patroni.yml').read_text()
        require(re.findall(r'^scope: (.+)$',config,re.M)==[cluster] and re.findall(r'^name: (.+)$',config,re.M)==[node],
                'Patroni cluster or member identity mismatch')
        if core:
            regular(deployment+'/config/etcd.yml',True)
            config=pathlib.Path(deployment+'/config/etcd.yml').read_text()
            require(re.findall(r'^name: (.+)$',config,re.M)==[node] and re.findall(r'^initial-cluster-token: (.+)$',config,re.M)==[cluster],
                    'etcd member or cluster identity mismatch')
    retained=None
    receipt=pathlib.Path(deployment)/'.one-postgres-ha-retained.json'
    if regular(receipt):
        info=receipt.stat()
        require(deployed and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600, 'Unsafe retained-data receipt')
        retained=json.loads(receipt.read_text())
        expected={'schema':1,'cluster':cluster,'node':node,'project':project,'deployment':deployment,'data':data}
        require(isinstance(retained,dict) and all(retained.get(key) == value for key,value in expected.items())
                and set(retained)==set(expected)|{'transaction','phase','system_identifier','image_id'}
                and retained['phase'] in ['stopped','resuming','complete']
                and re.fullmatch(r'[0-9a-f]{64}',retained['transaction'])
                and re.fullmatch(r'[1-9][0-9]{0,19}',retained['system_identifier'])
                and re.fullmatch(r'sha256:[0-9a-f]{64}',retained['image_id']), 'Retained-data receipt identity differs')
    ids=run(['docker','ps','--all','--quiet','--no-trunc']).stdout.split()
    require(all(re.fullmatch(r'[0-9a-f]{64}',cid) for cid in ids), 'Invalid Docker container identity')
    objects=json.loads(run(['docker','inspect',*ids]).stdout) if ids else []
    containers=[]
    expected_mounts={'postgres':{deployment+'/config':'/etc/one-postgres-ha',deployment+'/secrets':'/run/secrets',data+'/postgres':'/var/lib/postgresql/data'},
                     'etcd':{deployment+'/config':'/etc/one-postgres-ha',deployment+'/secrets':'/run/secrets',data+'/etcd':'/etcd-data'},
                     'haproxy':{deployment+'/config':'/etc/one-postgres-ha'}}
    for obj in objects:
        labels=obj.get('Config',{}).get('Labels') or {}
        mounts=obj.get('Mounts',[])
        bind_list=[item for item in mounts if item.get('Type')=='bind']
        binds={item['Source']:item['Destination'] for item in bind_list}
        if labels.get('com.docker.compose.project') != project:
            require(not any(overlap(source,deployment) or overlap(source,data)
                            for item in mounts if item.get('Source','').startswith('/')
                            for source in [item['Source'],os.path.realpath(item['Source'])]),
                    'Another container mounts a cleanup path or its parent')
            for item in mounts:
                if item.get('Type') != 'volume': continue
                volumes=json.loads(run(['docker','volume','inspect',item['Name']]).stdout)
                require(len(volumes)==1, 'Cannot inspect another container volume')
                device=(volumes[0].get('Options') or {}).get('device','')
                require(not device.startswith('/') or not (overlap(os.path.realpath(device),deployment) or overlap(os.path.realpath(device),data)),
                        'Another container has a bind-backed volume targeting a cleanup path')
            continue
        service=labels.get('com.docker.compose.service')
        require(deployed and service in (['postgres','etcd','haproxy'] if core else ['postgres']), 'Unknown project container or missing ownership')
        extra=[item for item in mounts if item.get('Type') not in ['bind','tmpfs']]
        if extra:
            # PG18's official base declares this parent volume; PGDATA itself is the SSD bind below it.
            require(service=='postgres' and len(extra)==1 and extra[0].get('Type')=='volume'
                    and extra[0].get('Destination')=='/var/lib/postgresql'
                    and re.fullmatch(r'[0-9a-f]{64}',extra[0].get('Name','')), 'Unknown extra project volume')
            inherited=json.loads(run(['docker','image','inspect','--format','{{json .Config.Volumes}}',obj['Image']]).stdout)
            volumes=json.loads(run(['docker','volume','inspect',extra[0]['Name']]).stdout)
            require('/var/lib/postgresql' in (inherited or {}) and len(volumes)==1 and volumes[0].get('Driver')=='local'
                    and not volumes[0].get('Options'), 'Unexpected image-inherited PostgreSQL volume')
        require(labels.get('com.docker.compose.project.working_dir') == deployment
                and labels.get('com.docker.compose.project.config_files') == deployment+'/docker-compose.yml'
                and labels.get('com.docker.compose.oneoff','False').lower()=='false'
                and binds == expected_mounts[service] and len(bind_list)==len(binds), 'Project container configuration or bind mounts differ')
        require(obj['Id'] in ids and isinstance(obj['State']['Running'],bool), 'Invalid inspected container state')
        require(not any(item['service']==service for item in containers), 'Duplicate project service containers')
        exit_code=obj['State'].get('ExitCode')
        require(isinstance(exit_code,int), 'Cannot verify container exit status')
        containers.append({'id':obj['Id'],'service':service,'running':obj['State']['Running'],'exit_code':exit_code,'image':obj['Image']})
    holders=[]
    pg_ids=[item['id'] for item in containers if item['service']=='postgres' and item['running']]
    for process in pathlib.Path('/proc').iterdir():
        if not process.name.isdigit(): continue
        try:
            for descriptor in (process/'fd').iterdir():
                try: descriptor_stat=descriptor.stat()
                except FileNotFoundError: continue
                if stat.S_ISCHR(descriptor_stat.st_mode) and descriptor_stat.st_rdev==watchdog_stat.st_rdev:
                    require(any(cid in (process/'cgroup').read_text() for cid in pg_ids), 'Another process owns the watchdog')
                    holders.append(int(process.name))
        except FileNotFoundError: continue
    if phase in ['stop-etcd','remove']:
        require(not holders and all(not item['running'] and item['exit_code']!=137 for item in containers if item['service']=='postgres'),
                'PostgreSQL was not stopped gracefully or the watchdog still has an owner')
    firewall=pathlib.Path(system+'/systemd/system/one-postgres-ha-firewall.service')
    firewall_owned=regular(firewall)
    firewall_active=run(['systemctl','is-active','--quiet','one-postgres-ha-firewall.service'],(0,3,4)).returncode==0
    require(not firewall_active or firewall_owned, 'Active firewall unit has no owned configuration')
    if firewall_owned:
        require(deployed, 'Firewall unit remains without deployment ownership')
        expected='[Unit]\nDescription=Allowlist for one-postgres-ha ports\nAfter=network-online.target\nWants=network-online.target\nBefore=docker.service keepalived.service\n[Service]\nType=oneshot\nExecStart='+deployment+'/bin/firewall.sh\nExecReload='+deployment+'/bin/firewall.sh\nRemainAfterExit=yes\n[Install]\nWantedBy=multi-user.target\n'
        legacy=expected.replace('ExecReload='+deployment+'/bin/firewall.sh\n','')
        require(firewall.read_text() in [expected,legacy], 'Firewall unit is not the managed unit')
        regular(deployment+'/bin/firewall.sh',True)
        require('Only the dedicated chains are replaced.' in pathlib.Path(deployment+'/bin/firewall.sh').read_text(), 'Firewall script ownership differs')
    for family in ['iptables','ip6tables']:
        rules=run([family,'--wait','5','-S']).stdout.splitlines()
        chain=any(line=='-N ONE_PG_HA' for line in rules)
        require(not chain or firewall_owned, 'Firewall chain has no ownership proof')
        for line in rules:
            parts=shlex.split(line)
            if '-j' not in parts or parts[parts.index('-j')+1]!='ONE_PG_HA': continue
            tcp=['-A','INPUT','-p','tcp','-m','multiport','--dports','5432,5433,8008,2379,2380','-j','ONE_PG_HA']
            vrrp=['-A','INPUT','-p','vrrp','-j','ONE_PG_HA']
            numeric=['-A','INPUT','-p','112','-j','ONE_PG_HA']
            require(firewall_owned and (parts==tcp or family=='iptables' and parts in [vrrp,numeric]),
                    'An unknown firewall rule refers to the dedicated chain')
    keepalived=pathlib.Path(system+'/keepalived/keepalived.conf')
    keep_owned=False
    if core and regular(keepalived):
        require(deployed, 'Keepalived configuration remains without deployment ownership')
        config=keepalived.read_text()
        require(config.startswith('# Managed by one-postgres-ha.')
                and re.findall(r'^\s*router_id (\S+)\s*$',config,re.M)==[node]
                and re.findall(r'^\s*script "([^"]+)"\s*$',config,re.M)==[deployment+'/bin/check-proxy.sh']
                and re.findall(r'^vrrp_instance (\S+)',config,re.M)==['POSTGRES_HA']
                and not re.search(r'^\s*include\b',config,re.M), 'Keepalived configuration is not solely owned by this node')
        keep_owned=True
    if core:
        active=run(['systemctl','is-active','--quiet','keepalived.service'],(0,3,4)).returncode==0
        require(not active or keep_owned, 'Active Keepalived has no owned configuration')
    dependency='# Managed by one-postgres-ha.\n[Unit]\nRequires=one-postgres-ha-firewall.service\nAfter=one-postgres-ha-firewall.service\n'
    dependency_services=[]
    for service in ['docker.service','keepalived.service']:
        directory=pathlib.Path(system+'/systemd/system/'+service+'.d')
        require(not directory.is_symlink(), 'A startup dependency directory is linked')
        if directory.exists():
            info=directory.stat()
            require(directory.is_dir() and info.st_uid==0 and not info.st_mode & 0o022,
                    'A startup dependency directory is unowned or writable')
        gate=directory/'30-one-postgres-ha-firewall.conf'
        if regular(gate):
            require(firewall_owned and (service=='docker.service' or keep_owned) and gate.read_text()==dependency,
                    'Startup firewall dependency ownership differs')
            dependency_services.append(service)
    for unit in ['one-postgres-ha-firewall.service']+(['keepalived.service'] if keep_owned else []):
        override=pathlib.Path(system+'/systemd/system/'+unit+'.d')
        allowed=[override/'30-one-postgres-ha-firewall.conf'] if unit in dependency_services else []
        require(not override.is_symlink() and (not override.exists() or all(item in allowed for item in override.iterdir())),
                'A managed service has unknown overrides')
        loaded=shlex.split(run(['systemctl','show','--property=DropInPaths','--value',unit]).stdout)
        require(all(pathlib.Path(item) in allowed for item in loaded), 'A managed service has external drop-ins')
    for service in ['backup','restore-test']:
        for extension in ['service','timer']:
            require(not pathlib.Path(system+'/systemd/system/one-postgres-ha-'+service+'.'+extension).exists(),
                    'Backup timers on a PG node require manual review; independent backup hosts are outside cleanup scope')
    udev=pathlib.Path(system+'/udev/rules.d/70-one-postgres-ha-watchdog.rules')
    udev_owned=regular(udev)
    if udev_owned:
        expected='SUBSYSTEM=="watchdog", KERNEL=="watchdog*", GROUP="'+watchdog_gid+'", MODE="0660"\nSUBSYSTEM=="misc", KERNEL=="watchdog", GROUP="'+watchdog_gid+'", MODE="0660"\n'
        require(deployed and udev.read_text()==expected, 'Watchdog udev rule ownership differs')
    keep_data=cleanup_level == 'keep-data'
    print(json.dumps({'node':node,'cluster':cluster,'deployment_present':deployed,'data_present':stored,
                      'deployment_root':deployment,'data_root':data,'data_mount':mount,'compose_project':project,
                      'cleanup_level':cleanup_level,
                      'delete_paths':[] if keep_data else [deployment,data],
                      'retained_paths':[deployment,data] if keep_data and deployed else [],
                      'deployment_preserved':keep_data and deployed,'data_preserved':keep_data and stored,
                      'retained_receipt':retained,
                      'firewall_owned':firewall_owned,'keepalived_owned':keep_owned,'udev_owned':udev_owned,
                      'firewall_dependency_services':dependency_services,
                      'watchdog_holders':holders,'containers':containers}))
except (RuntimeError,ValueError,OSError,KeyError,TypeError) as error:
    print('cleanup-node: audit refused: '+str(error),file=sys.stderr)
    raise SystemExit(2)
PY
)
if [[ "$PHASE" == audit ]]; then
  printf '%s\n' "$AUDIT"
  exit 0
fi
mapfile -t CONTAINERS < <(python3 -c 'import json,sys; print("\n".join(item["id"]+" "+item["service"]+" "+str(item["running"]).lower() for item in json.loads(sys.argv[1])["containers"]))' "$AUDIT")
owned() { python3 -c 'import json,sys; print(str(json.loads(sys.argv[1])[sys.argv[2]]).lower())' "$AUDIT" "$1"; }
firewall_exists() {
  local result=0
  "$@" >/dev/null 2>&1 || result=$?
  case "$result" in 0) return 0 ;; 1) return 1 ;; *) die 'Firewall state could not be checked during removal' ;; esac
}
stop_service() {
  local line cid service running
  for line in "${CONTAINERS[@]}"; do
    [[ -n "$line" ]] || continue
    read -r cid service running <<<"$line"
    [[ "$service" == "$1" ]] || continue
    docker update --restart=no "$cid" >/dev/null
    if [[ "$running" == true ]]; then docker stop --time 120 "$cid" >/dev/null; fi
    [[ $(docker inspect --format '{{.State.Running}}' "$cid") == false ]] || die 'A project container did not stop'
    if [[ "$service" == postgres ]]; then
      [[ $(docker inspect --format '{{.State.ExitCode}}' "$cid") != 137 ]] || die 'PostgreSQL required SIGKILL; keep DCS/data intact and verify watchdog recovery before retrying'
    fi
  done
}
case "$PHASE" in
  stop-ingress)
    if [[ $(owned keepalived_owned) == true ]]; then systemctl disable --now keepalived.service; fi
    stop_service haproxy
    ;;
  stop-postgres) stop_service postgres ;;
  stop-etcd) stop_service etcd ;;
  remove)
    for line in "${CONTAINERS[@]}"; do
      [[ -n "$line" ]] || continue
      read -r cid service running <<<"$line"
      [[ "$running" == false ]] || die 'A project container is still running; complete all stop phases first'
    done
    if [[ $(owned keepalived_owned) == true ]]; then
      ! systemctl is-active --quiet keepalived.service || die 'Keepalived is still active'
    fi
    if [[ "$CLEANUP_LEVEL" == keep-data && $(owned deployment_present) == true ]]; then
      [[ "$CLEANUP_ID" =~ ^[0-9a-f]{64}$ ]] || die 'Keep-data removal requires the cluster-wide cleanup transaction'
      # All nodes passed graceful PG/DCS shutdown barriers before this phase.
      # Read the identity through the existing immutable image without starting
      # PostgreSQL, opening the watchdog, or granting write access to PGDATA.
      python3 - "$AUDIT" "$CLEANUP_ID" <<'PY'
import json,os,pathlib,re,stat,subprocess,sys,tempfile
audit=json.loads(sys.argv[1]); transaction=sys.argv[2]
data=pathlib.Path(audit['data_root'])/'postgres'
version=data/'PG_VERSION'
if not version.exists(): raise SystemExit(0)
previous=audit['retained_receipt']
if previous is not None and previous['transaction'] != transaction:
    raise SystemExit('cleanup-node: retained-data transaction differs; preserve and review')
images=[entry['image'] for entry in audit['containers'] if entry['service']=='postgres']
image=images[0] if images else previous['image_id'] if previous else ''
if not re.fullmatch(r'sha256:[0-9a-f]{64}',image): raise SystemExit('cleanup-node: no verified PostgreSQL image remains')
control=data/'global/pg_control'
info=control.lstat()
if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != 999 or info.st_mode & 0o022:
    raise SystemExit('cleanup-node: unsafe PostgreSQL control file')
result=subprocess.run(['docker','run','--rm','--network','none','--read-only','--cap-drop','ALL',
    '--security-opt','no-new-privileges','--user','999:999','--env','LC_ALL=C',
    '--mount','type=bind,src='+str(data)+',dst=/var/lib/postgresql/data,readonly',
    '--entrypoint','/usr/lib/postgresql/18/bin/pg_controldata',image,'/var/lib/postgresql/data'],
    capture_output=True,text=True,timeout=60)
identities=re.findall(r'^Database system identifier:\s+([1-9][0-9]{0,19})\s*$',result.stdout,re.M)
states=re.findall(r'^Database cluster state:\s+(.+?)\s*$',result.stdout,re.M)
if result.returncode != 0 or len(identities) != 1 or len(states) != 1 or states[0] not in ['shut down','shut down in recovery']:
    raise SystemExit('cleanup-node: PostgreSQL control identity inspection failed')
if previous is not None and previous['system_identifier'] != identities[0]:
    raise SystemExit('cleanup-node: PostgreSQL identity differs from its retained receipt')
receipt={key:audit[key] for key in ['cluster','node']}
receipt.update(schema=1,project=audit['compose_project'],deployment=audit['deployment_root'],data=audit['data_root'],transaction=transaction,
               phase='stopped',system_identifier=identities[0],image_id=image)
directory=pathlib.Path(audit['deployment_root'])
descriptor,temporary=tempfile.mkstemp(prefix='.retained-',dir=directory)
try:
    with os.fdopen(descriptor,'w') as output:
        json.dump(receipt,output,sort_keys=True); output.write('\n'); output.flush(); os.fsync(output.fileno())
    os.replace(temporary,directory/'.one-postgres-ha-retained.json')
    directory_descriptor=os.open(directory,os.O_RDONLY|os.O_DIRECTORY)
    try: os.fsync(directory_descriptor)
    finally: os.close(directory_descriptor)
finally:
    if os.path.exists(temporary): os.unlink(temporary)
PY
    fi
    for line in "${CONTAINERS[@]}"; do
      [[ -n "$line" ]] || continue
      read -r cid service running <<<"$line"
      docker rm "$cid" >/dev/null
    done
    mapfile -t DEPENDENCY_SERVICES < <(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])["firewall_dependency_services"]))' "$AUDIT")
    for service in "${DEPENDENCY_SERVICES[@]}"; do
      [[ -n "$service" ]] || continue
      rm -- "$SYSTEM_ROOT/systemd/system/$service.d/30-one-postgres-ha-firewall.conf"
    done
    # Forget Requires before stopping the firewall, so Docker keeps running.
    if [[ -n ${DEPENDENCY_SERVICES[0]:-} ]]; then systemctl daemon-reload; fi
    if [[ $(owned firewall_owned) == true ]]; then
      systemctl disable --now one-postgres-ha-firewall.service
      for family in iptables ip6tables; do
        while firewall_exists "$family" --wait 5 -C INPUT -p tcp -m multiport --dports 5432,5433,8008,2379,2380 -j ONE_PG_HA; do
          "$family" --wait 5 -D INPUT -p tcp -m multiport --dports 5432,5433,8008,2379,2380 -j ONE_PG_HA
        done
        if [[ "$family" == iptables ]]; then
          while firewall_exists "$family" --wait 5 -C INPUT -p 112 -j ONE_PG_HA; do "$family" --wait 5 -D INPUT -p 112 -j ONE_PG_HA; done
        fi
        if firewall_exists "$family" --wait 5 -S ONE_PG_HA; then
          "$family" --wait 5 -F ONE_PG_HA
          "$family" --wait 5 -X ONE_PG_HA
        fi
      done
      rm -- "$SYSTEM_ROOT/systemd/system/one-postgres-ha-firewall.service"
    fi
    if [[ $(owned keepalived_owned) == true ]]; then rm -- "$SYSTEM_ROOT/keepalived/keepalived.conf"; fi
    if [[ $(owned udev_owned) == true ]]; then
      rm -- "$SYSTEM_ROOT/udev/rules.d/70-one-postgres-ha-watchdog.rules"
      udevadm control --reload
    fi
    if [[ $(owned deployment_present) == true && "$CLEANUP_LEVEL" == purge-data ]]; then
      # Audit proved ownership, canonical roots, an SSD mount and no nested mounts.
      # rm does not follow internal symlinks; --one-file-system adds a second boundary.
      rm -rf --one-file-system -- "$DATA/postgres" "$DATA/etcd"
      rm -f -- "$DATA/.one-postgres-ha-join-pending" "$DATA/.one-postgres-ha-cluster"
      rmdir -- "$DATA"
      rm -rf --one-file-system -- "$DEPLOYMENT"
    fi
    systemctl daemon-reload
    ;;
esac
printf '{"node":"%s","phase":"%s","cleanup_level":"%s","status":"complete"}\n' "$NODE" "$PHASE" "$CLEANUP_LEVEL"
