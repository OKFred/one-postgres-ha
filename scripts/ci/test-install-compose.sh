#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
DOCKER_CONFIG="$WORK/valid" bash "$ROOT/scripts/ci/install-compose.sh"
[[ $("$WORK/valid/cli-plugins/docker-compose" version --short) == 5.6.0 ]]

# An invalid download must fail before replacing an existing installation.
mkdir -p "$WORK/bin" "$WORK/corrupt/cli-plugins"
printf 'existing-installation\n' >"$WORK/corrupt/cli-plugins/docker-compose"
cat >"$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  if [[ $1 == --output ]]; then printf 'corrupt-download\n' >"$2"; exit 0; fi
  shift
done
exit 2
SH
chmod 755 "$WORK/bin/curl"
if PATH="$WORK/bin:$PATH" DOCKER_CONFIG="$WORK/corrupt" bash "$ROOT/scripts/ci/install-compose.sh" >"$WORK/rejected.log" 2>&1; then
  echo 'Corrupt Compose download unexpectedly accepted' >&2
  exit 1
fi
[[ $(cat "$WORK/corrupt/cli-plugins/docker-compose") == existing-installation ]]
printf 'PASS: a corrupt Compose download is rejected without replacing the installed plugin\n'
