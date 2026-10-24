#!/usr/bin/env bash
# Isolated version gates and offline restore; no Docker daemon or live database.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 -B - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(sys.argv[1]) / "scripts/data/data.sh").read_text()

def function(name):
    lines = source.splitlines(keepends=True)
    start = next(i for i, line in enumerate(lines) if line.startswith(name + "() {"))
    if lines[start].rstrip().endswith("}"):
        return lines[start]
    end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "}")
    return "".join(lines[start:end + 1])

with tempfile.TemporaryDirectory(prefix="pg17-data-versions-") as temporary:
    fixture = Path(temporary)
    library = fixture / "production.sh"
    names = ("require_pg17_client", "server_version", "require_pg17_server",
             "migration_version_checks", "write_json", "safe_name", "owned_backup",
             "isolated_restore", "restore_test")
    library.write_text("\n".join(function(name) for name in names))
    binary = fixture / "bin"
    binary.mkdir()
    (binary / "docker").write_text(r'''#!/usr/bin/env bash
set -Eeuo pipefail
printf 'docker %s\n' "$*" >>"$VERSION_LOG"
if [[ ${!#} == --version ]]; then
  printf 'pg_dump (PostgreSQL) %s\n' "${CLIENT_VERSION:-17.11}"
elif [[ " $* " == *' --list '* ]]; then
  if [[ $1 == run ]]; then
    [[ " $* " == *' -i '* && " $* " != *' --volume '* && ${!#} == --list ]] || exit 98
    [[ $(cat) == 'fixture archive' ]] || exit 99
  fi
  printf '; Dumped from database version: %s\n; Dumped by pg_dump version: %s\n' \
    "${ARCHIVE_SERVER:-17.10}" "${ARCHIVE_CLIENT:-17.11}"
elif [[ $1 == exec && $3 == pg_restore ]]; then
  :
else
  printf 'Unexpected Docker operation\n' >&2
  exit 97
fi
''')
    (binary / "docker").chmod(0o755)
    body = fixture / "case.sh"
    body.write_text(r'''#!/usr/bin/env bash
set -Eeuo pipefail
source "$VERSION_LIBRARY"
die() { printf 'data: %s\n' "$*" >&2; exit 1; }
root=$VERSION_ROOT
owner_file=$root/.one-postgres-ha-data.json
cluster=fixture
here=$VERSION_SQL
image=postgres@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
client_version_checked=false
work=$root/backup-20261024T000000-1
restore_container=''
sql() {
  local query
  query=$(cat)
  printf 'live-sql %s %s\n' "$1" "$query" >>"$VERSION_LOG"
  [[ $query == 'SHOW server_version_num;' ]] || exit 91
  case "$1" in
    source) printf '%s\n' "${SOURCE_VERSION:-170010}" ;;
    target) printf '%s\n' "${TARGET_VERSION:-170011}" ;;
    *) exit 92 ;;
  esac
}
control_id() { printf 'forbidden live identity\n' >>"$VERSION_LOG"; exit 93; }
start_restore() { printf 'restore-start\n' >>"$VERSION_LOG"; restore_container=isolated-fixture; }
restore_sql() {
  local query
  query=$(cat)
  printf 'isolated-sql %s\n' "$query" >>"$VERSION_LOG"
  if [[ $query == 'SHOW server_version_num;' ]]; then
    printf '%s\n' "${RESTORE_VERSION:-170011}"
  fi
}
case "$VERSION_ACTION" in
  gate) migration_version_checks ;;
  restore) restore_test ;;
  *) exit 94 ;;
esac
''')
    log = fixture / "calls"
    sql_dir = fixture / "sql"
    sql_dir.mkdir()
    (sql_dir / "sql").mkdir()
    for name in ("fingerprint.sql", "verify-sequences.sql"):
        (sql_dir / "sql" / name).write_text("")

    def run(action="gate", **extra):
        root = fixture / "backups"
        root.mkdir(exist_ok=True)
        archive = root / "backup-20261024T000000-1"
        archive.mkdir(exist_ok=True)
        (root / "state").mkdir(exist_ok=True)
        identity = "1111111111111111111"
        (root / ".one-postgres-ha-data.json").write_text(json.dumps({"system_identifier": identity}))
        (archive / "manifest.json").write_text(json.dumps({
            "complete": True, "cluster_name": "fixture", "system_identifier": identity}))
        (archive / "app.dump").write_text("fixture archive\n")
        (archive / "app.fingerprint").write_text("")
        subprocess.run(["sha256sum", "app.dump", "app.fingerprint"], cwd=archive,
                       stdout=(archive / "SHA256SUMS").open("w"), check=True)
        (root / "state/latest-backup").write_text(str(archive) + "\n")
        (archive / "restore-test.json").unlink(missing_ok=True)
        log.write_text("")
        env = os.environ | extra | {
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "VERSION_LIBRARY": str(library), "VERSION_ROOT": str(root),
            "VERSION_SQL": str(sql_dir), "VERSION_LOG": str(log), "VERSION_ACTION": action}
        result = subprocess.run(["bash", str(body)], env=env, text=True,
                                capture_output=True, timeout=15, check=False)
        return result, log.read_text(), archive

    result, calls, _ = run(CLIENT_VERSION="17.9", SOURCE_VERSION="170011", TARGET_VERSION="170010")
    assert result.returncode == 0, result.stderr
    assert "live-sql source" in calls and "live-sql target" in calls
    for values in ({"CLIENT_VERSION": "18.6"}, {"SOURCE_VERSION": "180006"},
                   {"TARGET_VERSION": "180006"}, {"SOURCE_VERSION": "190000"},
                   {"TARGET_VERSION": "bad response"}):
        result, calls, _ = run(**values)
        assert result.returncode != 0, values
        assert "restore-start" not in calls and "--file" not in calls
    for values in ({"ARCHIVE_SERVER": "18.6"}, {"ARCHIVE_CLIENT": "18.6"},
                   {"CLIENT_VERSION": "18.6"}):
        result, calls, archive = run("restore", **values)
        assert result.returncode != 0, values
        assert "restore-start" not in calls and "live-sql" not in calls
        assert not (archive / "restore-test.json").exists()
    result, calls, archive = run("restore", RESTORE_VERSION="180006")
    assert result.returncode != 0 and "restore-start" in calls
    assert "--clean" not in calls and "live-sql" not in calls
    assert not (archive / "restore-test.json").exists()
    result, calls, archive = run("restore")
    assert result.returncode == 0, result.stderr
    assert "live-sql" not in calls and "forbidden live identity" not in calls
    report = json.loads((archive / "restore-test.json").read_text())
    assert report["passed"] and report["system_identifier"] == "1111111111111111111"
    print("PASS: PG17 minor flexibility, client/server/archive major refusal and offline owned-backup restore")
PY
