#!/usr/bin/env bash
# Exercises only temporary directories and a Docker command stub; no site access.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/bin"
cat >"$fixture/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
case $1 in
  ps) exit 0 ;;
  run)
    if [[ ${!#} == --version ]]; then printf 'pg_dump (PostgreSQL) 17.11\n'; exit 0; fi
    query=$(cat)
    if [[ $query == 'SHOW server_version_num;' ]]; then printf '170011\n'; exit 0; fi
    [[ $query = 'SELECT system_identifier FROM pg_control_system();' ]] || exit 97
    printf '%s\n' "${FIXTURE_CONTROL_ID:?}"
    ;;
  *) exit 97 ;;
esac
STUB
chmod +x "$fixture/bin/docker"
export PATH="$fixture/bin:$PATH"
script="$repo/scripts/data/data.sh"
cluster=cluster_a
root="$fixture/backups"
config="$fixture/config.json"
owner_file="$root/.one-postgres-ha-data.json"
write_config() {
  jq -n --arg cluster "$1" --arg directory "$2" \
    '{cluster_name:$cluster,directory:$directory,postgres_image:("postgres@sha256:"+("a"*64))}' >"$config"
}
run_data() { HA_DATA_CONFIG="$config" bash "$script" "$@"; }
refused() {
  if ("$@") >"$fixture/refused.log" 2>&1; then
    printf 'Expected refusal: %s\n' "$*" >&2
    exit 1
  fi
}

# An unknown nonempty path must remain byte-for-byte untouched.
mkdir "$fixture/unknown"
printf 'keep this data\n' >"$fixture/unknown/sentinel"
write_config "$cluster" "$fixture/unknown"
refused run_data prepare-directory
grep -Fq 'nonempty and unowned' "$fixture/refused.log"
[[ $(find "$fixture/unknown" -mindepth 1 -maxdepth 1 | wc -l) = 1 ]]
[[ $(cat "$fixture/unknown/sentinel") = 'keep this data' ]]

# An empty directory is claimed once; the same path cannot be used by cluster B.
write_config "$cluster" "$root"
run_data prepare-directory >"$fixture/prepared.log"
grep -qx 'data directory initialized' "$fixture/prepared.log"
run_data prepare-directory >"$fixture/prepared.log"
grep -qx 'data directory ownership verified' "$fixture/prepared.log"
write_config cluster_b "$root"
refused run_data prepare-directory
grep -Fq 'another cluster' "$fixture/refused.log"
jq -e '.cluster_name=="cluster_a" and .system_identifier==null' "$owner_file" >/dev/null
write_config "$cluster" "$root"

# Parent symlinks and symlinked internal directories cannot redirect writes.
ln -s "$fixture" "$fixture/alias"
write_config "$cluster" "$fixture/alias/backups"
refused run_data prepare-directory
grep -Fq 'without symlinks' "$fixture/refused.log"
mkdir "$fixture/internal-link" "$fixture/outside"
cp "$owner_file" "$fixture/internal-link/.one-postgres-ha-data.json"
ln -s "$fixture/outside" "$fixture/internal-link/state"
write_config "$cluster" "$fixture/internal-link"
refused run_data prepare-directory
grep -Fq 'unsafe data subdirectory' "$fixture/refused.log"
[[ -z $(find "$fixture/outside" -mindepth 1 -print -quit) ]]
mkdir "$fixture/marker-link" "$fixture/invalid-marker"
ln -s "$owner_file" "$fixture/marker-link/.one-postgres-ha-data.json"
write_config "$cluster" "$fixture/marker-link"
refused run_data prepare-directory
grep -Fq 'marker must be a regular file' "$fixture/refused.log"
jq 'del(.system_identifier)' "$owner_file" >"$fixture/invalid-marker/.one-postgres-ha-data.json"
write_config "$cluster" "$fixture/invalid-marker"
refused run_data prepare-directory
grep -Fq 'invalid ownership marker' "$fixture/refused.log"
write_config "$cluster" "$root"

# Load the exact production functions; retention really removes fixture files.
for function_name in write_json bind_backup_identity owned_backup retain_backups; do
  awk -v name="$function_name" '$0==name"() {" {copy=1} copy {print} copy && /^\}$/ {exit}' "$script" >>"$fixture/functions.sh"
done
# shellcheck source=/dev/null
source "$fixture/functions.sh"
die() { printf 'data: %s\n' "$*" >&2; exit 1; }
bind_backup_identity 1111111111111111111
refused bind_backup_identity 2222222222222222222
grep -Fq 'another PostgreSQL instance' "$fixture/refused.log"
jq -e '.system_identifier=="1111111111111111111"' "$owner_file" >/dev/null

# Exercise the real backup CLI with a different instance identity. It must stop
# before creating an archive or requesting any SQL besides the identity query.
printf 'temporary-test-password\n' >"$fixture/password"
jq --arg password "$fixture/password" \
  '.target={host:"192.0.2.1",port:5432,user:"postgres",password_file:$password}' "$config" >"$fixture/config.tmp"
mv "$fixture/config.tmp" "$config"
export FIXTURE_CONTROL_ID=2222222222222222222
refused run_data backup
grep -Fq 'another PostgreSQL instance' "$fixture/refused.log"
[[ -z $(find "$root" -mindepth 1 -maxdepth 1 -name 'backup-*' -print -quit) ]]
[[ ! -e $root/state/.pgpass-target ]]

make_backup() {
  local path="$root/$1"
  mkdir "$path"
  jq -n --arg cluster "$2" --arg id "$3" --argjson complete "${4:-true}" \
    '{complete:$complete,cluster_name:$cluster,system_identifier:$id}' >"$path/manifest.json"
  printf 'archive fixture\n' >"$path/archive.dump"
}
for ((i = 1; i <= 17; i++)); do
  printf -v name 'backup-202501%02dT000000-1' "$i"
  make_backup "$name" "$cluster" 1111111111111111111
done
make_backup backup-20240101T000000-1 cluster_b 1111111111111111111
make_backup backup-20240102T000000-1 "$cluster" 2222222222222222222
make_backup backup-20240103T000000-1 "$cluster" 1111111111111111111 false
make_backup backup-20240104T000000-1 "$cluster" 1111111111111111111
printf '{invalid json\n' >"$root/backup-20240104T000000-1/manifest.json"
make_backup backup-20240105T000000-1 "$cluster" 1111111111111111111
mv "$root/backup-20240105T000000-1/manifest.json" "$fixture/external-manifest.json"
ln -s "$fixture/external-manifest.json" "$root/backup-20240105T000000-1/manifest.json"
mkdir "$fixture/external-backup"
cp "$fixture/external-manifest.json" "$fixture/external-backup/manifest.json"
printf 'preserve external data\n' >"$fixture/external-backup/sentinel"
ln -s "$fixture/external-backup" "$root/backup-20240106T000000-1"
make_backup backup-20-unrecognized "$cluster" 1111111111111111111

retain_backups 1111111111111111111
for ((i = 1; i <= 17; i++)); do
  printf -v name 'backup-202501%02dT000000-1' "$i"
  if ((i <= 3)); then [[ ! -e $root/$name ]]; else [[ -f $root/$name/archive.dump ]]; fi
done
[[ $(find "$root" -maxdepth 1 -type d -name 'backup-202501*' | wc -l) = 14 ]]
for ((i = 1; i <= 6; i++)); do
  printf -v name 'backup-202401%02dT000000-1' "$i"
  [[ -d $root/$name ]]
done
[[ -d $root/backup-20-unrecognized ]]
[[ $(cat "$fixture/external-backup/sentinel") = 'preserve external data' ]]

# A forged latest pointer cannot make restore-test accept a foreign archive.
printf '%s\n' "$root/backup-20240101T000000-1" >"$root/state/latest-backup"
refused run_data restore-test
grep -Fq 'latest backup does not belong' "$fixture/refused.log"
mv "$root/state/latest-backup" "$fixture/external-latest"
ln -s "$fixture/external-latest" "$root/state/latest-backup"
refused run_data restore-test
grep -Fq 'latest-backup must not be a symlink' "$fixture/refused.log"
printf 'PASS: backup roots reject foreign ownership and unsafe paths; retention keeps 14 owned complete archives and preserves foreign/incomplete backups\n'
